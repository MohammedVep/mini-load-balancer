package main

import (
	"encoding/json"
	"io"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

type CostConfig struct {
	Enabled                bool
	RequestUSDPerMillion   float64
	EgressUSDPerGB         float64
	AIInputUSDPer1KTokens  float64
	AIOutputUSDPer1KTokens float64
}

func CostConfigFromEnv() CostConfig {
	cfg := CostConfig{
		Enabled:                true,
		RequestUSDPerMillion:   0.20,
		EgressUSDPerGB:         0.09,
		AIInputUSDPer1KTokens:  0.00015,
		AIOutputUSDPer1KTokens: 0.00060,
	}
	if raw := strings.TrimSpace(os.Getenv("COST_AWARENESS_ENABLED")); raw != "" {
		cfg.Enabled = strings.EqualFold(raw, "true") || raw == "1" || strings.EqualFold(raw, "yes")
	}
	if raw := strings.TrimSpace(os.Getenv("COST_PER_MILLION_REQUESTS_USD")); raw != "" {
		if value, err := strconv.ParseFloat(raw, 64); err == nil && value >= 0 {
			cfg.RequestUSDPerMillion = value
		}
	}
	if raw := strings.TrimSpace(os.Getenv("COST_PER_GB_EGRESS_USD")); raw != "" {
		if value, err := strconv.ParseFloat(raw, 64); err == nil && value >= 0 {
			cfg.EgressUSDPerGB = value
		}
	}
	if raw := strings.TrimSpace(os.Getenv("COST_AI_INPUT_PER_1K_TOKENS_USD")); raw != "" {
		if value, err := strconv.ParseFloat(raw, 64); err == nil && value >= 0 {
			cfg.AIInputUSDPer1KTokens = value
		}
	}
	if raw := strings.TrimSpace(os.Getenv("COST_AI_OUTPUT_PER_1K_TOKENS_USD")); raw != "" {
		if value, err := strconv.ParseFloat(raw, 64); err == nil && value >= 0 {
			cfg.AIOutputUSDPer1KTokens = value
		}
	}
	return cfg
}

type CostTracker struct {
	config CostConfig

	startedAt time.Time

	httpRequests atomic.Uint64
	ingressBytes atomic.Uint64
	egressBytes  atomic.Uint64

	aiRequests     atomic.Uint64
	aiInputTokens  atomic.Uint64
	aiOutputTokens atomic.Uint64
}

func NewCostTracker(config CostConfig) *CostTracker {
	return &CostTracker{
		config:    config,
		startedAt: time.Now().UTC(),
	}
}

func (c *CostTracker) Enabled() bool {
	return c != nil && c.config.Enabled
}

func (c *CostTracker) Middleware(next http.Handler) http.Handler {
	if c == nil || !c.config.Enabled {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		recorder := &costResponseRecorder{
			ResponseWriter: w,
			statusCode:     http.StatusOK,
		}

		var bodyCounter *countingReadCloser
		if r.Body != nil && r.Body != http.NoBody {
			bodyCounter = &countingReadCloser{ReadCloser: r.Body}
			clone := r.Clone(r.Context())
			clone.Body = bodyCounter
			r = clone
		}

		next.ServeHTTP(recorder, r)

		c.httpRequests.Add(1)
		if bodyCounter != nil {
			ingress := bodyCounter.bytesRead
			if ingress == 0 && r.ContentLength > 0 {
				ingress = uint64(r.ContentLength)
			}
			c.ingressBytes.Add(ingress)
		} else if r.ContentLength > 0 {
			c.ingressBytes.Add(uint64(r.ContentLength))
		}
		if recorder.bytes > 0 {
			c.egressBytes.Add(uint64(recorder.bytes))
		}
	})
}

func (c *CostTracker) RecordAIUsage(inputTokens, outputTokens int) {
	if c == nil || !c.config.Enabled {
		return
	}
	if inputTokens < 0 {
		inputTokens = 0
	}
	if outputTokens < 0 {
		outputTokens = 0
	}
	c.aiRequests.Add(1)
	c.aiInputTokens.Add(uint64(inputTokens))
	c.aiOutputTokens.Add(uint64(outputTokens))
}

