output "cluster_name" {
  value = module.gke.cluster_name
}

output "cluster_location" {
  value = module.gke.cluster_location
}

output "get_credentials_command" {
  description = "Step 1 of the ArgoCD bootstrap in Task 5."
  value       = module.gke.get_credentials_command
}

output "workload_identity_pool" {
  value = module.gke.workload_identity_pool
}

output "app_service_account_email" {
  description = "Substitute into the KSA annotation in k8s/overlays/prod/patches/serviceaccount-wi.yaml."
  value       = module.iam.app_service_account_email
}

output "ksa_annotation" {
  description = "The exact annotation line for the KSA, so the two halves of the Workload Identity binding cannot drift apart by transcription error."
  value       = module.iam.ksa_annotation
}

output "node_service_account_email" {
  value = module.iam.node_service_account_email
}

output "image_repository" {
  description = <<-EOT
    The PULL path for manifests. Substitute into
    k8s/overlays/prod/kustomization.yaml, replacing PROJECT_ID and
    DOCKERHUB_USER, and use it as the target of `kustomize edit set image` in CI.

    Reminder: images are PUSHED to docker.io/<user>/go-sample-app. This URL is a
    read-through cache and cannot be pushed to.
  EOT
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dockerhub_remote.repository_id}"
}

output "kustomize_set_image_command" {
  description = "Copy-paste bump command, with the registry path already resolved. DOCKERHUB_USER and TAG still need filling in."
  value       = "kustomize edit set image go-sample-app=${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dockerhub_remote.repository_id}/DOCKERHUB_USER/go-sample-app:TAG"
}
