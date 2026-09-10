"""
Source-agnostic streaming detection pipeline.

This is the logic that used to live inside `run_consumer()` in kafka_consumer.py,
welded to a `for message in consumer:` loop. Pulling it out leaves one seam between
"where the events come from" and "what we do with them", so the same detection path
serves both ingestion sources:

    Kafka pull   -> src/ingestion/kafka_consumer.py  (local dev, docker-compose)
    Pub/Sub push -> src/serving/pubsub.py            (Cloud Run)

State note: the rolling buffer is IN MEMORY. One StreamingDetector sees one stream.
Running two copies against the same topic gives each a partial view, so every window
is scored against incomplete data. The Cloud Run consumer service is pinned to a
single instance for exactly this reason -- see terraform/run.tf. Sharding by series
would mean moving the buffer into Firestore or Memorystore and keying it per series.
"""

import os
from collections import deque
from typing import Optional

import pandas as pd

from src.ingestion.features import Normalizer, sliding_windows
from src.models.lstm_autoencoder import AnomalyDetector as LSTMDetector
from src.models.statistical import EWMADetector

ARTIFACT_DIR = "artifacts"
WINDOW_SIZE = 50


def load_artifacts(dataset: str, artifact_dir: str = ARTIFACT_DIR):
    """Load the EWMA detector, LSTM detector and fitted Normalizer for a dataset."""
    ewma = EWMADetector.load(os.path.join(artifact_dir, f"{dataset}_ewma.pkl"))
    lstm = LSTMDetector.load(os.path.join(artifact_dir, f"{dataset}_lstm.pt"))
    normalizer = Normalizer.load(os.path.join(artifact_dir, f"{dataset}_scaler.pkl"))
    return ewma, lstm, normalizer


class MissingFieldsError(ValueError):
    """A message arrived without every feature column the detectors expect."""


class StreamingDetector:
    """
    Scores a stream of rows one at a time, holding the last WINDOW_SIZE of them.

    Feed it with handle(). It returns None while the buffer is still filling, then a
    result dict for every row once it is full.
    """

    def __init__(
        self,
        dataset: str = "univariate",
        artifact_dir: str = ARTIFACT_DIR,
        window_size: int = WINDOW_SIZE,
    ) -> None:
        self.dataset = dataset
        self.window_size = window_size
        self.ewma, self.lstm, self.normalizer = load_artifacts(dataset, artifact_dir)
        self.feature_cols = self.ewma.feature_cols
        self._buffer: deque = deque(maxlen=window_size)

    @property
    def warm(self) -> bool:
        """True once enough rows have arrived to score a full window."""
        return len(self._buffer) >= self.window_size

    def handle(self, row: dict) -> Optional[dict]:
        """
        Add one row to the rolling buffer and score it if the window is full.

        Returns None while the buffer is still filling. Raises MissingFieldsError if
        the row is missing a feature column -- callers decide whether that is a skip
        (Kafka) or a dead-letter (Pub/Sub).
        """
        values = {col: row.get(col) for col in self.feature_cols}
        missing = [col for col, v in values.items() if v is None]
        if missing:
            raise MissingFieldsError(f"missing feature columns: {missing}")

        self._buffer.append(values)
        if not self.warm:
            return None

        df = pd.DataFrame(list(self._buffer))
        df_norm = self.normalizer.transform(df)

        # EWMA scores the most recent point
        _, ewma_flags = self.ewma.predict(df_norm)
        ewma_anomaly = bool(ewma_flags[-1])
        ewma_score = float(self.ewma.anomaly_score(df_norm)[-1])

        # LSTM scores the whole window
        windows, _ = sliding_windows(
            df_norm, self.feature_cols, window_size=self.window_size, step=self.window_size
        )
        lstm_scores, lstm_flags = self.lstm.predict(windows)
        lstm_anomaly = bool(lstm_flags[0])
        lstm_score = float(lstm_scores[0])

        return {
            "timestamp": row.get("timestamp", "unknown"),
            "is_anomaly": ewma_anomaly or lstm_anomaly,
            "ewma": {"score": ewma_score, "is_anomaly": ewma_anomaly},
            "lstm": {"score": lstm_score, "is_anomaly": lstm_anomaly},
        }


def format_result(result: dict) -> str:
    """One-line human readable rendering, matching the original consumer output."""
    status = "ANOMALY" if result["is_anomaly"] else "normal"
    ewma, lstm = result["ewma"], result["lstm"]
    return (
        f"[{result['timestamp']}]  {status:8s}  "
        f"ewma={ewma['score']:.4f}({'!' if ewma['is_anomaly'] else ' '})  "
        f"lstm={lstm['score']:.6f}({'!' if lstm['is_anomaly'] else ' '})"
    )
