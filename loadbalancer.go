package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Strategy string

const (
	StrategyRoundRobin      Strategy = "round_robin"
	StrategyLeastConnection Strategy = "least_connections"
	StrategyConsistentHash  Strategy = "consistent_hash"
)

func ParseStrategy(raw string) (Strategy, error) {
	switch Strategy(strings.ToLower(strings.TrimSpace(raw))) {
	case StrategyRoundRobin:
		return StrategyRoundRobin, nil
	case StrategyLeastConnection:
		return StrategyLeastConnection, nil
	case StrategyConsistentHash:
		return StrategyConsistentHash, nil
	default:
		return "", errors.New("invalid strategy: use round_robin, least_connections, or consistent_hash")
	}
}

type LoadBalancerConfig struct {
	HashReplicas            int
	MaxRetries              int
	RetryBackoff            time.Duration
	UpstreamTimeout         time.Duration
	CircuitFailureThreshold int64
	CircuitOpenDuration     time.Duration
	HealthFailThreshold     int64
	HealthSuccessThreshold  int64
}

func DefaultLoadBalancerConfig() LoadBalancerConfig {
	return LoadBalancerConfig{
		HashReplicas:            100,
		MaxRetries:              2,
		RetryBackoff:            60 * time.Millisecond,
		UpstreamTimeout:         10 * time.Second,
		CircuitFailureThreshold: 3,
		CircuitOpenDuration:     30 * time.Second,
		HealthFailThreshold:     2,
		HealthSuccessThreshold:  2,
	}
}

func normalizeConfig(cfg *LoadBalancerConfig) {
	defaults := DefaultLoadBalancerConfig()
	if cfg.HashReplicas <= 0 {
		cfg.HashReplicas = defaults.HashReplicas
	}
	if cfg.MaxRetries < 0 {
		cfg.MaxRetries = defaults.MaxRetries
	}
	if cfg.RetryBackoff < 0 {
		cfg.RetryBackoff = defaults.RetryBackoff
	}
	if cfg.UpstreamTimeout <= 0 {
		cfg.UpstreamTimeout = defaults.UpstreamTimeout
	}
	if cfg.CircuitFailureThreshold <= 0 {
		cfg.CircuitFailureThreshold = defaults.CircuitFailureThreshold
	}
	if cfg.CircuitOpenDuration <= 0 {
		cfg.CircuitOpenDuration = defaults.CircuitOpenDuration
	}
	if cfg.HealthFailThreshold <= 0 {
		cfg.HealthFailThreshold = defaults.HealthFailThreshold
	}
	if cfg.HealthSuccessThreshold <= 0 {
		cfg.HealthSuccessThreshold = defaults.HealthSuccessThreshold
	}
}

type Backend struct {
	URL *url.URL

	client *http.Client

	alive             atomic.Bool
	activeConnections atomic.Int64

	circuitFailures      atomic.Int64
	circuitOpenUntilUnix atomic.Int64

	healthFailStreak    atomic.Int64
	healthSuccessStreak atomic.Int64
}

func (b *Backend) IsAlive() bool {
	return b.alive.Load()
}

func (b *Backend) SetAlive(alive bool) {
	b.alive.Store(alive)
}

func (b *Backend) isCircuitOpen(now time.Time) bool {
	openUntil := b.circuitOpenUntilUnix.Load()
	if openUntil == 0 {
		return false
	}
	return now.UnixNano() < openUntil
}

func (b *Backend) circuitOpenUntil() time.Time {
	unixNano := b.circuitOpenUntilUnix.Load()
	if unixNano == 0 {
		return time.Time{}
	}
	return time.Unix(0, unixNano).UTC()
}

func (b *Backend) markSuccess() {
	b.circuitFailures.Store(0)
	b.circuitOpenUntilUnix.Store(0)
}

func (b *Backend) markFailure(cfg LoadBalancerConfig) bool {
	failures := b.circuitFailures.Add(1)
	if failures < cfg.CircuitFailureThreshold {
		return false
	}

	openUntil := time.Now().Add(cfg.CircuitOpenDuration).UnixNano()
	b.circuitOpenUntilUnix.Store(openUntil)
	b.circuitFailures.Store(0)
	return true
}

func (b *Backend) markHealthResult(healthy bool, cfg LoadBalancerConfig) bool {
	if healthy {
		b.healthFailStreak.Store(0)
		successes := b.healthSuccessStreak.Add(1)
		if !b.IsAlive() && successes >= cfg.HealthSuccessThreshold {
			b.SetAlive(true)
			b.markSuccess()
			return true
		}
		return false
	}

	b.healthSuccessStreak.Store(0)
	failures := b.healthFailStreak.Add(1)
	if b.IsAlive() && failures >= cfg.HealthFailThreshold {
		b.SetAlive(false)
		return true
	}
	return false
}

