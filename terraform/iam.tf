# =============================================================================
# Service accounts.
#
# Two, deliberately. Cloud Run's default compute service account is broadly
# privileged; running the app as a dedicated account with no project roles means
# a compromised container can do nothing but serve HTTP.
# =============================================================================

# The identity the containers run as. It holds NO project-level roles -- the
# services only need to receive requests and write logs, both of which come for
# free with the Cloud Run runtime.
resource "google_service_account" "runtime" {
  account_id   = "anomaly-runtime"
  display_name = "Anomaly detection runtime"
  description  = "Identity the Cloud Run services run as. Intentionally holds no project roles."

  depends_on = [google_project_service.required]
}

# The identity Pub/Sub uses to CALL the consumer service. Pub/Sub signs each push
# with an OIDC token for this account; Cloud Run verifies it at the edge and
# rejects anything unsigned. That is why the app needs no auth middleware.
resource "google_service_account" "pubsub_push" {
  account_id   = "anomaly-pubsub-push"
  display_name = "Pub/Sub push invoker"
  description  = "Signs push requests to the consumer service"

  depends_on = [google_project_service.required]
}

# The ONLY principal allowed to invoke the private consumer service.
resource "google_cloud_run_v2_service_iam_member" "consumer_invoker" {
  project  = google_cloud_run_v2_service.consumer.project
  location = google_cloud_run_v2_service.consumer.location
  name     = google_cloud_run_v2_service.consumer.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pubsub_push.email}"
}

# The API service is PUBLIC -- a deliberate choice, so the URL is clickable from
# a portfolio without a gcloud identity token. The exposure is bounded by
# api_max_instances and by the budget alert in budget.tf; /predict is pure
# inference over the request body and touches no storage.
resource "google_cloud_run_v2_service_iam_member" "api_public" {
  project  = google_cloud_run_v2_service.api.project
  location = google_cloud_run_v2_service.api.location
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Pub/Sub's own service agent needs this to mint OIDC tokens for push delivery.
data "google_project" "current" {}

resource "google_project_iam_member" "pubsub_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"

  depends_on = [google_project_service.required]
}
