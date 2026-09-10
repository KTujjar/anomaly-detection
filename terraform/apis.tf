# Services this project needs turned on. Terraform enables them rather than
# leaving it to a console click nobody remembers making.
resource "google_project_service" "required" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "pubsub.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "logging.googleapis.com",
  ])
  service = each.key

  # Disabling an API on destroy can break unrelated resources in the same
  # project, and re-enabling is free. Leave them on.
  disable_on_destroy = false
}
