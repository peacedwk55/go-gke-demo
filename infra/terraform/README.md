# Infrastructure — Task 4

Terraform for a regional, private, VPC-native GKE cluster with Workload Identity.

```
envs/prod/          root module — the only place you run terraform
modules/network/    VPC, subnet + secondary ranges, Cloud Router + NAT, firewall
modules/gke/        cluster + separately-managed node pool
modules/iam/        node SA, app GSA (the WI binding itself lives in envs/prod — see below)
```

Modules take inputs and return outputs; the root module wires them together. Apply order is
derived from that data flow, so there is no hand-maintained dependency list to fall out of date.

---

## The Important Condition: deploying without injected keys

The assignment's condition is that no service account key may be injected. The answer is
**Workload Identity**, and it is worth being precise about why a key is the wrong tool rather than
merely a discouraged one.

A `google_service_account_key` is a permanent, offline-usable bearer credential. Create one and it
lands in Terraform state, then a CI secret store, then a Kubernetes Secret, and eventually
somebody's Downloads folder. It does not expire. Nothing tells you when it leaks. Rotation is a
manual, coordinated change across every consumer.

Workload Identity replaces the credential with a *trust relationship*:

```
┌─ Terraform (modules/iam) ────────────────────────────────────────────────┐
│                                                                          │
│  1. google_service_account "app"                                         │
│         └─> app-prod@<project>.iam.gserviceaccount.com                    │
│                                                                          │
│  2. google_service_account_iam_member                                    │
│         role   = roles/iam.workloadIdentityUser                          │
│         member = serviceAccount:<project>.svc.id.goog[prod/go-sample-app] │
│                                          └── namespace ──┘└─── KSA ───┘  │
└──────────────────────────────────────────────────────────────────────────┘
                                    ▲
                                    │ names, does not authenticate
                                    │
┌─ Kubernetes (k8s/overlays/prod) ───┴──────────────────────────────────────┐
│  ServiceAccount go-sample-app in namespace prod                           │
│    annotations:                                                           │
│      iam.gke.io/gcp-service-account: app-prod@<project>.iam.gserviceac…    │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                    pod starts, asks the GKE metadata server
                                    ▼
                 short-lived, auto-rotated OAuth token (~1h)
```

**No key material is created, stored or transported at any point.** Verify it yourself:

```bash
grep -rE 'resource +"google_service_account_key"' --include='*.tf' .   # no matches
```

Three details that are easy to get wrong, and each of which produces a setup that *looks*
configured and silently does nothing:

1. **`workload_identity_config` on the cluster is only half of it.** The node pool must also set
   `workload_metadata_config { mode = "GKE_METADATA" }`. With the pool enabled but nodes left on
   `GCE_METADATA`, pods read the raw metadata server and inherit the *node's* identity.
2. **The member string must match the KSA exactly** — namespace *and* name. A mismatch authorises
   nothing, with no error anywhere.
3. **`google_service_account_iam_member`, not `_binding`.** The `_binding` form is authoritative and
   silently deletes any other binding on that GSA which Terraform does not know about.

The binding is created before the namespace or KSA exists, and that part is genuinely fine — the
member string names an identity, it does not resolve one.

**But there IS an ordering dependency, and an earlier version of this file denied it.** The first
apply failed here:

```
Error 400: Identity Pool does not exist (<project>.svc.id.goog)
```

The *pool* in that member string is not a pre-existing project resource: GKE creates it as a side
effect of `workload_identity_config` on the cluster. So the binding has to come after the cluster —
which the `iam` module cannot express, because the `gke` module already consumes its node service
account and `depends_on = [module.gke]` there would close a cycle.

The binding therefore lives in the **root module** (`envs/prod/main.tf`), which can see both and
order them. Fourth thing that is easy to get wrong, found by applying rather than by reading.

---

## Prerequisites

```bash
gcloud auth application-default login
gcloud config set project <project-id>
```

The state bucket must exist before `terraform init` — Terraform cannot create its own backend:

```bash
gcloud storage buckets create gs://<project>-tfstate \
  --location=asia-southeast1 --uniform-bucket-level-access
gcloud storage buckets update gs://<project>-tfstate --versioning
```

Versioning is the part that matters: it is what makes a bad apply recoverable. State holds the
cluster CA and endpoint, so restrict the bucket to the Terraform principals.

---

## Step 0 — check the CPU quota BEFORE anything else

```bash
gcloud services enable compute.googleapis.com

gcloud compute regions describe asia-southeast1 \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  | grep -iE "^CPUS|SSD_TOTAL|DISKS_TOTAL_GB|IN_USE_ADDRESSES"
```