type LoadBalancer struct {
	backends []*Backend
	config   LoadBalancerConfig
	metrics  *LBMetrics

	strategy atomic.Value // Strategy
	rrCursor atomic.Uint64

	ringMu   sync.RWMutex
	hashRing *HashRing

	draining atomic.Bool
}

func NewLoadBalancer(rawBackends []string, strategy Strategy, hashReplicas int) (*LoadBalancer, error) {
	cfg := DefaultLoadBalancerConfig()
	if hashReplicas > 0 {
		cfg.HashReplicas = hashReplicas
	}
	return NewLoadBalancerWithConfig(rawBackends, strategy, cfg, nil)
}

func NewLoadBalancerWithConfig(rawBackends []string, strategy Strategy, config LoadBalancerConfig, metrics *LBMetrics) (*LoadBalancer, error) {
	if len(rawBackends) == 0 {
		return nil, errors.New("at least one backend is required")
	}
	normalizeConfig(&config)

	lb := &LoadBalancer{
		backends: make([]*Backend, 0, len(rawBackends)),
		config:   config,
		metrics:  metrics,
	}
	lb.strategy.Store(strategy)

	for _, raw := range rawBackends {
		backend, err := newBackend(raw, config)
		if err != nil {
			return nil, err
		}
		lb.backends = append(lb.backends, backend)
	}

	lb.rebuildHashRing()
	return lb, nil
}

func newBackend(rawURL string, cfg LoadBalancerConfig) (*Backend, error) {
	targetURL, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return nil, err
	}
	if targetURL.Scheme == "" || targetURL.Host == "" {
		return nil, errors.New("backend URL must include scheme and host: " + rawURL)
	}

	backend := &Backend{
		URL: targetURL,
		client: &http.Client{
			Timeout: cfg.UpstreamTimeout,
		},
	}
	backend.SetAlive(true)
	return backend, nil
}

func (lb *LoadBalancer) Strategy() Strategy {
	value := lb.strategy.Load()
	if value == nil {
		return StrategyRoundRobin
	}
	return value.(Strategy)
}

func (lb *LoadBalancer) SetStrategy(strategy Strategy) {
	lb.strategy.Store(strategy)
}

func (lb *LoadBalancer) StartDrain() {
	lb.draining.Store(true)
}

func (lb *LoadBalancer) IsDraining() bool {
	return lb.draining.Load()
}

func (lb *LoadBalancer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if lb.IsDraining() {
		http.Error(w, "load balancer is draining", http.StatusServiceUnavailable)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "unable to read request body", http.StatusBadRequest)
		return
	}
	r.Body.Close()

	maxAttempts := 1
	if isIdempotentMethod(r.Method) {
		maxAttempts = lb.config.MaxRetries + 1
	}
	if maxAttempts < 1 {
		maxAttempts = 1
	}
	if maxAttempts > len(lb.backends) {
		maxAttempts = len(lb.backends)
	}

	requestID := RequestIDFromContext(r.Context())
	excluded := make(map[*Backend]struct{}, maxAttempts)
	var (
		lastErr    error
		lastStatus int
		attempts   int
	)

	for attempts < maxAttempts {
		backend := lb.selectBackend(r, excluded)
		if backend == nil {
			break
		}
		attempts++

		if lb.metrics != nil {
			lb.metrics.RecordBackendSelection(backend.URL.Host, string(lb.Strategy()))
		}

		backend.activeConnections.Add(1)
		resp, reqErr := lb.forwardToBackend(r, body, backend, requestID)
		backend.activeConnections.Add(-1)

		if reqErr != nil {
			lastErr = reqErr
			lastStatus = http.StatusBadGateway
			lb.handleBackendFailure(backend, "transport")
			excluded[backend] = struct{}{}
			if lb.shouldRetry(attempts, maxAttempts, r, 0, reqErr) {
				lb.recordRetry(attempts)
				lb.sleepBackoff(r.Context())
				continue
			}
			break
		}

		lastStatus = resp.StatusCode
		if resp.StatusCode >= 500 {
			lb.handleBackendFailure(backend, fmt.Sprintf("status_%d", resp.StatusCode))
			if lb.shouldRetry(attempts, maxAttempts, r, resp.StatusCode, nil) {
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				excluded[backend] = struct{}{}
				lb.recordRetry(attempts)
				lb.sleepBackoff(r.Context())
				continue
			}
			writeResponse(w, resp)
			lb.logProxyResult(r, requestID, attempts, resp.StatusCode, backend.URL.Host, "upstream_5xx")
			return
		}

		backend.markSuccess()
		writeResponse(w, resp)
		lb.logProxyResult(r, requestID, attempts, lastStatus, backend.URL.Host, "")
		return
	}

	if lastErr != nil || lastStatus >= 500 {
		http.Error(w, "upstream unavailable", http.StatusBadGateway)
		lb.logProxyResult(r, requestID, attempts, http.StatusBadGateway, "", "upstream_unavailable")
		return
	}

	http.Error(w, "no healthy backends available", http.StatusServiceUnavailable)
	lb.logProxyResult(r, requestID, attempts, http.StatusServiceUnavailable, "", "no_healthy_backends")
}

