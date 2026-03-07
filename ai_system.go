package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

type AIConfig struct {
	Provider      string
	OpenAIAPIKey  string
	OpenAIBaseURL string
	OpenAIModel   string
	Timeout       time.Duration
}

func AIConfigFromEnv() AIConfig {
	timeout := resolveDuration(-1, "AI_TIMEOUT", 12*time.Second)
	return AIConfig{
		Provider:      firstNonEmpty(strings.TrimSpace(os.Getenv("AI_PROVIDER")), "heuristic"),
		OpenAIAPIKey:  strings.TrimSpace(os.Getenv("AI_OPENAI_API_KEY")),
		OpenAIBaseURL: firstNonEmpty(strings.TrimSpace(os.Getenv("AI_OPENAI_BASE_URL")), "https://api.openai.com"),
		OpenAIModel:   firstNonEmpty(strings.TrimSpace(os.Getenv("AI_MODEL")), "gpt-4o-mini"),
		Timeout:       timeout,
	}
}

type AISystem struct {
	lb          *LoadBalancer
	metrics     *LBMetrics
	config      AIConfig
	client      *http.Client
	costTracker *CostTracker
}

type AISnapshot struct {
	Strategy            string `json:"strategy"`
	Draining            bool   `json:"draining"`
	TotalBackends       int    `json:"total_backends"`
	HealthyBackends     int    `json:"healthy_backends"`
	CircuitOpenBackends int    `json:"circuit_open_backends"`
	TotalConnections    int64  `json:"total_active_connections"`

	InFlightRequests    int64  `json:"in_flight_requests"`
	RetriesTotal        uint64 `json:"retries_total"`
	FailoversTotal      uint64 `json:"failovers_total"`
	RequestsTotal       uint64 `json:"requests_total"`
	UpstreamErrorsTotal uint64 `json:"upstream_errors_total"`
	CircuitOpensTotal   uint64 `json:"circuit_opens_total"`
}

type aiAnalyzeRequest struct {
	Question string `json:"question"`
}

type aiAnalyzeResponse struct {
	Provider     string     `json:"provider"`
	Answer       string     `json:"answer"`
	Snapshot     AISnapshot `json:"snapshot"`
	UsedFallback bool       `json:"used_fallback"`
}

func NewAISystem(lb *LoadBalancer, metrics *LBMetrics, config AIConfig) *AISystem {
	if config.Timeout <= 0 {
		config.Timeout = 12 * time.Second
	}
	config.Provider = strings.ToLower(strings.TrimSpace(config.Provider))
	if config.Provider == "" {
		config.Provider = "heuristic"
	}
	return &AISystem{
		lb:      lb,
		metrics: metrics,
		config:  config,
		client: &http.Client{
			Timeout: config.Timeout,
		},
	}
}

func (ai *AISystem) SetCostTracker(costTracker *CostTracker) {
	if ai == nil {
		return
	}
	ai.costTracker = costTracker
}

func (ai *AISystem) ProviderName() string {
	if ai.canUseOpenAI() {
		if ai.config.Provider == "openai" || ai.config.Provider == "auto" {
			return "openai"
		}
	}
	return "heuristic"
}

func (ai *AISystem) StatusHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSONResponse(w, map[string]any{
		"provider":          ai.ProviderName(),
		"openai_configured": ai.canUseOpenAI(),
		"model":             ai.config.OpenAIModel,
	})
}

func (ai *AISystem) AnalyzeHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req aiAnalyzeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}
	req.Question = strings.TrimSpace(req.Question)
	if req.Question == "" {
		http.Error(w, "question is required", http.StatusBadRequest)
		return
	}

	snapshot := ai.captureSnapshot()
	heuristicAnswer := ai.heuristicAnswer(req.Question, snapshot)
	answer := heuristicAnswer
	provider := "heuristic"
	usedFallback := false

	if ai.ProviderName() == "openai" {
		openAIAnswer, err := ai.askOpenAI(r.Context(), req.Question, snapshot, heuristicAnswer)
		if err != nil {
			usedFallback = true
			logJSON(map[string]any{
				"event":      "ai_fallback",
				"request_id": RequestIDFromContext(r.Context()),
				"trace_id":   TraceIDFromContext(r.Context()),
				"error":      err.Error(),
			})
		} else if strings.TrimSpace(openAIAnswer) != "" {
			answer = strings.TrimSpace(openAIAnswer)
			provider = "openai"
		}
	}

	if ai.costTracker != nil && ai.costTracker.Enabled() && ai.ProviderName() == "openai" {
		inputTokens := estimateTokenCount(req.Question)
		outputTokens := 0
		if provider == "openai" {
			outputTokens = estimateTokenCount(answer)
		}
		ai.costTracker.RecordAIUsage(inputTokens, outputTokens)
	}

	writeJSONResponse(w, aiAnalyzeResponse{
		Provider:     provider,
		Answer:       answer,
		Snapshot:     snapshot,
		UsedFallback: usedFallback,
	})
}

