output "node_service_account_email" {
  description = "Node SA e-mail, consumed by the gke module's node pool."
  value       = google_service_account.node.email
}

output "app_service_account_email" {
  description = "Application GSA e-mail. This exact string must appear in the iam.gke.io/gcp-service-account annotation on the KSA -- see k8s/overlays/prod/patches/serviceaccount-wi.yaml."
  value       = google_service_account.app.email
}

output "app_service_account_id" {
  description = "Fully qualified GSA resource name. Consumed by the root module, which owns the Workload Identity binding because that binding must be created after the cluster."
  value       = google_service_account.app.name
}

output "ksa_annotation" {
  description = "Copy-paste value for the KSA annotation, so the two halves of the binding cannot drift apart by transcription error."
  value       = "iam.gke.io/gcp-service-account: ${google_service_account.app.email}"
}
