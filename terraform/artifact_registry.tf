resource "google_artifact_registry_repository" "anomaly" {
  location      = var.region
  repository_id = "anomaly"
  description   = "Container images for the anomaly detection service"
  format        = "DOCKER"

  # Every push tags by commit SHA, so old tags accumulate forever without this.
  # Storage is cheap but not free, and an unbounded registry is a slow leak.
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  depends_on = [google_project_service.required]
}