func (ai *AISystem) captureSnapshot() AISnapshot {
	var snapshot AISnapshot
	if ai.lb != nil {
		snapshot.Strategy = string(ai.lb.Strategy())
		snapshot.Draining = ai.lb.IsDraining()
		snapshot.TotalBackends = len(ai.lb.backends)
		for _, backend := range ai.lb.backends {
			if backend.IsAlive() {
				snapshot.HealthyBackends++
			}
			if backend.isCircuitOpen(time.Now()) {
				snapshot.CircuitOpenBackends++
			}
			snapshot.TotalConnections += backend.activeConnections.Load()
		}
	}
	if ai.metrics != nil {
		m := ai.metrics.Snapshot()
		snapshot.InFlightRequests = m.InFlightRequests
		snapshot.RetriesTotal = m.RetriesTotal
		snapshot.FailoversTotal = m.FailoversTotal
		snapshot.RequestsTotal = m.RequestsTotal
		snapshot.UpstreamErrorsTotal = m.UpstreamErrorsTotal
		snapshot.CircuitOpensTotal = m.CircuitOpensTotal
	}
	return snapshot
}

func (ai *AISystem) heuristicAnswer(question string, s AISnapshot) string {
	lq := strings.ToLower(question)
	lines := []string{
		"AI Copilot recommendation (heuristic):",
		fmt.Sprintf("- Current strategy: %s", s.Strategy),
		fmt.Sprintf("- Healthy backends: %d/%d, circuit-open backends: %d", s.HealthyBackends, s.TotalBackends, s.CircuitOpenBackends),
		fmt.Sprintf("- Requests: %d total, retries: %d, failovers: %d, upstream errors: %d", s.RequestsTotal, s.RetriesTotal, s.FailoversTotal, s.UpstreamErrorsTotal),
	}

	if s.Draining {
		lines = append(lines, "- Service is in draining mode; avoid strategy changes until draining completes.")
	}
	if s.TotalBackends > 0 && s.HealthyBackends < s.TotalBackends {
		lines = append(lines, "- Some backends are unhealthy; keep retry/circuit-breaker enabled and investigate backend health endpoints.")
	}
	if s.CircuitOpenBackends > 0 || s.CircuitOpensTotal > 0 {
		lines = append(lines, "- Circuits have opened; increase backend stability or tune failure threshold/open duration to avoid repeated trips.")
	}
	if s.RequestsTotal > 0 && s.RetriesTotal > s.RequestsTotal/2 {
		lines = append(lines, "- Retry volume is high relative to traffic; this indicates upstream instability.")
	}

	switch {
	case strings.Contains(lq, "strategy"), strings.Contains(lq, "routing"):
		lines = append(lines, ai.strategyGuidance(s))
	case strings.Contains(lq, "scale"), strings.Contains(lq, "capacity"):
		lines = append(lines, "- Scale recommendation: increase backend replicas when active connections rise and retries/failovers trend upward.")
	case strings.Contains(lq, "recruit"), strings.Contains(lq, "interview"), strings.Contains(lq, "credib"):
		lines = append(lines, "- Recruiter narrative: show live strategy switching, induced backend failure, automatic failover, and metrics proving resilience.")
	default:
		lines = append(lines, "- General next step: monitor /metrics and keep strategy aligned with workload shape (latency-sensitive vs sticky-session traffic).")
	}

	return strings.Join(lines, "\n")
}

