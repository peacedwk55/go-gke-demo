variable "project_id" {
  description = "GCP project that owns the network."
  type        = string
}

variable "region" {
  description = "Region for the subnet, Cloud Router and Cloud NAT."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to every resource name, so several environments can coexist in one project."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary range of the subnet: the node IPs live here. /24 gives 254 usable addresses, far more than the 9-node ceiling of the pool."
  type        = string
  default     = "10.10.0.0/24"
}

variable "pods_cidr" {
  description = <<-EOT
    Secondary range for Pod IPs. This is the sizing decision that cannot be
    changed later without rebuilding the cluster, so it is deliberately generous.

    GKE allocates a /24 of this range to each node (110 pods per node by
    default). A /17 therefore supports 128 nodes -- roughly 14x the 9-node
    ceiling of the current pool, leaving room to grow the node pool or add
    another one without renumbering.
  EOT
  type        = string
  default     = "10.20.0.0/17"
}

variable "services_cidr" {
  description = "Secondary range for Service ClusterIPs. A /22 gives 1024 Services, which is ample; unlike the Pod range this one is cheap to over-provision because it consumes no per-node allocation."
  type        = string
  default     = "10.30.0.0/22"
}

variable "master_ipv4_cidr_block" {
  description = "The /28 that GKE uses for the private control plane. Must not overlap any other range in the VPC. Consumed by the gke module, declared here so all address planning lives in one file."
  type        = string
  default     = "172.16.0.0/28"
}
