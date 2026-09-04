terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      # Pinned to a major version with ~>, so patch and minor upgrades come in
      # (bug and CVE fixes) but a breaking 7.x cannot arrive silently on
      # somebody's next `terraform init -upgrade`.
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable every API this stack touches, before anything tries to use it.
#
# Without this the first apply fails partway through with an opaque
# "API not enabled" error, having already created some resources.
#
# disable_on_destroy = false is deliberate: `terraform destroy` should tear down
# our cluster, not disable project-wide APIs that other things may depend on.
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "artifactregistry.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Artifact Registry remote repository — a read-through cache of Docker Hub.
#
# Task 2 requires pushing to Docker Hub. Pulling from Docker Hub on GKE is the
# problem: every private node egresses through one Cloud NAT IP, so Docker Hub's
# per-IP pull limit is shared by the entire cluster. A rollout that restarts
# nine nodes' worth of pods can exhaust it, and the failure mode is
# ImagePullBackOff with a 429 -- during a deploy, which is the worst time.
#
# So: push to Docker Hub (assignment satisfied, reviewer gets a browsable URL),
# pull through here. This is also what makes roles/artifactregistry.reader on
# the node SA meaningful rather than vestigial.
#
# Two properties worth stating plainly:
#   - It is PULL-ONLY. A remote repository cannot be pushed to. Do not point
#     `docker buildx --push` at this URL.
#   - It pulls ANONYMOUSLY by default, so the upstream Docker Hub repo must be
#     public. A private upstream needs remote_repository_config
#     .upstream_credentials with a Docker Hub token in Secret Manager plus an
#     IAM grant for the AR service agent. Out of scope here on purpose: the repo
#     is public because Task 2's DoD already requires a public URL.
# ─────────────────────────────────────────────────────────────────────────────
resource "google_artifact_registry_repository" "dockerhub_remote" {
  project       = var.project_id
  location      = var.region
  repository_id = "dockerhub-remote"
  description   = "Read-through cache of Docker Hub. Protects the node pool from per-IP pull limits behind Cloud NAT. Pull-only."
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = "docker.io"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  depends_on = [google_project_service.required]
}

# ─────────────────────────────────────────────────────────────────────────────
# Modules
#
# Apply order is expressed through data flow, not depends_on: network outputs
# feed gke, iam outputs feed gke. Terraform derives the graph from that, which
# is more robust than a hand-maintained dependency list.
# ─────────────────────────────────────────────────────────────────────────────

module "network" {
  source = "../../modules/network"

  project_id  = var.project_id
  region      = var.region
  name_prefix = var.name_prefix

  subnet_cidr            = var.subnet_cidr
  pods_cidr              = var.pods_cidr
  services_cidr          = var.services_cidr
  master_ipv4_cidr_block = var.master_ipv4_cidr_block

  depends_on = [google_project_service.required]
}

module "iam" {
  source = "../../modules/iam"

  project_id  = var.project_id
  name_prefix = var.name_prefix

  # These two must match the workload exactly. `ksa_namespace` is the namespace
  # created by k8s/overlays/prod/namespace.yaml and `ksa_name` is metadata.name
  # in k8s/base/serviceaccount.yaml. A mismatch produces a binding that looks
  # correct and never authorises anything.
  ksa_namespace = var.ksa_namespace
  ksa_name      = var.ksa_name

  # Empty: the sample app calls no GCP API. Least privilege means the identity
  # exists and holds nothing until there is a reason.
  app_roles = var.app_roles

  depends_on = [google_project_service.required]
}

module "gke" {
  source = "../../modules/gke"

  project_id   = var.project_id
  region       = var.region
  cluster_name = var.cluster_name
  environment  = "prod"

  network_name           = module.network.network_name
  subnet_name            = module.network.subnet_name
  pods_range_name        = module.network.pods_range_name
  services_range_name    = module.network.services_range_name
  node_tag               = module.network.node_tag
  master_ipv4_cidr_block = module.network.master_ipv4_cidr_block

  node_service_account_email = module.iam.node_service_account_email
  master_authorized_networks = var.master_authorized_networks

  machine_type    = var.machine_type
  disk_type       = var.disk_type
  disk_size_gb    = var.disk_size_gb
  min_nodes_total = var.min_nodes_total
  max_nodes_total = var.max_nodes_total

  spot                = var.spot
  deletion_protection = var.deletion_protection
}

# ─────────────────────────────────────────────────────────────────────────────
# The Workload Identity binding — the whole answer to "deploy without keys".
#
# ─────────────────────────────────────────────────────────────────────────────
# Why this is here rather than inside modules/iam
# ─────────────────────────────────────────────────────────────────────────────
#
# It was in the iam module, and the first apply failed on it:
#
#   Error 400: Identity Pool does not exist (<project>.svc.id.goog)
#
# The pool named in the member string is not a pre-existing project resource —
# GKE creates it as a side effect of workload_identity_config on the cluster. So
# the binding must come after the cluster.
#
# It cannot express that from inside the iam module: the gke module already
# consumes iam's node service account, so `depends_on = [module.gke]` there
# would close a cycle. The root module can see both, so the ordering lives here.
#
# This corrects an earlier claim in infra/terraform/README.md that there was no
# ordering dependency at all. That was true of the namespace and the KSA — which
# genuinely need not exist yet, and still do not at this point — and false of the
# pool.
#
# google_service_account_iam_member, not _binding: the _binding form is
# authoritative and would silently delete any other binding on this GSA that
# Terraform does not know about.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = module.iam.app_service_account_id
  role               = "roles/iam.workloadIdentityUser"

  # Scoped as tightly as the mechanism allows: one KSA, in one namespace, in one
  # cluster's pool. A pod in another namespace, or under a differently-named
  # KSA, cannot impersonate this GSA even if an attacker can create pods.
  member = "serviceAccount:${module.gke.workload_identity_pool}[${var.ksa_namespace}/${var.ksa_name}]"

  # The member string above already references module.gke, so Terraform derives
  # the ordering from that reference alone. depends_on is stated anyway because
  # the constraint is not obvious from reading the string — someone
  # "simplifying" it back to "${var.project_id}.svc.id.goog" would silently
  # remove the dependency and reintroduce the failure above.
  depends_on = [module.gke]
}

# ─────────────────────────────────────────────────────────────────────────────
# GitHub Actions OIDC — so `terraform plan` can run in CI without a key
# ─────────────────────────────────────────────────────────────────────────────
#
# Optional by construction. With `github_repository` empty this module creates
# nothing, `terraform plan` in CI stays impossible, and the workflow's `plan`
# job stays gated behind `vars.TERRAFORM_PLAN_ENABLED` — which is the state the
# repository shipped in, and the reason that job had never once executed.
#
# Kept optional rather than mandatory because it is the one part of this
# configuration that is about the repository rather than about the application:
# someone forking this to a different repo, or running it with no CI at all,
# should not be blocked by it.
#
# count rather than for_each: this is one thing that either exists or does not,
# and for_each over a single-element set would only obscure that.
module "github_oidc" {
  source = "../../modules/github_oidc"
  count  = var.github_repository == "" ? 0 : 1

  project_id        = var.project_id
  github_repository = var.github_repository
  state_bucket      = var.state_bucket != "" ? var.state_bucket : "${var.project_id}-tfstate"

  depends_on = [google_project_service.required]
}
