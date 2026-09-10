# Workflows

Two pipelines with deliberately different endings.

| | `ci.yaml` | `terraform.yaml` |
|---|---|---|
| Triggered by | `app/` `docker/` `k8s/base/` `scripts/` … | `infra/terraform/**` |
| Gates | tests · gosec · govulncheck · 11 invariants · gitleaks · kubeconform · Trivy IaC · Trivy image · **ZAP baseline** | `fmt` · `validate` · `plan` |
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
test  →  invariants  →  render + validate  →  build  →  scan  →  DAST  →  push  →  bump
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

### The DAST gate, and why it is the only one that proves anything about the binary

Every other gate reads a *description* of the program: the tests read the
handler, gosec reads the source, Trivy reads the image's package list, the
invariants read the repository. The ZAP step is the only one that speaks HTTP to
the running process and reads what actually comes back.

That distinction is not decorative here. The app reflects `?name=` unescaped and
is safe only because of two response headers (CLAUDE.md §1.1). A unit test can
prove the handler sets them; only a request from outside can prove they survive
the Dockerfile, the server config, and anything that might sit in front.

It runs **after Trivy and before the Docker Hub login**, for the same reason
Trivy does — the image under test is the one that would be published, and it has
not been published yet.

**It was proven to fail before it was committed.** The app was copied outside the
working tree with both headers deleted, and both builds were scanned:

```
hardened build           FAIL-NEW: 0   PASS: 65   exit 0
X-Content-Type-Options   FAIL-NEW: 1   PASS: 64   exit 1
  removed                └─ X-Content-Type-Options Header Missing [10021]
```

One line differed, and it was the right line. A gate observed only passing is not
a gate that is known to work — which is the recurring lesson of this repository,
and the reason `.zap/rules.tsv` marks rule 10021 `FAIL` and says so in a comment.

`.zap/README.md` carries the rest: why the fast passive baseline beats the
8-minute full scan on an app with four plaintext endpoints (measured — the full
scan found nothing extra), why the output directory needs `chmod 777` (ZAP is uid
1000, the runner workspace is uid 1001), and why the tutorial image name
`owasp/zap2docker-stable` no longer resolves.

It is deliberately **not** in the required-status-checks list, and that is a
judgement call rather than an oversight: it lives inside `Build, scan, push`,
which already is required, so it gates every pull request through that job.

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

## Review gates

Now configured, having been absent for the first 59 commits — all of which were
pushed straight to `main`. Verified against the API rather than the settings
screen:

```
protected               : true
deletion                : restricted
non_fast_forward        : blocked
pull_request            : approvals=1, code owner review=true
required_status_checks  : Lint & test · Repository invariants · Build, scan, push
```

Why it matters here specifically: the Trivy gates, the eleven invariants, gosec,
govulncheck and gitleaks all live in this directory and in `scripts/`. Whoever can
push can also switch any of them off in a one-line diff that looks small, so the
review boundary is what protects the other gates.

`.github/CODEOWNERS` carries that boundary — app code and overlay values to the
app team, the pipeline and infra and `k8s/base` to platform. It enforces nothing
on its own: CODEOWNERS applies only where pull requests are required and reviews
are enforced, which is what the ruleset above now provides.

### Switching it on (for a fresh clone of this setup)

GitHub → **Settings → Branches → Add branch ruleset** (or *Add rule* on the
classic screen), targeting `main`:

- [x] **Require a pull request before merging**
  - Required approvals: **1**
  - [x] Require review from Code Owners
- [x] **Require status checks to pass**, and select exactly these three:
  - `Lint & test`
  - `Repository invariants`
  - `Build, scan, push`
- [x] Require branches to be up to date before merging
- [x] Block force pushes

> **Do not add `fmt & validate`, and this correction is from getting it wrong.**
> An earlier version of this list included it, and the very first pull request
> proved why that breaks: `terraform.yaml` is path-filtered to
> `infra/terraform/**`, so on a PR that touches anything else the workflow never
> runs, the check reports nothing, and it sits at *"Expected — Waiting for status
> to be reported"* forever. The PR becomes permanently unmergeable.
>
> The rule is that **a required check must be one that runs on every pull
> request**. `Terraform / plan` was excluded for exactly this reason and the same
> reasoning applies one step earlier, to `fmt & validate` — which I missed while
> writing the warning about `plan`.
>
> If a path-filtered workflow genuinely must be required, the standard pattern is
> a companion job that reports the same check name and succeeds immediately when
> the paths do not match. That is real complexity for little gain here:
> `terraform.yaml` already runs on every PR that touches Terraform, which is when
> it means anything.

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

### "Require 1 approval" cannot be satisfied by a single author

GitHub does not let anyone approve their own pull request. On a repository with
one human, `Required approvals: 1` is therefore not a rule that is waiting for
someone — it is unsatisfiable, and every PR needs the admin bypass to merge.

Two honest ways to hold that:

- **Keep `1` and bypass.** The configuration is then correct for the team it is
  written for, it starts working the moment a second reviewer exists, and each
  use of the bypass is recorded on the PR. The three status checks still have to
  be green first, which is the part of the ruleset carrying most of the value.
- **Set it to `0`.** Every rule in the ruleset is then satisfiable and nothing
  needs bypassing — at the cost of the repository having no review requirement at
  all, and needing to be reconfigured when a second person arrives.

Neither is wrong. What would be wrong is leaving `1` in place without saying that
the only human on the repository has to step around it.

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
