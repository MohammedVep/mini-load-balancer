package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAIStatusHandler(t *testing.T) {
	lb, err := NewLoadBalancer([]string{"http://a.internal"}, StrategyRoundRobin, 100)
	if err != nil {
		t.Fatal(err)
	}
	ai := NewAISystem(lb, NewLBMetrics(), AIConfig{Provider: "heuristic"})

	req := httptest.NewRequest(http.MethodGet, "/ai/status", nil)
	rec := httptest.NewRecorder()
	ai.StatusHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["provider"] != "heuristic" {
		t.Fatalf("expected heuristic provider, got %v", payload["provider"])
	}
}

func TestAIAnalyzeHandler(t *testing.T) {
	lb, err := NewLoadBalancer([]string{"http://a.internal"}, StrategyLeastConnection, 100)
	if err != nil {
		t.Fatal(err)
	}
	metrics := NewLBMetrics()
	metrics.RecordRequest(http.MethodGet, "/proxy/*", 200, 0)
	ai := NewAISystem(lb, metrics, AIConfig{Provider: "heuristic"})

	req := httptest.NewRequest(http.MethodPost, "/ai/analyze", strings.NewReader(`{"question":"What strategy should I use?"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	ai.AnalyzeHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var payload aiAnalyzeResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Provider != "heuristic" {
		t.Fatalf("expected heuristic provider, got %s", payload.Provider)
	}
	if !strings.Contains(payload.Answer, "AI Copilot recommendation") {
		t.Fatalf("unexpected answer: %q", payload.Answer)
	}
}
