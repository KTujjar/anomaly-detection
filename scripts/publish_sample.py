"""
Publish generated rows to a Pub/Sub topic, so the deployed pipeline can be proven
end to end.

This is the only file in the repo that needs google-cloud-pubsub. It is a developer
tool, never part of the serving image -- which is why the dependency lives in
requirements.txt and NOT in requirements-serving.txt.

Prerequisites:
    python data/generate_data.py --rows 5000
    gcloud auth application-default login

Usage:
    python scripts/publish_sample.py --project <PROJECT_ID> --topic anomaly-events
    python scripts/publish_sample.py --project <PROJECT_ID> --dataset multivariate --rows 200
    python scripts/publish_sample.py --project <PROJECT_ID> --poison   # dead-letter check
"""

import argparse
import json
import os
import sys

import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

FEATURE_COLS = {
    "univariate": ["value"],
    "multivariate": ["signal_0", "signal_1", "signal_2"],
}


def publish_rows(project: str, topic: str, dataset: str, rows: int, sample_dir: str) -> None:
    from google.cloud import pubsub_v1

    csv_path = os.path.join(sample_dir, f"{dataset}.csv")
    if not os.path.exists(csv_path):
        raise SystemExit(
            f"{csv_path} not found -- run `python data/generate_data.py` first"
        )

    df = pd.read_csv(csv_path).head(rows)
    cols = FEATURE_COLS[dataset]

    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(project, topic)
    print(f"Publishing {len(df)} rows to {topic_path}")

    futures = []
    for _, row in df.iterrows():
        payload = {"timestamp": str(row["timestamp"])}
        payload.update({col: float(row[col]) for col in cols})
        futures.append(publisher.publish(topic_path, json.dumps(payload).encode("utf-8")))

    for future in futures:
        future.result()

    # The consumer holds a rolling window and stays silent until it fills, so a run
    # shorter than the window size produces no output at all -- which looks like a
    # failure but is not.
    print(f"Published {len(df)} rows")
    if len(df) < 50:
        print("NOTE: fewer rows than the 50-row window -- the consumer will not score any yet")


def publish_poison(project: str, topic: str) -> None:
    """Publish messages the consumer cannot use, to exercise the dead-letter path."""
    from google.cloud import pubsub_v1

    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(project, topic)

    bad = [
        b"this is not json",
        json.dumps({"timestamp": "2024-01-01T00:00:00"}).encode("utf-8"),  # no features
        json.dumps(["not", "an", "object"]).encode("utf-8"),
    ]
    for payload in bad:
        publisher.publish(topic_path, payload).result()

    print(f"Published {len(bad)} malformed messages to {topic_path}")
    print("Each is acked by the push endpoint; check the dead-letter topic and the logs")


def main() -> None:
    parser = argparse.ArgumentParser(description="Publish sample rows to Pub/Sub")
    parser.add_argument("--project", required=True, help="GCP project ID")
    parser.add_argument("--topic", default="anomaly-events")
    parser.add_argument("--dataset", choices=["univariate", "multivariate"], default="univariate")
    parser.add_argument("--rows", type=int, default=200)
    parser.add_argument("--sample-dir", default="data/sample")
    parser.add_argument(
        "--poison",
        action="store_true",
        help="publish malformed messages instead, to test the dead-letter path",
    )
    args = parser.parse_args()

    if args.poison:
        publish_poison(args.project, args.topic)
    else:
        publish_rows(args.project, args.topic, args.dataset, args.rows, args.sample_dir)


if __name__ == "__main__":
    main()
