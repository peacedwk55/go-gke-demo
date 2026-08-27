terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# Custom-mode VPC, not auto-mode.
#
# An auto-mode network silently creates a subnet in every current and future
# GCP region with predictable 10.128.0.0/9 ranges. That is more address space
# than we asked for, in more places than we operate, and it collides with
# on-prem or peer ranges sooner or later. Custom mode means every subnet is a
# deliberate, reviewed decision.
resource "google_compute_network" "vpc" {
  project                         = var.project_id
  name                            = "${var.name_prefix}-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
}

# One subnet with two secondary ranges. Attaching the secondary ranges here is
# what makes the cluster VPC-native (alias IPs): Pods get real, routable VPC
# addresses instead of being NAT-ed behind the node, which is a prerequisite
# for Dataplane V2 and for any future VPC peering or Private Service Connect.
resource "google_compute_subnetwork" "subnet" {
  project       = var.project_id
  name          = "${var.name_prefix}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Required for private nodes to reach Google APIs (Artifact Registry, Cloud
  # Logging, the GKE control plane) over internal addresses instead of going
  # out through Cloud NAT. Cheaper, faster, and it keeps that traffic off the
  # public internet entirely.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${var.name_prefix}-pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "${var.name_prefix}-services"
    ip_cidr_range = var.services_cidr
  }

  # VPC Flow Logs. Sampled at 50% with 5-minute aggregation: enough to
  # investigate a connectivity or exfiltration question after the fact, without
  # the cost of full-fidelity capture.
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Egress for private nodes
#
# Private nodes have no external IP, so without NAT they cannot reach anything
# outside Google's own APIs -- no Docker Hub pull-through, no OS package
# updates, no third-party webhook. Cloud NAT provides that egress while keeping
# the nodes unreachable from the internet: connections can only be initiated
# outbound.
# ─────────────────────────────────────────────────────────────────────────────
resource "google_compute_router" "router" {
  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  project = var.project_id
  name    = "${var.name_prefix}-nat"
  router  = google_compute_router.router.name
  region  = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    # ERRORS_ONLY rather than ALL: the useful signal is port exhaustion and
    # dropped translations, and full NAT logging on a chatty cluster is a
    # meaningful line on the bill for very little added insight.
    filter = "ERRORS_ONLY"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Firewall
#
# GCP's implied rules already deny all ingress and allow all egress, so there
# is no explicit deny rule to write -- the default posture is deny-by-default
# for inbound. What follows is only the minimum set of exceptions.
#
# Deliberately absent: any rule opening 22 to 0.0.0.0/0. Node access is via IAP
# TCP forwarding, which needs no public SSH surface at all.
# ─────────────────────────────────────────────────────────────────────────────

# The GKE control plane must reach webhook servers running in Pods (admission
# controllers, metrics adapters, ArgoCD's own webhooks). Without this the
# cluster comes up but every mutating/validating webhook times out, which
# presents as slow, confusing failures rather than an obvious network error.
resource "google_compute_firewall" "allow_master_to_webhooks" {
  project     = var.project_id
  name        = "${var.name_prefix}-allow-master-webhooks"
  network     = google_compute_network.vpc.name
  description = "GKE control plane to Pod webhook ports"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.master_ipv4_cidr_block]
  target_tags   = ["${var.name_prefix}-node"]

  allow {
    protocol = "tcp"
    ports    = ["8443", "9443", "15017"]
  }
}

# Health checks and load balancing come from these two fixed Google-owned
# ranges. They are documented constants, not arbitrary CIDRs.
resource "google_compute_firewall" "allow_health_checks" {
  project     = var.project_id
  name        = "${var.name_prefix}-allow-health-checks"
  network     = google_compute_network.vpc.name
  description = "GCP load balancer health check probes"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["${var.name_prefix}-node"]

  allow {
    protocol = "tcp"
  }
}

# IAP TCP forwarding range, for SSH to a bastion or directly to a node without
# any node having a public IP. This is the replacement for a public SSH rule.
resource "google_compute_firewall" "allow_iap_ssh" {
  project     = var.project_id
  name        = "${var.name_prefix}-allow-iap-ssh"
  network     = google_compute_network.vpc.name
  description = "SSH via IAP TCP forwarding only -- no public SSH surface"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-node"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