func (ai *AISystem) strategyGuidance(s AISnapshot) string {
	switch s.Strategy {
	case string(StrategyLeastConnection):
		return "- Strategy guidance: least-connections is good for uneven backend response times and bursty traffic."
	case string(StrategyWeighted):
		return "- Strategy guidance: weighted routing is best when backends have different capacity; assign higher weights to stronger nodes."
	case string(StrategyConsistentHash):
		return "- Strategy guidance: consistent-hashing is best when request affinity or cache locality matters."
	default:
		return "- Strategy guidance: round-robin is simple and fair for homogeneous pools; use weighted when backend capacity differs."
	}
}

func (ai *AISystem) askOpenAI(ctx context.Context, question string, s AISnapshot, heuristic string) (string, error) {
	if !ai.canUseOpenAI() {
		return "", errors.New("openai is not configured")
	}
	if ai.config.Provider != "openai" && ai.config.Provider != "auto" {
		return "", errors.New("openai provider is disabled")
	}

	response, err := ai.callResponsesAPI(ctx, question, s, heuristic)
	if err == nil && strings.TrimSpace(response) != "" {
		return response, nil
	}

	chatResp, chatErr := ai.callChatCompletionsAPI(ctx, question, s, heuristic)
	if chatErr != nil {
		if err != nil {
			return "", fmt.Errorf("responses api error: %v; chat api error: %v", err, chatErr)
		}
		return "", chatErr
	}
	return chatResp, nil
}

func (ai *AISystem) callResponsesAPI(ctx context.Context, question string, s AISnapshot, heuristic string) (string, error) {
	type requestBody struct {
		Model string `json:"model"`
		Input []any  `json:"input"`
	}

	snapshotJSON, _ := json.Marshal(s)
	systemPrompt := "You are an AI copilot for a mini load balancer. Be concise, practical, and action-oriented."
	userPrompt := fmt.Sprintf("Question: %s\nLive snapshot: %s\nHeuristic baseline: %s\nReturn concise operational guidance.",
		question, string(snapshotJSON), heuristic)

	body := requestBody{
		Model: ai.config.OpenAIModel,
		Input: []any{
			map[string]any{
				"role": "system",
				"content": []map[string]string{
					{"type": "text", "text": systemPrompt},
				},
			},
			map[string]any{
				"role": "user",
				"content": []map[string]string{
					{"type": "text", "text": userPrompt},
				},
			},
		},
	}

	raw, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(ai.config.OpenAIBaseURL, "/")+"/v1/responses", bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+ai.config.OpenAIAPIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := ai.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("responses api status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var parsed struct {
		OutputText string `json:"output_text"`
		Output     []struct {
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"output"`
	}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return "", err
	}
	if strings.TrimSpace(parsed.OutputText) != "" {
		return strings.TrimSpace(parsed.OutputText), nil
	}
	for _, out := range parsed.Output {
		for _, content := range out.Content {
			if strings.TrimSpace(content.Text) != "" {
				return strings.TrimSpace(content.Text), nil
			}
		}
	}
	return "", errors.New("responses api returned empty output")
}

func (ai *AISystem) callChatCompletionsAPI(ctx context.Context, question string, s AISnapshot, heuristic string) (string, error) {
	type requestBody struct {
		Model    string `json:"model"`
		Messages []any  `json:"messages"`
	}

	snapshotJSON, _ := json.Marshal(s)
	body := requestBody{
		Model: ai.config.OpenAIModel,
		Messages: []any{
			map[string]string{"role": "system", "content": "You are an AI copilot for a mini load balancer. Be concise and operational."},
			map[string]string{
				"role": "user",
				"content": fmt.Sprintf("Question: %s\nSnapshot: %s\nHeuristic baseline: %s\nReturn concise guidance.",
					question, string(snapshotJSON), heuristic),
			},
		},
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(ai.config.OpenAIBaseURL, "/")+"/v1/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+ai.config.OpenAIAPIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := ai.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("chat completions status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var parsed struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return "", err
	}
	if len(parsed.Choices) == 0 {
		return "", errors.New("chat completions returned no choices")
	}
	return strings.TrimSpace(parsed.Choices[0].Message.Content), nil
}

func (ai *AISystem) canUseOpenAI() bool {
	return strings.TrimSpace(ai.config.OpenAIAPIKey) != ""
}

func writeJSONResponse(w http.ResponseWriter, payload any) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.Encode(payload)
}
