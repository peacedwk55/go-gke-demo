# Application — Task 0

A small Go HTTP service. The starting point was a bare `hello` handler; everything here exists
because something downstream needs it, and the [§1.1 contract](../CLAUDE.md) records which task
consumes what.

```
main.go        startup, signal handling, the drain sequence
config.go      env -> Config, with validation that fails loudly
server.go      routes, middleware, handlers
telemetry.go   Prometheus registry + OpenTelemetry wiring
server_test.go 9 tests
```

## Why this was not optional

The provided sample was:

```go
http.HandleFunc("/", getHello)
http.ListenAndServe(":8080", nil)
```

Four things follow from that, and each breaks a task downstream:

**`/` is a catch-all, so the probes would have passed while testing nothing.** `/healthz` and
`/readyz` would both have matched the root handler and returned `200 Hello`. That is worse than a
failing probe: everything looks green, liveness and readiness are indistinguishable, and a pod that
has not finished starting receives traffic immediately. Fixed by registering `GET /{$}` — the `{$}`
anchor restricts the route to exactly `/`, so unknown paths 404 and the probes reach real handlers.
`TestProbePathsAreNotShadowed` locks that in.

**No SIGTERM handling, so `maxUnavailable: 0` was a promise the app could not keep.** Go's default
behaviour on SIGTERM is to die immediately, cutting in-flight requests. See below.

**No `/metrics` and no tracing**, so the entire observability task would have had nothing to scrape,
log, or correlate.

**Reflected XSS.** `io.WriteString(w, "Hello "+name)` with no `Content-Type` leaves Go to sniff one
from the body; a body starting with `<` is served as `text/html`, so `?name=<script>alert(1)</script>`
executes. Security is one of the three pillars of this assignment, so this was not a stylistic point.

## The drain sequence

This is the part worth reading. `maxUnavailable: 0` guarantees new pods are ready before old ones go
away — it says nothing about requests still in flight to a pod that is shutting down. That half lives
here, in `drain()`:

```
SIGTERM
  → 1. readiness flag = false     /readyz returns 503 immediately
  → 2. wait ~5s                   kube-proxy / EndpointSlice remove this pod
  → 3. srv.Shutdown(ctx)          drain in-flight requests
  → 4. flush OTLP exporter, exit 0
```

Step 2 is the one people skip. Readiness propagation is asynchronous: without the pause the pod stops
accepting connections while traffic is still being routed to it. Measured through a rolling update
under continuous load on a 2-node cluster:

| `SHUTDOWN_DELAY` | Requests | Failed |
|---|---|---|
| 1s | 10,486 | **15** (0.14%, connection reset) |
| 5s | 8,017 | **0** |

The wait **must** live in Go, not in a `preStop` hook: the runtime image is distroless, so there is
no shell for `lifecycle.preStop.exec: ["sleep","5"]` to run. Keeping it in the app also makes it
testable — `TestDrainOrdering` starts a real listener, samples `/readyz` midway through the delay
window, and asserts it already returns 503 while the listener is still accepting.

## Decisions worth defending

### Liveness must not depend on anything

`/healthz` reports only that the process is running. A liveness probe that consults a database turns
a dependency outage into a restart storm: every pod fails its probe, gets killed, and the restarts
add load to the thing that was already struggling.

`/readyz` is where dependency state would belong, because failing readiness removes the pod from
rotation without killing it.

### A 503 from `/readyz` during drain is logged at INFO

That 503 is the system working as designed. Logging it at ERROR would light up the alerting stack on
every single rollout and train everyone to ignore the channel. The same reasoning excludes probe
routes from the RED queries and the error-rate alert — see `observability/README.md`.

### `trace_id` on every log line

One field, present in metrics (as a histogram exemplar), logs (as a JSON field) and traces (as the
trace itself). That single join key is what makes metric → trace → log navigation work in Grafana.

Because Grafana's Loki derived field matches it with a regex against this exact log format, changing
the format breaks correlation **silently** — no error, just a "View trace" button that stops
appearing. That is why it is in the contract rather than left to implementation taste.

### Config errors fail the pod, loudly

`LoadConfig` returns an error on an unparseable value rather than falling back to a default. A typo
in a ConfigMap should produce `CrashLoopBackOff` with a clear message, not a pod running quietly on
values nobody chose. `TestLoadConfigRejectsBadValues` covers it.

### Server timeouts are set explicitly

Go's zero value for `ReadTimeout`, `WriteTimeout` and `IdleTimeout` is *no timeout*, so a slow client
can hold a connection open indefinitely (Slowloris). `ReadHeaderTimeout` in particular has no default
and is the one that matters most.

### Route labels are hardcoded, not derived from the path

`instrument(route, handler)` takes the route as a literal. Deriving it from `r.URL.Path` would let an
unbounded path space create unbounded Prometheus series — the classic cardinality explosion.

### `/metrics` is not instrumented

Scraping is not application traffic. Counting it would pollute the RED panels with a perfectly
regular 30-second heartbeat.

### A private Prometheus registry

Rather than `prometheus.DefaultRegisterer`. Tests can build an isolated instance, and the exposed
series are exactly the intended ones plus explicitly re-added Go/process collectors — not whatever a
transitive dependency happened to register into the global default.

### Tracing is disabled when `OTEL_EXPORTER_OTLP_ENDPOINT` is empty

An empty endpoint is meaningful, not missing. The same image then runs under `docker run` or on a
kind cluster with no LGTM stack, with no separate build and no second code path.

## Run and test

```bash
go test -race ./...
go vet ./...
gofmt -l .

# locally
go run .
curl -i localhost:8080/healthz
curl    "localhost:8080/?name=world"
curl -s  localhost:8080/metrics | grep http_requests_total

# the drain sequence, by hand
go run . &
kill -TERM %1     # /readyz turns 503 at once; the listener closes ~5s later
```

Everything runs in a container if Go is not installed locally:

```bash
docker run --rm -v "$PWD:/src" -w /src golang:1.26-bookworm go test -race ./...
```

## Results

| Check | Result |
|---|---|
| `go test -race ./...` | 9/9 pass |
| `go vet` / `gofmt -l` | clean |
| Static binary | 16.7 MB; `CGO_ENABLED=0` asserted at image build time |
| Dependencies | `prometheus/client_golang`, OpenTelemetry SDK + OTLP/HTTP + `otelhttp` |

Go 1.26. The original `go.mod` said 1.21.4, which is out of support — and
`prometheus/client_golang` now requires ≥1.25 regardless.
