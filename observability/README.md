# Observability — Task 6

The LGTM stack, installed by ArgoCD, configured entirely from files in this directory.

```
kube-prometheus-stack.values.yaml   Prometheus + Grafana + Alertmanager (+ the datasource wiring)
loki.values.yaml                    logs
tempo.values.yaml                   traces (+ metrics-generator)
alloy.values.yaml                   collection: node logs -> Loki, OTLP -> Tempo
alerts/app-alerts.yaml              PrometheusRule
dashboards/*.json                   3 dashboards, provisioned as ConfigMaps
kustomization.yaml                  turns the JSON into labelled ConfigMaps
```

Chart versions are pinned in `argocd/apps/observability.yaml`. There is no `helm install` and no
`--set` anywhere: `helm install` for the monitoring stack is the exception people usually make, and
it is the one that hurts — six months on nobody knows which flags were passed, and the system that
is meant to explain drift is itself undocumented drift.

## Correlation is the point

Three datasources that cannot link to each other are three tools. What makes them one system is a
single join key — `trace_id` — present in metrics, logs and traces:

```
                 ┌──────────────────────────────────────┐
                 │  app emits, on every request:        │
                 │    • trace_id in the JSON log line   │
                 │    • trace_id exemplar on the        │
                 │      latency histogram               │
                 │    • the span itself, via OTLP       │
                 └──────────────────────────────────────┘
                       │            │            │
              logs     │   metrics  │   traces   │
                       ▼            ▼            ▼
                     Loki      Prometheus      Tempo
                       │            │            │
    ┌──────────────────┴────────────┴────────────┴──────────────────┐
    │                                                              │
    │  metric → trace   exemplarTraceIdDestinations                │
    │                   click a diamond on the latency panel       │
    │                                                              │
    │  log → trace      Loki derivedFields                         │
    │                   regex '"trace_id":"([a-f0-9]{32})"'        │
    │                   renders a "View trace" button              │
    │                                                              │
    │  trace → log      Tempo tracesToLogsV2                       │
    │                   {namespace="prod"} |= "<traceID>"          │
    │                                                              │
    │  trace → metric   Tempo tracesToMetrics                      │
    │                   RED queries for the span's route           │
    │                                                              │
    └──────────────────────────────────────────────────────────────┘
```

All four links are configured in `kube-prometheus-stack.values.yaml` under `grafana.datasources`.

The regex in `derivedFields` matches the app's actual log format (`log/slog` JSON). **Change the log
format and this breaks silently** — no error, just a "View trace" button that stops appearing. That
is precisely why `trace_id` in a JSON log line is written into the application contract
(CLAUDE.md §1.1) rather than left as an implementation detail.

## Try it

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

Then, end to end:

1. **App — RED** dashboard → latency panel → click an exemplar diamond → lands on a trace in Tempo.
2. In that trace → **Logs for this span** → the log lines for that exact request.
3. **Logs & traces** dashboard → expand any log line → **View trace** → back to Tempo.

If step 1 shows no diamonds, the usual causes are `enableFeatures: [exemplar-storage]` missing from
the Prometheus spec, or the ServiceMonitor dropping exemplars at scrape time.

## Decisions worth defending

### Probe traffic is excluded from every RED query

At one readiness check every 5s and one liveness check every 10s per pod, probe requests dominate the
request rate and dilute the error ratio into meaninglessness. Worse: `/readyz` returns **503 on every
graceful shutdown** — by design, it is what makes the rollout zero-downtime — so including it would
make the high-error-rate alert fire on every single deploy.

Every RED query and the `AppHighErrorRate` rule therefore filter `route!~"/healthz|/readyz"`. The
series are still collected, because they are genuinely useful when debugging a failing probe.

The app makes the same distinction in its logging: a 503 from `/readyz` is logged at `INFO`, not
`ERROR` (`app/server.go`). An alert that fires on every correct deployment is worse than no alert,
because it teaches people to ignore the channel.

### `trace_id` is structured metadata in Loki, never a stream label

A trace id is unique per request. Promoting it to a Loki stream label would create one stream per
request and destroy the index. As structured metadata it is still filterable, and Grafana's derived
field reads it straight out of the log line.

The same reasoning excludes `pod` as a label: with an HPA scaling and rolling updates replacing pods,
every deploy would mint a fresh set of streams. `namespace`, `app`, `container` and `level` are
stable and low-cardinality; those are the labels.

### `tempo-distributed`, not single-binary Tempo

Only the distributed chart runs the **metrics-generator**, which derives the service graph and span
metrics from the traces and remote-writes them into Prometheus. That powers Grafana's service map and
the trace → metrics jump, and it means span-derived latency exists even for code paths nobody
instrumented by hand.

It is also a second, independent measurement of latency alongside the app's own histogram. When the
two disagree, that disagreement is itself the finding.

### Loki in SingleBinary mode

Loki's default topology is eight Deployments (distributor, ingester, querier, query-frontend,
compactor, index-gateway, …). That is correct at scale and pure operational overhead for one
application's logs. SingleBinary is one pod with the same query API, and the scale-out path is a
values change rather than a rewrite.

