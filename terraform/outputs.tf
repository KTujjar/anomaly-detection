output "api_url" {
  value       = google_cloud_run_v2_service.api.uri
  description = "Public HTTPS URL. Try /health, /ready, /metrics and POST /predict."
}

output "consumer_url" {
  value       = google_cloud_run_v2_service.consumer.uri
  description = "Private. Only the Pub/Sub push service account can invoke it."
}

output "topic" {
  value       = google_pubsub_topic.events.name
  description = "Publish here with scripts/publish_sample.py"
}

output "dead_letter_subscription" {
  value       = google_pubsub_subscription.dead_letter_inspect.name
  description = "gcloud pubsub subscriptions pull <this> --auto-ack"
}

output "image" {
  value       = local.image
  description = "The exact image this deploy is serving"
}