func (lb *LoadBalancer) shouldRetry(attempt, maxAttempts int, r *http.Request, statusCode int, err error) bool {
	if attempt >= maxAttempts || !isIdempotentMethod(r.Method) {
		return false
	}
	if err != nil {
		return true
	}
	return statusCode >= 500
}

func (lb *LoadBalancer) recordRetry(attempt int) {
	if lb.metrics == nil {
		return
	}
	lb.metrics.RecordRetry()
	if attempt == 1 {
		lb.metrics.RecordFailover()
	}
}

func (lb *LoadBalancer) sleepBackoff(ctx context.Context) {
	if lb.config.RetryBackoff <= 0 {
		return
	}
	timer := time.NewTimer(lb.config.RetryBackoff)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-timer.C:
	}
}

func (lb *LoadBalancer) handleBackendFailure(backend *Backend, reason string) {
	opened := backend.markFailure(lb.config)
	if lb.metrics != nil {
		lb.metrics.RecordUpstreamError(backend.URL.Host, reason)
		if opened {
			lb.metrics.RecordCircuitOpen(backend.URL.Host)
		}
	}
}

func (lb *LoadBalancer) forwardToBackend(src *http.Request, body []byte, backend *Backend, requestID string) (*http.Response, error) {
	target := backend.URL.ResolveReference(&url.URL{
		Path:     src.URL.Path,
		RawPath:  src.URL.RawPath,
		RawQuery: src.URL.RawQuery,
	})

	var reqBody io.ReadCloser = http.NoBody
	if len(body) > 0 {
		reqBody = io.NopCloser(bytes.NewReader(body))
	}

	outReq, err := http.NewRequestWithContext(src.Context(), src.Method, target.String(), reqBody)
	if err != nil {
		return nil, err
	}
	if len(body) > 0 {
		outReq.ContentLength = int64(len(body))
	}

	outReq.Header = cloneRequestHeader(src.Header)
	outReq.Host = backend.URL.Host
	outReq.Header.Set("X-Forwarded-Host", src.Host)
	if requestID != "" {
		outReq.Header.Set("X-Request-ID", requestID)
	}
	if traceID := TraceIDFromContext(src.Context()); traceID != "" {
		outReq.Header.Set("X-Trace-ID", traceID)
		if outReq.Header.Get("traceparent") == "" {
			outReq.Header.Set("traceparent", traceparentFromTraceID(traceID))
		}
	}
	addForwardHeaders(outReq, src)

	return backend.client.Do(outReq)
}

func addForwardHeaders(outReq *http.Request, src *http.Request) {
	proto := "http"
	if src.TLS != nil {
		proto = "https"
	}
	outReq.Header.Set("X-Forwarded-Proto", proto)

	ip := src.RemoteAddr
	if host, _, err := net.SplitHostPort(src.RemoteAddr); err == nil {
		ip = host
	}
	if ip != "" {
		if prior := src.Header.Get("X-Forwarded-For"); prior != "" {
			ip = prior + ", " + ip
		}
		outReq.Header.Set("X-Forwarded-For", ip)
	}
}

var hopHeaders = map[string]struct{}{
	"Connection":          {},
	"Proxy-Connection":    {},
	"Keep-Alive":          {},
	"Proxy-Authenticate":  {},
	"Proxy-Authorization": {},
	"Te":                  {},
	"Trailer":             {},
	"Transfer-Encoding":   {},
	"Upgrade":             {},
}

var sensitiveUpstreamResponseHeaders = map[string]struct{}{
	"Server":                        {},
	"Via":                           {},
	"X-Powered-By":                  {},
	"X-Aspnet-Version":              {},
	"X-Aspnetmvc-Version":           {},
	"X-Envoy-Upstream-Service-Time": {},
}

