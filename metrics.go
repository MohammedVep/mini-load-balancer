package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var defaultLatencyBuckets = []float64{
	0.005, 0.01, 0.025, 0.05,
	0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
}

type latencyHistogram struct {
	// bucketCounts stores per-bucket non-cumulative counts.
	bucketCounts []uint64
	count        uint64
	sum          float64
}

type LBMetrics struct {
	inFlight     atomic.Int64
	retriesTotal atomic.Uint64
	failovers    atomic.Uint64

	mu sync.Mutex

	requests         map[string]uint64
	latencies        map[string]*latencyHistogram
	backendSelection map[string]uint64
	upstreamErrors   map[string]uint64
	circuitOpens     map[string]uint64
}

type MetricsSnapshot struct {
	InFlightRequests    int64
	RetriesTotal        uint64
	FailoversTotal      uint64
	RequestsTotal       uint64
	UpstreamErrorsTotal uint64
	CircuitOpensTotal   uint64
}

type MetricsDashboardSnapshot struct {
	InFlightRequests    int64                    `json:"in_flight_requests"`
	RequestsTotal       uint64                   `json:"requests_total"`
	RetriesTotal        uint64                   `json:"retries_total"`
	FailoversTotal      uint64                   `json:"failovers_total"`
	UpstreamErrorsTotal uint64                   `json:"upstream_errors_total"`
	CircuitOpensTotal   uint64                   `json:"circuit_opens_total"`
	StatusClasses       map[string]uint64        `json:"status_classes"`
	Routes              []RouteMetric            `json:"routes"`
	BackendSelections   []BackendSelectionMetric `json:"backend_selections"`
	UpstreamErrors      []UpstreamErrorMetric    `json:"upstream_errors"`
	CircuitOpens        []CircuitOpenMetric      `json:"circuit_opens"`
	Latencies           []LatencyMetric          `json:"latencies"`
}

type RouteMetric struct {
	Method string `json:"method"`
	Route  string `json:"route"`
	Status string `json:"status"`
	Count  uint64 `json:"count"`
}

type BackendSelectionMetric struct {
	Backend  string `json:"backend"`
	Strategy string `json:"strategy"`
	Count    uint64 `json:"count"`
}

type UpstreamErrorMetric struct {
	Backend string `json:"backend"`
	Reason  string `json:"reason"`
	Count   uint64 `json:"count"`
}

type CircuitOpenMetric struct {
	Backend string `json:"backend"`
	Count   uint64 `json:"count"`
}

type LatencyMetric struct {
	Method    string  `json:"method"`
	Route     string  `json:"route"`
	Count     uint64  `json:"count"`
	AverageMS float64 `json:"average_ms"`
}

func NewLBMetrics() *LBMetrics {
	return &LBMetrics{
		requests:         make(map[string]uint64),
		latencies:        make(map[string]*latencyHistogram),
		backendSelection: make(map[string]uint64),
		upstreamErrors:   make(map[string]uint64),
		circuitOpens:     make(map[string]uint64),
	}
}

func (m *LBMetrics) IncInFlight() {
	m.inFlight.Add(1)
}

func (m *LBMetrics) DecInFlight() {
	m.inFlight.Add(-1)
}

func (m *LBMetrics) RecordRetry() {
	m.retriesTotal.Add(1)
}

func (m *LBMetrics) RecordFailover() {
	m.failovers.Add(1)
}

func (m *LBMetrics) RecordRequest(method, route string, status int, duration time.Duration) {
	key := labelKey(method, route, strconv.Itoa(status))
	latencyKey := labelKey(method, route)

	m.mu.Lock()
	m.requests[key]++
	hist := m.latencies[latencyKey]
	if hist == nil {
		hist = &latencyHistogram{
			bucketCounts: make([]uint64, len(defaultLatencyBuckets)),
		}
		m.latencies[latencyKey] = hist
	}
	seconds := duration.Seconds()
	hist.count++
	hist.sum += seconds
	index := len(defaultLatencyBuckets) // +Inf
	for i, bound := range defaultLatencyBuckets {
		if seconds <= bound {
			index = i
			break
		}
	}
	if index < len(defaultLatencyBuckets) {
		hist.bucketCounts[index]++
	}
	m.mu.Unlock()
}

func (m *LBMetrics) RecordBackendSelection(backend, strategy string) {
	key := labelKey(backend, strategy)
	m.mu.Lock()
	m.backendSelection[key]++
	m.mu.Unlock()
}

func (m *LBMetrics) RecordUpstreamError(backend, reason string) {
	key := labelKey(backend, reason)
	m.mu.Lock()
	m.upstreamErrors[key]++
	m.mu.Unlock()
}

func (m *LBMetrics) RecordCircuitOpen(backend string) {
	m.mu.Lock()
	m.circuitOpens[labelKey(backend)]++
	m.mu.Unlock()
}

func (m *LBMetrics) Handler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Write([]byte(m.RenderPrometheus()))
}

