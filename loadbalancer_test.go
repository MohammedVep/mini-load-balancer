package main

import (
	"context"
	"encoding/json"
	"io"
	"math"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestParseStrategyAcceptsWeighted(t *testing.T) {
	strategy, err := ParseStrategy("weighted")
	if err != nil {
		t.Fatalf("expected weighted strategy to parse: %v", err)
	}
	if strategy != StrategyWeighted {
		t.Fatalf("expected %q, got %q", StrategyWeighted, strategy)
	}
}

func TestParseStrategyErrorMentionsWeighted(t *testing.T) {
	_, err := ParseStrategy("invalid")
	if err == nil {
		t.Fatal("expected parse strategy to fail")
	}
	if !strings.Contains(err.Error(), "weighted") {
		t.Fatalf("expected error to mention weighted, got %q", err.Error())
	}
}

func TestNewLoadBalancerWithConfigRejectsInvalidWeights(t *testing.T) {
	cfg := DefaultLoadBalancerConfig()
	cfg.BackendWeights = []int{1}
	if _, err := NewLoadBalancerWithConfig(
		[]string{"http://a.internal", "http://b.internal"},
		StrategyWeighted,
		cfg,
		nil,
	); err == nil {
		t.Fatal("expected backend weights count mismatch error")
	}

	cfg.BackendWeights = []int{1, 0}
	if _, err := NewLoadBalancerWithConfig(
		[]string{"http://a.internal", "http://b.internal"},
		StrategyWeighted,
		cfg,
		nil,
	); err == nil {
		t.Fatal("expected non-positive backend weight error")
	}
}

func TestRoundRobinSelection(t *testing.T) {
	lb, err := NewLoadBalancer(
		[]string{"http://a.internal", "http://b.internal", "http://c.internal"},
		StrategyRoundRobin,
		100,
	)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	req.RemoteAddr = "10.0.0.1:12345"

	var got []string
	for i := 0; i < 4; i++ {
		backend := lb.selectBackend(req, nil)
		if backend == nil {
			t.Fatal("expected backend, got nil")
		}
		got = append(got, backend.URL.Host)
	}

	want := []string{"a.internal", "b.internal", "c.internal", "a.internal"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected sequence: got %v, want %v", got, want)
	}
}

func TestWeightedSelectionDistribution(t *testing.T) {
	cfg := DefaultLoadBalancerConfig()
	cfg.BackendWeights = []int{1, 3, 6}

	lb, err := NewLoadBalancerWithConfig(
		[]string{"http://a.internal", "http://b.internal", "http://c.internal"},
		StrategyWeighted,
		cfg,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	lb.rand = rand.New(rand.NewSource(12345))

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	counts := map[string]int{}
	const total = 20000
	for i := 0; i < total; i++ {
		backend := lb.selectBackend(req, nil)
		if backend == nil {
			t.Fatal("expected backend, got nil")
		}
		counts[backend.URL.Host]++
	}

	expected := map[string]float64{
		"a.internal": 0.10,
		"b.internal": 0.30,
		"c.internal": 0.60,
	}
	for host, ratio := range expected {
		got := float64(counts[host]) / total
		if math.Abs(got-ratio) > 0.03 {
			t.Fatalf("unexpected ratio for %s: got %.4f want %.4f +/- 0.03", host, got, ratio)
		}
	}
}

func TestWeightedSelectionSkipsExcludedAndUnhealthy(t *testing.T) {
	cfg := DefaultLoadBalancerConfig()
	cfg.BackendWeights = []int{8, 1}

	lb, err := NewLoadBalancerWithConfig(
		[]string{"http://a.internal", "http://b.internal"},
		StrategyWeighted,
		cfg,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	lb.rand = rand.New(rand.NewSource(1))

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	selected := lb.selectBackend(req, map[*Backend]struct{}{lb.backends[0]: struct{}{}})
	if selected == nil || selected.URL.Host != "b.internal" {
		t.Fatalf("expected excluded backend to be skipped, got %v", selected)
	}

	lb.backends[1].SetAlive(false)
	selected = lb.selectBackend(req, nil)
	if selected == nil || selected.URL.Host != "a.internal" {
		t.Fatalf("expected unhealthy backend to be skipped, got %v", selected)
	}
}

func TestWeightedSelectionReturnsNilWhenNoEligibleWeightedBackends(t *testing.T) {
	cfg := DefaultLoadBalancerConfig()
	cfg.BackendWeights = []int{1, 2}

	lb, err := NewLoadBalancerWithConfig(
		[]string{"http://a.internal", "http://b.internal"},
		StrategyWeighted,
		cfg,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	lb.backends[0].SetAlive(false)
	lb.backends[1].SetAlive(false)

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	if selected := lb.selectBackend(req, nil); selected != nil {
		t.Fatalf("expected nil backend when none are eligible, got %v", selected.URL.Host)
	}
}

func TestLeastConnectionsSelection(t *testing.T) {
	lb, err := NewLoadBalancer(
		[]string{"http://a.internal", "http://b.internal", "http://c.internal"},
		StrategyLeastConnection,
		100,
	)
	if err != nil {
		t.Fatal(err)
	}

	lb.backends[0].activeConnections.Store(5)
	lb.backends[1].activeConnections.Store(1)
	lb.backends[2].activeConnections.Store(3)

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	backend := lb.selectBackend(req, nil)
	if backend == nil {
		t.Fatal("expected backend, got nil")
	}
	if backend.URL.Host != "b.internal" {
		t.Fatalf("expected least-loaded backend b.internal, got %s", backend.URL.Host)
	}
}

func TestConsistentHashStability(t *testing.T) {
	lb, err := NewLoadBalancer(
		[]string{"http://a.internal", "http://b.internal", "http://c.internal"},
		StrategyConsistentHash,
		100,
	)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	req.Header.Set("X-Client-Key", "user-42")

	first := lb.selectBackend(req, nil)
	if first == nil {
		t.Fatal("expected backend, got nil")
	}

	for i := 0; i < 20; i++ {
		next := lb.selectBackend(req, nil)
		if next == nil || next.URL.Host != first.URL.Host {
			t.Fatalf("expected stable backend %s, got %v", first.URL.Host, next)
		}
	}
}

func TestHealthCheckHysteresis(t *testing.T) {
	var healthy atomic.Bool
	healthy.Store(true)

	backendServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if healthy.Load() {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer backendServer.Close()

	cfg := DefaultLoadBalancerConfig()
	cfg.HealthFailThreshold = 2
	cfg.HealthSuccessThreshold = 2

	lb, err := NewLoadBalancerWithConfig([]string{backendServer.URL}, StrategyRoundRobin, cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	backend := lb.backends[0]

	healthy.Store(false)
	lb.runHealthCheckOnce(200*time.Millisecond, "/health")
	if !backend.IsAlive() {
		t.Fatal("backend should remain alive after first failed probe")
	}
	lb.runHealthCheckOnce(200*time.Millisecond, "/health")
	if backend.IsAlive() {
		t.Fatal("backend should be marked dead after second failed probe")
	}

	healthy.Store(true)
	lb.runHealthCheckOnce(200*time.Millisecond, "/health")
	if backend.IsAlive() {
		t.Fatal("backend should remain dead after first successful probe")
	}
	lb.runHealthCheckOnce(200*time.Millisecond, "/health")
	if !backend.IsAlive() {
		t.Fatal("backend should be marked alive after second successful probe")
	}
}

func TestIdempotentRetryFailover(t *testing.T) {
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	deadURL := dead.URL
	dead.Close()

	live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("live"))
	}))
	defer live.Close()

	cfg := DefaultLoadBalancerConfig()
	cfg.MaxRetries = 1
	cfg.RetryBackoff = 0
	cfg.CircuitFailureThreshold = 1
	cfg.CircuitOpenDuration = time.Minute

	lb, err := NewLoadBalancerWithConfig([]string{deadURL, live.URL}, StrategyRoundRobin, cfg, nil)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	req.RemoteAddr = "10.0.0.5:1001"
	rec := httptest.NewRecorder()
	lb.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected GET retry failover to succeed, got %d", rec.Code)
	}
	body, _ := io.ReadAll(rec.Body)
	if string(body) != "live" {
		t.Fatalf("expected body live, got %q", string(body))
	}
}

func TestNonIdempotentRequestDoesNotRetry(t *testing.T) {
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	deadURL := dead.URL
	dead.Close()

	live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("live"))
	}))
	defer live.Close()

	cfg := DefaultLoadBalancerConfig()
	cfg.MaxRetries = 3
	cfg.RetryBackoff = 0

	lb, err := NewLoadBalancerWithConfig([]string{deadURL, live.URL}, StrategyRoundRobin, cfg, nil)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "http://lb.internal/", strings.NewReader("payload"))
	req.RemoteAddr = "10.0.0.5:1001"
	rec := httptest.NewRecorder()
	lb.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("expected POST without retry to fail with 502, got %d", rec.Code)
	}
}