type CostSnapshot struct {
	StartedAtUTC         string  `json:"started_at_utc"`
	UptimeSeconds        int64   `json:"uptime_seconds"`
	HTTPRequestsTotal    uint64  `json:"http_requests_total"`
	IngressBytesTotal    uint64  `json:"ingress_bytes_total"`
	EgressBytesTotal     uint64  `json:"egress_bytes_total"`
	AIRequestsTotal      uint64  `json:"ai_requests_total"`
	AIInputTokensTotal   uint64  `json:"ai_input_tokens_total"`
	AIOutputTokensTotal  uint64  `json:"ai_output_tokens_total"`
	RequestCostUSD       float64 `json:"request_cost_usd"`
	EgressCostUSD        float64 `json:"egress_cost_usd"`
	AICostUSD            float64 `json:"ai_cost_usd"`
	EstimatedCostUSD     float64 `json:"estimated_cost_usd"`
	RequestUSDPerMillion float64 `json:"request_usd_per_million"`
	EgressUSDPerGB       float64 `json:"egress_usd_per_gb"`
	AIInputUSDPer1K      float64 `json:"ai_input_usd_per_1k_tokens"`
	AIOutputUSDPer1K     float64 `json:"ai_output_usd_per_1k_tokens"`
}

func (c *CostTracker) Snapshot() CostSnapshot {
	if c == nil {
		return CostSnapshot{}
	}
	requests := c.httpRequests.Load()
	ingress := c.ingressBytes.Load()
	egress := c.egressBytes.Load()
	aiRequests := c.aiRequests.Load()
	aiInput := c.aiInputTokens.Load()
	aiOutput := c.aiOutputTokens.Load()

	requestCost := (float64(requests) / 1_000_000.0) * c.config.RequestUSDPerMillion
	egressCost := (float64(egress) / (1024.0 * 1024.0 * 1024.0)) * c.config.EgressUSDPerGB
	aiCost := (float64(aiInput)/1000.0)*c.config.AIInputUSDPer1KTokens + (float64(aiOutput)/1000.0)*c.config.AIOutputUSDPer1KTokens

	return CostSnapshot{
		StartedAtUTC:         c.startedAt.Format(time.RFC3339),
		UptimeSeconds:        int64(time.Since(c.startedAt).Seconds()),
		HTTPRequestsTotal:    requests,
		IngressBytesTotal:    ingress,
		EgressBytesTotal:     egress,
		AIRequestsTotal:      aiRequests,
		AIInputTokensTotal:   aiInput,
		AIOutputTokensTotal:  aiOutput,
		RequestCostUSD:       requestCost,
		EgressCostUSD:        egressCost,
		AICostUSD:            aiCost,
		EstimatedCostUSD:     requestCost + egressCost + aiCost,
		RequestUSDPerMillion: c.config.RequestUSDPerMillion,
		EgressUSDPerGB:       c.config.EgressUSDPerGB,
		AIInputUSDPer1K:      c.config.AIInputUSDPer1KTokens,
		AIOutputUSDPer1K:     c.config.AIOutputUSDPer1KTokens,
	}
}

func (c *CostTracker) Handler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	snapshot := c.Snapshot()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(snapshot)
}

type costResponseRecorder struct {
	http.ResponseWriter
	statusCode int
	bytes      int
}

func (sr *costResponseRecorder) WriteHeader(statusCode int) {
	sr.statusCode = statusCode
	sr.ResponseWriter.WriteHeader(statusCode)
}

func (sr *costResponseRecorder) Write(payload []byte) (int, error) {
	if sr.statusCode == 0 {
		sr.statusCode = http.StatusOK
	}
	n, err := sr.ResponseWriter.Write(payload)
	sr.bytes += n
	return n, err
}

type countingReadCloser struct {
	io.ReadCloser
	bytesRead uint64
}

func (c *countingReadCloser) Read(payload []byte) (int, error) {
	n, err := c.ReadCloser.Read(payload)
	if n > 0 {
		c.bytesRead += uint64(n)
	}
	return n, err
}

func estimateTokenCount(text string) int {
	text = strings.TrimSpace(text)
	if text == "" {
		return 0
	}
	runes := len([]rune(text))
	return int(math.Ceil(float64(runes) / 4.0))
}
