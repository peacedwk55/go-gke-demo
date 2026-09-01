variable "project_id" {
  description = "GCP project that owns the cluster."
  type        = string
}

variable "region" {
  description = "Region for the REGIONAL cluster. A region here (not a zone) is what makes the control plane and node pools multi-zone."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name."
  type        = string
}

variable "environment" {
  description = "Environment label applied to nodes."
  type        = string
  default     = "prod"
}

# ── Network wiring (all from the network module's outputs) ───────────────────

variable "network_name" {
  type        = string
  description = "VPC name."
}

variable "subnet_name" {
  type        = string
  description = "Subnet name."
}

variable "pods_range_name" {
  type        = string
  description = "Secondary range name for Pods."
}

variable "services_range_name" {
  type        = string
  description = "Secondary range name for Services."
}

variable "node_tag" {
  type        = string
  description = "Network tag applied to nodes. Must match the firewall rules' target_tags."
}

variable "master_ipv4_cidr_block" {
  type        = string
  description = "The /28 GKE uses for the private control plane. Must not overlap any other range in the VPC."
}

variable "node_service_account_email" {
  type        = string
  description = "Least-privilege node SA from the iam module. Leaving this empty makes GKE fall back to the Compute Engine default SA, which holds roles/editor."
}

# ── Control-plane access ────────────────────────────────────────────────────

variable "master_authorized_networks" {
  description = <<-EOT
    CIDRs permitted to reach the control plane.

    This is the answer to "how does Task 5's `kubectl apply -f argocd/` work
    against a private cluster?" -- the operator's own IP goes here as a /32.
    Production would use IAP TCP forwarding through a bastion, or GKE Connect
    Gateway, and drop the public endpoint entirely.

    The validation below rejects 0.0.0.0/0, so the single worst misconfiguration
    cannot be introduced through a tfvars file.
  EOT
  type = list(object({
    cidr_block   = string
    display_name = string
  }))

  validation {
    condition     = length([for n in var.master_authorized_networks : n if n.cidr_block == "0.0.0.0/0"]) == 0
    error_message = "master_authorized_networks must not contain 0.0.0.0/0 -- that exposes the Kubernetes API to the entire internet. Use your own IP as a /32, or a bastion subnet."
  }

  validation {
    condition     = length(var.master_authorized_networks) > 0
    error_message = "At least one authorized network is required, or nothing can reach the control plane and the cluster cannot be bootstrapped."
  }
}

# ── Node sizing ─────────────────────────────────────────────────────────────

variable "machine_type" {
  description = "Node machine type. e2-standard-4 (4 vCPU / 16 GB) is sized for the LGTM stack of Task 6, not for the app -- the observability stack needs ~4-6 vCPU and 8-12 GB in aggregate and will not schedule on smaller nodes."
  type        = string
  default     = "e2-standard-4"
}

variable "disk_type" {
  description = "pd-balanced: SSD-class latency at roughly half the price of pd-ssd. pd-standard would bottleneck etcd-adjacent and Prometheus write workloads."
  type        = string
  default     = "pd-balanced"
}

variable "disk_size_gb" {
  description = "Node boot disk. 50 GB leaves room for the container image cache; the default 100 GB is more than this workload needs and is billed per node."
  type        = number
  default     = 50
}

variable "min_nodes_total" {
  description = <<-EOT
    Autoscaler floor, TOTAL across the region — not per zone.

    Must stay >= 3 on a three-zone regional cluster, for two separate reasons:

      1. The topologySpreadConstraints and pod anti-affinity in
         k8s/base/deployment.yaml need more than one zone and more than one node
         to mean anything at all.
      2. The LGTM stack's PVCs bind to ZONAL disks, which pin each pod to one
         zone for the life of the volume. Drop below one node per zone and those
         pods go Pending with no way to recover — see observability/README.md.

    Expressed as a total rather than per-zone because the per-zone form did not
    behave as documented: min_node_count = 1 across three zones produced a
    single node, and stayed there. See the autoscaling block in main.tf.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.min_nodes_total >= 3
    error_message = "min_nodes_total must be at least 3 — one node per zone. Fewer leaves the observability stack's zonal PVCs unschedulable and makes the zone-spreading in the Deployment meaningless."
  }
}

variable "max_nodes_total" {
  description = "Autoscaler ceiling, TOTAL across the region. 9 leaves each of three zones room to reach 3 nodes."
  type        = number
  default     = 9

  validation {
    condition     = var.max_nodes_total >= var.min_nodes_total
    error_message = "max_nodes_total must be >= min_nodes_total."
  }
}

# ── Optional hardening ──────────────────────────────────────────────────────

variable "spot" {
  description = <<-EOT
    Use Spot VMs for the node pool. 60-90% cheaper, reclaimable at short notice.

    false for production. Set true for a demo run, where preemption is a feature
    rather than a risk: it exercises the PDB and the graceful-drain path under
    conditions that are hard to manufacture deliberately.

    Caveat worth knowing before enabling it in earnest: GKE's shutdown window for
    a preempted Spot VM is shorter than this workload's
    terminationGracePeriodSeconds (30s), so a preemption can truncate the drain.
    The surge replica and the PDB are what still hold in that case.
  EOT
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Blocks accidental cluster deletion. Because it is stored in state, teardown requires `terraform apply -var deletion_protection=false` BEFORE `terraform destroy`."
  type        = bool
  default     = true
}

variable "database_encryption_key_name" {
  description = "Cloud KMS key for application-layer etcd secret encryption. Null (the default) leaves GKE's own envelope encryption in place; supplying a key needs a KMS keyring, which is out of scope here."
  type        = string
  default     = null
}
