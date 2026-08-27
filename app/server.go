package main

import (
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/trace"
)

// Server owns the HTTP surface and the readiness flag.
//
// ready is atomic because it is flipped from the signal-handling goroutine in
// main while request goroutines read it concurrently.
type Server struct {
	cfg     Config
	log     *slog.Logger
	metrics *Metrics
	ready   atomic.Bool
}

func NewServer(cfg Config, log *slog.Logger, m *Metrics) *Server {
	s := &Server{cfg: cfg, log: log, metrics: m}
	s.ready.Store(true)
	return s
}

// SetReady flips readiness. Called with false as the very first step of the
// shutdown sequence (CLAUDE.md §1.1) so that /readyz fails before the server
// stops accepting connections.
func (s *Server) SetReady(v bool) { s.ready.Store(v) }

// Handler builds the mux.
//
// Note the "/{$}" pattern on the root route. The original sample registered a
// bare "/", which is a catch-all: it would have answered /healthz and /readyz
// with "200 Hello", making all three probes pass while testing nothing. The
// "{$}" anchor restricts the route to exactly "/", so unknown paths 404 and the
// probes exercise real handlers.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /{$}", s.instrument("/", s.handleHello))
	mux.Handle("GET /healthz", s.instrument("/healthz", s.handleHealthz))
	mux.Handle("GET /readyz", s.instrument("/readyz", s.handleReadyz))
	// /metrics is intentionally NOT instrumented: scraping itself is not
	// application traffic, and self-observation would pollute the RED panels.
	mux.Handle("GET /metrics", s.metrics.Handler())
	return mux
}

// instrument wraps one route with tracing, metrics and access logging.
//
// The route label is supplied explicitly rather than derived from r.URL.Path so
// that an unbounded path space can never explode Prometheus cardinality.
func (s *Server) instrument(route string, h http.HandlerFunc) http.Handler {
	var inner http.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		s.metrics.InFlight.Inc()
		defer s.metrics.InFlight.Dec()

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		h(rec, r)

		elapsed := time.Since(start)
		code := strconv.Itoa(rec.status)

		// The trace id is the join key for the whole observability story:
		// it is an exemplar on the latency histogram AND a field on the log
		// line, which is what Loki's derived field matches to offer
		// "view trace" (see observability/loki.values.yaml).
		var traceID string
		if sc := trace.SpanContextFromContext(r.Context()); sc.IsValid() {
			traceID = sc.TraceID().String()
		}

		s.metrics.observe(route, r.Method, code, traceID, elapsed)

		// A 503 from /readyz during drain is the system working as designed, not
		// an incident. Logging it at ERROR would light up the alerting stack on
		// every single rollout and train everyone to ignore it.
		//
		// The same caveat applies to the metrics: probe traffic is counted (it
		// is useful when debugging a probe that is failing), but at one
		// readiness check every 5s and one liveness check every 10s per pod it
		// would swamp the RED rate panel and skew the error ratio. Both the app
		// dashboard and the high-error-rate PrometheusRule therefore filter on
		// route!~"/healthz|/readyz" — see observability/.
		level := slog.LevelInfo
		switch {
		case route == "/readyz" && rec.status == http.StatusServiceUnavailable:
			level = slog.LevelInfo
		case rec.status >= 500:
			level = slog.LevelError
		case rec.status >= 400:
			level = slog.LevelWarn
		}
		s.log.LogAttrs(r.Context(), level, "http_request",
			slog.String("route", route),
			slog.String("method", r.Method),
			slog.Int("status", rec.status),
			slog.Duration("duration", elapsed),
			slog.String("trace_id", traceID),
			slog.String("user_agent", r.UserAgent()),
		)
	})
	// otelhttp is outermost so a span exists by the time the middleware above
	// reads the trace id, and so W3C traceparent headers are extracted.
	return otelhttp.NewHandler(inner, route)
}

// statusRecorder captures the status code for metrics and logs.
type statusRecorder struct {
	http.ResponseWriter
	status  int
	written bool
}

func (r *statusRecorder) WriteHeader(code int) {
	if r.written {
		return
	}
	r.status = code
	r.written = true
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if !r.written {
		r.written = true
	}
	return r.ResponseWriter.Write(b)
}

// writePlain centralises the two headers that make reflecting user input safe.
//
// The sample app wrote the query parameter straight to the body with no
// Content-Type. Go then falls back to DetectContentType, which sniffs a body
// beginning with "<" as text/html — turning ?name=<script>… into a working
// reflected XSS. An explicit text/plain plus nosniff closes that off, and the
// test suite asserts both headers so the fix cannot silently regress.
func writePlain(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	io.WriteString(w, body)
}

func (s *Server) handleHello(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if len(name) > s.cfg.MaxNameLen {
		writePlain(w, http.StatusBadRequest,
			"name must be at most "+strconv.Itoa(s.cfg.MaxNameLen)+" characters\n")
		return
	}
	writePlain(w, http.StatusOK, s.cfg.Greeting+" "+name+"\n")
}

// handleHealthz answers the startup and liveness probes. It reports only whether
// the process is running and must never consult a dependency: a liveness probe
// that fails on a downstream outage converts that outage into a restart storm.
func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writePlain(w, http.StatusOK, "ok\n")
}

// handleReadyz answers the readiness probe and is the mechanism that makes
// maxUnavailable: 0 real. It returns 503 from the instant SIGTERM is received,
// so the pod leaves the Service endpoints before it stops serving.
func (s *Server) handleReadyz(w http.ResponseWriter, _ *http.Request) {
	if !s.ready.Load() {
		writePlain(w, http.StatusServiceUnavailable, "shutting down\n")
		return
	}
	writePlain(w, http.StatusOK, "ready\n")
}
