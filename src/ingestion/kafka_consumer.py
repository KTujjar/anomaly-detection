"""
Kafka consumer that feeds live time-series data through both detectors.

Reads JSON messages from a Kafka topic and hands each row to the shared
StreamingDetector in src/ingestion/pipeline.py, which owns the rolling window and
both models. Anomaly flags are printed and can be forwarded to any downstream sink
(alerting, database, another topic).

This is the local development path -- `docker-compose up` brings up Kafka alongside
the API. The deployed path on Cloud Run uses Pub/Sub push instead; both run the same
detection code.

Message format expected on the topic:
    {"timestamp": "2024-01-01T00:00:00", "value": 1.23}          # univariate
    {"timestamp": "...", "signal_0": 1.2, "signal_1": 0.9, ...}  # multivariate

Usage:
    python -m src.ingestion.kafka_consumer \
        --topic sensor-metrics \
        --bootstrap-servers localhost:9092 \
        --dataset univariate
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(__file__))))

from src.ingestion.pipeline import (  # noqa: E402
    ARTIFACT_DIR,
    MissingFieldsError,
    StreamingDetector,
    format_result,
)


def run_consumer(topic: str, bootstrap_servers: str, dataset: str) -> None:
    from kafka import KafkaConsumer

    print(f"Loading artifacts for dataset='{dataset}'...")
    detector = StreamingDetector(dataset=dataset, artifact_dir=ARTIFACT_DIR)
    print(f"  Features: {detector.feature_cols}")
    print(f"  Connecting to Kafka at {bootstrap_servers}, topic='{topic}'")

    consumer = KafkaConsumer(
        topic,
        bootstrap_servers=bootstrap_servers,
        value_deserializer=lambda m: json.loads(m.decode("utf-8")),
        auto_offset_reset="latest",
        enable_auto_commit=True,
        group_id="anomaly-detector",
    )

    print(f"Listening on topic '{topic}'... (Ctrl-C to stop)\n")

    for message in consumer:
        row = message.value
        try:
            result = detector.handle(row)
        except MissingFieldsError as exc:
            print(f"[SKIP] {exc} in message: {row}")
            continue

        if result is None:
            continue  # not enough data yet to fill a window

        print(format_result(result))


def main() -> None:
    parser = argparse.ArgumentParser(description="Kafka anomaly detection consumer")
    parser.add_argument("--topic", default="sensor-metrics")
    parser.add_argument("--bootstrap-servers", default="localhost:9092")
    parser.add_argument("--dataset", choices=["univariate", "multivariate"], default="univariate")
    args = parser.parse_args()

    run_consumer(args.topic, args.bootstrap_servers, args.dataset)


if __name__ == "__main__":
    main()