func cloneRequestHeader(src http.Header) http.Header {
	dst := make(http.Header, len(src))
	for key, values := range src {
		if _, skip := hopHeaders[http.CanonicalHeaderKey(key)]; skip {
			continue
		}
		for _, value := range values {
			dst.Add(key, value)
		}
	}
	if connectionValues := src.Values("Connection"); len(connectionValues) > 0 {
		for _, value := range connectionValues {
			for _, token := range strings.Split(value, ",") {
				if trimmed := strings.TrimSpace(token); trimmed != "" {
					dst.Del(trimmed)
				}
			}
		}
	}
	return dst
}

func writeResponse(w http.ResponseWriter, resp *http.Response) {
	defer resp.Body.Close()
	copyHeader(w.Header(), resp.Header)
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

func copyHeader(dst, src http.Header) {
	for key, values := range src {
		canonical := http.CanonicalHeaderKey(key)
		if _, skip := hopHeaders[canonical]; skip {
			continue
		}
		if shouldHideUpstreamHeaders() {
			if _, sensitive := sensitiveUpstreamResponseHeaders[canonical]; sensitive {
				continue
			}
		}
		for _, value := range values {
			dst.Add(key, value)
		}
	}
}

func shouldHideUpstreamHeaders() bool {
	raw := strings.TrimSpace(os.Getenv("HIDE_UPSTREAM_HEADERS"))
	if raw == "" {
		return true
	}
	return strings.EqualFold(raw, "1") || strings.EqualFold(raw, "true") || strings.EqualFold(raw, "yes")
}

func (lb *LoadBalancer) logProxyResult(r *http.Request, requestID string, attempts int, statusCode int, backend string, errorCode string) {
	fields := map[string]any{
		"event":      "proxy_result",
		"request_id": requestID,
		"trace_id":   TraceIDFromContext(r.Context()),
		"method":     r.Method,
		"path":       r.URL.Path,
		"status":     statusCode,
		"attempts":   attempts,
		"strategy":   lb.Strategy(),
	}
	if backend != "" {
		fields["backend"] = backend
	}
	if errorCode != "" {
		fields["error_code"] = errorCode
	}
	logJSON(fields)
}

func isIdempotentMethod(method string) bool {
	switch strings.ToUpper(strings.TrimSpace(method)) {
	case http.MethodGet, http.MethodHead, http.MethodOptions, http.MethodTrace, http.MethodPut, http.MethodDelete:
		return true
	default:
		return false
	}
}

func (lb *LoadBalancer) selectBackend(r *http.Request, excluded map[*Backend]struct{}) *Backend {
	switch lb.Strategy() {
	case StrategyLeastConnection:
		return lb.selectLeastConnections(excluded)
	case StrategyConsistentHash:
		if backend := lb.selectConsistentHash(r, excluded); backend != nil {
			return backend
		}
		return lb.selectRoundRobin(excluded)
	default:
		return lb.selectRoundRobin(excluded)
	}
}

func (lb *LoadBalancer) selectRoundRobin(excluded map[*Backend]struct{}) *Backend {
	total := len(lb.backends)
	if total == 0 {
		return nil
	}

	now := time.Now()
	start := int(lb.rrCursor.Add(1)-1) % total
	for i := 0; i < total; i++ {
		backend := lb.backends[(start+i)%total]
		if !backend.IsAlive() || backend.isCircuitOpen(now) || isExcluded(backend, excluded) {
			continue
		}
		return backend
	}
	return nil
}

func (lb *LoadBalancer) selectLeastConnections(excluded map[*Backend]struct{}) *Backend {
	var selected *Backend
	least := int64(math.MaxInt64)
	now := time.Now()

	for _, backend := range lb.backends {
		if !backend.IsAlive() || backend.isCircuitOpen(now) || isExcluded(backend, excluded) {
			continue
		}
		active := backend.activeConnections.Load()
		if selected == nil || active < least {
			selected = backend
			least = active
		}
	}
	return selected
}

func (lb *LoadBalancer) selectConsistentHash(r *http.Request, excluded map[*Backend]struct{}) *Backend {
	lb.ringMu.RLock()
	ring := lb.hashRing
	lb.ringMu.RUnlock()
	if ring == nil {
		return nil
	}

	now := time.Now()
	localExcluded := cloneExcluded(excluded)
	for i := 0; i < len(lb.backends); i++ {
		backend := ring.Get(requestHashKey(r), localExcluded)
		if backend == nil {
			return nil
		}
		if backend.IsAlive() && !backend.isCircuitOpen(now) {
			return backend
		}
		localExcluded[backend] = struct{}{}
	}
	return nil
}

func cloneExcluded(excluded map[*Backend]struct{}) map[*Backend]struct{} {
	if len(excluded) == 0 {
		return make(map[*Backend]struct{})
	}
	copy := make(map[*Backend]struct{}, len(excluded))
	for backend := range excluded {
		copy[backend] = struct{}{}
	}
	return copy
}

func (lb *LoadBalancer) StartHealthChecks(ctx context.Context, interval, timeout time.Duration, healthPath string) {
	if interval <= 0 {
		interval = 5 * time.Second
	}
	lb.runHealthCheckOnce(timeout, healthPath)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			lb.runHealthCheckOnce(timeout, healthPath)
		}
	}
}

