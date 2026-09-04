output "workload_identity_provider" {
  description = <<-EOT
    Full resource name of the OIDC provider. Goes into the GitHub repository
    secret GCP_WIF_PROVIDER, which google-github-actions/auth reads.
  EOT
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "terraform_ci_service_account" {
  description = "Email of the CI service account. Goes into the GitHub repository secret GCP_TERRAFORM_SA."
  value       = google_service_account.terraform_ci.email
}

output "github_secrets_setup" {
  description = "Copy-paste setup: the two repository secrets and the variable that ungates the plan job."
  value       = <<-EOT

    Set these on the GitHub repository (Settings → Secrets and variables → Actions):

      Secrets
        GCP_WIF_PROVIDER  = ${google_iam_workload_identity_pool_provider.github.name}
        GCP_TERRAFORM_SA  = ${google_service_account.terraform_ci.email}

      Variables
        TERRAFORM_PLAN_ENABLED = true
        TF_STATE_BUCKET        = ${var.state_bucket}

    Neither secret is a credential — one is a resource path, the other an email.
    They are secrets only because the workflow reads them from that store. Nobody
    can use them without pushing from ${var.github_repository}.
  EOT
}
