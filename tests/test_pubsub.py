import base64
import json
import os
import warnings

import numpy as np
import pytest

warnings.filterwarnings("ignore", category=DeprecationWarning)

from fastapi.testclient import TestClient

from src.ingestion.pipeline import MissingFieldsError, StreamingDetector, format_result
from src.serving.api import app
from src.serving.pubsub import PubSubEnvelopeError, decode_envelope

ARTIFACT_DIR = os.environ.get("ARTIFACT_DIR", "artifacts")
DATASET = os.environ.get("DATASET", "univariate")


def _artifacts_present() -> bool:
    return all(
        os.path.exists(os.path.join(ARTIFACT_DIR, f"{DATASET}_{suffix}"))
        for suffix in ("ewma.pkl", "lstm.pt", "scaler.pkl")
    )


needs_artifacts = pytest.mark.skipif(
    not _artifacts_present(), reason="Artifacts not present — run train.py first"
)


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


def envelope(payload) -> dict:
    """Wrap a payload the way Pub/Sub push wraps it."""
    if isinstance(payload, (dict, list)):
        payload = json.dumps(payload)
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    return {
        "message": {
            "data": base64.b64encode(payload).decode("utf-8"),
            "messageId": "1",
            "publishTime": "2024-01-01T00:00:00Z",
        },
        "subscription": "projects/p/subscriptions/s",
    }


# ------------------------------------------------------------------
# Envelope decoding
# ------------------------------------------------------------------

def test_decode_envelope_roundtrip():
    row = {"timestamp": "2024-01-01T00:00:00", "value": 1.23}
    assert decode_envelope(envelope(row)) == row


@pytest.mark.parametrize(
    "body",
    [
        {},                                          # no message
        {"message": "not-an-object"},
        {"message": {}},                             # no data
        {"message": {"data": "!!!not-base64!!!"}},
        {"message": {"data": base64.b64encode(b"not json").decode()}},
        {"message": {"data": base64.b64encode(b'["a","list"]').decode()}},
    ],
)
def test_decode_envelope_rejects_malformed(body):
    with pytest.raises(PubSubEnvelopeError):
        decode_envelope(body)


# ------------------------------------------------------------------
# The push endpoint's ack contract
#
# Pub/Sub redelivers anything non-2xx. A message that can never parse must be
# ACKED, or it is redelivered until the retention window expires.
# ------------------------------------------------------------------

@needs_artifacts
def test_push_acks_valid_row(client):
    r = client.post("/pubsub/push", json=envelope({"timestamp": "t", "value": 0.5}))
    assert r.status_code == 204


@needs_artifacts
@pytest.mark.parametrize(
    "body",
    [
        {"message": {"data": base64.b64encode(b"not json").decode()}},
        {"message": {}},
        {"garbage": True},
    ],
)
def test_push_acks_poison_messages(client, body):
    """Malformed input is acked, not nacked — the dead-letter topic handles it."""
    r = client.post("/pubsub/push", json=body)
    assert r.status_code == 204


@needs_artifacts
def test_push_acks_row_missing_features(client):
    r = client.post("/pubsub/push", json=envelope({"timestamp": "t"}))
    assert r.status_code == 204


# ------------------------------------------------------------------
# StreamingDetector
# ------------------------------------------------------------------

@needs_artifacts
def test_detector_is_silent_until_window_fills():
    det = StreamingDetector(dataset=DATASET, artifact_dir=ARTIFACT_DIR)
    col = det.feature_cols[0]

    for i in range(det.window_size - 1):
        assert det.handle({"timestamp": str(i), col: 0.5}) is None
    assert not det.warm

    result = det.handle({"timestamp": "last", col: 0.5})
    assert det.warm
    assert result is not None
    assert set(result) == {"timestamp", "is_anomaly", "ewma", "lstm"}
    assert isinstance(result["is_anomaly"], bool)
    assert isinstance(result["ewma"]["score"], float)
    assert isinstance(result["lstm"]["score"], float)


@needs_artifacts
def test_detector_rejects_missing_fields():
    det = StreamingDetector(dataset=DATASET, artifact_dir=ARTIFACT_DIR)
    with pytest.raises(MissingFieldsError):
        det.handle({"timestamp": "t"})


@needs_artifacts
def test_detector_scores_every_row_once_warm():
    """Past the window size, every row produces a result — the buffer slides."""
    det = StreamingDetector(dataset=DATASET, artifact_dir=ARTIFACT_DIR)
    col = det.feature_cols[0]
    values = np.linspace(0, 1, det.window_size + 10)

    results = [det.handle({"timestamp": str(i), col: float(v)}) for i, v in enumerate(values)]
    assert all(r is None for r in results[: det.window_size - 1])
    assert all(r is not None for r in results[det.window_size - 1 :])


@needs_artifacts
def test_format_result_is_one_line():
    det = StreamingDetector(dataset=DATASET, artifact_dir=ARTIFACT_DIR)
    col = det.feature_cols[0]
    result = None
    for i in range(det.window_size):
        result = det.handle({"timestamp": str(i), col: 0.5})
    line = format_result(result)
    assert "\n" not in line
    assert "ewma=" in line and "lstm=" in line