func TestCircuitOpensAndSkipsBackend(t *testing.T) {
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	deadURL := dead.URL
	dead.Close()

	cfg := DefaultLoadBalancerConfig()
	cfg.MaxRetries = 0
	cfg.CircuitFailureThreshold = 1
	cfg.CircuitOpenDuration = time.Minute
	cfg.RetryBackoff = 0

	lb, err := NewLoadBalancerWithConfig([]string{deadURL}, StrategyRoundRobin, cfg, nil)
	if err != nil {
		t.Fatal(err)
	}

	req1 := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	rec1 := httptest.NewRecorder()
	lb.ServeHTTP(rec1, req1)
	if rec1.Code != http.StatusBadGateway {
		t.Fatalf("expected first request to fail with 502, got %d", rec1.Code)
	}

	req2 := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	rec2 := httptest.NewRecorder()
	lb.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected second request to skip open circuit and return 503, got %d", rec2.Code)
	}
}

func TestDrainRejectsNewRequests(t *testing.T) {
	live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer live.Close()

	lb, err := NewLoadBalancer([]string{live.URL}, StrategyRoundRobin, 100)
	if err != nil {
		t.Fatal(err)
	}

	lb.StartDrain()
	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/", nil)
	rec := httptest.NewRecorder()
	lb.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected draining mode to reject new requests with 503, got %d", rec.Code)
	}
}

