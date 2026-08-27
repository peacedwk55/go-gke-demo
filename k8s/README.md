# Kubernetes manifests — Task 3

Kustomize, structured as `base/` + `overlays/{dev,prod}`.

## The shape, and why

`base/` is the canonical, environment-agnostic definition of the workload. It names no
environment, no GCP project, no registry and no image tag. Overlays hold only the differences.

The practical consequence — and the actual requirement behind "adjust values without rebuilding
Kustomize" — is that day-to-day changes never touch `base/`:

| To change… | Edit | Mechanism |
|---|---|---|
| Image tag | `overlays/prod/kustomization.yaml` | `images:` transformer (`kustomize edit set image`, which is exactly what CI runs) |
| Runtime config | `overlays/<env>/config.env` | `configMapGenerator` → `envFrom` |
| CPU / memory | `overlays/prod/patches/resources.yaml` | strategic-merge patch |
| Scaling envelope | `overlays/<env>/patches/hpa-scale.yaml` | strategic-merge patch on the HPA |

```bash
kustomize build k8s/overlays/prod    # render
kustomize build k8s/overlays/dev
```

## Decisions worth defending

### The Deployment has no `spec.replicas`

This is the one that catches people. `spec.replicas` + an HPA + ArgoCD `selfHeal: true` is a
three-way fight: the HPA scales to 4, ArgoCD sees drift against a manifest that says 2, reverts it,
the HPA scales up again — forever.

So the HPA is the sole owner of the replica count, and `minReplicas: 2` is where the HA baseline
actually lives. `argocd/apps/app-prod.yaml` additionally declares `ignoreDifferences` on
`/spec/replicas` plus `RespectIgnoreDifferences=true` — belt and braces, because
`ignoreDifferences` without that sync option still lets selfHeal revert the field.

**Expected on a first apply:** Kubernetes defaults the absent field to 1, and the HPA raises it to
2 on its next reconcile. Measured on a cluster with **no metrics-server at all**, the HPA still went
from 1 → 2 within 5 seconds (`AbleToScale=True reason=SucceededRescale`) — `minReplicas` is enforced
independently of whether metrics are available.

### No CPU limit

A CPU limit is enforced by CFS quota, which throttles the container even when the node has idle
cores. For a latency-sensitive HTTP service that converts spare capacity into p99 spikes for no
benefit. The `requests` value already guarantees a scheduling share, and it is also the denominator
for the HPA's utilisation target.

Memory is different: it is incompressible, so `limit == request`. A memory limit above the request
only buys the chance to be OOM-killed after the scheduler has over-committed the node. Equal values
also place the pod in the **Guaranteed** QoS class, so it is evicted last under node pressure.

### PDB math

`minAvailable: 1` against an HPA floor of 2 replicas. That always permits exactly one voluntary
eviction, so `kubectl drain`, GKE node upgrades and autoscaler scale-downs all proceed.

`minAvailable: 2` is the trap: at the floor of 2 replicas it permits **zero** evictions and drains
hang forever. `minAvailable: 50%` reproduces the same deadlock, because Kubernetes rounds that up
to 2.

### ConfigMap hash suffix stays on

`configMapGenerator` appends a content hash to the ConfigMap name and rewrites the Deployment's
reference to match. Changing `config.env` therefore changes the pod spec, which rolls the pods
automatically.

Turning the suffix off would update the ConfigMap in place and leave running pods on stale values
until something unrelated happened to restart them — silent config drift, and one of the more
annoying production bugs to diagnose. The cost is orphaned ConfigMaps accumulating over time;
ArgoCD prunes them, since the old hashed name simply disappears from the desired state.

### Two registries

`prod` pulls through the Artifact Registry remote repository, `dev` pulls straight from Docker Hub.

Every private GKE node egresses via a single Cloud NAT IP and would collectively trip Docker Hub's
per-IP pull limit; the AR remote repo is a read-through cache that removes that risk (and is what
justifies `artifactregistry.reader` on the node SA). A local kind cluster has neither problem, and
pointing dev at AR would force every developer to hold GCP credentials.

