package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	var (
		addr           string
		modeRaw        string
		backendName    string
		backendList    string
		strategyRaw    string
		healthPath     string
		healthInterval time.Duration
		healthTimeout  time.Duration
		proxyPrefix    string
		enableFrontend bool

		maxRetries              int
		retryBackoff            time.Duration
		upstreamTimeout         time.Duration
		circuitFailureThreshold int64
		circuitOpenDuration     time.Duration
		healthFailThreshold     int64
		healthSuccessThreshold  int64

		drainDelay      time.Duration
		shutdownTimeout time.Duration
	)

	flag.StringVar(&addr, "addr", ":8080", "listen address")
	flag.StringVar(&modeRaw, "mode", "", "runtime mode: load_balancer | backend_demo")
	flag.StringVar(&backendName, "backend-name", "", "backend identifier when mode=backend_demo")
	flag.StringVar(&backendList, "backends", "", "comma-separated backend URLs (or set BACKENDS env var)")
	flag.StringVar(&strategyRaw, "strategy", "", "routing strategy: round_robin | least_connections | consistent_hash")
	flag.StringVar(&healthPath, "health-path", "", "health check path")
	flag.DurationVar(&healthInterval, "health-interval", 5*time.Second, "health check interval")
	flag.DurationVar(&healthTimeout, "health-timeout", 2*time.Second, "health check timeout")
	flag.StringVar(&proxyPrefix, "proxy-prefix", "", "request path prefix forwarded to backend pool")
	flag.BoolVar(&enableFrontend, "frontend", true, "serve recruiter-facing frontend at /")

	flag.IntVar(&maxRetries, "max-retries", -1, "bounded retries for idempotent requests")
	flag.DurationVar(&retryBackoff, "retry-backoff", -1, "delay between retries")
	flag.DurationVar(&upstreamTimeout, "upstream-timeout", -1, "upstream per-request timeout")
	flag.Int64Var(&circuitFailureThreshold, "circuit-failure-threshold", 0, "consecutive failures to open circuit")
	flag.DurationVar(&circuitOpenDuration, "circuit-open-duration", -1, "how long a circuit remains open")
	flag.Int64Var(&healthFailThreshold, "health-fail-threshold", 0, "consecutive failed probes before marking backend unhealthy")
	flag.Int64Var(&healthSuccessThreshold, "health-success-threshold", 0, "consecutive successful probes before marking backend healthy")

	flag.DurationVar(&drainDelay, "drain-delay", -1, "delay between entering drain mode and shutdown")
	flag.DurationVar(&shutdownTimeout, "shutdown-timeout", -1, "grace period to finish in-flight requests")
	flag.Parse()

	modeRaw = firstNonEmpty(strings.TrimSpace(modeRaw), strings.TrimSpace(os.Getenv("MODE")), "load_balancer")
	backendName = firstNonEmpty(strings.TrimSpace(backendName), strings.TrimSpace(os.Getenv("BACKEND_NAME")), "backend-demo")
	backendList = firstNonEmpty(strings.TrimSpace(backendList), strings.TrimSpace(os.Getenv("BACKENDS")))
	strategyRaw = firstNonEmpty(strings.TrimSpace(strategyRaw), strings.TrimSpace(os.Getenv("STRATEGY")), string(StrategyRoundRobin))
	healthPath = firstNonEmpty(strings.TrimSpace(healthPath), strings.TrimSpace(os.Getenv("HEALTH_PATH")), "/health")
	proxyPrefix = firstNonEmpty(strings.TrimSpace(proxyPrefix), strings.TrimSpace(os.Getenv("PROXY_PREFIX")), "/proxy")
	if fromEnv := strings.TrimSpace(os.Getenv("ENABLE_FRONTEND")); fromEnv != "" {
		enableFrontend = strings.EqualFold(fromEnv, "1") || strings.EqualFold(fromEnv, "true") || strings.EqualFold(fromEnv, "yes")
	}

	switch strings.ToLower(modeRaw) {
	case "backend_demo":
		runBackendDemoServer(addr, backendName)
		return
	case "load_balancer":
		// continue below.
	default:
		log.Fatalf("invalid mode: %s (use load_balancer or backend_demo)", modeRaw)
	}

	if strings.TrimSpace(backendList) == "" {
		log.Fatal("missing backends: set -backends or BACKENDS env var")
	}

	strategy, err := ParseStrategy(strategyRaw)
	if err != nil {
		log.Fatal(err)
	}

	defaults := DefaultLoadBalancerConfig()
	lbConfig := LoadBalancerConfig{
		HashReplicas:            defaults.HashReplicas,
		MaxRetries:              resolveInt(maxRetries, "MAX_RETRIES", defaults.MaxRetries),
		RetryBackoff:            resolveDuration(retryBackoff, "RETRY_BACKOFF", defaults.RetryBackoff),
		UpstreamTimeout:         resolveDuration(upstreamTimeout, "UPSTREAM_TIMEOUT", defaults.UpstreamTimeout),
		CircuitFailureThreshold: resolveInt64(circuitFailureThreshold, "CIRCUIT_FAILURE_THRESHOLD", defaults.CircuitFailureThreshold),
		CircuitOpenDuration:     resolveDuration(circuitOpenDuration, "CIRCUIT_OPEN_DURATION", defaults.CircuitOpenDuration),
		HealthFailThreshold:     resolveInt64(healthFailThreshold, "HEALTH_FAIL_THRESHOLD", defaults.HealthFailThreshold),
		HealthSuccessThreshold:  resolveInt64(healthSuccessThreshold, "HEALTH_SUCCESS_THRESHOLD", defaults.HealthSuccessThreshold),
	}
	normalizeConfig(&lbConfig)

	drainDelay = resolveDuration(drainDelay, "DRAIN_DELAY", 5*time.Second)
	shutdownTimeout = resolveDuration(shutdownTimeout, "SHUTDOWN_TIMEOUT", 15*time.Second)

	metrics := NewLBMetrics()
	backends := splitCSV(backendList)
	lb, err := NewLoadBalancerWithConfig(backends, strategy, lbConfig, metrics)
	if err != nil {
		log.Fatal(err)
	}

	authConfig, err := AuthConfigFromEnv()
	if err != nil {
		log.Fatal(err)
	}
	authenticator := NewAuthenticator(authConfig)

	rateLimitConfig := RateLimitConfigFromEnv()
	rateLimiter := NewRateLimiter(rateLimitConfig)

	costConfig := CostConfigFromEnv()
	costTracker := NewCostTracker(costConfig)

	aiSystem := NewAISystem(lb, metrics, AIConfigFromEnv())
	aiSystem.SetCostTracker(costTracker)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go lb.StartHealthChecks(ctx, healthInterval, healthTimeout, healthPath)

	normalizedProxyPrefix, err := normalizePrefix(proxyPrefix)
	if err != nil {
		log.Fatal(err)
	}
	frontendHandler := NewFrontendHandler(normalizedProxyPrefix)

	appHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/healthz":
			if r.Method != http.MethodGet {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			if lb.IsDraining() {
				w.WriteHeader(http.StatusServiceUnavailable)
				w.Write([]byte(`{"status":"draining"}`))
				return
			}
			w.Write([]byte(`{"status":"ok"}`))
		case r.URL.Path == "/metrics":
			metrics.Handler(w, r)
		case r.URL.Path == "/ai/status":
			aiSystem.StatusHandler(w, r)
		case r.URL.Path == "/ai/analyze":
			aiSystem.AnalyzeHandler(w, r)
		case r.URL.Path == "/admin/backends":
			lb.BackendsHandler(w, r)
		case r.URL.Path == "/admin/strategy":
			lb.StrategyHandler(w, r)
		case r.URL.Path == "/admin/cost":
			costTracker.Handler(w, r)
		case r.URL.Path == "/config.js":
			if r.Method != http.MethodGet {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
			w.Write([]byte("window.__MINILB_CONFIG = { proxyPrefix: '" + normalizedProxyPrefix + "', aiProvider: '" + aiSystem.ProviderName() + "' };"))
		case r.URL.Path == normalizedProxyPrefix:
			http.Redirect(w, r, normalizedProxyPrefix+"/", http.StatusPermanentRedirect)
		case strings.HasPrefix(r.URL.Path, normalizedProxyPrefix+"/"):
			proxyReq := r.Clone(r.Context())
			proxyURL := *r.URL
			strippedPath := strings.TrimPrefix(r.URL.Path, normalizedProxyPrefix)
			if strippedPath == "" {
				strippedPath = "/"
			}
			proxyURL.Path = strippedPath
			if r.URL.RawPath != "" {
				raw := strings.TrimPrefix(r.URL.RawPath, normalizedProxyPrefix)
				if raw == "" {
					raw = "/"
				}
				proxyURL.RawPath = raw
			}
			proxyReq.URL = &proxyURL
			lb.ServeHTTP(w, proxyReq)
		default:
			if enableFrontend {
				frontendHandler.ServeHTTP(w, r)
				return
			}
			lb.ServeHTTP(w, r)
		}
	})

	routeLabeler := func(r *http.Request) string {
		path := r.URL.Path
		switch {
		case path == "/healthz":
			return "/healthz"
		case path == "/metrics":
			return "/metrics"
		case strings.HasPrefix(path, "/ai/"):
			return "/ai/*"
		case strings.HasPrefix(path, "/admin/"):
			return "/admin/*"
		case path == normalizedProxyPrefix || strings.HasPrefix(path, normalizedProxyPrefix+"/"):
			return normalizedProxyPrefix + "/*"
		case path == "/config.js" || path == "/app.js" || path == "/styles.css" || path == "/robots.txt":
			return "/frontend_asset"
		default:
			return "/frontend"
		}
	}

	protectedRoute := func(r *http.Request) bool {
		path := r.URL.Path
		return strings.HasPrefix(path, "/admin/") || path == "/metrics"
	}

	var handler http.Handler = appHandler
	handler = authenticator.Middleware(handler, protectedRoute)
	handler = withRateLimit(handler, rateLimiter)
	handler = withAccessLogAndMetrics(handler, metrics, routeLabeler)
	handler = costTracker.Middleware(handler)
	handler = withTraceContext(handler)
	handler = withRequestID(handler)
	handler = withRecovery(handler)

	server := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
		sig := <-signals

		logJSON(map[string]any{
			"event":  "shutdown_signal",
			"signal": sig.String(),
		})

		lb.StartDrain()
		if drainDelay > 0 {
			time.Sleep(drainDelay)
		}

		cancel()
		shutdownCtx, stop := context.WithTimeout(context.Background(), shutdownTimeout)
		defer stop()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutdown error: %v", err)
		}
	}()

	logJSON(map[string]any{
		"event":                     "startup",
		"addr":                      addr,
		"strategy":                  strategy,
		"proxy_prefix":              normalizedProxyPrefix,
		"frontend_enabled":          enableFrontend,
		"auth_mode":                 authConfig.Mode,
		"rate_limit_enabled":        rateLimitConfig.Enabled,
		"rate_limit_rps":            rateLimitConfig.RPS,
		"rate_limit_burst":          rateLimitConfig.Burst,
		"cost_awareness_enabled":    costConfig.Enabled,
		"max_retries":               lbConfig.MaxRetries,
		"retry_backoff":             lbConfig.RetryBackoff.String(),
		"upstream_timeout":          lbConfig.UpstreamTimeout.String(),
		"circuit_failure_threshold": lbConfig.CircuitFailureThreshold,
		"circuit_open_duration":     lbConfig.CircuitOpenDuration.String(),
		"health_fail_threshold":     lbConfig.HealthFailThreshold,
		"health_success_threshold":  lbConfig.HealthSuccessThreshold,
		"drain_delay":               drainDelay.String(),
		"shutdown_timeout":          shutdownTimeout.String(),
	})

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func splitCSV(raw string) []string {
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func normalizePrefix(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", errors.New("proxy prefix cannot be empty")
	}
	if !strings.HasPrefix(value, "/") {
		value = "/" + value
	}
	if strings.HasSuffix(value, "/") {
		value = strings.TrimSuffix(value, "/")
	}
	if value == "" {
		return "", errors.New("proxy prefix cannot be /")
	}
	return value, nil
}

func resolveInt(flagValue int, envName string, fallback int) int {
	if flagValue >= 0 {
		return flagValue
	}
	raw := strings.TrimSpace(os.Getenv(envName))
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return value
}

func resolveInt64(flagValue int64, envName string, fallback int64) int64 {
	if flagValue > 0 {
		return flagValue
	}
	raw := strings.TrimSpace(os.Getenv(envName))
	if raw == "" {
		return fallback
	}
	value, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return fallback
	}
	return value
}

func resolveDuration(flagValue time.Duration, envName string, fallback time.Duration) time.Duration {
	if flagValue >= 0 {
		return flagValue
	}
	raw := strings.TrimSpace(os.Getenv(envName))
	if raw == "" {
		return fallback
	}
	value, err := time.ParseDuration(raw)
	if err != nil {
		return fallback
	}
	return value
}
