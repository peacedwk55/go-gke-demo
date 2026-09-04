# CLAUDE.md — DevOps Candidate Assignment: Go App to Production on GKE

> **Purpose of this file:** This is the single source of truth for design decisions, conventions, and acceptance criteria for this project. When working in this repo, follow every rule here. Every task has a **Definition of Done checklist** — do not consider a task complete until every box can be checked.

---

## 1. Project Overview

Deliver a sample **Go application** to Production on **GKE**, driven by three pillars:

| Pillar | How we achieve it |
|---|---|
| **High Availability** | ≥2 replicas, PDB, pod anti-affinity, multi-zone (regional) GKE, RollingUpdate with zero downtime, health probes |
| **Scalability** | HPA-ready resource requests, GKE node autoscaling, stateless container, VPC-native cluster with sized secondary ranges |
| **Security** | Distroless non-root image, full Pod securityContext, private GKE cluster, Workload Identity (NO service account keys), least-privilege IAM, no secrets in Git |

**Golden rules (apply everywhere):**
- ❌ Never use the `latest` image tag. Tags are `vX.Y.Z` or `sha-<gitsha>`.
- ❌ Never commit secrets, GCP JSON keys, or kubeconfigs to Git.
- ❌ CI never runs `kubectl apply` against the cluster. Deployment happens **only** via ArgoCD watching Git (pull-based GitOps).
- ✅ Everything is declarative: Terraform for infra, Kustomize for workloads, ArgoCD `Application` YAML for delivery, Ansible for VMs.
- ✅ Every directory ships with a `README.md` explaining **why**, not just how.

---

## 1.1 Application Contract (Go)

The application is developed in **Go** (target: Go 1.26, module-based). All infra in this repo assumes the app satisfies this contract — if the sample app is missing any of these, add them to the Go code first (they are trivial handlers):

