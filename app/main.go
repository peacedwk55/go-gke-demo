package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// version is stamped at build time:
//
//	-ldflags="-X main.version=v1.0.0"
//
// It surfaces in the app_build_info metric and on every log line, so a dashboard
// or a log query can always answer "which build produced this?".
var version = "dev"

func main() {
	if err := run(); err != nil {
		// stderr, not stdout: the JSON access log owns stdout, and a fatal
		// startup error should not have to be valid JSON to be readable.
		os.Stderr.WriteString("fatal: " + err.Error() + "\n")
		os.Exit(1)
	}
}

func run() error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}

	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})).
		With(slog.String("service", cfg.ServiceName), slog.String("version", cfg.ServiceVersion))
	slog.SetDefault(log)

	// signal.NotifyContext must be installed before anything long-running, so a
	// SIGTERM arriving during startup is still handled gracefully instead of
	// killing the process outright.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdownTracing, err := InitTracing(ctx, cfg.OTLPEndpoint, cfg.ServiceName, cfg.ServiceVersion)
	if err != nil {
		return err
	}

	metrics := NewMetrics(cfg.ServiceName, cfg.ServiceVersion)
	srv := NewServer(cfg, log, metrics)

	httpSrv := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: srv.Handler(),
		// Without these an idle or deliberately slow client can hold a
		// connection open indefinitely (Slowloris). Go's zero value for each
		// of them is "no timeout", so they must be set explicitly.
		ReadHeaderTimeout: cfg.ReadHeaderTO,
		ReadTimeout:       cfg.ReadTO,
		WriteTimeout:      cfg.WriteTO,
		IdleTimeout:       cfg.IdleTO,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}

	serveErr := make(chan error, 1)
	go func() {
		log.Info("server starting",
			slog.String("addr", httpSrv.Addr),
			slog.Bool("tracing_enabled", cfg.OTLPEndpoint != ""),
		)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
			return
		}
		serveErr <- nil
	}()

	select {
	case err := <-serveErr:
		// The listener died on its own (port in use, fatal accept error).
		if err != nil {
			return err
		}
		return nil
	case <-ctx.Done():
		// Restore default signal behaviour so a second Ctrl-C / SIGTERM during
		// a slow drain can still kill the process immediately.
		stop()
	}

	return drain(context.Background(), cfg, log, srv, httpSrv, shutdownTracing)
}

// drain implements the shutdown sequence specified in CLAUDE.md §1.1.
//
// The ordering is the entire point. Reversing steps 1 and 3, or dropping the
// pause in step 2, produces dropped requests on every rollout while still
// looking correct in a casual test — which is exactly why it is written out
// here and asserted in the test suite.
func drain(
	ctx context.Context,
	cfg Config,
	log *slog.Logger,
	srv *Server,
	httpSrv *http.Server,
	shutdownTracing func(context.Context) error,
) error {
	log.Info("shutdown signal received, draining",
		slog.Duration("delay", cfg.ShutdownDelay),
		slog.Duration("timeout", cfg.ShutdownTimeout),
	)

	// 1. Fail readiness first. The pod is still serving, but the control plane
	//    can now begin removing it from the Service endpoints.
	srv.SetReady(false)

	// 2. Wait for that removal to propagate. Endpoint updates reach every node's
	//    kube-proxy asynchronously; without this pause the pod stops accepting
	//    connections while traffic is still being routed to it.
	select {
	case <-time.After(cfg.ShutdownDelay):
	case <-ctx.Done():
	}

	// 3. Stop accepting new connections and let in-flight requests finish.
	shutdownCtx, cancel := context.WithTimeout(ctx, cfg.ShutdownTimeout)
	defer cancel()

	var firstErr error
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown timed out; forcing close", slog.String("error", err.Error()))
		_ = httpSrv.Close()
		firstErr = err
	}

	// 4. Flush buffered spans. The batch processor holds the traces for the last
	//    few requests; skipping this loses exactly the spans a rollout
	//    investigation would need.
	flushCtx, cancelFlush := context.WithTimeout(ctx, 5*time.Second)
	defer cancelFlush()
	if err := shutdownTracing(flushCtx); err != nil {
		log.Error("tracer flush failed", slog.String("error", err.Error()))
		if firstErr == nil {
			firstErr = err
		}
	}

	log.Info("shutdown complete")
	return firstErr
}