### Alloy, not Promtail

Promtail is deprecated (support ends 2026) and handles only logs. Alloy handles logs, metrics and
OTLP in one agent — one DaemonSet instead of three. Its config is River, not YAML, which is why
`alloy.values.yaml` embeds a config string.

Alloy runs as `runAsUser: 0`. Container logs on the node are root-owned and there is no way around
that for a log collector; it is called out rather than glossed over, and contained by dropping every
capability plus a read-only root filesystem.

### Persistence, and why the node pool floor is 1 per zone

Prometheus, Loki and Tempo all have PVCs rather than the charts' default `emptyDir`. With `emptyDir`
every pod restart — including a routine node upgrade — silently discards all history, which is
discovered while looking back at an incident that just happened.

The consequence: those PVCs bind to **zonal** Persistent Disks, which pin each pod to one zone for
the life of the claim. If the cluster autoscaler drained a zone to zero, they would go `Pending` and
could not recover. That is why `min_nodes_total = 3` in Terraform (a total, not per-zone — the per-zone form produced a single node) — the two settings are causally
linked, and the link is written down in both places.

Retention is 15d for metrics, 7d for logs and traces. Loki's `compactor.retention_enabled: true` is
required for that to be enforced at all; without it `retention_period` is a suggestion and the disk
fills.

### Cloud Ops runs alongside this

Not redundancy. This entire stack runs **inside** the cluster, so when the cluster is the thing that
is broken it cannot tell you why. GKE's Cloud Logging and system metrics are the out-of-band view
that survives that — see `logging_config` in `infra/terraform/modules/gke`.

### Dashboards are ConfigMaps, not chart values

A dashboard is a 200-line JSON document. Embedding it in a values file makes both unreadable; as a
generated ConfigMap it stays a real `.json` file an editor can validate and a reviewer can read as a
dashboard diff.

`disableNameSuffixHash: true` on those generators — the opposite of the app's config ConfigMap — 
because the Grafana sidecar watches by **label** and reloads on content change. A hash suffix would
only leave a trail of orphaned dashboards.

`allowUiUpdates: false` means edits made in the Grafana UI are discarded on restart. Deliberately
unfriendly: it forces dashboard changes through Git, which is the only way they survive and get
reviewed.

### Control-plane exporters are disabled

`kubeControllerManager`, `kubeScheduler`, `kubeEtcd` and `kubeProxy` are off. GKE does not expose
those components — the control plane is managed. Left enabled they produce permanently-down scrape
targets, and a dashboard with known-broken panels trains people to ignore red.

### No credentials in these files

`grafana.admin.existingSecret` points at a Secret created out of band. There is no `adminPassword:`
here, and no Alertmanager webhook URL — a Slack or PagerDuty URL is a credential. In production both
come from External Secrets Operator backed by Secret Manager.

```bash
kubectl -n observability create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
```

## Alerts

`alerts/app-alerts.yaml`, four groups. Two conventions throughout:

- **Every rule has a `for:`.** Without it an alert fires on a single scrape, so transient blips page
  people and the alerts get muted.
- **Every annotation says what to do**, not just what happened. "High error rate" at 3am is not
  actionable; "5xx above 5% — open the RED dashboard, use the exemplars to reach a failing trace" is.

| Alert | Catches |
|---|---|
| `AppPodCrashLooping` | >3 restarts in 15m — not >0, which fires on a normal eviction |
| `AppNoReadyReplicas` | full outage |
| `AppBelowHABaseline` | 1 replica: the next disruption becomes an outage |
| `AppHighErrorRate` | 5xx >5%, probe routes excluded |
| `AppHighLatency` | p95 >1s |
| `AppNoTraffic` | routing/DNS failure — invisible to error-rate alerts, because there are no errors |
| `AppHPAAtMaxReplicas` | no scaling headroom left |
| `AppHPAUnableToScale` | HPA cannot read metrics; holds at min and stops responding to load |
| `AppPDBBlockingDisruptions` | node drains will hang — breaks maintenance, not the app |
| `PrometheusTargetDown` | a target down means every alert scoped to it is silently not evaluating |
| `LokiIngestionStalled` | logs are being lost right now, and the gap is permanent |

The `release: kube-prometheus-stack` label on the PrometheusRule is load-bearing: Prometheus's
`ruleSelector` matches on it, and without it the rule is silently ignored.

## Next, with more time

**Mimir** in place of Prometheus once a single Prometheus stops fitting — horizontally scalable,
object-storage backed, and the query API is unchanged.

**Tail-based sampling** in Alloy. Sampling is 100% at the SDK today, which is right at assignment
volume and a cost problem at real traffic. Tail-based sampling keeps every erroring and slow trace
and samples the rest.

**GCS backends** for Loki and Tempo instead of filesystem — cheaper, survives the pod, and decouples
retention from disk size. One values change plus a Workload Identity annotation.

**SLOs and burn-rate alerts** rather than static thresholds. `AppHighErrorRate > 5%` is a reasonable
starting point and not a stated reliability objective; multi-window burn-rate alerting on an error
budget pages proportionally to how fast the budget is being spent.
