# Evidence

What was actually run, on what, and what it produced. Recorded because a cluster
that has been torn down cannot be re-examined, and because "the manifest is
correct" and "the system works" turned out to be different claims often enough
in this project to be worth separating on purpose.

Everything below was queried from the live cluster. Where a claim could have been
made from reading a file instead, the command that produced it is shown.

## Environment

| | |
|---|---|
| Cluster | `go-sample-app-prod`, regional, `asia-southeast1`, private nodes |
| Kubernetes | `v1.35.7-gke.1027000` (release channel REGULAR) |
| Node pool | `go-sample-app-prod-pool` · `e2-standard-2` · pd-balanced 30 GB |
| Node allocatable | 1930m CPU / 5.88 GiB per node (measured, not derived) |
| Dataplane | `ADVANCED_DATAPATH` (Dataplane V2) |
| ArgoCD | `v3.5.2` |
| Image running | `asia-southeast1-docker.pkg.dev/<project>/dockerhub-remote/dockerpeace/go-sample-app:sha-823cc02` |

---

## The delivery loop closed end to end

The running pods' image tag is `sha-823cc02` — a commit made during this session.
Nothing was applied by hand to get it there:

```
git push  →  GitHub Actions: test → build → Trivy → push to Docker Hub
          →  kustomize edit set image  →  commit "[skip ci]"
          →  ArgoCD (in-cluster) pulls  →  GKE pulls via Artifact Registry
```

Two properties of that chain are worth stating separately because they are the
ones the assignment asks for:

- **CI holds no cluster credentials.** Its only write is a Git commit. Invariant 3
  in `scripts/check-invariants.sh` fails the build if `kubectl` appears anywhere
  under `.github/workflows/`.
- **The pull path is Artifact Registry, not Docker Hub.** The image reference on
  the running pod is the `dockerhub-remote` path, so private nodes are not
  sharing one Cloud NAT IP against Docker Hub's per-IP rate limit. The push path
  is still Docker Hub, per Task 2. Same tag, different host.

Every fix in this session was delivered by `git push` alone.

---

## Task 3 — the workload

```
$ kubectl get deploy,hpa,pdb -n prod
hpa/go-sample-app   cpu: 0%/70%   MINPODS 2   MAXPODS 6   REPLICAS 2
pdb/go-sample-app   MIN AVAILABLE 1   ALLOWED DISRUPTIONS 1
```

- **HPA raised the Deployment from 1 to 2 on its own.** The Deployment ships no
  `spec.replicas`, so Kubernetes defaulted it to 1 on create and the HPA
  corrected it to `minReplicas: 2` on its next reconcile. This is documented in
  CLAUDE.md as expected behaviour; it is now also observed.
- **PDB math holds.** `ALLOWED DISRUPTIONS 1` against `minAvailable: 1` and two
  replicas means a node drain is never blocked.
- **Pods are on different nodes, in different zones** — `asia-southeast1-a` and
  `asia-southeast1-b`. podAntiAffinity and topologySpreadConstraints both had
  somewhere to act, which is the thing a single-node cluster cannot demonstrate.

### Pod Security Standards are enforced, not merely declared

A throwaway `curl` pod was refused by the `prod` namespace:

```
Error from server (Forbidden): pods "traffic" is forbidden:
violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false,
unrestricted capabilities, runAsNonRoot != true, seccompProfile
```

It only ran after being given the same securityContext the application carries.
This was an accident, and it is better evidence than a deliberate test.

### HTTP hardening, in production

```
$ curl -D- "http://go-sample-app.prod.svc.cluster.local/?name=xss<script>"
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
```

These are the two headers that stop Go's MIME sniffing from turning the
reflected `?name=` parameter into stored XSS, tested with an actual payload.

---

## Task 5 — ArgoCD owns the cluster, and does not fight the HPA

All six Applications reached `Synced/Healthy`:

```
alloy                   Synced   Healthy
go-sample-app-prod      Synced   Healthy
kube-prometheus-stack   Synced   Healthy
loki                    Synced   Healthy
observability-config    Synced   Healthy
tempo                   Synced   Healthy
```

The `ignoreDifferences` claim was tested rather than asserted. The Deployment was
scaled by hand to 4 — simulating an HPA scale-up — and watched for three minutes:

