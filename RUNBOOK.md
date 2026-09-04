# Runbook — bring the demo up, look at it, tear it down

The whole session, in order, with the commands that actually worked. PowerShell
for Terraform (it needs the quoting), bash for the scripts.

Roughly 1 hour end to end. The cluster bills about **฿15/hour**, so the last
section is not optional.

---

## 1. Bring the infrastructure up  (~18 min)

```powershell
cd D:\Project\Demo-Project\Demo-DevOps\infra\terraform\envs\prod
terraform plan "-var-file=demo.tfvars" "-out=tfplan"
terraform apply tfplan 2>&1 | Tee-Object -FilePath apply.log
```

**Quote every `-flag=value`.** PowerShell 7 splits an unquoted one into two
arguments, and Terraform then rejects the whole command with a message pointing
at `-chdir`, which sends you looking in the wrong place entirely.

`terraform apply <planfile>` does not prompt, so the output can be piped to
`Tee-Object` without swallowing an interactive question. The log matters: the
first time this ran, the process died silently and there was nothing to look at.

### Is it finished?

```powershell
terraform state list | Measure-Object -Line   # expect 25
gcloud container clusters list                # STATUS must be RUNNING, not RECONCILING
```

Watch out for a trap here. Partway through, `gcloud compute instances list` shows
three nodes of type **`e2-medium`** named `default-pool`. Those are not the
cluster's nodes — GKE always creates a default pool, and `remove_default_node_pool`
deletes it before the real pool is built. The pool you want is
**`go-sample-app-prod-pool`** on **`e2-standard-2`**:

```powershell
gcloud container node-pools list --cluster=go-sample-app-prod --region=asia-southeast1
gcloud compute instances list --format="table(name,zone,machineType,status)"
```

Expect one node in each of `asia-southeast1-a`, `-b`, `-c`.

---

## 2. Hand the cluster to ArgoCD  (~8 min)

```bash
cd /d/Project/Demo-Project/Demo-DevOps
./scripts/bootstrap-cluster.sh dockerpeace peacedwk55/go-gke-demo
```

This is the only imperative step in the system. Everything after it arrives
through Git.

The script **refuses to run if the working tree is dirty or HEAD is unpushed** —
that is not fussiness. ArgoCD syncs from the GitHub remote, so bootstrapping
against a commit that only exists on your laptop gives you a "Synced" badge for
code nobody else has. If it stops, commit and push, then run it again.

### Wait for all six Applications

```bash
kubectl get applications -n argocd -w
```

Expect `Synced / Healthy` on all six: `go-sample-app-prod`, `kube-prometheus-stack`,
`loki`, `tempo`, `alloy`, `observability-config`. Five to eight minutes.

---

## 3. Give it something to look at

Grafana's graphs are empty without traffic, and an empty graph looks like a
broken one. Exemplars in particular only exist where a request happened.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: load, namespace: prod }
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: l
      image: curlimages/curl:8.11.1
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      command: ["sh","-c"]
      args:
        - |
          i=0
          while [ $i -lt 900 ]; do
            curl -s -o /dev/null http://go-sample-app.prod.svc.cluster.local/?name=demo$i
            [ $((i % 12)) -eq 0 ] && curl -s -o /dev/null http://go-sample-app.prod.svc.cluster.local/nope$i
            i=$((i+1)); sleep 1
          done
          echo DONE
