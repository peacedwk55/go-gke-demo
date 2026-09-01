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
# Step 2 does NOT live in this module — see the note at the bottom of the file.
# It has to run after the cluster exists, and the cluster already depends on
# this module, so it sits in the root module instead.
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

# ─────────────────────────────────────────────────────────────────────────────
# The Workload Identity binding is NOT here — it lives in the root module.
#
# It cannot live in this module, and the reason is a real ordering constraint
# that only surfaced on the first apply:
#
#   Error 400: Identity Pool does not exist (<project>.svc.id.goog)
#
# The pool named in the member string is created BY THE CLUSTER, as a side
# effect of workload_identity_config. So the binding has to come after the
# cluster. But the cluster already depends on this module for the node service
# account, so `depends_on = [module.gke]` here would be a cycle.
#
# The binding therefore sits in envs/prod/main.tf, which can see both modules
# and can order them explicitly. See google_service_account_iam_member
# "workload_identity" there.
#
# Worth recording that the earlier reasoning was wrong, not just incomplete:
# "the member string is just an identity name, so there is no ordering
# dependency" is true of the namespace and the KSA, which genuinely need not
# exist yet — and false of the pool, which must.