```
t+30s   spec.replicas=4  ready=4  argocd=Synced/Healthy
t+60s   spec.replicas=4  ready=4  argocd=Synced/Healthy
t+90s   spec.replicas=3  ready=3  argocd=Synced/Healthy
t+120s  spec.replicas=3  ready=3  argocd=Synced/Healthy
t+150s  spec.replicas=2  ready=2  argocd=Synced/Healthy
t+180s  spec.replicas=2  ready=2  argocd=Synced/Healthy
```

Two things to read here. ArgoCD never reported `OutOfSync` and never reverted the
field — `ignoreDifferences` on `/spec/replicas` with
`RespectIgnoreDifferences=true` is working. And the walk from 4 to 2 is gradual,
which is the HPA's own scale-down stabilization, not a snap-back. A selfHeal
fighting the HPA would have looked like an immediate revert to 2 and an
`OutOfSync` in between.

---

## Task 6 — the correlation chain, proven with one trace id

This is the part the whole observability stack exists for: a single request
identifiable in metrics, traces and logs by the same key.

`trace_id = 015c5fcc901567470ac254aa4baafcf5`, found in all three:

**1. Prometheus — the metric carries it as an exemplar**

```
$ curl -G .../api/v1/query_exemplars \
    --data-urlencode 'query=http_request_duration_seconds_bucket{route="/"}'
labels={'trace_id': '015c5fcc901567470ac254aa4baafcf5'} value=...
```

**2. Tempo — the trace exists**

```
$ curl .../api/traces/015c5fcc901567470ac254aa4baafcf5
HTTP=200
"name":"GET /{$}"
"stringValue":"go-sample-app"
"intValue":"200"
```

The span also carries `service.version: sha-4125566`, so a trace can be tied back
to the exact image that served it. `GET /{$}` is the route pattern with the Go
1.22 exact-match anchor, visible in the trace because the app registers it that
way rather than as a catch-all.

**3. Loki — the log line carries it too**

```
$ curl -G .../loki/api/v1/query_range \
    --data-urlencode 'query={namespace="prod"} |= "015c5fcc901567470ac254aa4baafcf5"'
{"app":"go-sample-app","container":"app","level":"INFO","namespace":"prod",
 "route":"/","status":"200","service_name":"go-sample-app","stream":"stdout",
 "trace_id":"015c5fcc901567470ac254aa4baafcf5"}
```

`trace_id` is structured metadata, not a stream label — a label would create one
Loki stream per request and destroy the index. Loki's label set is
`app, container, level, namespace, service_name, stream`: all low cardinality,
with `pod` deliberately absent so that an HPA scale event or a rolling update
does not multiply streams.

### Metrics really are scraped through the ServiceMonitor

```
$ curl -G .../api/v1/query --data-urlencode 'query=sum(http_requests_total)by(route,pod)'
{'pod': 'go-sample-app-...-6lnfc', 'route': '/'}        = 44
{'pod': 'go-sample-app-...-pf9mm', 'route': '/'}        = 38
{'pod': 'go-sample-app-...-6lnfc', 'route': '/healthz'} = 145
{'pod': 'go-sample-app-...-pf9mm', 'route': '/readyz'}  = 286
```

44 + 38 = 82, against exactly 82 requests sent to `/` (80 in a loop, plus one
`final` and one XSS probe). Counting the traffic and counting the metric agree,
which is a stronger statement than "the target is up".

---

## Task 4 — what only a real cluster could show

Verified against the live API, not the plan:

| Claim | Observed |
|---|---|
| Default node pool removed | only `go-sample-app-prod-pool` exists |
| Machine type explicit | `e2-standard-2`, disk 30 GB |
| Autoscaling | total 3–9, `location_policy: BALANCED` |
| auto-repair / auto-upgrade | `True` / `True` |
| Shielded Nodes | Secure Boot `True` |
| Workload Identity on the pool | `GKE_METADATA` |
| Private nodes | `True` |
| WI pool at cluster level | `<project>.svc.id.goog` |
| Dataplane V2 | `ADVANCED_DATAPATH` |
| Master authorized networks | enabled |
| Artifact Registry remote repo | `dockerhub-remote`, mode `REMOTE_REPOSITORY` |
| Cloud NAT router | present |
| `google_service_account_key` anywhere | none — invariant 2 enforces it |

