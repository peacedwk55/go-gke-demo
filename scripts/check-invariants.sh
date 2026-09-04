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

# ── 9. Every `uses:` ref actually exists ────────────────────────────────────
# Requires network; skipped without it so a laptop with no connection still gets
# the other eight checks.
#
# This exists because of a real failure that nothing else caught:
#
#   Error: Unable to resolve action `aquasecurity/trivy-action@0.28.0`,
#          unable to find version `0.28.0`
#
# The tag is v0.28.0. The `v` was missing. GitHub reports this as a failure in
# "Set up job" — before any step runs — so the log gives no hint about which
# action is at fault, and the whole job's real work never executes.
#
# actionlint cannot catch it: verifying that a tag exists needs a network call,
# and actionlint deliberately makes none. So a linter pass is not evidence that
# the workflow can start.
#
# ── What this check does NOT cover ──────────────────────────────────────────
#
# Only top-level `uses:` refs in our own workflows. Composite actions carry
# their own nested `uses:`, resolved at the same "Set up job" moment, and those
# are invisible here.
#
# That gap is not hypothetical — it is the second failure this repository hit:
#
#   trivy-action@v0.28.0  ->  uses: aquasecurity/setup-trivy@v0.2.1
#
# That inner tag had been deleted upstream (404; setup-trivy now publishes
# v0.2.6 and later), so v0.28.0 of trivy-action is permanently unusable and the
# job fails at setup naming neither action. This check passed on it, because the
# ref WE wrote was valid.
#
# Chasing nested refs recursively would be fragile and still incomplete. The
# real protection is upstream's own fix: newer trivy-action versions pin
# setup-trivy by commit SHA rather than by tag, which cannot be retagged out
# from under them. Same reason a SHA beats a tag in our own workflows.
# ── "cannot verify" is not "invalid" ────────────────────────────────────────
#
# The first version of this check treated any failed curl as a bad ref. That is
# wrong, and it turned the check red in CI on refs that were perfectly fine:
# unauthenticated GitHub API calls are limited to 60/hour PER IP, Actions
# runners share IPs, and this check makes up to two calls per ref. The quota is
# routinely already spent before the job starts.
#
# So the status code decides:
#     200  -> the ref exists
#     404  -> the ref does not exist        <- the only failure
#   other  -> we could not tell (rate limit, outage, timeout) -> skip, say so
#
# A check that cannot distinguish "broken" from "unknown" produces exactly the
# kind of red that people learn to ignore.
gh_status() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -s -m 10 -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" "$1" 2>/dev/null || echo 000
    else
        curl -s -m 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000
    fi
}

if [ "${SKIP_NETWORK_CHECKS:-}" = "1" ]; then
    printf '  %sSKIP%s  every workflow action ref resolves (SKIP_NETWORK_CHECKS=1)\n' "$RED" "$RESET"
