variable "project_id" {
  description = "Target GCP project id."
  type        = string
}

variable "region" {
  description = "Region for every regional resource. Also the Artifact Registry location."
  type        = string
  default     = "asia-southeast1"
}

variable "name_prefix" {
  description = "Prefix for network and IAM resource names."
  type        = string
  default     = "gsa-prod"
}

variable "cluster_name" {
  description = "GKE cluster name."
  type        = string
  default     = "go-sample-app-prod"
}

# ── Addressing (see modules/network/variables.tf for the sizing rationale) ──

variable "subnet_cidr" {
  type    = string
  default = "10.10.0.0/24"
}

variable "pods_cidr" {
  type    = string
  default = "10.20.0.0/17"
}

variable "services_cidr" {
  type    = string
  default = "10.30.0.0/22"
}

variable "master_ipv4_cidr_block" {
  type    = string
  default = "172.16.0.0/28"
}

# ── Control-plane access ────────────────────────────────────────────────────

variable "master_authorized_networks" {
  description = <<-EOT
    Who may reach the Kubernetes API. Required -- there is no default, because a
    default here would either be insecure or would lock you out.

    Get your own address with:  curl -s https://ifconfig.me
    then set, in terraform.tfvars:

      master_authorized_networks = [
        { cidr_block = "203.0.113.7/32", display_name = "operator-laptop" }
      ]

    The gke module rejects 0.0.0.0/0.
  EOT
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
}

# ── Workload Identity wiring ────────────────────────────────────────────────

variable "ksa_namespace" {
  description = "Namespace of the KSA permitted to impersonate the app GSA. Must match k8s/overlays/prod/namespace.yaml."
  type        = string
  default     = "prod"
}

variable "ksa_name" {
  description = "KSA name permitted to impersonate the app GSA. Must match metadata.name in k8s/base/serviceaccount.yaml."
  type        = string
  default     = "go-sample-app"
}

variable "app_roles" {
  description = "Project roles for the application GSA. Empty by default -- the sample app calls no GCP API."
  type        = list(string)
  default     = []
}

# ── Node sizing ─────────────────────────────────────────────────────────────

variable "machine_type" {
  description = "Sized for the LGTM stack, not the app. See modules/gke/variables.tf."
  type        = string
  default     = "e2-standard-4"
}

variable "disk_type" {
  type    = string
  default = "pd-balanced"
}

variable "disk_size_gb" {
  type    = number
  default = 50
}

variable "min_nodes_total" {
  description = "TOTAL across the region, not per zone. Must be >= 3 — one node per zone. See modules/gke/variables.tf."
  type        = number
  default     = 3
}

variable "max_nodes_total" {
  description = "TOTAL across the region, not per zone."
  type        = number
  default     = 9
}

# ── Lifecycle ───────────────────────────────────────────────────────────────

variable "deletion_protection" {
  description = "True in normal operation. Set false and APPLY before running destroy -- the flag lives in state, so destroy alone cannot clear it."
  type        = bool
  default     = true
}

variable "spot" {
  description = "Use Spot VMs for the node pool. false for production; true for a demo run, where preemption also exercises the PDB and the drain path. See modules/gke/variables.tf."
  type        = bool
  default     = false
}