| Requirement | Value | Consumed by |
|---|---|---|
| Language / build | Go ≥1.26, `go.mod` present, static build (`CGO_ENABLED=0`) | Task 1 Dockerfile, Task 7 CI (`go vet`, `go test ./...`) |
| Listen port | `:8080` (configurable via `PORT` env) | Service, probes, Dockerfile `EXPOSE` |
| Liveness endpoint | `GET /healthz` → 200 whenever the process is alive. **Must not** depend on downstreams — a dependency outage must never restart the pod | startupProbe, livenessProbe |
| Readiness endpoint | `GET /readyz` → 200 when able to serve; **flips to 503 the instant SIGTERM arrives** (this is the real zero-downtime mechanism — see note below) | readinessProbe |
| Metrics | `GET /metrics` (Prometheus format, e.g. `promhttp`) — RED counters/histogram labelled by route+status, plus exemplars carrying `trace_id` | Task 6 ServiceMonitor |
| Traces | OTLP export via `OTEL_EXPORTER_OTLP_ENDPOINT` env (points to Tempo/Alloy) | Task 6 Tempo |
| Config | 12-factor: all config via env vars (fed by ConfigMap from `config.env`) — no config files baked into image | Task 3 configMapGenerator |
| Shutdown | Graceful SIGTERM handling in the exact order below; the whole drain must finish inside `terminationGracePeriodSeconds: 30` | Zero-downtime RollingUpdate |
| HTTP hardening | Explicit `Content-Type: text/plain; charset=utf-8` **and** `X-Content-Type-Options: nosniff` on every response (the sample app reflects `?name=` unescaped — without these, Go's MIME sniffing turns it into reflected XSS); bounded input length; `http.Server` configured with `ReadHeaderTimeout`/`ReadTimeout`/`WriteTimeout`/`IdleTimeout` (Slowloris) | Security pillar |
| Structured logs | JSON to **stdout** via `log/slog`, one line per request, carrying `trace_id` — this field is what Loki's derived-field regex keys on to jump into Tempo | Task 6 log↔trace correlation |
| Tests | `*_test.go` covering every handler, including one asserting the `nosniff` header and one asserting `/readyz` returns 503 once shutdown is signalled. `go test ./...` must not pass vacuously | Task 7 CI gate |
| State | Stateless — no local disk writes (rootfs is read-only); use `emptyDir` mount only if temp files are unavoidable | securityContext `readOnlyRootFilesystem` |

### ⚠️ The graceful-shutdown sequence (do not simplify this)

`maxUnavailable: 0` only buys zero downtime if the *old* pod stops **receiving** traffic before it stops **serving** it. Required order:

```
SIGTERM received
  → 1. readiness flag = false   → /readyz returns 503 immediately
  → 2. wait ~5s                 → gives kube-proxy / EndpointSlice / LB time to actually
                                  remove this pod. Readiness propagation is asynchronous;
                                  skip this and requests keep landing on a closing pod.
  → 3. srv.Shutdown(ctx)        → drains in-flight requests
  → 4. flush OTLP exporter, exit 0
```

That 5s wait **must live in the Go code**. The runtime image is distroless — no shell — so
`lifecycle.preStop.exec: ["sleep","5"]` cannot run. Keeping it in the app also keeps the behaviour
testable in CI.

---

## 2. Repository Layout

```
.
├── CLAUDE.md                        # this file
├── README.md                        # top-level: architecture diagram + quickstart
├── .dockerignore                    # MUST live at the build-context root (= repo root), not in docker/
├── app/                             # Go source (given sample — extended to satisfy the §1.1 contract)
├── docker/
│   ├── Dockerfile
│   └── README.md
├── k8s/                             # Task 3 — Kustomize
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── pdb.yaml
│   │   └── hpa.yaml
│   └── overlays/
│       ├── dev/
│       │   ├── kustomization.yaml
│       │   └── config.env          # dev-tunable values (configMapGenerator)
│       └── prod/
│           ├── kustomization.yaml
│           ├── config.env
│           └── patches/            # HPA min/max, resources overrides (never Deployment replicas)
├── infra/terraform/                 # Task 4 — GKE + network
│   ├── modules/
│   │   ├── network/                # VPC, subnets, secondary ranges, Cloud NAT
│   │   ├── gke/                    # cluster + node pools
│   │   └── iam/                    # GSAs, Workload Identity bindings
│   ├── envs/
│   │   └── prod/                   # backend.tf (GCS), terraform.tfvars
│   └── README.md
├── argocd/                          # Task 5
│   ├── projects/app-project.yaml
│   ├── apps/app-prod.yaml
│   └── apps/observability.yaml     # LGTM stack, also GitOps-managed
├── observability/                   # Task 6 — LGTM Helm values
│   ├── kube-prometheus-stack.values.yaml
│   ├── loki.values.yaml
│   ├── tempo.values.yaml
│   └── dashboards/                 # JSON dashboards provisioned via sidecar
├── .github/workflows/               # Task 7
│   ├── ci.yaml                     # test → build → scan → push → bump tag
│   └── terraform.yaml              # fmt/validate/plan on PR
└── ansible/                         # Task 8
    ├── ansible.cfg
    ├── inventory/hosts.ini
    ├── group_vars/all.yml
    ├── site.yml
    └── roles/
        ├── common/                 # OS updates
        ├── docker/                 # install + daemon.json log rotation
        ├── nginx_container/        # templated HTML + container
        └── node_exporter/          # systemd + system user
```

---

## 3. Task 1 — Dockerfile + .dockerignore

### Design decisions
- **Multi-stage build**: stage 1 `golang:1.26-bookworm` (build), stage 2 `gcr.io/distroless/static-debian12:nonroot` (runtime). Distroless = no shell, no package manager → minimal attack surface (this is the "hardened image" bonus).
- Build a **static binary**: `CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w"`.
- Leverage layer caching: `COPY go.mod go.sum` + `go mod download` **before** copying source.
- Run as `USER nonroot:nonroot` (uid 65532), `EXPOSE 8080`, add `HEALTHCHECK`-equivalent handled by K8s probes (distroless has no shell — do **not** add a shell-based HEALTHCHECK).
- Add OCI labels: `org.opencontainers.image.source`, `.revision`, `.version`.

### .dockerignore must exclude
`.git`, `.github`, `*.md`, `k8s/`, `infra/`, `ansible/`, `argocd/`, `observability/`, test files, local env files (`.env*`), editor/IDE dirs.

> **Placement matters.** The build context is the **repository root** (`docker buildx build -f docker/Dockerfile .`), and Docker only reads `.dockerignore` from the context root. A file at `docker/.dockerignore` is silently ignored — the build appears to work while shipping the whole repo into the context. BuildKit does honour a `docker/Dockerfile.dockerignore` sibling, but that is silently inert under the classic builder, so the root file is the safe choice.

### ✅ Definition of Done — Task 1
- [ ] Multi-stage: builder + distroless/static runtime, final image < ~30 MB
- [ ] `CGO_ENABLED=0`, `-trimpath -ldflags="-s -w"` used
- [ ] `USER nonroot` (never root), no shell in final image
- [ ] `go mod download` layer cached before source copy
- [ ] `.dockerignore` excludes VCS, docs, infra dirs, secrets/env files
- [ ] OCI labels present (source, version, revision)
- [ ] `docker build` succeeds and `docker run -p 8080:8080` serves traffic as non-root
- [ ] Image scanned locally (`trivy image`) — no CRITICAL vulns unresolved/undocumented

---

## 4. Task 2 — Build & Push (no `latest`)

### Design decisions
- Tag scheme: **`vX.Y.Z`** for releases, **`sha-<short-sha>`** for CI builds. Both may be pushed; deployments pin to exactly one immutable tag.
- Use `docker buildx` for `linux/amd64` (GKE default) and record the **image digest** in the README.

```bash
export TAG=v1.0.0
docker buildx build \
  --platform linux/amd64 \
  -f docker/Dockerfile \
  -t <dockerhub-user>/go-sample-app:${TAG} \
  --push .
```

### ✅ Definition of Done — Task 2
- [ ] Image pushed to Docker Hub with semantic tag (e.g., `v1.0.0`) — **`latest` never pushed**
- [ ] Docker Hub URL documented in README
- [ ] Image digest (`sha256:…`) recorded in README for supply-chain traceability
- [ ] Exact build/push commands documented and reproducible

---

## 5. Task 3 — Kustomize (production-grade workload)

### Design decisions
- **base/** holds the canonical, environment-agnostic manifests. **overlays/** hold only diffs. Developers touch **only** the overlay: image tag via `images:` transformer, env values via `configMapGenerator` (`config.env`), scaling (HPA min/max) and resources via small strategic-merge patches. → "adjust values without rebuilding Kustomize" requirement satisfied.
- `configMapGenerator` with hash suffix (default) → changing config triggers an automatic rolling restart. This is intentional; document it.

### Deployment spec — required fields (this is where the grade is)
```yaml
# deployment.yaml (key excerpts — full file must contain all of these)
spec:
  # ⚠️ NO `replicas` field here — HPA owns replica count (minReplicas: 2 = HA baseline).
  # Setting it would make ArgoCD (selfHeal) fight the HPA on every scale event.
  # Belt-and-braces: ArgoCD Application also sets ignoreDifferences on /spec/replicas (see Task 5).
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }   # zero-downtime
  template:
    spec:
      terminationGracePeriodSeconds: 30   # must exceed the app's drain budget (503 → 5s wait → Shutdown), see §1.1
      securityContext:             # POD level
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: { type: RuntimeDefault }
      affinity:
        podAntiAffinity:           # spread across nodes
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector: { matchLabels: { app: go-sample-app } }
      topologySpreadConstraints:   # spread across zones (regional cluster)
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { app: go-sample-app } }
      containers:
        - name: app
          securityContext:         # CONTAINER level
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 128Mi }        # memory req==limit; NO cpu limit (avoid throttling) — document this choice
          startupProbe:  { httpGet: { path: /healthz, port: 8080 }, failureThreshold: 30, periodSeconds: 2 }
          livenessProbe: { httpGet: { path: /healthz, port: 8080 }, periodSeconds: 10 }
          readinessProbe:{ httpGet: { path: /readyz,  port: 8080 }, periodSeconds: 5 }
          volumeMounts:              # required by readOnlyRootFilesystem (see §1.1 contract)
            - { name: tmp, mountPath: /tmp }
      volumes:
        - { name: tmp, emptyDir: { sizeLimit: 64Mi } }
```
- **PDB**: `minAvailable: 1` with HPA `minReplicas: 2` (never a PDB that blocks node drain — verify math against the *minimum* replica count, since HPA may scale down to it).
- **HPA**: target CPU 70%, min 2 / max 6 (scalability pillar). **HPA is the single owner of replica count** — the Deployment omits `spec.replicas` entirely.
  - *Known and accepted*: with the field absent, Kubernetes defaults the Deployment to **1** replica on first create. The HPA raises it to `minReplicas: 2` on its next reconcile (~15–30 s) — it enforces `minReplicas` even while metrics still read `<unknown>`, so this self-corrects without intervention. Document this; a reviewer watching the first sync will see it.
- **Image reference**: manifests always pull through the **Artifact Registry remote repository**, never `docker.io/…` directly — see Task 4 §"Registry strategy". The `images:` transformer name in `base/` is the bare `go-sample-app`; the overlay maps it to the full AR path + tag, and that is the single line CI rewrites.
- Service type `ClusterIP`; expose via Ingress/Gateway later — not in scope, note it.
- If the app needs GCP APIs: dedicated `ServiceAccount` annotated with `iam.gke.io/gcp-service-account` (see Task 4 — Workload Identity). **No key files, no env-injected credentials.**

### ✅ Definition of Done — Task 3
- [ ] `base/` + `overlays/dev|prod` structure; `kustomize build overlays/prod` renders cleanly
- [ ] Image tag changed **only** via `images:` transformer in overlay (`kustomize edit set image` works)
- [ ] Dev-tunable values live in `config.env` via `configMapGenerator` (hash-suffix rollout documented)
- [ ] Deployment has **no** `spec.replicas` (HPA owns it, minReplicas 2); RollingUpdate `maxUnavailable: 0`
- [ ] `/tmp` emptyDir volume + mount present (consistent with readOnlyRootFilesystem and §1.1)
- [ ] All 3 probes present with distinct purposes (startup vs liveness vs readiness)
- [ ] Resources: memory request == limit; CPU request set; CPU limit intentionally omitted **and documented**
- [ ] PDB present and mathematically compatible with replica count (drain never blocked)
- [ ] podAntiAffinity (hostname) + topologySpreadConstraints (zone) present
- [ ] Full securityContext at pod **and** container level: runAsNonRoot, readOnlyRootFilesystem, drop ALL caps, no privilege escalation, seccomp RuntimeDefault
- [ ] HPA manifest present (min 2, max 6, CPU 70%)
- [ ] `kubeconform`/`kubectl apply --dry-run=server` passes; no deprecated APIs

---

## 6. Task 4 — GKE via Terraform (best practices, no injected keys)

### Design decisions
- **Terraform** with GCS remote backend + state locking; pinned provider versions; module layout (`network`, `gke`, `iam`), env folder `envs/prod`.
- **Network (module `network`)**: custom-mode VPC, one subnet with **secondary ranges** for Pods (/17) and Services (/22) → VPC-native cluster; **Cloud NAT + Cloud Router** so private nodes reach the internet egress-only; firewall: deny-by-default posture, only required rules.
- **Cluster (module `gke`)**:
  - **Regional** cluster (multi-zone control plane + nodes) → HA pillar
  - **Private nodes** (`enable_private_nodes = true`), control plane with `master_authorized_networks` restricted (no 0.0.0.0/0)
  - **Control-plane access for bootstrap/ops** (needed for `kubectl apply -f argocd/` in Task 5 — decide it here, don't leave it implicit): expose `authorized_cidrs` as a Terraform variable and add the operator's IP/32 (or a bastion/IAP-tunneled VM inside the VPC) to `master_authorized_networks`. For this assignment: operator-IP entry via variable, with a README note that production would use IAP/bastion or Connect Gateway instead
  - `remove_default_node_pool = true` + separately managed node pool with **autoscaling** (1–3 per zone), `auto_repair`/`auto_upgrade` on, **Shielded Nodes**, `workload_metadata_config = GKE_METADATA`
  - **Node sizing (an explicit decision, not a default)**: `machine_type = "e2-standard-4"` (4 vCPU / 16 GB), `disk_type = "pd-balanced"`, `disk_size_gb = 50`. Rationale: the app itself is tiny, but the in-cluster LGTM stack of Task 6 (Prometheus + Loki + Tempo + Grafana + Alloy) needs roughly **4–6 vCPU and 8–12 GB in aggregate** — on `e2-medium` the stack simply never schedules. `min_count = 1` per zone (×3 zones = 3 nodes floor) is also what keeps zonal PVCs schedulable (see Task 6 note). This is the dominant cost driver: ~US$8–13/day, so run `terraform destroy` between demo sessions.
  - **Workload Identity enabled** (`workload_pool = <project>.svc.id.goog`)
  - Release channel `REGULAR`; VPC-native (`ip_allocation_policy` bound to secondary ranges); **Dataplane V2** (`datapath_provider = "ADVANCED_DATAPATH"`) which enforces NetworkPolicy natively — do **NOT** also set the `network_policy` addon block (mutually exclusive; GKE rejects both together); logging+monitoring to Cloud Ops (coexists with in-cluster LGTM)
  - `deletion_protection = var.deletion_protection` (default `true`; hardcoding `true` makes `terraform destroy` fail). **Teardown is a two-step sequence** — the flag lives in Terraform *state*, not in the CLI invocation, so you must first `terraform apply -var deletion_protection=false` and only then `terraform destroy`. Put this in `infra/terraform/README.md`; discovering it at teardown time is a guaranteed stumble.
- **Registry strategy (reconciling Task 2's Docker Hub requirement)**: the assignment mandates pushing to Docker Hub, but pulling straight from Docker Hub is bad practice on GKE — all private nodes egress through one Cloud NAT IP, so Docker Hub's per-IP rate limit throttles the whole cluster. Solution: Terraform creates an **Artifact Registry *remote repository*** (`mode = "REMOTE_REPOSITORY"`, `remote_repository_config.docker_repository.public_repository = "DOCKER_HUB"`) that proxies and caches Docker Hub. Image is pushed to Docker Hub (per Task 2), but manifests reference it via `<region>-docker.pkg.dev/<project>/dockerhub-remote/<dockerhub-user>/go-sample-app:<tag>`. This is exactly why the node SA gets `artifactregistry.reader`, and it removes the rate-limit risk.
  - **A remote repository is a read-through cache — you cannot push to it.** The write path stays `docker buildx --push` → Docker Hub; only the *pull* path goes through AR. Do not point Task 2's push command at the AR URL.
  - **The Docker Hub repository must therefore be public.** AR pulls anonymously by default; a private upstream requires `upstream_credentials` holding a Docker Hub username + access token in **Secret Manager**, plus an IAM grant for the AR service agent. We deliberately keep the repo public — Task 2's DoD already requires a browsable Docker Hub URL for the reviewer — and note the Secret Manager variant in the README as the production path.
  - Document the split in the Task 2, Task 3 **and Task 7** READMEs — Task 7 is where the two registries actually meet in code.
- **IAM (module `iam`)**:
  - Custom **node service account** with only `roles/logging.logWriter`, `roles/monitoring.metricWriter`, `roles/monitoring.viewer`, `roles/artifactregistry.reader` (consumed by the remote-repo pull path above) — never the default Compute Engine SA
  - **App GSA** + `roles/iam.workloadIdentityUser` binding to `serviceAccount:<project>.svc.id.goog[<ns>/<ksa>]`

### 🔑 The "no injected keys" condition — the answer is Workload Identity
1. Terraform creates GSA `app-prod@<project>.iam.gserviceaccount.com` with least-privilege roles.
2. Terraform binds KSA `prod/go-sample-app` → GSA via `workloadIdentityUser`.
3. Kustomize `ServiceAccount` carries annotation `iam.gke.io/gcp-service-account: app-prod@…`.
4. Pod obtains short-lived tokens from the GKE metadata server automatically. **Zero JSON keys exist anywhere.** Explain this flow in `infra/terraform/README.md` — it directly answers the assignment's "Important Condition".

### ✅ Definition of Done — Task 4
- [ ] Remote state in GCS bucket (versioned), providers/modules version-pinned
- [ ] Custom VPC + subnet with secondary ranges; cluster is VPC-native
- [ ] Cloud Router + Cloud NAT for private node egress
- [ ] Regional, **private** cluster; master authorized networks restricted **with operator access path defined** (authorized_cidrs variable / bastion+IAP) so Task 5 bootstrap is actually possible
- [ ] Dataplane V2 (`ADVANCED_DATAPATH`) enabled; `network_policy` addon block **absent** (mutually exclusive)
- [ ] `deletion_protection` parameterized as a variable **and the two-step teardown (`apply -var deletion_protection=false` → `destroy`) documented**
- [ ] Artifact Registry **remote repository** proxying Docker Hub created; manifests pull via AR path (NAT-IP rate-limit risk addressed; consistent with node SA's `artifactregistry.reader`)
- [ ] Docker Hub repo is public (or `upstream_credentials` via Secret Manager wired) — and "remote repo is pull-only, never a push target" is stated in the README
- [ ] Default node pool removed; managed pool with autoscaling, auto-repair/upgrade, Shielded Nodes
- [ ] `machine_type` / `disk_type` / `disk_size_gb` explicitly set and justified against the LGTM stack's aggregate requests (not left to provider defaults)
- [ ] Workload Identity enabled at cluster **and** node-pool level
- [ ] Custom least-privilege node SA (default compute SA not used)
- [ ] App GSA + workloadIdentityUser binding + KSA annotation wired end-to-end
- [ ] **No `google_service_account_key` resource anywhere in the codebase**
- [ ] `terraform fmt -check`, `validate`, and `plan` clean; README documents apply order & WI flow

---

## 7. Task 5 — ArgoCD (declarative GitOps delivery)

### Design decisions
- Declarative **`AppProject`** (restrict source repo + destination ns) + **`Application`** YAMLs — no `argocd app create` imperative commands as the primary path.
- `Application` points at `k8s/overlays/prod`, with:
  ```yaml
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, PruneLast=true, RespectIgnoreDifferences=true]
    retry: { limit: 5, backoff: { duration: 5s, factor: 2, maxDuration: 3m } }
  ignoreDifferences:                 # HPA owns replica count — selfHeal must not fight it
    - group: apps
      kind: Deployment
      jsonPointers: ["/spec/replicas"]
  ```
- The **observability stack is also an ArgoCD Application** (Helm source) — everything in the cluster is GitOps-managed, nothing hand-installed.
- Document bootstrap: install ArgoCD via manifest/Helm → `kubectl apply -f argocd/projects/ -f argocd/apps/` → from then on Git drives everything. (Mention App-of-Apps as the scaling pattern.)

### ✅ Definition of Done — Task 5
- [ ] `AppProject` YAML restricting sources/destinations (least privilege)
- [ ] `Application` YAML: automated sync, prune, selfHeal, retry/backoff, CreateNamespace
- [ ] `ignoreDifferences` on `/spec/replicas` + `RespectIgnoreDifferences=true` (HPA compatibility — selfHeal must never revert scaling)
- [ ] Points to Kustomize overlay path in Git (not a local path, not Helm-for-app)
- [ ] Observability stack deployed as ArgoCD Application(s) too
- [ ] README: bootstrap commands + how a Git commit becomes a deployment (with rollback = `git revert`)

---

## 8. Task 6 — Observability: LGTM stack

### Design decisions
- **L**oki (logs) + **G**rafana (dashboards) + **T**empo (traces) + **M**imir/**Prometheus** (metrics — use `kube-prometheus-stack` for the assignment; note Mimir as the scale-out path).
- Collection: Grafana **Alloy** (or Promtail) DaemonSet ships container logs → Loki; app exposes `/metrics` + `ServiceMonitor`; traces exported via **OTLP** → Tempo.
- **Correlation is the differentiator**: Grafana datasources configured so logs ↔ traces link via `traceID` (Loki derived fields → Tempo) and Tempo → Loki "logs for this span". Mention exemplars (metrics → traces).
- Dashboards provisioned **as code** (JSON in `observability/dashboards/`, loaded via Grafana sidecar): (1) cluster/node health, (2) app golden signals (rate/errors/duration from RED), (3) logs explorer, (4) trace overview.
- Alerting: at minimum, PrometheusRule for pod crash-looping, HPA at max, PDB violations, high error rate.
- **Persistence is zonal — size the node pool floor around it.** Prometheus/Loki/Tempo PVCs bind to zonal Persistent Disks, which pins each pod to one zone for the life of the volume. If the cluster autoscaler drains a zone to zero the pod goes `Pending` and cannot recover. This is why Task 4 fixes `min_count = 1` per zone; write the causal link down rather than leaving it as a coincidence.

### ✅ Definition of Done — Task 6
- [ ] kube-prometheus-stack, Loki, Tempo installed **via ArgoCD** with pinned chart versions
- [ ] Helm values files in Git (no `--set` snowflakes)
- [ ] App metrics scraped via ServiceMonitor; logs flowing to Loki; OTLP traces to Tempo
- [ ] Grafana datasources: Prometheus + Loki + Tempo, with **trace↔log correlation configured**
- [ ] ≥3 provisioned dashboards as code (infra end-to-end + app RED + logs/traces)
- [ ] Basic PrometheusRule alerts committed
- [ ] Persistence/retention configured (not default ephemeral), resource requests set on the stack itself

---

## 9. Task 7 — CI/CD (GitOps pipeline)

### Design decisions — CI and CD are separate by design
```
push/tag → GitHub Actions (CI): lint+test → build (buildx) → trivy scan →
push image :sha-<sha>/:vX.Y.Z to DOCKER HUB → `kustomize edit set image` in k8s/overlays/prod
  (rewrites to the ARTIFACT REGISTRY REMOTE path, same tag) →
commit+push manifest change → ArgoCD detects → sync → GKE pulls via AR
```
- **⚠️ Two registries, one tag — write the push path and the pull path down explicitly.** CI *pushes* to Docker Hub but manifests *pull* through the AR remote repository (Task 4 §"Registry strategy"). The bump step is therefore:
  ```bash
  kustomize edit set image \
    go-sample-app=${REGION}-docker.pkg.dev/${PROJECT}/dockerhub-remote/${DOCKERHUB_USER}/go-sample-app:sha-${SHORT_SHA}
  ```
  The tag is identical on both sides — only the host prefix differs. `docker.io/…` must never appear in `k8s/`, and the AR path must never appear in a `docker push`. Assert both with a grep step in CI so the invariant cannot rot.
- **CI has zero cluster credentials.** The only write it performs is a Git commit updating the image tag. ArgoCD (in-cluster) pulls. This is the pull-based GitOps answer they want — state it explicitly in the README and include the diagram above (or Mermaid).
- Gates: `go vet` + tests → build → **Trivy scan: `--severity CRITICAL --exit-code 1 --ignore-unfixed`** → push → tag bump commit (`[skip ci]` guard to avoid loops). `--ignore-unfixed` is deliberate: CVEs with no upstream patch must not permanently block the pipeline; known accepted risks go in a committed `.trivyignore` with an expiry comment per entry.
- **Write-back credential (the manifest-bump commit needs one — the default `GITHUB_TOKEN` triggers no re-run and may be blocked by branch protection):** use a **GitHub App** installation token (preferred) or a fine-grained PAT with `contents:write` scoped to this repo only, stored as a repo secret. Branch protection on `main` stays ON; the bot goes in the protection rule's **bypass list** (or pushes to a `release/bump` branch with auto-merge if bypass is not allowed by org policy). Document the chosen path in the workflow README.
- Docker Hub creds via repository secrets only. Optional bonus: keyless **cosign** signing.
- Separate `terraform.yaml` workflow: fmt/validate/plan as PR checks (plan output as PR comment; apply manual/protected).

### ✅ Definition of Done — Task 7
- [ ] Workflow YAML: test → build → scan → push → manifest bump, in that order
- [ ] Image tagged `sha-<short-sha>` (and `vX.Y.Z` on release tags); never `latest`
- [ ] Push target is Docker Hub; the committed manifest image ref is the **AR remote path** with the same tag — plus a CI guard asserting `docker.io/` never appears under `k8s/`
- [ ] Pipeline commits `kustomize edit set image` change; **no kubectl in CI anywhere**
- [ ] Loop protection (`[skip ci]` / path filters) on the bump commit
- [ ] Trivy gate: fail on CRITICAL **with `--ignore-unfixed`**; `.trivyignore` (with expiry notes) for accepted risks
- [ ] Write-back auth defined: GitHub App / fine-grained PAT secret + branch-protection bypass (or bump-branch + auto-merge) — documented
- [ ] Secrets only via CI secret store; none in YAML
- [ ] Architecture diagram (Mermaid ok) showing CI vs CD separation committed to README

---

## 10. Task 8 — Ansible project

### Design decisions
- Proper structure: `site.yml` importing 4 roles; `inventory/hosts.ini`; `group_vars/all.yml` for versions/ports/paths; every role has `tasks/`, `handlers/`, `templates/`, `defaults/`.
- **Idempotency is the grading criterion**: second run must report `changed=0`. Use handlers for restarts; never `command` when a module exists.

| Role | Key implementation details |
|---|---|
| `common` | `ansible.builtin.apt: upgrade=dist update_cache=yes cache_valid_time=3600`; reboot-if-required check (`/var/run/reboot-required`) gated by a var |
| `docker` | Official Docker repo (keyring method, not apt-key); template `/etc/docker/daemon.json`: `{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}`; **handler** restarts docker only on change |
| `nginx_container` | `templates/index.html.j2` (uses `inventory_hostname`, `ansible_date_time` to prove templating); `community.docker.docker_container` with `image: nginx:1.27-alpine` (pinned!), `restart_policy: always`, `published_ports: "8080:80"`, volume-mount the rendered HTML read-only |
| `node_exporter` | `ansible.builtin.user: system=yes shell=/usr/sbin/nologin create_home=no`; download pinned release **with checksum verification**; `templates/node_exporter.service.j2` (`User=node_exporter`, `NoNewPrivileges=true`, `ProtectSystem=strict`); `systemd: daemon_reload=yes enabled=yes state=started` |

Execution: `ansible-playbook -i inventory/hosts.ini site.yml` (+ `--check --diff` documented for dry-run).

### ✅ Definition of Done — Task 8
- [ ] Full role structure (tasks/handlers/templates/defaults) ×4 roles + inventory + group_vars
- [ ] OS packages updated via apt module with cache handling
- [ ] Docker installed from official repo (keyring, no deprecated apt-key)
- [ ] `daemon.json` log rotation templated + change-triggered handler restart
- [ ] NGINX container: pinned tag, `restart_policy: always`, port published, HTML from Jinja2 template mounted read-only
- [ ] Node Exporter: dedicated **system, non-login** user; checksum-verified binary; hardened systemd unit; enabled+started
- [ ] All variables in `defaults/`/`group_vars` (no hardcoding); playbook idempotent (2nd run `changed=0`)
- [ ] Execution + dry-run commands documented

---

## 11. Cross-cutting: Definition of Done for the whole submission

- [ ] Top-level README: architecture diagram, repo map, per-task index, quickstart order (Task 4 infra → ArgoCD bootstrap → everything else via Git)
- [ ] Every non-obvious decision has a written **why** (no CPU limit, Workload Identity vs keys, pull-based CD, distroless, PDB math)
- [ ] `latest` appears nowhere; every image/chart/provider/binary version is pinned
- [ ] No secret material anywhere in Git history (verify with `gitleaks` before submitting)
- [ ] All YAML/HCL passes linters: `yamllint`, `kubeconform`, `terraform fmt/validate`, `ansible-lint`, `hadolint` (Dockerfile)
- [ ] Trade-offs / "what I'd do next with more time" section (e.g., Mimir at scale, cosign + policy controller, External Secrets Operator, multi-env promotion) — shows senior judgment

## 12. Suggested execution order

0. **Task 0 — bring the app up to the §1.1 contract.** The provided sample is a bare `hello` handler on `DefaultServeMux`: no `/healthz`, no `/readyz`, no `/metrics`, no tracing, no SIGTERM handling, no timeouts, and a reflected-XSS hole. Nothing downstream works without this — the probes in Task 3 would silently pass (a `/` catch-all answers `/healthz` with `200 Hello`), and all of Task 6 would have nothing to scrape, log, or trace. Bump `go.mod` to Go 1.26 here too (1.23 is out of support, and `prometheus/client_golang` now requires ≥1.25 anyway). **This is a prerequisite, not an optional polish.**
1. Task 1 → 2 (image exists) → 3 (manifests render) — the app storyline
2. Task 4 (cluster up) → 5 (ArgoCD bootstrap, app live)
3. Task 7 (pipeline closes the loop) → 6 (observability on top)
4. Task 8 (independent — can be done anytime)

**Cost-aware variant (recommended):** do steps 0–1–3–5–6 against the local `kind` cluster first, where iteration is free, and only then run Task 4's `terraform apply` once to demonstrate the same GitOps flow on real GKE. Capture evidence, then tear down via the two-step teardown in Task 4.

### Toolchain prerequisites
`go mod tidy` cannot be faked — the §1.1 contract pulls in `promhttp` and the OTel SDK, so a real `go.sum` must be generated by a real toolchain. Either install Go 1.26 locally, or run every Go command inside `golang:1.26-bookworm` via Docker (which is needed for Tasks 1–2 regardless). Other binaries used: `kustomize`, `kubeconform`, `trivy`, `ansible-lint`, `hadolint`, `gitleaks`, `gcloud`.

### วิธีรัน ###

1. start vm instance disks
cd D:\Project\Demo-Project\Demo-DevOps\infra\terraform\envs\prod
terraform plan "-var-file=demo.tfvars" "-out=tfplan"
terraform apply tfplan 2>&1 | Tee-Object -FilePath apply.log

2. check status
cd D:\Project\Demo-Project\Demo-DevOps\infra\terraform\envs\prod
terraform state list | Measure-Object -Line    # ต้องได้ 25
gcloud container clusters list    # STATUS ต้องเป็น RUNNING ไม่ใช่ RECONCILING
