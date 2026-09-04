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
# Workload Identity Federation for GitHub Actions — the SECOND keyless path
# ─────────────────────────────────────────────────────────────────────────────
#
# modules/iam solves "a pod needs GCP access without a key". This module solves
# the other half: "CI needs GCP access without a key".
#
# They are the same idea applied to different callers, and it is worth being
# explicit that they are separate pools:
#
#   modules/iam         GKE pods    <project>.svc.id.goog[namespace/ksa]
#   this module         GitHub CI   token.actions.githubusercontent.com
#
# Without this, `.github/workflows/terraform.yaml` cannot run its `plan` job —
# there is no provider name and no service account for it to reference, which is
# why the job sat behind `vars.TERRAFORM_PLAN_ENABLED` and never ran.
#
# Everything here is free: pools, providers, service accounts and IAM bindings
# carry no charge. Only the resources a plan reads cost money, and reading is
# free.

# ─────────────────────────────────────────────────────────────────────────────
# The pool and the OIDC provider
# ─────────────────────────────────────────────────────────────────────────────
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions"
  description               = "Federates GitHub Actions OIDC tokens. No service account keys."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub OIDC"

  oidc {
    # GitHub's OIDC issuer. Tokens are signed by GitHub and verified by Google
    # against this issuer's published keys — nothing shared, nothing stored.
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  # Which token claims become Google attributes. `assertion.repository` is the
  # one the condition below keys on.
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # ── The single most important line in this module ──────────────────────────
  #
  # Without an attribute_condition, this provider accepts a valid OIDC token
  # from ANY repository on GitHub — anyone's fork, anyone's personal project —
  # and lets it impersonate the service account below. That is not a subtle
  # misconfiguration; it is a public door.
  #
  # Google refuses to create a provider whose condition is absent when the
  # mapping includes a wildcard-capable attribute, which is a good default, but
  # the condition still has to be RIGHT rather than merely present. Pinned to
  # one repository:
  attribute_condition = "attribute.repository == \"${var.github_repository}\""
}

# ─────────────────────────────────────────────────────────────────────────────
# The identity CI assumes
# ─────────────────────────────────────────────────────────────────────────────
resource "google_service_account" "terraform_ci" {
  project      = var.project_id
  account_id   = var.service_account_id
  display_name = "Terraform CI (plan only)"
  description  = "Assumed by GitHub Actions via Workload Identity Federation. Read-only plus state lock."
}

# Only the CI provider, only that repository, may impersonate it.
resource "google_service_account_iam_member" "ci_may_impersonate" {
  service_account_id = google_service_account.terraform_ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# ─────────────────────────────────────────────────────────────────────────────
# What it is allowed to do — and why `roles/viewer` is the honest choice here
# ─────────────────────────────────────────────────────────────────────────────
#
# `terraform plan` must read EVERY resource type in the configuration: compute
# networks, subnets, routers, NAT, firewall rules, GKE clusters and node pools,
# service accounts, project IAM policy, Artifact Registry, enabled services.
#
# Assembling that from individual viewer roles is possible and it is a trap. The
# list breaks the moment a new resource type enters the config, and the failure
# mode is the dangerous one: a plan cannot read a resource, so it reports
# "will be created" for something that already exists, and the plan looks clean
# while describing the wrong world. A reviewer approves drift they cannot see.
#
# `roles/viewer` is broad but read-only, and breadth is the property a plan needs.
# The narrow grant that matters is the WRITE one below, which is scoped to a
# single bucket.
resource "google_project_iam_member" "viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.terraform_ci.email}"
}

# `plan` is not read-only against the backend: it acquires a lock, writes
# `default.tflock`, and removes it afterwards. Without object write access the
# job fails at `terraform init`/plan on the lock, not on anything informative.
#
# Scoped to the state bucket alone, not project-wide storage.
resource "google_storage_bucket_iam_member" "state" {
  bucket = var.state_bucket
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.terraform_ci.email}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Deliberately absent
# ─────────────────────────────────────────────────────────────────────────────
#
# No `google_service_account_key`. That is the whole point, and invariant 2 in
# scripts/check-invariants.sh fails the build if one ever appears.
#
# No `roles/editor`, no `roles/owner`, and no apply permission of any kind. This
# identity can describe what would change; it cannot change anything. Apply stays
# with a human, for the reason set out in .github/workflows/terraform.yaml.
