# Workflows

Two pipelines with deliberately different endings.

| | `ci.yaml` | `terraform.yaml` |
|---|---|---|
| Triggered by | `app/` `docker/` `k8s/base/` `scripts/` … | `infra/terraform/**` |
| Gates | tests · 11 invariants · kubeconform · Trivy IaC · Trivy image | `fmt` · `validate` · `plan` |
| Ends with | a Git commit — ArgoCD does the rest, unattended | **a plan for a human to read** |
| Touches the cluster | never | never |

The asymmetry is the point, and it is calibrated to how reversible a mistake is.
A bad application deploy stops itself — readiness fails and the rollout halts —
and `git revert` undoes it in about forty seconds with zero dropped requests
(measured: `ok=13437 bad=0`). A bad `terraform apply` can delete a cluster, and
no revert brings it back.

---

## `ci.yaml` — the order is load-bearing

```
test  →  invariants  →  render + validate  →  build  →  scan  →  push  →  bump
```

**Scan before push, not after.** Reversed, a vulnerable image is already
pullable by the time anything objects. The build produces a local tarball, Trivy
reads that, and only a clean result is pushed.

**Two registries, one tag.** CI *pushes* to Docker Hub; the manifest it commits
points at the Artifact Registry remote repository with the *same* tag. Private
nodes all egress through one Cloud NAT IP, so pulling from Docker Hub directly
would share a single per-IP rate limit across the cluster — and the failure mode
is `ImagePullBackOff` with a 429, mid-deploy. Invariant 4 fails the build if
`docker.io` appears anywhere under `k8s/`.

**No cluster credential exists here.** The only outward write this workflow
performs is a Git commit. Invariant 3 fails the build if the string `kubectl`
appears anywhere in this directory.

### Write-back credential — the chosen path

The bump commit needs to push to `main`, and the default `GITHUB_TOKEN` is the
wrong tool twice over: pushes made with it do not trigger workflows (which is
fine here) and it is commonly blocked by branch protection (which is not).

**Chosen:** a fine-grained PAT with `contents: write`, scoped to this repository
only, stored as the repository secret `MANIFEST_BUMP_TOKEN`.

A GitHub App installation token is the better answer at team scale — it is not
tied to a person, and it survives that person leaving. It is not used here
because a single-author repository does not have the problem the App solves, and
an App is a second thing to keep configured.

The alternative to bypassing protection is a `release/bump` branch with
auto-merge, which is what an org policy that forbids bypass leaves you. It costs
an extra merge commit per deploy.

### Loop protection, both halves

The bump commit would otherwise trigger this workflow, which would build, commit,
and trigger it again.

1. `paths-ignore` excludes `k8s/overlays/**`, `**/*.md`, `docs/**`, `*.html`
2. `[skip ci]` in the bump commit message

Belt and braces on purpose: a future edit to the path filters would silently
reintroduce an infinite loop, and the marker in the message is independent of them.

> **A warning that cost real time.** GitHub scans the *entire* commit message for
> `[skip ci]`, body included, so **quoting** the token is indistinguishable from
> **using** it. A documentation commit whose message explained this mechanism
> contained the literal text and silently opted itself out of CI. Harmless there;
> on a code commit it means tests, scan and build are all skipped with main
> carrying unverified code and nothing anywhere reporting it. Invariant 10 checks
> the commits you are about to push for exactly this.

---

## `terraform.yaml` — two jobs, split on credentials

**`fmt-validate`** uses `init -backend=false`, so it needs no credentials and no
state bucket. It therefore runs on every push *and* on pull requests from forks —
structural and type errors are caught even where secrets are not available.

**`plan`** reads real state and so needs a real identity. It authenticates with
Workload Identity Federation — GitHub's OIDC token exchanged for a short-lived
GCP token, no key file anywhere — and posts the plan as a PR comment so it is
reviewed alongside the diff rather than dug out of a logs pane.

It is gated on `vars.TERRAFORM_PLAN_ENABLED == 'true'` and on the PR not coming
from a fork. To enable it, apply `modules/github_oidc` (free — no cluster
required) and set the two secrets it outputs; see `infra/terraform/README.md`.

> `secrets.X != ''` does **not** work as a job-level `if`. The `secrets` context
> is unavailable there — only `github`, `inputs`, `needs` and `vars` are. That is
> why the opt-in is a repository *variable*. actionlint catches the mistake; the
> first attempt at this fix did not, because it was written and committed in one
> shell command so the failing linter never blocked the commit.

**There is deliberately no `apply` step.** Automating apply on merge means a
destructive plan reaches production because a PR was approved for its *code*, not
for its *plan* — and unlike a workload rollout there is no ArgoCD selfHeal to
catch it and no zero-downtime path back.

---

## Review gates: what is missing, and how to switch it on

As of this writing there is **no human review gate on the application path**:

```
branch protection on main : not configured   (protected: false)
pull requests opened      : 0
commits on main           : pushed directly
```

That is a consequence of one person building the whole thing, and it leaves a
real hole — the Trivy gate, the eleven invariants and the "no kubectl" rule all
live in this directory and in `scripts/`, so whoever can push can also switch any
of them off in a one-line diff that looks small.

`.github/CODEOWNERS` records the intended boundary, but **it enforces nothing on
its own**: CODEOWNERS applies only where a pull request is required and reviews
are enforced. Branch protection is the switch that gives it effect.

### Switching it on

GitHub → **Settings → Branches → Add branch ruleset** (or *Add rule* on the
classic screen), targeting `main`:

- [x] **Require a pull request before merging**
  - Required approvals: **1**
  - [x] Require review from Code Owners
- [x] **Require status checks to pass**, and select:
  - `Lint & test`
  - `Repository invariants`
  - `Build, scan, push`
  - `fmt & validate`
- [x] Require branches to be up to date before merging
- [x] Block force pushes

**Then the part that breaks the pipeline if you skip it.** The bump commit pushes
straight to `main`, so the identity behind `MANIFEST_BUMP_TOKEN` must be allowed
to bypass:

- Rulesets: add it under **Bypass list**
- Classic rules: **Allow specified actors to bypass required pull requests**

Without that, step 4 of the delivery chain fails, ArgoCD never sees a new tag,
and the symptom is a green CI with nothing deploying.

`Terraform / plan` is deliberately **not** in the required-checks list: it is
gated off by default, and a required check that never runs blocks every merge
forever.

### If you want an approval button before deploy

Note where deployment actually happens. CI does not deploy — ArgoCD does, from
inside the cluster. So a GitHub Environment with required reviewers would gate
the wrong step.

The approval gate for deployment belongs on the ArgoCD `Application`: drop
`syncPolicy.automated` and a human presses Sync. That buys an approval and costs
`selfHeal` — drift is no longer corrected automatically — plus the deploy latency
of however long it takes someone to notice. Worth it for a regulated
environment; not worth it here, where a bad deploy is forty seconds and one
`git revert` from being undone.
