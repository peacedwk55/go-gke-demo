package main

import (
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"
)

// Config is the complete runtime configuration of the service.
//
// Every field comes from an environment variable (12-factor, per CLAUDE.md §1.1).
// In-cluster these are fed by the ConfigMap that Kustomize's configMapGenerator
// builds from overlays/<env>/config.env, which is why nothing here reads a file:
// the image must stay identical across dev and prod.
type Config struct {
	Port            string
	Greeting        string
	MaxNameLen      int
	LogLevel        slog.Level
	ServiceName     string
	ServiceVersion  string
	OTLPEndpoint    string
	ReadHeaderTO    time.Duration
	ReadTO          time.Duration
	WriteTO         time.Duration
	IdleTO          time.Duration
	ShutdownDelay   time.Duration
	ShutdownTimeout time.Duration
}

// LoadConfig reads configuration from the environment, applying defaults that are
// safe for production. It returns an error rather than falling back silently when a
// value is present but unparseable — a typo in a ConfigMap should fail the rollout
// loudly (CrashLoopBackOff + a clear log line) instead of quietly running on defaults.
func LoadConfig() (Config, error) {
	c := Config{
		Port:           envStr("PORT", "8080"),
		Greeting:       envStr("GREETING", "Hello"),
		ServiceName:    envStr("SERVICE_NAME", "go-sample-app"),
		ServiceVersion: envStr("SERVICE_VERSION", version),
		// Empty endpoint is meaningful, not missing: tracing is then disabled
		// entirely so the app runs standalone (docker run, kind without Tempo).
		OTLPEndpoint: envStr("OTEL_EXPORTER_OTLP_ENDPOINT", ""),
	}

	var err error
	if c.MaxNameLen, err = envInt("MAX_NAME_LEN", 64); err != nil {
		return c, err
	}
	if c.LogLevel, err = envLevel("LOG_LEVEL", slog.LevelInfo); err != nil {
		return c, err
	}
	// Slowloris and slow-body protection. WriteTO must comfortably exceed the
	// slowest legitimate response; these are generous for a JSON/text API.
	if c.ReadHeaderTO, err = envDur("READ_HEADER_TIMEOUT", 5*time.Second); err != nil {
		return c, err
	}
	if c.ReadTO, err = envDur("READ_TIMEOUT", 10*time.Second); err != nil {
		return c, err
	}
	if c.WriteTO, err = envDur("WRITE_TIMEOUT", 15*time.Second); err != nil {
		return c, err
	}
	if c.IdleTO, err = envDur("IDLE_TIMEOUT", 60*time.Second); err != nil {
		return c, err
	}
	// Step 2 of the shutdown sequence in CLAUDE.md §1.1: the pause between
	// "/readyz starts failing" and "stop accepting work", so that kube-proxy and
	// the EndpointSlice controller have actually removed this pod from rotation.
	if c.ShutdownDelay, err = envDur("SHUTDOWN_DELAY", 5*time.Second); err != nil {
		return c, err
	}
	// Must leave headroom inside terminationGracePeriodSeconds (30s):
	// 5s delay + 20s drain + OTLP flush still fits.
	if c.ShutdownTimeout, err = envDur("SHUTDOWN_TIMEOUT", 20*time.Second); err != nil {
		return c, err
	}
	return c, nil
}

func envStr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) (int, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("env %s: %q is not an integer: %w", key, v, err)
	}
	if n <= 0 {
		return 0, fmt.Errorf("env %s: must be > 0, got %d", key, n)
	}
	return n, nil
}

func envDur(key string, def time.Duration) (time.Duration, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("env %s: %q is not a duration (e.g. 5s, 250ms): %w", key, v, err)
	}
	return d, nil
}

func envLevel(key string, def slog.Level) (slog.Level, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	var l slog.Level
	if err := l.UnmarshalText([]byte(v)); err != nil {
		return 0, fmt.Errorf("env %s: %q is not a log level (debug|info|warn|error): %w", key, v, err)
	}
	return l, nil
}