| Metric | Needed by the default profile | Needed by `demo.tfvars` |
|---|---|---|
| `CPUS` | 12 (3 × e2-standard-4) | **6** (3 × e2-standard-2) |
| `DISKS_TOTAL_GB` | 265 | 205 |
| `IN_USE_ADDRESSES` | 1 | 1 |

This is step 0 rather than a footnote for a specific reason: **the Google Cloud
free trial forbids requesting quota increases.** If the project's default CPU
quota is below what the profile needs, there is no way to raise it without
upgrading to a paid account — which is the thing the trial exists to avoid. And
the failure surfaces *mid-apply*, after the VPC and cluster already exist, as a
generic quota error on the node pool.

Fresh projects have historically defaulted to well under 12 vCPU per region, so
`demo.tfvars` exists to fit inside a small quota.

## Apply

```bash
cd envs/prod

# demo run — small nodes, Spot, disposable
cp demo.tfvars.example demo.tfvars
# edit: project_id, and master_authorized_networks with `curl -s https://ifconfig.me`/32

terraform init -backend-config="bucket=<project>-tfstate"
terraform fmt -check -recursive ../..
terraform validate
terraform plan -var-file=demo.tfvars -out=tfplan
terraform apply tfplan
```

For a production apply, use `terraform.tfvars.example` instead: larger nodes,
on-demand rather than Spot, and `deletion_protection = true`.

First apply takes roughly 12–18 minutes; most of it is the regional control plane.

Then hand the outputs to the workload layer:

```bash
terraform output -raw get_credentials_command   # gcloud … get-credentials …
terraform output ksa_annotation                 # paste into the KSA patch
terraform output image_repository               # the AR pull path for kustomize
```

Three values must be substituted into `k8s/overlays/prod/`:

| Output | Replaces | In |
|---|---|---|
| `project_id` | `PROJECT_ID` | `kustomization.yaml`, `patches/serviceaccount-wi.yaml` |
| Docker Hub username | `DOCKERHUB_USER` | `kustomization.yaml` |
| `image_repository` | the registry host | `kustomization.yaml` |

They are left as literal placeholders so the repository carries no project-specific identifiers,
and so it is obvious which facts have to come from the infrastructure layer.

---

## Teardown — two steps, in this order

```bash
terraform apply -var deletion_protection=false   # FIRST
terraform destroy                                # then
```

`deletion_protection` is stored in **state**, not read from the CLI invocation, so `terraform
destroy` alone fails with `Cannot destroy cluster because deletion_protection is set to true`. It is
a variable rather than a hardcoded `true` precisely so this path exists.

`demo.tfvars` sets it `false` from the start, so a demo teardown is one step. That is only
acceptable because the demo cluster is disposable.

### After destroy — verify, do not assume

```bash
terraform destroy -var-file=demo.tfvars

# 1. cluster actually gone
gcloud container clusters list

# 2. THE expensive one: disks Kubernetes created that Terraform never knew about
gcloud compute disks list --filter="-users:*" \
  --format="table(name,sizeGb,type,zone.basename())"

