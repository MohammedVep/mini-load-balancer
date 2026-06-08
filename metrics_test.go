package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestMetricsDashboardSnapshotAggregatesControlPlaneData(t *testing.T) {
	metrics := NewLBMetrics()
	metrics.IncInFlight()
	metrics.RecordRequest(http.MethodGet, "/proxy/*", http.StatusOK, 20*time.Millisecond)
	metrics.RecordRequest(http.MethodGet, "/admin/*", http.StatusTooManyRequests, 10*time.Millisecond)
	metrics.RecordBackendSelection("backend-a", string(StrategyRoundRobin))
	metrics.RecordBackendSelection("backend-a", string(StrategyRoundRobin))
	metrics.RecordUpstreamError("backend-b", "transport")
	metrics.RecordCircuitOpen("backend-b")
	metrics.RecordRetry()
	metrics.RecordFailover()

	snapshot := metrics.DashboardSnapshot()
	if snapshot.InFlightRequests != 1 {
		t.Fatalf("unexpected in-flight count: got %d", snapshot.InFlightRequests)
	}
	if snapshot.RequestsTotal != 2 {
		t.Fatalf("unexpected request total: got %d", snapshot.RequestsTotal)
	}
	if snapshot.StatusClasses["2xx"] != 1 || snapshot.StatusClasses["4xx"] != 1 {
		t.Fatalf("unexpected status classes: %#v", snapshot.StatusClasses)
	}
	if snapshot.RetriesTotal != 1 || snapshot.FailoversTotal != 1 {
		t.Fatalf("unexpected retry/failover totals: retries=%d failovers=%d", snapshot.RetriesTotal, snapshot.FailoversTotal)
	}
	if snapshot.UpstreamErrorsTotal != 1 || snapshot.CircuitOpensTotal != 1 {
		t.Fatalf("unexpected reliability totals: upstream=%d circuits=%d", snapshot.UpstreamErrorsTotal, snapshot.CircuitOpensTotal)
	}
	if len(snapshot.BackendSelections) != 1 || snapshot.BackendSelections[0].Count != 2 {
		t.Fatalf("unexpected backend selections: %#v", snapshot.BackendSelections)
	}
	if len(snapshot.Latencies) != 2 {
		t.Fatalf("expected latency summaries for two routes, got %#v", snapshot.Latencies)
	}
}

func TestMetricsDashboardHandlerReturnsJSON(t *testing.T) {
	metrics := NewLBMetrics()
	metrics.RecordRequest(http.MethodGet, "/healthz", http.StatusOK, time.Millisecond)

	req := httptest.NewRequest(http.MethodGet, "/admin/metrics-summary", nil)
	rec := httptest.NewRecorder()
	metrics.DashboardHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status: got %d", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("unexpected content type: %s", got)
	}

	var snapshot MetricsDashboardSnapshot
	if err := json.NewDecoder(rec.Body).Decode(&snapshot); err != nil {
		t.Fatalf("decode dashboard response: %v", err)
	}
	if snapshot.RequestsTotal != 1 {
		t.Fatalf("unexpected request total: got %d", snapshot.RequestsTotal)
	}
}
