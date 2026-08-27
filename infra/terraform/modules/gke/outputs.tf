output "cluster_name" {
  description = "Cluster name."
  value       = google_container_cluster.primary.name
}

output "cluster_location" {
  description = "Cluster region. Needed by `gcloud container clusters get-credentials --region`."
  value       = google_container_cluster.primary.location
}

output "cluster_endpoint" {
  description = "Control-plane endpoint. Reachable only from master_authorized_networks."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Cluster CA, base64. Marked sensitive so it never lands in CI logs."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "workload_identity_pool" {
  description = "The workload pool. Every Workload Identity member string is scoped to this."
  value       = google_container_cluster.primary.workload_identity_config[0].workload_pool
}

output "get_credentials_command" {
  description = "Ready-to-run kubectl bootstrap command, so the region/project pair cannot be mistyped."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${google_container_cluster.primary.location} --project ${var.project_id}"
}
