output "network_name" {
  description = "VPC name, consumed by the gke module."
  value       = google_compute_network.vpc.name
}

output "network_id" {
  description = "Fully qualified VPC id."
  value       = google_compute_network.vpc.id
}

output "subnet_name" {
  description = "Subnet name, consumed by the gke module."
  value       = google_compute_subnetwork.subnet.name
}

output "subnet_id" {
  description = "Fully qualified subnet id."
  value       = google_compute_subnetwork.subnet.id
}

output "pods_range_name" {
  description = "Secondary range name for Pods. The gke module binds ip_allocation_policy to this, which is what makes the cluster VPC-native."
  value       = google_compute_subnetwork.subnet.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "Secondary range name for Service ClusterIPs."
  value       = google_compute_subnetwork.subnet.secondary_ip_range[1].range_name
}

output "node_tag" {
  description = "Network tag the firewall rules target. The node pool must apply this tag or none of the rules above take effect."
  value       = "${var.name_prefix}-node"
}

output "master_ipv4_cidr_block" {
  description = "Control-plane /28, passed through so address planning stays in one module."
  value       = var.master_ipv4_cidr_block
}
