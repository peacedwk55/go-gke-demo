package main

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// Metrics holds the RED (Rate, Errors, Duration) instruments backing the app
// dashboard in Task 6. They live on a private registry rather than the global
// default one so that tests can build an isolated instance, and so the exposed
// series are exactly what we intend (plus explicitly re-added Go/process
// collectors) instead of whatever a transitive dependency happened to register.
type Metrics struct {
	Registry  *prometheus.Registry
	Requests  *prometheus.CounterVec
	Duration  *prometheus.HistogramVec
	InFlight  prometheus.Gauge
	BuildInfo *prometheus.GaugeVec
}

func NewMetrics(serviceName, serviceVersion string) *Metrics {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	m := &Metrics{
		Registry: reg,
		Requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests, by route, method and response code.",
		}, []string{"route", "method", "code"}),
		Duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "http_request_duration_seconds",
			Help: "HTTP request latency in seconds, by route and method.",
			// Tuned for a sub-second API. The bucket set is deliberately small:
			// every bucket is a separate time series per route+method.
			Buckets: []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		}, []string{"route", "method"}),
		InFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Number of HTTP requests currently being served.",
		}),
		BuildInfo: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "app_build_info",
			Help: "Build metadata; value is always 1. Join on this to annotate dashboards with the deployed version.",
		}, []string{"service", "version"}),
	}
	reg.MustRegister(m.Requests, m.Duration, m.InFlight, m.BuildInfo)
	m.BuildInfo.WithLabelValues(serviceName, serviceVersion).Set(1)
	return m
}

// Handler exposes /metrics. OpenMetrics negotiation is enabled because exemplars
// (the metric -> trace jump in Grafana) are only emitted in that format.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.Registry, promhttp.HandlerOpts{
		EnableOpenMetrics: true,
		Registry:          m.Registry,
	})
}

// observe records one completed request. When the request carried a sampled span
// the latency sample is annotated with an exemplar holding the trace_id, which is
// what lets a spike on the RED dashboard be clicked straight through to Tempo.
func (m *Metrics) observe(route, method, code, traceID string, d time.Duration) {
	m.Requests.WithLabelValues(route, method, code).Inc()

	obs := m.Duration.WithLabelValues(route, method)
	if traceID != "" {
		if eo, ok := obs.(prometheus.ExemplarObserver); ok {
			eo.ObserveWithExemplar(d.Seconds(), prometheus.Labels{"trace_id": traceID})
			return
		}
	}
	obs.Observe(d.Seconds())
}

// InitTracing wires the OTLP/HTTP exporter that ships spans to Tempo (directly or
// via the Alloy collector). It returns a shutdown func that MUST be called during
// termination: the batch processor buffers spans, so skipping the flush silently
// drops the traces belonging to the final requests before a rollout.
//
// An empty endpoint disables tracing rather than erroring. That keeps the same
// image runnable outside the cluster (docker run, kind without an LGTM stack)
// without a separate build or code path.
func InitTracing(ctx context.Context, endpoint, serviceName, serviceVersion string) (func(context.Context) error, error) {
	if endpoint == "" {
		return func(context.Context) error { return nil }, nil
	}

	exp, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("otlp exporter: %w", err)
	}

	// NewSchemaless carries no schema URL, so merging it into the default
	// resource cannot fail with a schema-conflict error.
	res, err := resource.Merge(resource.Default(), resource.NewSchemaless(
		attribute.String("service.name", serviceName),
		attribute.String("service.version", serviceVersion),
	))
	if err != nil {
		return nil, fmt.Errorf("otel resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(res),
		// ParentBased(AlwaysSample) honours an upstream sampling decision and
		// samples everything we originate. Fine at assignment scale; a real
		// deployment would swap in TraceIDRatioBased via an env var.
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))
	return tp.Shutdown, nil
}
