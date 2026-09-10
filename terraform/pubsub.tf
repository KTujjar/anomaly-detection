# =============================================================================
# Pub/Sub: the cloud replacement for the local Kafka broker.
#
# PUSH delivery, not pull. A pull subscriber is a process that has to stay alive
# waiting for messages, which means an instance billed around the clock. Push
# turns delivery into an ordinary HTTPS request, so the consumer scales to zero
# between bursts and the app needs no Pub/Sub client library at all.
# =============================================================================

resource "google_pubsub_topic" "events" {
  name = "anomaly-events"

  # Long enough to replay a bad afternoon, short enough to stay in the free tier.
  message_retention_duration = "86600s" # ~24h

  depends_on = [google_project_service.required]
}

# Where messages go when the consumer cannot use them. The push endpoint acks
# malformed input (returning 4xx would make Pub/Sub redeliver a message that can
# never parse), so delivery attempts are what route a genuinely broken message
# here -- not an error status.
resource "google_pubsub_topic" "dead_letter" {
  name = "anomaly-events-dead-letter"

  depends_on = [google_project_service.required]
}

resource "google_pubsub_subscription" "push_to_consumer" {
  name  = "anomaly-events-push"
  topic = google_pubsub_topic.events.id

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.consumer.uri}/pubsub/push"

    # Pub/Sub signs every push with an OIDC token for this account. Cloud Run
    # verifies it before the request reaches the container, which is why
    # src/serving/pubsub.py carries no auth code and no shared secret.
    oidc_token {
      service_account_email = google_service_account.pubsub_push.email
      audience              = google_cloud_run_v2_service.consumer.uri
    }
  }

  # Cold start on a scaled-to-zero service can take a while: pulling a
  # torch-bearing image and loading model artifacts. A short deadline would nack
  # the first message of every burst and redeliver it needlessly.
  ack_deadline_seconds = 60

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  expiration_policy {
    ttl = "" # never expire; the default deletes an idle subscription after 31 days
  }

  depends_on = [google_cloud_run_v2_service_iam_member.consumer_invoker]
}

# Pub/Sub's service agent needs these to move messages into the dead-letter
# topic and to acknowledge them on the source subscription.
resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  topic  = google_pubsub_topic.dead_letter.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription_iam_member" "dead_letter_subscriber" {
  subscription = google_pubsub_subscription.push_to_consumer.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# A pull subscription on the dead-letter topic, so poison messages are readable
# with `gcloud pubsub subscriptions pull` instead of vanishing.
resource "google_pubsub_subscription" "dead_letter_inspect" {
  name  = "anomaly-events-dead-letter-inspect"
  topic = google_pubsub_topic.dead_letter.id

  expiration_policy {
    ttl = ""
  }
}