EOF
```

The securityContext is not decoration. The `prod` namespace enforces the
`restricted` Pod Security Standard, and a plain `kubectl run` is refused outright.

One request in twelve goes to a path that does not exist, so the RED dashboard has
a non-zero error rate to draw.

---

## 4. Open everything

In a **second terminal**, and leave it running:

```bash
./scripts/port-forward-all.sh
```

Five UIs at once, with both passwords printed. Ctrl-C closes them all.

| | URL | Look at |
|---|---|---|
| **ArgoCD** | https://localhost:8080 | The browser will warn about the certificate — Advanced → Proceed. Six Applications as a tree; click one, then **DIFF**: Git on the left, the cluster on the right. This single screen explains GitOps better than any paragraph. |
| **Grafana** | http://localhost:3000 | Dashboards → `app-red`. On the latency panel, look for small marks under the line — those are **exemplars**. Click one → the trace opens in Tempo → **Logs for this span** → the real log line from Loki, carrying the same `trace_id`. Three clicks from a graph to the log of one request. |
| **Prometheus** | http://localhost:9090 | Status → Targets. `go-sample-app` should be UP, two of them. |
| **Alertmanager** | http://localhost:9093 | Whatever is currently firing. |
| **Alloy** | http://localhost:12345 | The log pipeline as connected components: `discovery.kubernetes → relabel → file → process → loki.write`. If a component is not green, logs are not flowing. |

Worth opening alongside: **Google Console → Kubernetes Engine → go-sample-app-prod**,
which shows the same cluster from the GCP side — Workloads, Nodes, and the Cloud
Logging that runs in parallel with the in-cluster stack.

---

## 5. Tear it down — **in this order**

The order is the whole point. Skip it and five Persistent Disks survive the
cluster and keep billing, which is exactly what happened the first time.

```bash
# 1. let the CSI controller reclaim the disks while it still exists
kubectl -n argocd delete application loki tempo kube-prometheus-stack alloy
kubectl -n observability delete pvc --all
kubectl -n observability get pvc                 # wait until empty
gcloud compute disks list --filter="-users:*"    # expect nothing
```

```powershell
# 2. only then
cd D:\Project\Demo-Project\Demo-DevOps\infra\terraform\envs\prod
terraform destroy "-var-file=demo.tfvars"
```

One command, not two — `demo.tfvars` already sets `deletion_protection = false`.
The two-step `apply -var deletion_protection=false` then `destroy` sequence is for
a production cluster, and running it here just spends minutes reconciling a
cluster you are about to delete.

`standard-rwo` uses `reclaimPolicy: Delete`, so deleting a PVC *does* delete its
disk — the CSI controller does that. But `terraform destroy` removes the whole
cluster at once and takes the controller with it, so anything not already
reclaimed is simply abandoned.

### Verify, do not assume

```powershell
gcloud container clusters list                  # 0
gcloud compute instances list                   # 0
gcloud compute disks list                       # 0
gcloud compute routers list                     # 0
gcloud compute addresses list                   # 0
gcloud artifacts repositories list              # 0
gcloud compute networks list                    # only `default`
gcloud storage ls                               # only the tfstate bucket
```

The tfstate bucket stays on purpose — a few hundred bytes, and it holds the
history. Remove it only when finished with the project entirely.

---

## If something is wrong

| Symptom | Where to look |
|---|---|
| `terraform apply` exits immediately, no output | A stale lock. `gcloud storage ls "gs://<project>-tfstate/**"` — if `default.tflock` is there and no terraform is running, unlock with the object's **generation** number, not the UUID inside the file: `terraform force-unlock -force <generation>` |
| Applications stuck `OutOfSync/Missing` | `kubectl get app <name> -n argocd -o json` and read `status.operationState.syncResult.resources`. The per-resource message names the real cause; the top-level "one or more synchronization tasks are not valid" never does. |
| Grafana `CrashLoopBackOff` | `kubectl -n observability logs deploy/kube-prometheus-stack-grafana -c grafana`. Provisioning errors are fatal, and ArgoCD will still report Synced — Synced means the manifests reached the API server, not that the process started. |
| Loki has no logs | Ask it what it knows: `curl .../loki/api/v1/labels` from inside the cluster. An empty label set means nothing ever arrived, which is an Alloy problem, not a Loki one. The Alloy UI at :12345 shows where the pipeline stops. |
| No exemplars in Grafana | Usually just no traffic. Section 3. |
