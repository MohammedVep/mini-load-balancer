package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAuthenticatorHS256MiddlewareAllowsProtectedRoute(t *testing.T) {
	secret := "unit-test-secret"
	auth := NewAuthenticator(AuthConfig{
		Mode:          "jwt_hs256",
		JWTHMACSecret: secret,
	})

	var gotSubject string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims := AuthClaimsFromContext(r.Context())
		if value, ok := claims["sub"].(string); ok {
			gotSubject = value
		}
		w.WriteHeader(http.StatusNoContent)
	})
	protected := func(r *http.Request) bool {
		return strings.HasPrefix(r.URL.Path, "/admin/")
	}
	handler := auth.Middleware(next, protected)

	token := buildHS256JWT(t, secret, map[string]any{
		"sub": "candidate-42",
		"exp": time.Now().Add(2 * time.Minute).Unix(),
	})

	req := httptest.NewRequest(http.MethodGet, "/admin/backends", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", rec.Code)
	}
	if gotSubject != "candidate-42" {
		t.Fatalf("expected authenticated claims in context, got %q", gotSubject)
	}
}

func TestAuthenticatorRejectsMissingToken(t *testing.T) {
	auth := NewAuthenticator(AuthConfig{
		Mode:          "jwt_hs256",
		JWTHMACSecret: "secret",
	})
	handler := auth.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}), func(r *http.Request) bool { return strings.HasPrefix(r.URL.Path, "/admin/") })

	req := httptest.NewRequest(http.MethodGet, "/admin/strategy", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for protected route without token, got %d", rec.Code)
	}
}

func TestAuthenticatorSkipsUnprotectedRoute(t *testing.T) {
	auth := NewAuthenticator(AuthConfig{
		Mode:          "jwt_hs256",
		JWTHMACSecret: "secret",
	})
	handler := auth.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}), func(r *http.Request) bool { return strings.HasPrefix(r.URL.Path, "/admin/") })

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected unprotected route to bypass auth, got %d", rec.Code)
	}
}

func TestRateLimiterAllowAndRefill(t *testing.T) {
	limiter := NewRateLimiter(RateLimitConfig{
		Enabled: true,
		RPS:     1,
		Burst:   1,
	})
	now := time.Now()

	if !limiter.Allow("10.0.0.10", now) {
		t.Fatal("expected first request to pass")
	}
	if limiter.Allow("10.0.0.10", now) {
		t.Fatal("expected second immediate request to be blocked")
	}
	if !limiter.Allow("10.0.0.10", now.Add(1200*time.Millisecond)) {
		t.Fatal("expected request after refill interval to pass")
	}
}

func TestRateLimitMiddlewareBypassesHealthz(t *testing.T) {
	limiter := NewRateLimiter(RateLimitConfig{
		Enabled: true,
		RPS:     1,
		Burst:   1,
	})

	handler := withRateLimit(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}), limiter)

	req1 := httptest.NewRequest(http.MethodGet, "/proxy/test", nil)
	req1.RemoteAddr = "10.0.0.1:12345"
	rec1 := httptest.NewRecorder()
	handler.ServeHTTP(rec1, req1)
	if rec1.Code != http.StatusOK {
		t.Fatalf("expected first non-health request to pass, got %d", rec1.Code)
	}

	req2 := httptest.NewRequest(http.MethodGet, "/proxy/test", nil)
	req2.RemoteAddr = "10.0.0.1:12345"
	rec2 := httptest.NewRecorder()
	handler.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusTooManyRequests {
		t.Fatalf("expected second non-health request to be limited, got %d", rec2.Code)
	}

	reqHealth := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	reqHealth.RemoteAddr = "10.0.0.1:12345"
	recHealth := httptest.NewRecorder()
	handler.ServeHTTP(recHealth, reqHealth)
	if recHealth.Code != http.StatusOK {
		t.Fatalf("expected healthz to bypass rate limiting, got %d", recHealth.Code)
	}
}

func TestWithRecoveryCatchesPanic(t *testing.T) {
	handler := withRecovery(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		panic("boom")
	}))

	req := httptest.NewRequest(http.MethodGet, "/panic", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500 when panic is recovered, got %d", rec.Code)
	}
}