func (m *LBMetrics) DashboardHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(m.DashboardSnapshot())
}

func (m *LBMetrics) RenderPrometheus() string {
	m.mu.Lock()
	requests := copyCounterMap(m.requests)
	backendSelection := copyCounterMap(m.backendSelection)
	upstreamErrors := copyCounterMap(m.upstreamErrors)
	circuitOpens := copyCounterMap(m.circuitOpens)
	latencies := copyLatencyMap(m.latencies)
	m.mu.Unlock()

	var b strings.Builder

	b.WriteString("# HELP minilb_inflight_requests Current number of in-flight HTTP requests.\n")
	b.WriteString("# TYPE minilb_inflight_requests gauge\n")
	b.WriteString(fmt.Sprintf("minilb_inflight_requests %d\n", m.inFlight.Load()))

	b.WriteString("# HELP minilb_retries_total Total retry attempts performed.\n")
	b.WriteString("# TYPE minilb_retries_total counter\n")
	b.WriteString(fmt.Sprintf("minilb_retries_total %d\n", m.retriesTotal.Load()))

	b.WriteString("# HELP minilb_failovers_total Total failover events where a retry switched backend.\n")
	b.WriteString("# TYPE minilb_failovers_total counter\n")
	b.WriteString(fmt.Sprintf("minilb_failovers_total %d\n", m.failovers.Load()))

	b.WriteString("# HELP minilb_requests_total Total HTTP requests observed by method/route/status.\n")
	b.WriteString("# TYPE minilb_requests_total counter\n")
	writeSortedCounterWith3Labels(&b, "minilb_requests_total", requests, "method", "route", "status")

	b.WriteString("# HELP minilb_backend_selection_total Backend selections by strategy.\n")
	b.WriteString("# TYPE minilb_backend_selection_total counter\n")
	writeSortedCounterWith2Labels(&b, "minilb_backend_selection_total", backendSelection, "backend", "strategy")

	b.WriteString("# HELP minilb_upstream_errors_total Upstream transport/status failures.\n")
	b.WriteString("# TYPE minilb_upstream_errors_total counter\n")
	writeSortedCounterWith2Labels(&b, "minilb_upstream_errors_total", upstreamErrors, "backend", "reason")

	b.WriteString("# HELP minilb_circuit_open_total Circuit breaker open transitions.\n")
	b.WriteString("# TYPE minilb_circuit_open_total counter\n")
	writeSortedCounterWith1Label(&b, "minilb_circuit_open_total", circuitOpens, "backend")

	b.WriteString("# HELP minilb_request_duration_seconds Request latency histogram by method/route.\n")
	b.WriteString("# TYPE minilb_request_duration_seconds histogram\n")
	writeLatencyHistogram(&b, latencies)

	return b.String()
}

func (m *LBMetrics) Snapshot() MetricsSnapshot {
	m.mu.Lock()
	defer m.mu.Unlock()

	snapshot := MetricsSnapshot{
		InFlightRequests: m.inFlight.Load(),
		RetriesTotal:     m.retriesTotal.Load(),
		FailoversTotal:   m.failovers.Load(),
	}
	for _, value := range m.requests {
		snapshot.RequestsTotal += value
	}
	for _, value := range m.upstreamErrors {
		snapshot.UpstreamErrorsTotal += value
	}
	for _, value := range m.circuitOpens {
		snapshot.CircuitOpensTotal += value
	}
	return snapshot
}

func (m *LBMetrics) DashboardSnapshot() MetricsDashboardSnapshot {
	m.mu.Lock()
	requests := copyCounterMap(m.requests)
	backendSelection := copyCounterMap(m.backendSelection)
	upstreamErrors := copyCounterMap(m.upstreamErrors)
	circuitOpens := copyCounterMap(m.circuitOpens)
	latencies := copyLatencyMap(m.latencies)
	m.mu.Unlock()

	snapshot := MetricsDashboardSnapshot{
		InFlightRequests: m.inFlight.Load(),
		RetriesTotal:     m.retriesTotal.Load(),
		FailoversTotal:   m.failovers.Load(),
		StatusClasses: map[string]uint64{
			"2xx": 0,
			"3xx": 0,
			"4xx": 0,
			"5xx": 0,
		},
	}

	for _, key := range sortedKeys(requests) {
		parts := splitKey(key, 3)
		count := requests[key]
		status := parts[2]
		snapshot.RequestsTotal += count
		snapshot.StatusClasses[statusClass(status)] += count
		snapshot.Routes = append(snapshot.Routes, RouteMetric{
			Method: parts[0],
			Route:  parts[1],
			Status: status,
			Count:  count,
		})
	}

	for _, key := range sortedKeys(backendSelection) {
		parts := splitKey(key, 2)
		snapshot.BackendSelections = append(snapshot.BackendSelections, BackendSelectionMetric{
			Backend:  parts[0],
			Strategy: parts[1],
			Count:    backendSelection[key],
		})
	}

	for _, key := range sortedKeys(upstreamErrors) {
		parts := splitKey(key, 2)
		count := upstreamErrors[key]
		snapshot.UpstreamErrorsTotal += count
		snapshot.UpstreamErrors = append(snapshot.UpstreamErrors, UpstreamErrorMetric{
			Backend: parts[0],
			Reason:  parts[1],
			Count:   count,
		})
	}

	for _, key := range sortedKeys(circuitOpens) {
		parts := splitKey(key, 1)
		count := circuitOpens[key]
		snapshot.CircuitOpensTotal += count
		snapshot.CircuitOpens = append(snapshot.CircuitOpens, CircuitOpenMetric{
			Backend: parts[0],
			Count:   count,
		})
	}

	for _, key := range sortedKeys(latencies) {
		parts := splitKey(key, 2)
		latency := latencies[key]
		averageMS := 0.0
		if latency.count > 0 {
			averageMS = (latency.sum / float64(latency.count)) * 1000
		}
		snapshot.Latencies = append(snapshot.Latencies, LatencyMetric{
			Method:    parts[0],
			Route:     parts[1],
			Count:     latency.count,
			AverageMS: averageMS,
		})
	}

	return snapshot
}

