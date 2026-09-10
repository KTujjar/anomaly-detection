# =============================================================================
# BOOTSTRAP -- run this ONCE, from your own machine, with your own credentials.
#
# It exists to break a chicken-and-egg problem: the deploy workflow authenticates
# to Google Cloud through Workload Identity Federation, but WIF itself has to be
# created by somebody who is already authenticated. So this directory is applied
# by hand, and everything in terraform/ afterwards is applied by CI.
#
# It deliberately uses LOCAL state -- it is what creates the bucket that holds
# every other state file. terraform.tfstate here is gitignored; if you lose it,
# you can import these resources back or recreate them, since nothing here holds
# application data.
#
#   cd terraform/bootstrap
#   terraform init
#   terraform apply -var project_id=YOUR_PROJECT_ID
#
# Then copy the three outputs into .github/workflows/deploy.yml.
# =============================================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type        = string
  description = "GCP project ID (not the display name)"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "github_repository" {
  type        = string
  default     = "KTujjar/anomaly-detection"
  description = "owner/repo allowed to assume the deployer service account"
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique GCS bucket name for Terraform state"
  default     = null
}

locals {
  state_bucket = coalesce(var.state_bucket_name, "${var.project_id}-tfstate")
}

# -----------------------------------------------------------------------------
# APIs this bootstrap needs. terraform/ enables the rest.
# -----------------------------------------------------------------------------
resource "google_project_service" "bootstrap" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
  ])
  service = each.key

  # Leave the APIs on when this is destroyed -- turning them off can break
  # unrelated resources in the same project.
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# Remote state bucket
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "tfstate" {
  name     = local.state_bucket
  location = var.region

  # Versioning is the undo button for a bad apply. State files are tiny.
  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true

  # State must never be public.
  public_access_prevention = "enforced"

  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.bootstrap]
}

# -----------------------------------------------------------------------------
# Workload Identity Federation for GitHub Actions
#
# This replaces a downloaded service-account JSON key. GitHub mints a short-lived
# OIDC token per run, Google exchanges it for an access token, and there is no
# long-lived credential in repository secrets to leak or rotate.
# -----------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  description               = "Identity pool for GitHub Actions deploys"

  depends_on = [google_project_service.bootstrap]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # MANDATORY. Google rejects a provider with no attribute condition, and for good
  # reason: without it, a workflow in ANY GitHub repository on earth could present
  # a valid GitHub OIDC token and assume the deployer service account below.
  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# -----------------------------------------------------------------------------
# Deployer service account
# -----------------------------------------------------------------------------
resource "google_service_account" "deployer" {
  account_id   = "gha-deployer"
  display_name = "GitHub Actions deployer"
  description  = "Assumed via WIF by ${var.github_repository} to apply terraform/"

  depends_on = [google_project_service.bootstrap]
}

# Project-level roles the deploy needs. run.admin and artifactregistry.writer are
# the deploy itself; pubsub.admin manages the topic and subscription;
# serviceAccountUser is required to deploy a Cloud Run service that RUNS AS
# another service account.
resource "google_project_iam_member" "deployer" {
  for_each = toset([
    "roles/run.admin",
    "roles/artifactregistry.admin",
    "roles/pubsub.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/serviceusage.serviceUsageAdmin",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# State bucket access is scoped to the bucket, not granted project-wide.
resource "google_storage_bucket_iam_member" "deployer_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.deployer.email}"
}

# The binding that actually lets the GitHub workflow become the deployer, scoped
# to this one repository by the attribute condition above.
resource "google_service_account_iam_member" "github_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# -----------------------------------------------------------------------------
# Outputs -- these go straight into .github/workflows/deploy.yml.
# None of them are secret. WIF has no key material; access is gated by the
# attribute condition, not by keeping these strings private.
# -----------------------------------------------------------------------------
output "workload_identity_provider" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "Pass as workload_identity_provider in google-github-actions/auth"
}

output "deployer_service_account" {
  value       = google_service_account.deployer.email
  description = "Pass as service_account in google-github-actions/auth"
}

output "state_bucket" {
  value       = google_storage_bucket.tfstate.name
  description = "Set as the bucket in terraform/versions.tf's gcs backend"
}
