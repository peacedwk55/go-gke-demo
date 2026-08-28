#!/usr/bin/env bash
#
# Repository invariants — the rules that must hold everywhere, checked cheaply.
#
# Run locally before pushing; CI runs exactly this script, so a green local run
# means a green CI check:
#
#   ./scripts/check-invariants.sh
#
# ─────────────────────────────────────────────────────────────────────────────
# Why this lives in scripts/ and not inline in the workflow
# ─────────────────────────────────────────────────────────────────────────────
#
# The "no kubectl in CI" check greps .github/workflows/. Written inline, the step
# matched its OWN name and its own grep pattern and failed on itself — observed,
# not theorised. Moving the checks out of the scanned directory removes the
# self-reference, and has the better side effect of making every invariant
# runnable on a laptop instead of only in CI.
#
# ─────────────────────────────────────────────────────────────────────────────
# Comment filtering
# ─────────────────────────────────────────────────────────────────────────────
#
# These files are heavily commented, and several comments explain the very rule
# being enforced ("never :latest", "never docker.io directly"). Unfiltered, the
# checks fail on their own documentation. The filter drops WHOLE-LINE comments
# only, so a real violation with a trailing comment is still caught.

set -euo pipefail

cd "$(dirname "$0")/.."

FAILED=0
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; RESET=$'\033[0m'

# Drops lines that are whole-line comments, given grep -n output
# (path:lineno:content).
strip_comments() { grep -vE ':[0-9]+:[[:space:]]*(#|//)' || true; }

pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; }
fail() {
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
    # GitHub Actions annotation; harmless noise locally.
    printf '::error::%s\n' "$1"
    FAILED=1
}

check() {
    local name="$1" hits="$2"
    if [ -n "$hits" ]; then
        fail "$name"
        printf '%s\n' "$hits" | sed 's/^/          /'
    else
        pass "$name"
    fi
}

echo "Repository invariants"
echo

# ── 1. No moving image tags ─────────────────────────────────────────────────
# A moving tag means "what is in production?" has no answer and a rollback is a
# race against whatever the tag points to now.
#
# `enforce-version: latest` is excluded: the restricted Pod Security Standard
# label legitimately uses that literal word and is not an image tag.
check "no ':latest' image tags" "$(
    grep -rn ':latest' \
        --include='*.yaml' --include='*.yml' --include='Dockerfile' \
        k8s/ argocd/ docker/ observability/ ansible/ 2>/dev/null \
        | grep -v 'enforce-version' \
        | strip_comments
)"

# ── 2. No service account keys ──────────────────────────────────────────────
# The Workload Identity guarantee, enforced rather than asserted. Anchored on
# `resource "..."` so the comment in modules/iam/main.tf that names the resource
# type — to explain why it is absent — does not trip the check.
check "no google_service_account_key resources" "$(
    grep -rEn '^[[:space:]]*resource[[:space:]]+"google_service_account_key"' \
        --include='*.tf' . 2>/dev/null || true
)"

# ── 3. No kubectl in CI ─────────────────────────────────────────────────────
# The core property of pull-based GitOps: CI holds no cluster credentials and
# applies nothing. ArgoCD, running inside the cluster, pulls.
#
# Matched as a command invocation (whitespace- or line-delimited) rather than as
# a bare substring, so prose mentioning the word is not a violation.
check "no kubectl invocation in .github/workflows" "$(
    grep -rnE '(^|[[:space:]|&;(])kubectl[[:space:]]' .github/workflows/ 2>/dev/null \
        | strip_comments \
        | grep -vE 'echo|printf' \
        || true
)"

# ── 4. Prod pulls through Artifact Registry ─────────────────────────────────
# CI PUSHES to Docker Hub; GKE PULLS through the AR remote repository. Every
# private node egresses via one Cloud NAT IP, so pulling from Docker Hub directly
# would share a single per-IP rate limit across the whole cluster — and the
# failure mode is ImagePullBackOff with a 429, mid-deploy.
#
# k8s/overlays/dev is exempt: a local kind cluster has neither the NAT bottleneck
# nor GCP credentials.
check "prod manifests do not reference docker.io" "$(
    grep -rn 'docker\.io' k8s/base k8s/overlays/prod 2>/dev/null \
        | strip_comments
)"

# ── 5. The HPA owns the replica count ───────────────────────────────────────
# A spec.replicas on the Deployment would make ArgoCD selfHeal revert every
# scale-up the HPA performs, forever. Two-space indent = a key under spec:.
check "Deployment does not pin spec.replicas" "$(
    grep -rnE '^[[:space:]]{2}replicas:' \
        k8s/base/deployment.yaml k8s/overlays/*/patches/*.yaml 2>/dev/null || true
)"

# ── 6. GitHub Actions are pinned ────────────────────────────────────────────
# `uses: foo@main` is a supply-chain hole: the action's code can change under you
# between runs. A tag is the minimum; a commit SHA is stricter still.
check "GitHub Actions are not pinned to a moving ref" "$(
    grep -rnE 'uses:[[:space:]]*[^[:space:]]+@(main|master|latest|v[0-9]+\.x)' \
        .github/workflows/ 2>/dev/null || true
)"

# ── 7. Every directory documents itself ─────────────────────────────────────
# "Every directory ships with a README explaining why, not just how."
missing=""
for d in app docker k8s infra/terraform argocd observability ansible; do
    [ -f "$d/README.md" ] || missing="${missing}${missing:+, }$d"
done
check "every top-level directory has a README" "$missing"

# ── 8. Standalone HTML declares its encoding ────────────────────────────────
# repo-guide.html is authored as an Artifact fragment, where the platform
# supplies <head> at publish time. Opened as a local file that same content has
# no charset declaration, a browser falls back to a legacy single-byte encoding,
# and every Thai character renders as mojibake. The bytes are valid UTF-8; only
# the declaration is missing — which is exactly the kind of bug that survives
# review, because the published page looks fine.
#
# Browsers stop looking for a charset after the first 1024 bytes, so checking
# the whole file would pass while the browser still ignored it.
noenc=""
for f in *.html; do
    [ -f "$f" ] || continue
    head -c 1024 "$f" | grep -qi 'charset' || noenc="${noenc}${noenc:+, }$f"
done
check "root HTML declares charset in the first 1024 bytes" "$noenc"

echo
if [ "$FAILED" -ne 0 ]; then
    echo "One or more invariants failed."
    exit 1
fi
echo "All invariants hold."