func writeLatencyHistogram(b *strings.Builder, values map[string]*latencyHistogram) {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		parts := splitKey(key, 2)
		method := escapeLabel(parts[0])
		route := escapeLabel(parts[1])
		h := values[key]

		var cumulative uint64
		for i, bound := range defaultLatencyBuckets {
			cumulative += h.bucketCounts[i]
			b.WriteString(fmt.Sprintf(
				"minilb_request_duration_seconds_bucket{method=\"%s\",route=\"%s\",le=\"%g\"} %d\n",
				method, route, bound, cumulative,
			))
		}
		b.WriteString(fmt.Sprintf(
			"minilb_request_duration_seconds_bucket{method=\"%s\",route=\"%s\",le=\"+Inf\"} %d\n",
			method, route, h.count,
		))
		b.WriteString(fmt.Sprintf(
			"minilb_request_duration_seconds_sum{method=\"%s\",route=\"%s\"} %g\n",
			method, route, h.sum,
		))
		b.WriteString(fmt.Sprintf(
			"minilb_request_duration_seconds_count{method=\"%s\",route=\"%s\"} %d\n",
			method, route, h.count,
		))
	}
}

func writeSortedCounterWith3Labels(b *strings.Builder, name string, values map[string]uint64, key1, key2, key3 string) {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		parts := splitKey(key, 3)
		b.WriteString(fmt.Sprintf(
			"%s{%s=\"%s\",%s=\"%s\",%s=\"%s\"} %d\n",
			name,
			key1, escapeLabel(parts[0]),
			key2, escapeLabel(parts[1]),
			key3, escapeLabel(parts[2]),
			values[key],
		))
	}
}

func writeSortedCounterWith2Labels(b *strings.Builder, name string, values map[string]uint64, key1, key2 string) {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		parts := splitKey(key, 2)
		b.WriteString(fmt.Sprintf(
			"%s{%s=\"%s\",%s=\"%s\"} %d\n",
			name,
			key1, escapeLabel(parts[0]),
			key2, escapeLabel(parts[1]),
			values[key],
		))
	}
}

func writeSortedCounterWith1Label(b *strings.Builder, name string, values map[string]uint64, key1 string) {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		parts := splitKey(key, 1)
		b.WriteString(fmt.Sprintf(
			"%s{%s=\"%s\"} %d\n",
			name,
			key1, escapeLabel(parts[0]),
			values[key],
		))
	}
}

func copyCounterMap(src map[string]uint64) map[string]uint64 {
	dst := make(map[string]uint64, len(src))
	for key, value := range src {
		dst[key] = value
	}
	return dst
}

func copyLatencyMap(src map[string]*latencyHistogram) map[string]*latencyHistogram {
	dst := make(map[string]*latencyHistogram, len(src))
	for key, value := range src {
		copyCounts := make([]uint64, len(value.bucketCounts))
		copy(copyCounts, value.bucketCounts)
		dst[key] = &latencyHistogram{
			bucketCounts: copyCounts,
			count:        value.count,
			sum:          value.sum,
		}
	}
	return dst
}

const keyDelim = "\xff"

func labelKey(parts ...string) string {
	return strings.Join(parts, keyDelim)
}

func sortedKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func splitKey(key string, expected int) []string {
	parts := strings.Split(key, keyDelim)
	for len(parts) < expected {
		parts = append(parts, "")
	}
	return parts
}

func statusClass(status string) string {
	if len(status) != 3 {
		return "other"
	}
	switch status[0] {
	case '2':
		return "2xx"
	case '3':
		return "3xx"
	case '4':
		return "4xx"
	case '5':
		return "5xx"
	default:
		return "other"
	}
}

func escapeLabel(value string) string {
	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, "\"", "\\\"")
	value = strings.ReplaceAll(value, "\n", "\\n")
	return value
}
