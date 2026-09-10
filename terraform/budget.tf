# A budget does not cap spend -- nothing on GCP does. It emails you when you
# cross a threshold, which for a public endpoint is the difference between
# noticing on day one and noticing on the invoice.
#
# Skipped unless billing_account is set, because creating a budget requires
# billing-account permissions that a plain project owner does not have.

resource "google_billing_budget" "monthly" {
  count = var.billing_account == "" ? 0 : 1

  billing_account = var.billing_account
  display_name    = "anomaly-detection monthly"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount)
    }
  }

  # Warn early, warn again at the line, and warn on the forecast so a runaway
  # is caught before it lands rather than after.
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }
}
