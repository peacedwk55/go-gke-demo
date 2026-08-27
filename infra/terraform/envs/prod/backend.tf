terraform {
  required_version = ">= 1.5"

  # Remote state in GCS.
  #
  # Why not local state: the state file is the record of what exists. Locally it
  # is unshareable, unbackuppable and one laptop failure away from an
  # unmanageable cluster. GCS also gives state locking, so two concurrent
  # applies cannot interleave and corrupt it.
  #
  # The bucket must exist before `terraform init` and must have Object
  # Versioning enabled -- versioning is what makes a bad apply recoverable.
  # Create it once, by hand, outside Terraform (a chicken-and-egg otherwise):
  #
  #   gcloud storage buckets create gs://<project>-tfstate \
  #     --location=asia-southeast1 --uniform-bucket-level-access
  #   gcloud storage buckets update gs://<project>-tfstate --versioning
  #
  # The bucket name is intentionally NOT templated: backend config cannot use
  # variables. Either edit it here per project, or pass it at init time:
  #
  #   terraform init -backend-config="bucket=<project>-tfstate"
  #
  # State contains the cluster CA and endpoint, so it is sensitive. Restrict the
  # bucket to the Terraform principals only -- and note that with Workload
  # Identity there are no service account keys in state to leak.
  backend "gcs" {
    bucket = "REPLACE_ME-tfstate"
    prefix = "gke/prod"
  }
}
