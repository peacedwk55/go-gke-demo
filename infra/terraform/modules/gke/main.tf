terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

resource "google_container_cluster" "primary" {
  project = var.project_id
  name    = var.cluster_name

  # REGIONAL, not zonal. `location` being a region rather than a zone is the
  # whole switch: the control plane is replicated across three zones (no
  # maintenance or zonal outage takes the API server down) and node pools
  # replicate per zone. This is the foundation the topologySpreadConstraints in
  # k8s/base/deployment.yaml rely on -- spreading across zones is meaningless on
  # a zonal cluster.
  location = var.region

  # Created and immediately discarded. The default pool cannot be configured
  # with a custom service account, Shielded Nodes or GKE_METADATA, so every
  # setting that matters is unavailable on it. GKE requires *a* pool at creation
  # time, so the sequence is: create with the default, delete it, manage a real
  # one as a separate resource.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Parameterised rather than hardcoded true. `deletion_protection` lives in
  # Terraform state, not in the CLI invocation, so a hardcoded true makes
  # `terraform destroy` fail permanently. Teardown is:
  #   terraform apply -var deletion_protection=false
  #   terraform destroy
  deletion_protection = var.deletion_protection

  network    = var.network_name
  subnetwork = var.subnet_name

  # Binding ip_allocation_policy to the pre-created secondary ranges is what
  # makes this a VPC-native cluster: Pods get routable VPC alias IPs. Required
  # for Dataplane V2, and it means Pod traffic is visible to VPC flow logs and
  # firewall rules instead of hidden behind per-node NAT.
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # ── Private cluster ────────────────────────────────────────────────────────
  private_cluster_config {
    # Nodes have no external IP. Egress goes through Cloud NAT; ingress from the
    # internet is impossible.
    enable_private_nodes = true

    # The control plane also gets a private endpoint, but the public endpoint
    # stays enabled and is restricted by master_authorized_networks below.
    #
    # Fully disabling it (enable_private_endpoint = true) is stronger, and is
    # what production should do -- but then kubectl only works from inside the
    # VPC, which means a bastion or Connect Gateway must exist *before* the
    # cluster can be bootstrapped. For an assignment that trade-off is not worth
    # the extra moving parts; the restriction below is what does the real work.
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block

    master_global_access_config {
      enabled = false
    }
  }

  # Who may reach the control plane. Never 0.0.0.0/0 -- an unrestricted API
  # endpoint is the single most common serious GKE misconfiguration.
  #
  # The variable is validated to reject 0.0.0.0/0 outright, so this cannot be
  # loosened by accident in a tfvars file.
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # ── Workload Identity ──────────────────────────────────────────────────────
  #
  # Enabling the pool at cluster level is only half of it; the node pool must
  # also set workload_metadata_config = GKE_METADATA (see below). With the pool
  # enabled but nodes left on GCE_METADATA, pods still read the raw metadata
  # server and inherit the *node's* identity -- the binding appears configured
  # and silently does nothing.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # ── Dataplane V2 ───────────────────────────────────────────────────────────
  #
  # eBPF-based dataplane which enforces NetworkPolicy natively and adds network
  # policy logging.
  #
  # There is deliberately NO `network_policy` block here. The two are mutually
  # exclusive: setting the legacy Calico addon alongside ADVANCED_DATAPATH makes
  # the API reject the cluster. Dataplane V2 supersedes it.
  datapath_provider = "ADVANCED_DATAPATH"

  release_channel {
    # REGULAR: versions are proven in RAPID first but still current, and GKE
    # manages control-plane upgrades. Pinning an exact version instead would
    # mean owning CVE patching by hand.
    channel = "REGULAR"
  }

  # Shielded Nodes: secure boot, vTPM and integrity monitoring, so a tampered
  # boot chain is detected rather than merely unlikely.
  enable_shielded_nodes = true

  # Cloud Operations coexists with the in-cluster LGTM stack of Task 6 on
  # purpose. LGTM lives *inside* the cluster, so when the cluster is the thing
  # that is broken it cannot tell you why. Cloud Logging and the managed
  # Prometheus system metrics are the out-of-band view that survives that.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false # kube-prometheus-stack owns application metrics
    }
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      # Must stay enabled: this is what runs the metrics-server the HPA in
      # k8s/base/hpa.yaml depends on.
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      # Needed by the LGTM stack's PVCs in Task 6.
      enabled = true
    }
  }

  # Weekly maintenance window, outside Thai business hours (17:00 UTC = 00:00
  # ICT). Without a window GKE picks its own, which will eventually be the
  # middle of a working day.
  maintenance_policy {
    recurring_window {
      start_time = "2026-01-05T17:00:00Z"
      end_time   = "2026-01-05T21:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  # Encrypt etcd application-layer secrets with a customer-managed key when one
  # is supplied. Left null by default because it needs a KMS keyring, which is
  # out of scope -- but wired so it is a one-variable change.
  dynamic "database_encryption" {
    for_each = var.database_encryption_key_name == null ? [] : [1]
    content {
      state    = "ENCRYPTED"
      key_name = var.database_encryption_key_name
    }
  }

  lifecycle {
    ignore_changes = [
      # GKE rewrites this after creation; without the exemption every plan shows
      # a spurious diff.
      initial_node_count,
    ]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Node pool, managed separately from the cluster.
#
# Keeping it a distinct resource means the pool can be replaced (new machine
# type, new disk, new image) without touching the cluster or its control plane.
# ─────────────────────────────────────────────────────────────────────────────
resource "google_container_node_pool" "primary" {
  project  = var.project_id
  name     = "${var.cluster_name}-pool"
  location = var.region
  cluster  = google_container_cluster.primary.name

  # PER ZONE, not in total. The cluster is regional, so this is 1-3 nodes in
  # each of three zones: a floor of 3 and a ceiling of 9.
  node_count = null

  autoscaling {
    min_node_count  = var.min_nodes_per_zone
    max_node_count  = var.max_nodes_per_zone
    location_policy = "BALANCED"
  }

  management {
    # auto_repair replaces a node that fails health checks; auto_upgrade keeps
    # the kubelet in step with the control plane. Both are safe precisely
    # because the workload has a PDB and a zero-downtime rollout -- a drain is
    # a non-event. Without those, autopilot node replacement would cause
    # outages, and the usual reaction is to disable it, which is backwards.
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    # Sized for the LGTM stack, not for the app. The app requests 200m/256Mi;
    # Prometheus + Loki + Tempo + Grafana + Alloy together want roughly 4-6 vCPU
    # and 8-12 GB. On e2-medium the observability stack simply never schedules,
    # which presents as mysterious Pending pods rather than an obvious error.
    machine_type = var.machine_type
    disk_type    = var.disk_type
    disk_size_gb = var.disk_size_gb
    image_type   = "COS_CONTAINERD"

    # Spot VMs: 60-90% cheaper, reclaimable at ~30 seconds' notice.
    #
    # false for production, and that default is the important part. But for a
    # demo run this is more than a cost lever: preemption exercises the PDB and
    # the graceful-drain path under conditions that are otherwise hard to
    # manufacture. A node vanishing mid-rollout is exactly the scenario
    # maxUnavailable: 0 + minAvailable: 1 exist for.
    #
    # One honest caveat rather than a claim it is free of tension: GKE's node
    # shutdown window for a preempted Spot VM is shorter than this workload's
    # terminationGracePeriodSeconds (30s), so a preemption can cut the drain
    # short. That is a real limit of Spot, not a flaw in the drain sequence —
    # and observing it is part of what makes the demo worth running. The
    # protection that still holds is the surge replica plus the PDB.
    spot = var.spot

    # The least-privilege SA from the iam module. Leaving this unset is the
    # trap: GKE then uses the Compute Engine default SA, which holds
    # roles/editor on the entire project.
    service_account = var.node_service_account_email

    # cloud-platform + IAM roles is the modern pattern: scopes act as a coarse
    # ceiling and the SA's roles do the actual authorisation. Hand-listing
    # narrow scopes here instead is a legacy approach that breaks in
    # hard-to-diagnose ways.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # THE line that makes Workload Identity real on the data plane. GKE_METADATA
    # runs the metadata server proxy, which blocks pods from reading the node's
    # own identity and serves them their KSA-bound token instead. Without it the
    # cluster-level workload_pool is decorative.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Must match the target_tags on the firewall rules in the network module,
    # or none of them apply and control-plane-to-webhook traffic is dropped.
    tags = [var.node_tag]

    labels = {
      environment = var.environment
    }

    metadata = {
      # Blocks the v1beta1 legacy metadata endpoints, which ignore the
      # GKE_METADATA protections above.
      disable-legacy-endpoints = "true"
    }
  }

  lifecycle {
    # The autoscaler owns the live node count; without this every plan after a
    # scaling event would propose reverting it.
    ignore_changes = [node_count]
  }
}
