variable "project_id" {
  description = "Target GCP project id."
  type        = string
}

variable "github_repository" {
  description = <<-EOT
    The ONE repository allowed to impersonate the CI service account, as
    "owner/repo". This is the security boundary of the whole module — see the
    attribute_condition in main.tf. A wildcard here would let any repository on
    GitHub assume this identity.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Must be exactly \"owner/repo\" — no wildcards, no bare owner, no URL."
  }
}

variable "state_bucket" {
  description = "GCS bucket holding the Terraform state. The CI identity gets object write access to this bucket only, because plan takes a lock."
  type        = string
}

variable "pool_id" {
  description = "Workload Identity Pool id. Pool ids cannot be reused for 30 days after deletion, so changing this is not free."
  type        = string
  default     = "github-actions"
}

variable "provider_id" {
  description = "Workload Identity Pool Provider id."
  type        = string
  default     = "github-oidc"
}

variable "service_account_id" {
  description = "Account id (the part before @) for the Terraform CI service account."
  type        = string
  default     = "terraform-ci"
}
