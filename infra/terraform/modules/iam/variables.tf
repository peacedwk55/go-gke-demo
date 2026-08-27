variable "project_id" {
  description = "GCP project that owns the service accounts."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the node service account id."
  type        = string
}

variable "app_sa_account_id" {
  description = "Account id (the part before the @) of the application GSA."
  type        = string
  default     = "app-prod"
}

variable "ksa_namespace" {
  description = "Kubernetes namespace holding the KSA that may impersonate the app GSA. Half of the Workload Identity member string, so it must match the namespace the workload actually runs in."
  type        = string
  default     = "prod"
}

variable "ksa_name" {
  description = "Kubernetes ServiceAccount name allowed to impersonate the app GSA. Must match metadata.name in k8s/base/serviceaccount.yaml."
  type        = string
  default     = "go-sample-app"
}

variable "app_roles" {
  description = <<-EOT
    Project roles granted to the application GSA.

    Empty by default, and that is the correct answer for this workload: the
    sample app calls no GCP API, so it needs no permission. The identity and its
    Workload Identity binding still exist, so granting a role later is a
    one-line change with no re-plumbing.

    Add narrowly when a need appears -- e.g. ["roles/secretmanager.secretAccessor"]
    -- and prefer resource-level bindings over project-level ones once more than
    one resource is involved.
  EOT
  type        = list(string)
  default     = []
}
