# Real-Time Anomaly Detection Platform

[![CI](https://github.com/KTujjar/anomaly-detection/actions/workflows/ci.yml/badge.svg)](https://github.com/KTujjar/anomaly-detection/actions/workflows/ci.yml)

A production-grade streaming anomaly detection service that compares a classical statistical detector (EWMA + 3-sigma) against a PyTorch LSTM Autoencoder, deployed as a containerized API on Kubernetes.

## Architecture

Ingestion is pluggable. `StreamingDetector` (`src/ingestion/pipeline.py`) owns the
rolling window and both models, and two sources feed it:

```
  LOCAL                                    CLOUD
  Kafka  ──┐                        Pub/Sub ──┐
           │  (pull loop)                     │  (push, HTTPS POST)
           ▼                                  ▼
      kafka_consumer.py                  /pubsub/push
           └──────────────┬───────────────────┘
                          ▼
                  StreamingDetector
                  (rolling 50-row window)
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
       EWMA (SciPy)          LSTM Autoencoder (PyTorch)

  Serving: FastAPI  →  Docker  →  Cloud Run (deployed) or Kubernetes (local)
```

Both paths run identical detection code. Kafka is the local development story;
Pub/Sub is what runs in the cloud.

## Key Finding

> The EWMA statistical baseline matches or exceeds the LSTM on univariate signals. The LSTM wins on multivariate correlated anomalies where temporal cross-signal patterns matter. Use both: EWMA as a fast first-pass alert, LSTM for high-value signals where false negatives are costly.

See `notebooks/03_comparison.ipynb` for the full analysis.

## Quickstart

### 1. Install dependencies
```bash
pip install -r requirements.txt
```

### 2. Generate synthetic data
```bash
python data/generate_data.py
```

### 3. Train the LSTM model
```bash
python src/training/train.py
```

### 4. Run the API locally
```bash
uvicorn src.serving.api:app --reload --port 8080
```

### 5. Test the API
```bash
curl -X POST http://localhost:8080/predict \
  -H "Content-Type: application/json" \
  -d '{"windows": [[0.1, 0.2, 0.3, 0.4, 0.5, 0.4, 0.3, 0.2, 0.1, 0.0]], "model": "both"}'
```

### 6. Run with Docker (includes Kafka)
```bash
docker-compose up --build
```

### 7. Deploy to Kubernetes (local)
```bash
minikube start
eval $(minikube docker-env)
docker build -t anomaly-api:latest .
kubectl apply -f k8s/
kubectl port-forward svc/anomaly-api 8080:8080
```

`k8s/` includes a HorizontalPodAutoscaler. This path targets a local minikube
cluster (`imagePullPolicy: Never`); the cloud path below is what actually runs.

---

## Deployment on Google Cloud

Infrastructure lives in `terraform/` and is applied by `.github/workflows/deploy.yml`.
Nothing is provisioned by hand.

| Piece | What it does |
|---|---|
| Artifact Registry | Holds the serving image, tagged by commit SHA |
| Cloud Run `anomaly-api` | Public. `/health`, `/ready`, `/metrics`, `POST /predict` |
| Cloud Run `anomaly-consumer` | Private. Receives Pub/Sub push at `/pubsub/push` |
| Pub/Sub | `anomaly-events` topic, push subscription, dead-letter topic |
| Workload Identity Federation | Lets GitHub Actions deploy with no service-account key |

### Two services, one image

They run the same container and differ only in scaling and IAM, because the two
endpoints have incompatible needs:

- **`/predict` is stateless.** Every request carries its own complete windows, so it
  scales freely.
- **`/pubsub/push` is not.** It feeds a rolling in-memory buffer, so a second instance
  would see half the stream and score every window against incomplete data.

The consumer is therefore pinned to `max_instance_count = 1`, enforced by a validation
block in `terraform/variables.tf`. Running one combined service would drag the public
API down to a single instance too.

**Known limitation:** that pin is the ceiling on throughput. Sharding would mean moving
the buffer out of process — keyed per series in Firestore or Memorystore — which is the
right fix if this ever needed to handle more than one stream.

### Authentication

Push requests are signed by Pub/Sub with an OIDC token and verified by Cloud Run IAM
before they reach the container, so there is no shared secret and no auth middleware in
the app. Only the push service account holds `roles/run.invoker` on the consumer.

The deploy has no long-lived credential either: GitHub mints a short-lived OIDC token
per run and Google exchanges it, gated by an attribute condition pinning the identity
pool to this repository.

### Cost

Built to sit near zero when idle:

- `min_instance_count = 0` on both services — no traffic, no instance, no charge
- `cpu_idle = true` — CPU billed while a request is in flight, not per instance-hour
- `max_instance_count` caps what a public endpoint can spend
- Registry cleanup policy deletes untagged images after a week
- Optional budget alert at 50/90/100% and on forecast (`billing_account` variable)
- Pub/Sub at demo volume sits inside the free tier

`terraform -chdir=terraform destroy` returns spend to zero.

> Verify current Cloud Run and Pub/Sub free-tier limits before deploying — they change.

### First-time setup

```bash
# 1. Bootstrap: state bucket, WIF pool, deployer service account. Once, by hand.
cd terraform/bootstrap
terraform init
terraform apply -var project_id=YOUR_PROJECT_ID

# 2. Copy the three outputs into GitHub repository VARIABLES (Settings →
#    Secrets and variables → Actions → Variables). None are secret — WIF has no
#    key material.
#      GCP_PROJECT_ID
#      GCP_WORKLOAD_IDENTITY_PROVIDER
#      GCP_DEPLOYER_SA
#      TF_STATE_BUCKET

# 3. Push to master. The workflow trains, builds, pushes, applies, and smoke-tests.
```

### Proving it end to end

```bash
API_URL=$(terraform -chdir=terraform output -raw api_url)
curl "$API_URL/ready"        # 200 proves model artifacts are baked into the image

python scripts/publish_sample.py --project YOUR_PROJECT_ID --rows 200
gcloud run services logs read anomaly-consumer --region us-central1 --limit 20

# Dead-letter path: these are acked, not retried forever, then routed after
# maxDeliveryAttempts.
python scripts/publish_sample.py --project YOUR_PROJECT_ID --poison
gcloud pubsub subscriptions pull anomaly-events-dead-letter-inspect --auto-ack
```

The consumer stays silent until the 50-row window fills — publishing fewer rows than
that produces no output, which looks like a failure and is not.

## Project Structure

```
├── data/
│   ├── generate_data.py      # Synthetic dataset generator
│   └── sample/               # Generated CSVs (gitignored)
├── notebooks/
│   ├── 01_eda_and_baseline.ipynb
│   ├── 02_lstm_autoencoder.ipynb
│   └── 03_comparison.ipynb   # Head-to-head results
├── src/
│   ├── ingestion/
│   │   ├── features.py       # Pandas feature engineering
│   │   ├── pipeline.py       # StreamingDetector — shared by both sources
│   │   └── kafka_consumer.py # Kafka pull loop (local)
│   ├── models/
│   │   ├── statistical.py    # EWMA + 3-sigma detector
│   │   └── lstm_autoencoder.py  # PyTorch LSTM Autoencoder
│   ├── serving/
│   │   ├── api.py            # FastAPI inference service
│   │   └── pubsub.py         # Pub/Sub push endpoint (cloud)
│   └── training/
│       └── train.py          # End-to-end training script
├── scripts/
│   └── publish_sample.py     # Publish rows to Pub/Sub
├── terraform/
│   ├── bootstrap/            # State bucket + WIF — applied once by hand
│   └── *.tf                  # Cloud Run, Pub/Sub, IAM — applied by CI
├── k8s/                      # Kubernetes manifests (local minikube)
├── tests/                    # pytest suite
├── Dockerfile
└── docker-compose.yml
```

## Running Tests

```bash
pytest tests/ -v
```

Tests that need trained models skip cleanly when `artifacts/` is empty, so a fresh
clone runs green without training first.

## Tech Stack

- **PyTorch** — LSTM Autoencoder for temporal anomaly detection
- **SciPy / Pandas** — Statistical baseline and feature engineering
- **FastAPI** — Async inference API
- **Kafka** — Streaming ingestion (local)
- **Google Cloud Pub/Sub** — Streaming ingestion (deployed)
- **Docker** — Containerization
- **Terraform** — Infrastructure as code for every cloud resource
- **Google Cloud Run** — Serverless deployment, scale to zero
- **GitHub Actions** — CI and keyless deploys via Workload Identity Federation
- **Kubernetes** — Local deployment with HPA auto-scaling
- **Jupyter** — Experimentation and comparison reports
