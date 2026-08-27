package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testServer(t *testing.T) *Server {
	t.Helper()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	log := slog.New(slog.NewJSONHandler(io.Discard, nil))
	return NewServer(cfg, log, NewMetrics(cfg.ServiceName, cfg.ServiceVersion))
}

func do(t *testing.T, s *Server, method, target string) *http.Response {
	t.Helper()
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest(method, target, nil))
	return rec.Result()
}

func body(t *testing.T, resp *http.Response) string {
	t.Helper()
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(b)
}

func TestHello(t *testing.T) {
	s := testServer(t)
	resp := do(t, s, http.MethodGet, "/?name=world")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if got, want := body(t, resp), "Hello world\n"; got != want {
		t.Errorf("body = %q, want %q", got, want)
	}
}

// TestHelloIsNotHTML is the regression test for the reflected-XSS hole in the
// original sample: it wrote the query parameter with no Content-Type, so Go's
// MIME sniffing served a body starting with "<" as text/html.
func TestHelloIsNotHTML(t *testing.T) {
	s := testServer(t)
	resp := do(t, s, http.MethodGet, "/?name=%3Cscript%3Ealert(1)%3C/script%3E")

	if got, want := resp.Header.Get("Content-Type"), "text/plain; charset=utf-8"; got != want {
		t.Errorf("Content-Type = %q, want %q", got, want)
	}
	if got, want := resp.Header.Get("X-Content-Type-Options"), "nosniff"; got != want {
		t.Errorf("X-Content-Type-Options = %q, want %q", got, want)
	}
}

func TestHelloRejectsOverlongName(t *testing.T) {
	s := testServer(t)
	resp := do(t, s, http.MethodGet, "/?name="+strings.Repeat("a", s.cfg.MaxNameLen+1))
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", resp.StatusCode)
	}
	// The boundary itself must still be accepted.
	resp = do(t, s, http.MethodGet, "/?name="+strings.Repeat("a", s.cfg.MaxNameLen))
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status at max length = %d, want 200", resp.StatusCode)
	}
}

// TestProbePathsAreNotShadowed guards the bug that the "/" catch-all in the
// original sample would have caused: /healthz and /readyz answering "200 Hello",
// making every probe pass without testing anything.
func TestProbePathsAreNotShadowed(t *testing.T) {
	s := testServer(t)
	for _, path := range []string{"/healthz", "/readyz"} {
		if got := body(t, do(t, s, http.MethodGet, path)); strings.Contains(got, "Hello") {
			t.Errorf("%s answered by the hello handler: %q", path, got)
		}
	}
	if resp := do(t, s, http.MethodGet, "/nope"); resp.StatusCode != http.StatusNotFound {
		t.Errorf("unknown path status = %d, want 404", resp.StatusCode)
	}
}

func TestHealthzIgnoresReadiness(t *testing.T) {
	s := testServer(t)
	s.SetReady(false) // liveness must not follow readiness, or drain becomes a restart
	if resp := do(t, s, http.MethodGet, "/healthz"); resp.StatusCode != http.StatusOK {
		t.Errorf("healthz status while not ready = %d, want 200", resp.StatusCode)
	}
}

func TestReadyzReportsShutdown(t *testing.T) {
	s := testServer(t)
	if resp := do(t, s, http.MethodGet, "/readyz"); resp.StatusCode != http.StatusOK {
		t.Fatalf("readyz status = %d, want 200", resp.StatusCode)
	}
	s.SetReady(false)
	if resp := do(t, s, http.MethodGet, "/readyz"); resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("readyz status after shutdown signalled = %d, want 503", resp.StatusCode)
	}
}

func TestMetricsExposesREDSeries(t *testing.T) {
	s := testServer(t)
	do(t, s, http.MethodGet, "/?name=metrics")

	out := body(t, do(t, s, http.MethodGet, "/metrics"))
	for _, want := range []string{
		`http_requests_total{code="200",method="GET",route="/"}`,
		"http_request_duration_seconds_bucket",
		"http_requests_in_flight",
		"app_build_info",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("/metrics missing %q", want)
		}
	}
}

// TestDrainOrdering asserts the sequence that makes maxUnavailable: 0 real:
// readiness must fail before the listener stops, and the pause between them
// must actually be observed.
func TestDrainOrdering(t *testing.T) {
	s := testServer(t)
	s.cfg.ShutdownDelay = 100 * time.Millisecond
	s.cfg.ShutdownTimeout = 2 * time.Second

	httpSrv := &http.Server{Handler: s.Handler()}
	ln, err := net_Listen(t)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	go func() { _ = httpSrv.Serve(ln) }()

	readyDuringDelay := make(chan int, 1)
	go func() {
		// Sample readiness midway through the delay window: the pod must
		// already be reporting 503 while it is still accepting connections.
		time.Sleep(50 * time.Millisecond)
		resp, err := http.Get("http://" + ln.Addr().String() + "/readyz")
		if err != nil {
			readyDuringDelay <- 0
			return
		}
		defer resp.Body.Close()
		readyDuringDelay <- resp.StatusCode
	}()

	start := time.Now()
	log := slog.New(slog.NewJSONHandler(io.Discard, nil))
	if err := drain(context.Background(), s.cfg, log, s, httpSrv, func(context.Context) error { return nil }); err != nil {
		t.Fatalf("drain: %v", err)
	}

	if got := <-readyDuringDelay; got != http.StatusServiceUnavailable {
		t.Errorf("readyz during drain delay = %d, want 503 (readiness must fail before the listener closes)", got)
	}
	if elapsed := time.Since(start); elapsed < s.cfg.ShutdownDelay {
		t.Errorf("drain returned after %v, want at least the %v propagation delay", elapsed, s.cfg.ShutdownDelay)
	}
}

func TestLoadConfigRejectsBadValues(t *testing.T) {
	t.Setenv("SHUTDOWN_DELAY", "five-seconds")
	if _, err := LoadConfig(); err == nil {
		t.Error("LoadConfig accepted an unparseable duration; a ConfigMap typo must fail the rollout loudly")
	}
}