The Workload Identity claim is the one the assignment calls out, and the evidence
for it is negative by design: pods obtain GCP tokens from the metadata server and
there is no key file anywhere in the repository, the cluster or the state.

---

## What this run found that no linter could

Seven defects, on manifests that passed `yamllint`, `kubeconform`,
`terraform validate`, `helm lint`, `actionlint`, `shellcheck` and `ansible-lint`.
Four of them were reported by ArgoCD as `Synced`.

| # | Defect | Why nothing caught it |
|---|---|---|
| 1 | Tempo accepted no traces — OTLP receivers under `distributor.receivers`, a key the chart does not have | Helm drops unknown values silently. Rendering showed `otlp` zero times. |
| 2 | One `coreDns` Service in `kube-system` failed five Applications | AppProject rejected it, so the whole sync was invalid and the Prometheus CRDs never installed. No error mentioned DNS. |
| 3 | Grafana CrashLoopBackOff — two datasources marked default | Ours and the chart's. `Synced` means the manifests reached the API server, not that the process starts. |
| 4 | ArgoCD v2.13.2 could not diff against Kubernetes 1.35 | `.status.terminatingReplicas` did not exist in its schema. Applications sat on a stale revision and silently stopped pulling new commits. |
| 5 | Alloy could not write `/tmp` | `readOnlyRootFilesystem: true` with no writable `/tmp`; `storagePath` defaults to `/tmp/alloy`. Crash on every node, zero logs. |
| 6 | Alloy's log file glob matched nothing | Built `/var/log/pods/*<ns>/<pod>/<container>/*.log`; the real layout is `<ns>_<pod>_<uid>/<container>/`. Alloy ran 2/2 with no errors and Loki held no labels at all. |
| 7 | `total_min_node_count = 3` produced one node | The autoscaler treats the total minimum as a floor it will not go below, not a target it scales up to. Creation size is set by `initial_node_count`. |

Number 6 is the one worth remembering. A path assembled from labels that all
exist, syntactically valid, unevaluatable by any linter, uncontradicted by a
healthy pod — and the symptom appears three systems away as an empty log panel.

### Teardown left five disks behind, as predicted

`terraform destroy` removed everything it owned — the custom VPC (only `default`
remains), Cloud NAT router, external addresses, the Artifact Registry repository
and the custom service accounts all gone, with only the tfstate bucket kept
deliberately.

What survived was 115 GB of `pd-balanced` in five orphaned disks:

| disk | GB | zone | created for |
|---|---|---|---|
| `pvc-b706c2f2…` | 50 | a | Prometheus |
| `pvc-cd90687e…` | 30 | b | Loki |
| `pvc-a64841a2…` | 20 | b | Tempo ingester |
| `pvc-eada2721…` | 10 | b | Grafana |
| `pvc-65eb9c52…` | 5 | b | Alertmanager |

Exactly the 115 GB computed during pre-flight, and exactly what
`infra/terraform/README.md` warned would happen — so the warning was right and
the procedure was still incomplete, because it said how to *find* them and not
how to *avoid* them.

The mechanism, now measured rather than guessed: `standard-rwo` uses
`reclaimPolicy: Delete`, so deleting a PVC does delete its disk. But
`terraform destroy` removes the whole cluster at once, taking the CSI controller
with it before it can reclaim anything. The disks are not retained by policy;
they are abandoned because the component responsible for deleting them was
deleted first. Deleting the observability Applications and their PVCs *before*
destroy prevents it entirely — that sequence is now in the README.

### Still outstanding

- `initial_node_count = 1` is committed but **not applied**: changing it forces
  node pool replacement (`terraform plan`: 1 to add, 1 to destroy). It belongs to
  the next fresh apply. This cluster ran on 1–4 autoscaled nodes across two
  zones, so the three-zone floor is configured and reasoned about but not yet
  observed.
- A plan archive and a log file were committed to the public repository earlier
  and have been removed from HEAD; both remain in history pending a decision on
  rewriting it. Neither contained a credential — Workload Identity means there is
  no key to leak — but the plan archive did contain a state snapshot.