CI still **pushes** to Docker Hub — a remote repository cannot be pushed to.

### `automountServiceAccountToken: false`

The app never calls the Kubernetes API, so mounting a token would hand any RCE a cluster credential
for nothing. This does **not** affect Workload Identity, which obtains GCP tokens from the GKE
metadata server rather than from a projected service-account token volume.

### `restricted` Pod Security Standard on the namespace

The workload already satisfies it, so the label costs nothing and converts every securityContext
setting from a convention into an admission-time guarantee. Verified the hard way: an ad-hoc
`kubectl run curl` pod was rejected by the API server for missing exactly those fields, while the
app's own pods admitted cleanly.

## The zero-downtime claim, measured

`maxUnavailable: 0` on its own does **not** give you zero downtime. It guarantees the new pods are
ready before old ones go away, but says nothing about traffic still in flight to a pod that is
shutting down. That half lives in the application (`app/main.go`, `drain()`): readiness flips to
503, then a pause, and only then does the listener close.

Measured on a 2-node kind cluster, continuous single-threaded load through the Service, one rolling
update mid-run:

| `SHUTDOWN_DELAY` | Requests | Failed |
|---|---|---|
| 1s | 10,486 | **15** (0.14%, connection reset) |
| 5s | 8,017 | **0** |

One second is not enough for the EndpointSlice update to reach every node's kube-proxy. This is why
`dev` uses the same 5s as `prod`: shortening it would make dev the one environment where the
zero-downtime guarantee is quietly false.

## Placeholders to substitute

`PROJECT_ID` and `DOCKERHUB_USER` appear in `overlays/prod/kustomization.yaml` and
`overlays/prod/patches/serviceaccount-wi.yaml`. Fill them in from the Terraform outputs
(`terraform -chdir=infra/terraform/envs/prod output`) as part of bootstrap.

They are left as literal placeholders rather than committed values so the repository contains no
project-specific identifiers, and so a reviewer can see exactly which two facts have to come from
the infrastructure layer.

## Verification

```bash
# render + schema-validate
kustomize build k8s/overlays/prod | kubeconform -strict -summary -kubernetes-version 1.30.0 -

# validate against a live API server (namespace must exist first — server dry-run
# cannot see a Namespace created in the same apply; ArgoCD handles this with
# CreateNamespace=true)
kubectl create ns prod
kustomize build k8s/overlays/prod | kubectl apply --dry-run=server -f -

# local end-to-end on kind
kind load docker-image go-sample-app:v1.0.0 --name <cluster>
kustomize build k8s/overlays/dev \
  | sed 's|docker.io/DOCKERHUB_USER/go-sample-app|go-sample-app|' \
  | kubectl apply -f -
kubectl -n dev rollout status deploy/go-sample-app
```

### Results on kind

| Check | Result |
|---|---|
| `kustomize build` (both overlays) | 7 resources each |
| `kubeconform -strict` | 7/7 valid, 0 errors, no deprecated APIs |
| `kubectl apply --dry-run=server` | all resources accepted |
| Rollout | `successfully rolled out`, 2/2 ready |
| Pod spread (podAntiAffinity) | pods landed on two different nodes |
| HPA without metrics-server | raised 1 → 2 in ~5 s |
| PDB | `ALLOWED DISRUPTIONS: 1` |
| ConfigMap plumbing | `GREETING=Hey there` from `config.env` reached the response body |
| Security headers in-cluster | `text/plain; charset=utf-8` + `nosniff` |
| Rolling update under load | 8,017 requests, 0 failures |

## Not in scope

No Ingress, Gateway or TLS: the Service is `ClusterIP`. Exposing it properly means an Ingress or
HTTPRoute plus cert-manager and a WAF policy, which is a task of its own. A `LoadBalancer` Service
would have been the shortcut — a billable external IP serving plaintext HTTP with no policy in
front — and is deliberately not used.

No NetworkPolicy manifests either, although Task 4 enables Dataplane V2 which would enforce them.
See the trade-offs section of the top-level README.
