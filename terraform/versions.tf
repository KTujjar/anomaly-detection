terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # State lives in the bucket created by terraform/bootstrap. The bucket name is
  # supplied at init time rather than hardcoded, because it has to be globally
  # unique and therefore differs per project:
  #
  #   terraform init -backend-config="bucket=<PROJECT_ID>-tfstate"
  #
  # The deploy workflow passes this automatically.
  backend "gcs" {
    prefix = "anomaly-detection"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
