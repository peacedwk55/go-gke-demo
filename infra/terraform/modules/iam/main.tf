terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# THE IMPORTANT CONDITION: no service account keys, anywhere.
#
# There is deliberately no `google_service_account_key` resource in this module
# -- or in this repository. Grep for it; it does not exist.
#
# A JSON key is a permanent, offline-usable bearer credential. Creating one puts
# it in Terraform state (which is why state itself becomes a secret), then in a
# CI secret store, then in a Kubernetes Secret, and eventually in somebody's
# Downloads folder. It does not expire on its own and nothing tells you when it
# leaks.
#
# Workload Identity replaces all of that with a trust relationship:
#
#   1. This module creates the GSA and grants it least-privilege roles.
#   2. This module grants roles/iam.workloadIdentityUser on that GSA to the
#      *identity of a specific KSA in a specific namespace*.
#   3. The KSA manifest carries the iam.gke.io/gcp-service-account annotation
#      (k8s/overlays/prod/patches/serviceaccount-wi.yaml).
#   4. At runtime the pod asks the GKE metadata server for a token. GKE checks
#      the annotation against the binding and mints a short-lived, auto-rotated
#      OAuth token.
#
# No key material is created, stored or transported at any point.
#
# Note the binding is created before the namespace or KSA exists. That is fine
# and intentional: the member string is just an identity name, so Terraform and
# the cluster bootstrap have no ordering dependency on each other.
# ─────────────────────────────────────────────────────────────────────────────

# ── Node service account ─────────────────────────────────────────────────────
#
# GKE defaults to the Compute Engine default service account, which holds
# roles/editor on the whole project. Every pod that reaches the metadata server
# on such a node inherits project-wide write access -- a single container escape
# becomes a full project compromise. So we create a purpose-built SA with only
# what kubelet genuinely needs.
resource "google_service_account" "node" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-node"
  display_name = "GKE node service account (${var.name_prefix})"
  description  = "Least-privilege identity for GKE nodes. Replaces the default Compute Engine SA, which carries roles/editor."
}

locals {
  # Exactly what kubelet and the node agents need, and nothing more:
  #   logWriter      -- ship container/system logs to Cloud Logging
  #   metricWriter   -- ship node metrics to Cloud Monitoring
  #   monitoringViewer -- read back metrics (autoscaling, node problem detector)
  #   artifactregistry.reader -- pull images through the AR remote repository
  #   stackdriver.resourceMetadata.writer -- node metadata for Cloud Ops
  #
  # Notably absent: any storage, compute or container role. Nodes do not need
  # to read GCS buckets or mutate the cluster they belong to.
  node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
    "roles/stackdriver.resourceMetadata.writer",
  ]
}

resource "google_project_iam_member" "node" {
  for_each = toset(local.node_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.node.email}"
}

# ── Application service account ──────────────────────────────────────────────
#
# The identity the workload itself assumes via Workload Identity. The sample app
# calls no GCP API, so app_roles defaults to empty: an identity that exists and
# can be granted something later is the right shape, and granting it nothing
# today is the correct least-privilege answer rather than an oversight.
resource "google_service_account" "app" {
  project      = var.project_id
  account_id   = var.app_sa_account_id
  display_name = "Application identity for ${var.ksa_namespace}/${var.ksa_name}"
  description  = "Bound to the Kubernetes SA via Workload Identity. No key is ever created for this account."
}

resource "google_project_iam_member" "app" {
  for_each = toset(var.app_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.app.email}"
}

# ── The Workload Identity binding ────────────────────────────────────────────
#
# This single resource is the whole answer to "deploy without injecting keys".
#
# The member string is the identity of one KSA in one namespace in one cluster's
# workload pool. It is scoped as tightly as it can be: another namespace, or a
# differently-named KSA, cannot impersonate this GSA even if an attacker can
# create pods.
#
# google_service_account_iam_member (not _binding) is used on purpose: _binding
# is authoritative and would silently delete any other binding on this GSA that
# Terraform does not know about.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.ksa_namespace}/${var.ksa_name}]"
}