func (lb *LoadBalancer) runHealthCheckOnce(timeout time.Duration, healthPath string) {
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	if strings.TrimSpace(healthPath) == "" {
		healthPath = "/health"
	}

	client := &http.Client{Timeout: timeout}
	changed := false

	for _, backend := range lb.backends {
		probeURL := backend.URL.ResolveReference(&url.URL{Path: healthPath})
		probeCtx, cancel := context.WithTimeout(context.Background(), timeout)
		req, err := http.NewRequestWithContext(probeCtx, http.MethodGet, probeURL.String(), nil)
		if err != nil {
			cancel()
			continue
		}

		resp, err := client.Do(req)
		healthy := false
		if err == nil && resp != nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			healthy = resp.StatusCode >= 200 && resp.StatusCode < 400
		}
		cancel()

		if backend.markHealthResult(healthy, lb.config) {
			changed = true
		}
		if healthy {
			backend.markSuccess()
		}
	}

	if changed {
		lb.rebuildHashRing()
	}
}

func (lb *LoadBalancer) rebuildHashRing() {
	alive := make([]*Backend, 0, len(lb.backends))
	for _, backend := range lb.backends {
		if backend.IsAlive() {
			alive = append(alive, backend)
		}
	}

	ring := NewHashRing(lb.config.HashReplicas)
	ring.Add(alive)

	lb.ringMu.Lock()
	lb.hashRing = ring
	lb.ringMu.Unlock()
}

func (lb *LoadBalancer) BackendsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	type backendStatus struct {
		URL                 string `json:"url"`
		Alive               bool   `json:"alive"`
		ActiveConnections   int64  `json:"active_connections"`
		CircuitOpen         bool   `json:"circuit_open"`
		CircuitOpenUntilUTC string `json:"circuit_open_until_utc,omitempty"`
	}

	status := make([]backendStatus, 0, len(lb.backends))
	now := time.Now()
	for _, backend := range lb.backends {
		openUntil := backend.circuitOpenUntil()
		item := backendStatus{
			URL:               backend.URL.String(),
			Alive:             backend.IsAlive(),
			ActiveConnections: backend.activeConnections.Load(),
			CircuitOpen:       backend.isCircuitOpen(now),
		}
		if !openUntil.IsZero() {
			item.CircuitOpenUntilUTC = openUntil.Format(time.RFC3339)
		}
		status = append(status, item)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"strategy": lb.Strategy(),
		"draining": lb.IsDraining(),
		"backends": status,
	})
}

func (lb *LoadBalancer) StrategyHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"strategy": string(lb.Strategy())})
		return
	case http.MethodPost:
		// continue below
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	strategy, err := strategyFromRequest(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	lb.SetStrategy(strategy)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"strategy": string(lb.Strategy())})
}

func strategyFromRequest(r *http.Request) (Strategy, error) {
	if err := r.ParseForm(); err == nil {
		if raw := strings.TrimSpace(r.FormValue("name")); raw != "" {
			return ParseStrategy(raw)
		}
	}

	var payload struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err == nil && strings.TrimSpace(payload.Name) != "" {
		return ParseStrategy(payload.Name)
	}
	return "", errors.New("strategy name is required")
}

func requestHashKey(r *http.Request) string {
	if r == nil {
		return "anonymous"
	}
	if key := strings.TrimSpace(r.Header.Get("X-Client-Key")); key != "" {
		return key
	}
	if key := strings.TrimSpace(r.URL.Query().Get("key")); key != "" {
		return key
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil && host != "" {
		return host
	}
	if strings.TrimSpace(r.RemoteAddr) != "" {
		return strings.TrimSpace(r.RemoteAddr)
	}
	return "anonymous"
}

func isExcluded(backend *Backend, excluded map[*Backend]struct{}) bool {
	if len(excluded) == 0 {
		return false
	}
	_, found := excluded[backend]
	return found
}