else
    badrefs=""
    unknown=0
    # `while read` rather than `for` over a command substitution: an action ref
    # never contains whitespace today, but word-splitting a URL list is the kind
    # of shortcut that breaks quietly later (shellcheck SC2013).
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        repo="${u%@*}"
        ref="${u#*@}"
        # A ref may be a tag or a branch, so a 404 on tags is not yet a verdict.
        st="$(gh_status "https://api.github.com/repos/$repo/git/ref/tags/$ref")"
        [ "$st" = "404" ] && st="$(gh_status "https://api.github.com/repos/$repo/commits/$ref")"
        case "$st" in
            200) ;;
            404) badrefs="${badrefs}${badrefs:+$'\n'}$u  (404)" ;;
            *)   unknown=$((unknown + 1)) ;;
        esac
    done < <(grep -hoE 'uses: [^ ]+' .github/workflows/*.y*ml 2>/dev/null | cut -d' ' -f2 | sort -u)

    if [ -n "$badrefs" ]; then
        check "every workflow action ref resolves" "$badrefs"
    elif [ "$unknown" -gt 0 ]; then
        printf '  %sSKIP%s  every workflow action ref resolves (%d unverifiable — rate limit or no network)\n' \
            "$RED" "$RESET" "$unknown"
        printf '        set GITHUB_TOKEN to raise the API quota from 60/hour to 5000\n'
    else
        pass "every workflow action ref resolves"
    fi
fi

# ── 10. No accidental CI skip token in the commits about to be pushed ───────
#
# GitHub scans the ENTIRE commit message for the CI skip tokens, body as well as
# subject. Quoting one is therefore indistinguishable from using it.
#
# That happened here. 863b908 was a docs commit whose message explained the loop
# protection and, in explaining it, contained the token. It produced no workflow
# run at all — and a missing run looks exactly like a path-filtered push, so
# nothing pointed at the cause. It surfaced only because the run NUMBERS skipped:
# CI #7 was the commit before it and CI #8 the commit after.
#
# On a docs commit that costs nothing. On a code commit it means the tests, the
# Trivy scan and the image build are all silently skipped, and main now carries
# unverified code.
#
# ── Why this is scoped to unpushed commits ─────────────────────────────────
#
# Because CI structurally CANNOT catch this: the offending commit is precisely
# the one that gets no run, so a check living only in CI is blind to it by
# definition. The useful moment is before the push, on a laptop — the same reason
# every invariant here is runnable locally.
#
# In CI the range is empty and this check is a no-op, and it says so rather than
# printing a green that would be meaningless.
SKIP_RE='\[(skip ci|ci skip|no ci|skip actions|actions skip)\]'

if ! git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf '  %sSKIP%s  no accidental skip token in unpushed commits (no origin/main)\n' "$RED" "$RESET"
elif [ -z "$(git rev-list origin/main..HEAD 2>/dev/null)" ]; then
    printf '  %sSKIP%s  no accidental skip token in unpushed commits (nothing unpushed)\n' "$RED" "$RESET"
else
    offenders=""
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        # The bump commit uses the token deliberately; that is the loop
        # protection working, not a mistake.
        case "$(git log -1 --format=%s "$sha")" in
            'chore(deploy):'*) continue ;;
        esac
        if git log -1 --format=%B "$sha" | grep -qiE "$SKIP_RE"; then
            offenders="${offenders}${offenders:+$'\n'}$(git log -1 --format='%h %s' "$sha")"
        fi
    done < <(git rev-list origin/main..HEAD)
    if [ -n "$offenders" ]; then
        fail "no accidental skip token in unpushed commits"
        printf '%s\n' "$offenders" | sed 's/^/          /'
        printf '        These commits get NO workflow run at all.\n'
        printf '        Write "the skip token" in prose instead of the literal text.\n'
    else
        pass "no accidental skip token in unpushed commits"
    fi
fi

# ── 11. No Terraform plan archive is tracked ────────────────────────────────
#
# `terraform plan -out=tfplan` writes an archive that embeds a FULL tfstate
# snapshot and every variable value. Committing one publishes infrastructure
# detail that never belonged in Git.
#
# It happened twice here. .gitignore said `*.tfplan`, which does not match a file
# literally named `tfplan` — the name the README and the Terraform workflow both
# use. The rule looked like it covered the case.
#
# Two reasons nothing caught it:
#   - the zip entries are compressed, so the contents are not
#     plaintext-searchable; gitleaks and GitHub secret scanning both stayed quiet
#   - a check on the FILENAME would have repeated the .gitignore mistake
#
# So this looks INSIDE tracked files: a zip whose entries include `tfstate` is a
# plan archive whatever it is called.
#
# Worth stating plainly: no credential leaked, and that is not luck. Workload
# Identity means no service-account key exists anywhere to be captured in state.
# Invariant 2 enforces that; this one limits the blast radius when state does
# escape.
# ── How this is detected, and why not with Python ───────────────────────────
#
# The first version shelled out to a Python one-liner using zipfile. It reported
# PASS on a tracked plan archive — because `python3` on the author's machine is
# the Microsoft Store App Execution Alias stub, which is not an interpreter: it
# prints a message and exits 49. `command -v python3` finds it, so it was chosen,
# every invocation failed, and `2>/dev/null` swallowed the evidence.
#
# That is the same mistake as invariant 9's first version wearing a different
# costume: a broken tool reported as a clean result. A check that cannot run must
# say so, never pass.
#
# The fix removes the dependency instead of guarding it. A zip stores entry NAMES
# uncompressed, in both the local headers and the central directory, so a plain
# grep over the raw bytes finds them — no interpreter, nothing to be missing.
# `head -c2` = "PK" gates it to actual archives first.
#
# This errs toward flagging: a PK-prefixed file containing the literal text
# `tfstate` trips it even if it is not a plan. That is the right direction for a
# check whose miss published a state snapshot.
planfiles=""
while IFS= read -r f; do
    [ -f "$f" ] || continue
    [ "$(head -c2 "$f" 2>/dev/null)" = "PK" ] || continue
    grep -qa 'tfstate' "$f" 2>/dev/null && planfiles="${planfiles}${planfiles:+$'
'}$f"
done < <(git ls-files)
check "no Terraform plan archive is tracked" "$planfiles"

echo
if [ "$FAILED" -ne 0 ]; then
    echo "One or more invariants failed."
    exit 1
fi
echo "All invariants hold."
