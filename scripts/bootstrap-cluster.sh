#!/usr/bin/env bash
#
# Bootstrap: hand a freshly-applied cluster over to ArgoCD.
#
# This is the ONE imperative step in the whole system. Everything after it
# arrives through Git — which is why it is a script rather than a runbook: the
# step that hands control to GitOps should itself be reproducible.
#
# Run AFTER `terraform apply` has finished:
#
#   ./scripts/bootstrap-cluster.sh <dockerhub-user> <github-owner/repo>
#
# Both arguments are required and neither has a sensible default:
#   - the Docker Hub user is half of the image path the manifests pull
#   - the GitHub repo is where ArgoCD pulls from; without it there is nothing
#     to sync and the whole pull-based model has no source

set -euo pipefail

cd "$(dirname "$0")/.."

DOCKERHUB_USER="${1:-}"
GH_REPO="${2:-}"
ARGOCD_VERSION="v2.13.2" # pinned: fetching the moving `stable` manifest is how
                         # you end up running a version nobody chose

if [ -z "$DOCKERHUB_USER" ] || [ -z "$GH_REPO" ]; then
    cat >&2 <<'USAGE'
usage: ./scripts/bootstrap-cluster.sh <dockerhub-user> <github-owner/repo>

  example: ./scripts/bootstrap-cluster.sh santiphap santiphap/go-gke-demo

Both are required. The Docker Hub repository must be PUBLIC — the Artifact
Registry remote repository pulls from it anonymously.
USAGE
    exit 1
fi

TF_DIR="infra/terraform/envs/prod"
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
step() { printf '\n%s──%s %s\n' "$DIM" "$RESET" "$1"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
die()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
step "1. Read the facts the workload layer needs from the infrastructure layer"
# ─────────────────────────────────────────────────────────────────────────────
#
# Taken from `terraform output` rather than retyped. These two strings are the
# seam between Terraform and Kubernetes, and a typo in either produces a
# failure with no useful error: a wrong GSA e-mail means Workload Identity
# authorises nothing, a wrong registry path means ImagePullBackOff.
PROJECT_ID="$(terraform -chdir="$TF_DIR" output -raw project_id 2>/dev/null || true)"
[ -n "$PROJECT_ID" ] || PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[ -n "$PROJECT_ID" ] || die "could not determine the project id"

IMAGE_REPO="$(terraform -chdir="$TF_DIR" output -raw image_repository)" \
    || die "terraform output failed — has apply finished?"
GET_CREDS="$(terraform -chdir="$TF_DIR" output -raw get_credentials_command)"

ok "project        $PROJECT_ID"
ok "image repo     $IMAGE_REPO"

# ─────────────────────────────────────────────────────────────────────────────
step "2. Substitute the placeholders the repository deliberately ships with"
# ─────────────────────────────────────────────────────────────────────────────
#
# PROJECT_ID, DOCKERHUB_USER and GH_OWNER/GH_REPO are committed as literal
# placeholders so the repository carries no environment-specific identifiers.
# This is where they become real.
subst() {
    local f="$1"
    sed -i \
        -e "s|PROJECT_ID|${PROJECT_ID}|g" \
        -e "s|DOCKERHUB_USER|${DOCKERHUB_USER}|g" \
        -e "s|GH_OWNER/GH_REPO|${GH_REPO}|g" \
        "$f"
}
for f in k8s/overlays/prod/kustomization.yaml \
         k8s/overlays/prod/patches/serviceaccount-wi.yaml \
         k8s/overlays/dev/kustomization.yaml \
         argocd/projects/app-project.yaml \
         argocd/projects/observability-project.yaml \
         argocd/apps/app-prod.yaml \
         argocd/apps/observability.yaml; do
    subst "$f"
    ok "$f"
done

# Fail loudly if any placeholder survived — a leftover one means a silent
# misconfiguration later, which is exactly what this check exists to prevent.
if grep -rn 'PROJECT_ID\|DOCKERHUB_USER\|GH_OWNER' k8s/ argocd/ 2>/dev/null; then
    die "placeholders remain — see the lines above"
fi
ok "no placeholders remain"

# ─────────────────────────────────────────────────────────────────────────────
step "3. kubectl credentials"
# ─────────────────────────────────────────────────────────────────────────────
#
# This only works if your public IP is still in master_authorized_networks. If
# it times out, your address has changed: re-check `curl -s https://ifconfig.me`
# and re-apply.
eval "$GET_CREDS"
kubectl cluster-info >/dev/null || die "cannot reach the control plane — is your IP still in master_authorized_networks?"
ok "connected"
kubectl get nodes -o custom-columns=NODE:.metadata.name,ZONE:.metadata.labels.'topology\.kubernetes\.io/zone',READY:.status.conditions[-1].type --no-headers

# ─────────────────────────────────────────────────────────────────────────────
step "4. Install ArgoCD"
# ─────────────────────────────────────────────────────────────────────────────
#
# ArgoCD does not manage its own installation here — that would be circular.
# This is the only `kubectl apply` a human runs against the cluster.
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
ok "ArgoCD ${ARGOCD_VERSION} ready"

# ─────────────────────────────────────────────────────────────────────────────
step "5. Grafana admin secret"
# ─────────────────────────────────────────────────────────────────────────────
#
# Created out of band, never committed. observability/kube-prometheus-stack
# .values.yaml references it by name via `admin.existingSecret`, so the LGTM
# sync in the next step will fail without it.
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if kubectl -n observability get secret grafana-admin >/dev/null 2>&1; then
    ok "grafana-admin already exists"
else
    GRAFANA_PW="$(openssl rand -base64 24)"
    kubectl -n observability create secret generic grafana-admin \
        --from-literal=admin-user=admin \
        --from-literal=admin-password="$GRAFANA_PW" >/dev/null
    ok "grafana-admin created"
    printf '     %susername%s admin\n' "$DIM" "$RESET"
    printf '     %spassword%s %s\n' "$DIM" "$RESET" "$GRAFANA_PW"
    printf '     %s^ save this now; it is not stored anywhere else%s\n' "$DIM" "$RESET"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "6. Hand control to Git"
# ─────────────────────────────────────────────────────────────────────────────
#
# From this point on, the cluster's contents are whatever is in the repository.
# Note the ordering: projects before apps, because an Application referencing a
# project that does not exist is rejected.
kubectl apply -f argocd/projects/
kubectl apply -f argocd/apps/
ok "projects and applications applied"

cat <<EOF

$(printf '%s' "$DIM")────────────────────────────────────────────────────────$(printf '%s' "$RESET")

Git now drives the cluster. Watch the sync:

  kubectl -n argocd get applications -w

Reach the ArgoCD UI (port-forward, not an Ingress — the UI is
cluster-admin-equivalent and does not belong on the internet without SSO):

  kubectl -n argocd port-forward svc/argocd-server 8080:443
  kubectl -n argocd get secret argocd-initial-admin-secret \\
    -o jsonpath='{.data.password}' | base64 -d

Reach Grafana once the observability apps are Healthy:

  kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80

REMEMBER the cluster is billing. When finished:

  terraform -chdir=$TF_DIR destroy -var-file=demo.tfvars
  gcloud compute disks list --filter="-users:*"   # LGTM PVCs outlive destroy

EOF