func TestWithTraceContextUsesHeader(t *testing.T) {
	traceID := "4bf92f3577b34da6a3ce929d0e0e4736"
	var ctxTrace string
	handler := withTraceContext(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctxTrace = TraceIDFromContext(r.Context())
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodGet, "/trace", nil)
	req.Header.Set("X-Trace-ID", traceID)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", rec.Code)
	}
	if ctxTrace != traceID {
		t.Fatalf("expected context trace id %q, got %q", traceID, ctxTrace)
	}
	if rec.Header().Get("X-Trace-ID") != traceID {
		t.Fatalf("expected response to expose trace id %q, got %q", traceID, rec.Header().Get("X-Trace-ID"))
	}
}

func TestWithTraceContextParsesTraceparent(t *testing.T) {
	traceID := "4bf92f3577b34da6a3ce929d0e0e4736"
	var got string
	handler := withTraceContext(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = TraceIDFromContext(r.Context())
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodGet, "/trace", nil)
	req.Header.Set("traceparent", "00-"+traceID+"-00f067aa0ba902b7-01")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if got != traceID {
		t.Fatalf("expected trace id parsed from traceparent %q, got %q", traceID, got)
	}
}

func TestCostTrackerMiddlewareAndSnapshot(t *testing.T) {
	tracker := NewCostTracker(CostConfig{
		Enabled:                true,
		RequestUSDPerMillion:   1.0,
		EgressUSDPerGB:         0,
		AIInputUSDPer1KTokens:  0.2,
		AIOutputUSDPer1KTokens: 0.4,
	})
	handler := tracker.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte("hello"))
	}))

	req := httptest.NewRequest(http.MethodPost, "/ai/analyze", strings.NewReader("abc"))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	tracker.RecordAIUsage(1000, 500)
	snapshot := tracker.Snapshot()

	if snapshot.HTTPRequestsTotal != 1 {
		t.Fatalf("expected 1 tracked request, got %d", snapshot.HTTPRequestsTotal)
	}
	if snapshot.IngressBytesTotal != 3 {
		t.Fatalf("expected ingress bytes 3, got %d", snapshot.IngressBytesTotal)
	}
	if snapshot.EgressBytesTotal != 5 {
		t.Fatalf("expected egress bytes 5, got %d", snapshot.EgressBytesTotal)
	}
	if snapshot.AIRequestsTotal != 1 || snapshot.AIInputTokensTotal != 1000 || snapshot.AIOutputTokensTotal != 500 {
		t.Fatalf("unexpected AI usage snapshot: %+v", snapshot)
	}
	// request cost + ai cost = 1e-6 + (0.2 + 0.2)
	expected := 0.400001
	if math.Abs(snapshot.EstimatedCostUSD-expected) > 0.00001 {
		t.Fatalf("unexpected estimated cost: got %f want %f", snapshot.EstimatedCostUSD, expected)
	}
}

func TestEstimateTokenCount(t *testing.T) {
	if got := estimateTokenCount(""); got != 0 {
		t.Fatalf("expected empty text to produce 0 tokens, got %d", got)
	}
	if got := estimateTokenCount("abcd"); got != 1 {
		t.Fatalf("expected 1 token estimate for 4 chars, got %d", got)
	}
	if got := estimateTokenCount("abcdefghij"); got != 3 {
		t.Fatalf("expected ceil(10/4)=3 tokens, got %d", got)
	}
}

func buildHS256JWT(t *testing.T, secret string, claims map[string]any) string {
	t.Helper()
	headerBytes, err := json.Marshal(map[string]string{
		"alg": "HS256",
		"typ": "JWT",
	})
	if err != nil {
		t.Fatal(err)
	}
	claimsBytes, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}

	encodedHeader := base64.RawURLEncoding.EncodeToString(headerBytes)
	encodedClaims := base64.RawURLEncoding.EncodeToString(claimsBytes)
	signingInput := encodedHeader + "." + encodedClaims

	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(signingInput))
	signature := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return signingInput + "." + signature
}

func TestTraceIDFromContextEmpty(t *testing.T) {
	if got := TraceIDFromContext(context.Background()); got != "" {
		t.Fatalf("expected empty trace id on context without value, got %q", got)
	}
}