# 3. the rest
gcloud compute addresses list
gcloud compute routers list
gcloud artifacts repositories list
```

**Step 2 is the one that costs money after you think you are done.** The LGTM stack's PVCs are
created by Kubernetes, not by Terraform, so `terraform destroy` has no knowledge of them. With a
`Retain` reclaim policy — or if the PVC outlives the cluster deletion — 115 GB of `pd-balanced` sits
there billing roughly **$14/month** for nothing, and nothing in the Terraform output hints at it.

Delete what step 2 lists, once you have confirmed the names are the demo's:

```bash
gcloud compute disks delete <name> --zone=<zone>
```

The GCS state bucket is worth keeping between sessions (it costs a few cents and holds the history);
remove it only when finished with the project entirely.

A regional cluster with 3 × `e2-standard-4` costs roughly **US$8–13/day**, so destroy between
sessions. `google_project_service.required` sets `disable_on_destroy = false` on purpose — teardown
should remove our cluster, not disable project-wide APIs other things may depend on.

---

## Decisions worth defending

### Regional, not zonal

`location` is a region, which replicates the control plane across three zones and the node pool per
zone. Without this the `topologySpreadConstraints` on `topology.kubernetes.io/zone` in
`k8s/base/deployment.yaml` are meaningless — there is only one zone to spread across. It is also the
only way a zonal outage does not take the API server down.

### Private nodes, restricted public control plane

Nodes have no external IP; egress is Cloud NAT only, so nothing can initiate a connection inward.

The control plane keeps its public endpoint but restricts it with `master_authorized_networks`, and
a variable validation **rejects `0.0.0.0/0`** so the single worst GKE misconfiguration cannot be
introduced through a tfvars file. Verified:

```
Error: Invalid value for variable
master_authorized_networks must not contain 0.0.0.0/0 — that exposes the
Kubernetes API to the entire internet.
```

Fully disabling the public endpoint is stronger and is what production should do — but then
`kubectl` only works from inside the VPC, so a bastion or Connect Gateway must exist *before* the
cluster can be bootstrapped. That trade-off is not worth the moving parts here; the CIDR restriction
does the real work. **This is deliberately decided rather than left implicit**, because Task 5's
`kubectl apply -f argocd/` has to work against this cluster.

### Dataplane V2, and no `network_policy` block

`datapath_provider = "ADVANCED_DATAPATH"` gives an eBPF dataplane that enforces NetworkPolicy
natively. There is deliberately **no `network_policy` block**: the two are mutually exclusive and
GKE rejects a cluster that sets both. Writing "enable network policy and Dataplane V2" is a natural
thing to specify and an impossible thing to apply.

### Custom node service account

Left unset, GKE uses the Compute Engine default service account, which holds `roles/editor` on the
whole project — so any container escape becomes a full project compromise. The node SA here holds
five roles and nothing else: `logging.logWriter`, `monitoring.metricWriter`, `monitoring.viewer`,
`artifactregistry.reader`, `stackdriver.resourceMetadata.writer`.

The app GSA holds **no** roles, because the sample app calls no GCP API. That is the correct
least-privilege answer, not an oversight — the identity and binding exist, so granting a role later
is a one-line change.

### Artifact Registry remote repository

Task 2 requires pushing to Docker Hub. Pulling from Docker Hub on GKE is the problem: every private
node egresses through one Cloud NAT IP, so Docker Hub's per-IP rate limit is shared by the whole
cluster. A rollout restarting nine nodes' worth of pods can exhaust it, and the failure is
`ImagePullBackOff` with a 429 — mid-deploy.

So images are **pushed** to Docker Hub and **pulled** through a read-through cache. This is also
what makes `artifactregistry.reader` on the node SA meaningful rather than vestigial.

Two properties to keep straight:

- **Pull-only.** A remote repository cannot be pushed to. Do not point `docker buildx --push` at it.
- **Anonymous by default**, so the upstream Docker Hub repo must be **public**. A private upstream
  needs `upstream_credentials` with a Docker Hub token in Secret Manager plus an IAM grant for the
  AR service agent. Kept public here because Task 2's DoD already requires a browsable URL.

### Node sizing is an explicit decision

`e2-standard-4` / `pd-balanced` / 50 GB, with a floor of 1 node per zone.

Sized for the **LGTM stack**, not the app. The app requests 200m/256Mi; Prometheus + Loki + Tempo +
Grafana + Alloy together want roughly 4–6 vCPU and 8–12 GB. On `e2-medium` the observability stack
simply never schedules, which presents as mysterious `Pending` pods rather than a clear error.

`min_nodes_total = 3` is also load-bearing for Task 6: the LGTM PVCs bind to **zonal**
Persistent Disks, which pins each pod to one zone for the life of the volume. If the autoscaler
drained a zone to zero those pods would go `Pending` and could not recover.

### `auto_repair` and `auto_upgrade` on

Both are safe *because* the workload has a PDB and a genuinely zero-downtime rollout — a node drain
is a non-event. Without those, automatic node replacement causes outages, and the usual reaction is
to disable it, which is exactly backwards: the fix is to make drains safe, not to stop draining.

### Cloud Ops alongside in-cluster LGTM

Not redundancy. LGTM runs *inside* the cluster, so when the cluster is the thing that is broken it
cannot tell you why. Cloud Logging and system metrics are the out-of-band view that survives that.

---

## Verified

| Check | Result |
|---|---|
| `terraform fmt -check -recursive` | clean |
| `terraform init` | provider `hashicorp/google v6.50.0`, lock file written |
| `terraform validate` | `Success! The configuration is valid.` |
| `0.0.0.0/0` in `master_authorized_networks` | rejected by variable validation |
| Empty `master_authorized_networks` | rejected by variable validation |
| `resource "google_service_account_key"` | zero occurrences in the repository |

`terraform plan` against a real project needs `gcloud auth application-default login`; everything
above is reproducible without GCP credentials.

## Not done here

No KMS key for etcd application-layer encryption (wired as
`database_encryption_key_name`, needs a keyring). No bastion or Connect Gateway. No Binary
Authorization. No VPC Service Controls. See the trade-offs section of the top-level README.
