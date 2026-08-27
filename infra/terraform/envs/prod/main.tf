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

  machine_type       = var.machine_type
  disk_type          = var.disk_type
  disk_size_gb       = var.disk_size_gb
  min_nodes_per_zone = var.min_nodes_per_zone
  max_nodes_per_zone = var.max_nodes_per_zone

  deletion_protection = var.deletion_protection
}
