# =============================================================================
# Two Cloud Run services, ONE image.
#
# They differ only in scaling and IAM, so there is no second build and no code
# branching -- the same container serves /predict on one and /pubsub/push on the
# other.
#
# The split exists because the two endpoints have incompatible scaling needs:
#
#   /predict      is stateless. Each request carries its own complete windows,
#                 so it can run on as many instances as traffic warrants.
#   /pubsub/push  is NOT. It feeds a rolling in-memory buffer inside
#                 StreamingDetector, so a second instance would see half the
#                 stream and score every window against incomplete data.
#
# Running one service would force the whole thing down to a single instance to
# protect the buffer. Splitting keeps the public API free to scale.
# =============================================================================

locals {
  image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.anomaly.repository_id}/anomaly-api:${var.image_tag}"

  common_env = {
    ARTIFACT_DIR = "/app/artifacts"
    DATASET      = var.dataset
  }
}

resource "google_cloud_run_v2_service" "api" {
  name     = "anomaly-api"
  location = var.region

  # Public. See google_cloud_run_v2_service_iam_member.api_public in iam.tf.
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.runtime.email

    scaling {
      min_instance_count = 0 # scale to zero -- an idle month costs nothing
      max_instance_count = var.api_max_instances
    }

    containers {
      image = local.image

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = local.common_env
        content {
          name  = env.key
          value = env.value
        }
      }

      resources {
        limits = {
          # torch needs headroom to load the LSTM; 512Mi OOMs on cold start.
          cpu    = "1"
          memory = "1Gi"
        }
        # Bill for CPU only while a request is in flight, not for the whole
        # instance lifetime. This is what makes scale-to-zero actually cheap.
        cpu_idle          = true
        startup_cpu_boost = true
      }

      startup_probe {
        # Cold start pulls a torch-bearing image and loads model artifacts.
        # A tight probe here restart-loops the container before it ever serves.
        initial_delay_seconds = 10
        period_seconds        = 5
        failure_threshold     = 30
        timeout_seconds       = 5
        http_get {
          path = "/health"
          port = 8080
        }
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        period_seconds    = 30
        failure_threshold = 3
      }
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_cloud_run_v2_service" "consumer" {
  name     = "anomaly-consumer"
  location = var.region

  # Private. Only the Pub/Sub push service account can reach it, enforced by
  # Cloud Run IAM before the request touches the container.
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.runtime.email

    scaling {
      min_instance_count = 0
      # Pinned to 1 on purpose -- see the header comment and the validation on
      # consumer_max_instances in variables.tf.
      max_instance_count = var.consumer_max_instances
    }

    # Push delivery arrives as a request, so the instance is only alive while
    # messages flow. Between bursts it scales to zero like the API.
    max_instance_request_concurrency = 10

    containers {
      image = local.image

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = merge(local.common_env, {
          # Log every scored row, not just anomalies. Volume is low on a demo
          # stream and it makes `gcloud run services logs read` actually show
          # the pipeline working.
          LOG_ALL_RESULTS = "true"
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      startup_probe {
        initial_delay_seconds = 10
        period_seconds        = 5
        failure_threshold     = 30
        timeout_seconds       = 5
        http_get {
          path = "/health"
          port = 8080
        }
      }
    }
  }

  depends_on = [google_project_service.required]
}
