variable "project_id" {
  type        = string
  description = "GCP project ID (not the display name)"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for Cloud Run and Artifact Registry. us-east1 is closer to Orlando; cost is comparable."
}

variable "image_tag" {
  type        = string
  description = "Container image tag to deploy. The workflow passes the commit SHA, so infrastructure and release move together."
  default     = "latest"
}

variable "dataset" {
  type        = string
  default     = "univariate"
  description = "Which trained model set the services load"

  validation {
    condition     = contains(["univariate", "multivariate"], var.dataset)
    error_message = "dataset must be univariate or multivariate."
  }
}

# ---------------------------------------------------------------------------
# Scaling. These are the cost controls, not decoration.
#
# min_instance_count = 0 is the important one: with no traffic there is no
# instance, and no instance is no charge. Setting it above zero to avoid cold
# starts turns this from a nearly-free demo into a monthly bill.
# ---------------------------------------------------------------------------
variable "api_max_instances" {
  type        = number
  default     = 2
  description = "Ceiling on the PUBLIC api service. Caps what a scraper or a bad actor can spend."
}

variable "consumer_max_instances" {
  type        = number
  default     = 1
  description = "Must stay 1. StreamingDetector's rolling buffer is in memory, so a second instance would score against a partial stream. See src/ingestion/pipeline.py."

  validation {
    condition     = var.consumer_max_instances == 1
    error_message = "consumer_max_instances must be 1 while the rolling buffer is in-process."
  }
}

# ---------------------------------------------------------------------------
# Budget alerting. Optional -- creating a budget needs billing-account access,
# which a plain project owner does not automatically have.
# ---------------------------------------------------------------------------
variable "billing_account" {
  type        = string
  default     = ""
  description = "Billing account ID. Leave empty to skip budget creation."
}

variable "budget_amount" {
  type        = number
  default     = 10
  description = "Monthly budget ceiling in USD that triggers alert emails."
}
