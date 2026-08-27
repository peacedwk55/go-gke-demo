# GitOps delivery — Task 5

```
projects/app-project.yaml            tenancy boundary for the app (tight)
projects/observability-project.yaml  tenancy boundary for LGTM (needs CRDs)
apps/app-prod.yaml                   Application -> k8s/overlays/prod
apps/observability.yaml              4 Helm Applications, sync-wave ordered
```

## How a Git commit becomes a deployment

```
developer merges to main
        │
        ▼
GitHub Actions (CI)  ── test → build → trivy → push image to Docker Hub
        │                                   ── kustomize edit set image
        │                                   ── commit + push manifest change
        ▼
      Git  ◄──────────────── ArgoCD polls / receives webhook
                                     │
                                     ▼
                        ArgoCD (running IN the cluster) syncs
                                     │
                                     ▼
                        GKE pulls image via Artifact Registry
```

**CI never touches the cluster.** No kubeconfig, no GCP key, no `kubectl` anywhere in
`.github/workflows/`. The only write CI performs is a Git commit that changes one image tag.

That is the actual security argument for pull-based GitOps, and it is worth stating plainly: if the
CI runner is compromised, the attacker gets the ability to make a Git commit — reviewable,
revertible, and attributable — rather than cluster-admin. In a push-based pipeline the same
compromise yields credentials that apply arbitrary manifests to production.

**Rollback is `git revert`.** No special tooling, no "roll back" button whose behaviour differs from
the deploy path, and the revert itself is a reviewed commit that leaves a trail.

## Bootstrap

Once, after `terraform apply`:

```bash
# 1. credentials (from the Terraform output, so the region cannot be mistyped)
eval "$(terraform -chdir=../infra/terraform/envs/prod output -raw get_credentials_command)"

# 2. install ArgoCD itself — the one imperative step in the whole system
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# 3. hand over control
kubectl apply -f argocd/projects/
kubectl apply -f argocd/apps/
```

From step 3 onward, Git drives everything. ArgoCD does not manage its own installation here — that
would be circular. Note the pinned `v2.13.2` in the URL: fetching the moving `stable` manifest is
the standard way to end up with an ArgoCD version nobody chose.

Then get the initial password and reach the UI:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

`port-forward` rather than a LoadBalancer or Ingress: exposing the ArgoCD UI publicly means putting
a cluster-admin-equivalent console on the internet. Doing that properly needs SSO, an Ingress and
TLS — a task of its own, and out of scope here.

### The private-cluster prerequisite

Step 1 only works if your IP is in `master_authorized_networks`. This is decided in Terraform rather
than left implicit precisely because this bootstrap has to work — see `infra/terraform/README.md`.
If `kubectl` times out, your public IP has probably changed:

```bash
curl -s https://ifconfig.me    # then update terraform.tfvars and re-apply
```

### Placeholders

`GH_OWNER` and `GH_REPO` appear in all four project/app files. Substitute before the first
`kubectl apply`:

```bash
grep -rl 'GH_OWNER' argocd/ | xargs sed -i "s|GH_OWNER/GH_REPO|<owner>/<repo>|g"
```

For a private repository, register credentials first (`argocd repo add … --ssh-private-key-path`,
or a Secret labelled `argocd.argoproj.io/secret-type: repository`). Do not commit that Secret —
in a real deployment it comes from External Secrets Operator or Secret Manager.

## Decisions worth defending

### `ignoreDifferences` on `/spec/replicas` + `RespectIgnoreDifferences=true`

This is the subtle one, and it is a genuine trap.

The Deployment omits `spec.replicas` so the HPA owns scaling. Kubernetes still defaults the field to
a concrete number in the live object, so ArgoCD sees `live=4` against a manifest that says nothing,
calls it drift, and with `selfHeal: true` reverts it. The HPA scales back up. Repeat forever.

`ignoreDifferences` alone is **not enough**: without `RespectIgnoreDifferences=true` in
`syncOptions`, the field is hidden from the diff *view* but selfHeal still reverts it. The setting
looks applied and does nothing — the worst kind of configuration bug. Both are required.

### Two AppProjects

The app project allows exactly seven namespaced kinds and one cluster-scoped kind (`Namespace`). A
manifest that tries to introduce a `Secret` or a `ClusterRoleBinding` is refused by ArgoCD rather
than applied — a real guard against a malicious or careless manifest edit.

The observability stack genuinely needs to install CRDs and ClusterRoles; the Prometheus Operator
does not function otherwise. Folding it into the app project would mean granting the app pipeline
the right to create `ClusterRoleBinding`s, which is cluster-admin by another route. Two projects
keeps each blast radius matched to its real need.

*(This is a deliberate deviation from the single-project layout sketched in CLAUDE.md §2.)*

### `ServerSideApply=true` on the Helm Applications

The Prometheus Operator CRDs exceed the 262144-byte annotation limit that client-side apply uses for
`last-applied-configuration`. Without server-side apply the sync fails outright. Not needed for the
app, whose manifests are small.

### Sync waves

Wave 0 installs kube-prometheus-stack, because it provides the `ServiceMonitor` and `PrometheusRule`
CRDs everything else references. Waves 1–2 put Loki and Tempo before Alloy, which ships to both —
otherwise Alloy spends its first minutes crash-looping against endpoints that do not exist yet.

### `PruneLast=true`

Prune after everything else is healthy. Otherwise there is a window where the old hash-suffixed
ConfigMap has been deleted but the new Deployment has not finished rolling out.

### `allowEmpty: false`

A force-push that empties the overlay directory would otherwise be faithfully reproduced as
"delete production".

### Multi-source Applications for Helm

Chart from upstream, values from our repo (`$values/observability/…`). Values in Git means they are
reviewable, diffable and revertible; `--set` flags in a runbook are none of those.

## Verifying it works

```bash
kubectl -n argocd get applications
argocd app get go-sample-app-prod

# prove selfHeal: delete a pod by hand and watch it come back
kubectl -n prod delete pod -l app=go-sample-app --wait=false

# prove the HPA is not being fought: scale by hand, confirm ArgoCD leaves it
kubectl -n prod scale deploy/go-sample-app --replicas=4
kubectl -n argocd get application go-sample-app-prod \
  -o jsonpath='{.status.sync.status}'   # must stay Synced, not OutOfSync

# prove rollback
git revert <commit> && git push        # ArgoCD syncs the previous image tag
```

## Not done here

**App-of-Apps** is the scaling pattern: a single root Application whose source is `argocd/apps/`, so
adding an Application becomes a commit rather than a `kubectl apply`. With two Application files the
indirection costs more clarity than it buys; the ApplicationSet generator is the next step beyond
that for multi-cluster or per-branch environments.

No SSO, no Ingress for the UI, no notifications. No `ApplicationSet` for multi-environment
promotion — with one environment there is nothing to generate.