func TestMetricsExposePrometheusFormat(t *testing.T) {
	m := NewLBMetrics()
	m.IncInFlight()
	m.RecordRequest(http.MethodGet, "/proxy/*", http.StatusOK, 35*time.Millisecond)
	m.RecordBackendSelection("a.internal", string(StrategyRoundRobin))
	m.RecordUpstreamError("a.internal", "transport")
	m.RecordCircuitOpen("a.internal")
	m.RecordRetry()
	m.RecordFailover()
	m.DecInFlight()

	rendered := m.RenderPrometheus()
	for _, token := range []string{
		"minilb_requests_total",
		"minilb_request_duration_seconds_bucket",
		"minilb_backend_selection_total",
		"minilb_upstream_errors_total",
		"minilb_circuit_open_total",
		"minilb_retries_total",
		"minilb_failovers_total",
	} {
		if !strings.Contains(rendered, token) {
			t.Fatalf("expected metrics output to contain %q", token)
		}
	}
}

func TestProxyStripsSensitiveUpstreamHeaders(t *testing.T) {
	t.Setenv("HIDE_UPSTREAM_HEADERS", "true")

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Server", "internal-backend")
		w.Header().Set("X-Powered-By", "leaky-runtime")
		w.Header().Set("X-Custom-Header", "ok")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))
	defer backend.Close()

	lb, err := NewLoadBalancer([]string{backend.URL}, StrategyRoundRobin, 100)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/test", nil)
	req.RemoteAddr = "10.0.0.2:9000"
	rec := httptest.NewRecorder()
	lb.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 from backend proxy, got %d", rec.Code)
	}
	if got := rec.Header().Get("Server"); got != "" {
		t.Fatalf("expected Server header to be stripped, got %q", got)
	}
	if got := rec.Header().Get("X-Powered-By"); got != "" {
		t.Fatalf("expected X-Powered-By header to be stripped, got %q", got)
	}
	if got := rec.Header().Get("X-Custom-Header"); got != "ok" {
		t.Fatalf("expected non-sensitive header to be preserved, got %q", got)
	}
}

func TestProxyPropagatesTraceID(t *testing.T) {
	traceID := "4bf92f3577b34da6a3ce929d0e0e4736"
	var gotTrace string

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotTrace = r.Header.Get("X-Trace-ID")
		w.WriteHeader(http.StatusOK)
	}))
	defer backend.Close()

	lb, err := NewLoadBalancer([]string{backend.URL}, StrategyRoundRobin, 100)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/test", nil)
	req = req.WithContext(context.WithValue(req.Context(), traceIDContextKey, traceID))
	req.RemoteAddr = "10.0.0.2:9000"
	rec := httptest.NewRecorder()
	lb.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected proxied response status 200, got %d", rec.Code)
	}
	if gotTrace != traceID {
		t.Fatalf("expected X-Trace-ID %q to reach backend, got %q", traceID, gotTrace)
	}
}

func TestStrategyHandlerSwitchesToWeighted(t *testing.T) {
	lb, err := NewLoadBalancer(
		[]string{"http://a.internal", "http://b.internal"},
		StrategyRoundRobin,
		100,
	)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "http://lb.internal/admin/strategy", strings.NewReader(`{"name":"weighted"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	lb.StrategyHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected strategy switch to succeed, got %d", rec.Code)
	}
	if lb.Strategy() != StrategyWeighted {
		t.Fatalf("expected strategy %q, got %q", StrategyWeighted, lb.Strategy())
	}
}

func TestBackendsHandlerIncludesWeight(t *testing.T) {
	cfg := DefaultLoadBalancerConfig()
	cfg.BackendWeights = []int{2, 5}

	lb, err := NewLoadBalancerWithConfig(
		[]string{"http://a.internal", "http://b.internal"},
		StrategyWeighted,
		cfg,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "http://lb.internal/admin/backends", nil)
	rec := httptest.NewRecorder()
	lb.BackendsHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var payload struct {
		Backends []struct {
			URL    string `json:"url"`
			Weight int    `json:"weight"`
		} `json:"backends"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Backends) != 2 {
		t.Fatalf("expected 2 backends, got %d", len(payload.Backends))
	}
	if payload.Backends[0].Weight != 2 || payload.Backends[1].Weight != 5 {
		t.Fatalf("unexpected weights in response: %+v", payload.Backends)
	}
}
