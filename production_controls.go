package main

import (
	"context"
	"crypto"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"net"
	"net/http"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
)

type AuthConfig struct {
	Mode            string
	JWTHMACSecret   string
	CognitoIssuer   string
	CognitoAudience string
}

func AuthConfigFromEnv() (AuthConfig, error) {
	cfg := AuthConfig{
		Mode:            strings.ToLower(firstNonEmpty(strings.TrimSpace(os.Getenv("AUTH_MODE")), "none")),
		JWTHMACSecret:   strings.TrimSpace(os.Getenv("AUTH_JWT_HMAC_SECRET")),
		CognitoIssuer:   strings.TrimSpace(os.Getenv("AUTH_COGNITO_ISSUER")),
		CognitoAudience: strings.TrimSpace(os.Getenv("AUTH_COGNITO_AUDIENCE")),
	}

	switch cfg.Mode {
	case "none":
		return cfg, nil
	case "jwt_hs256":
		if cfg.JWTHMACSecret == "" {
			return cfg, errors.New("AUTH_JWT_HMAC_SECRET is required when AUTH_MODE=jwt_hs256")
		}
		return cfg, nil
	case "cognito_jwt":
		if cfg.CognitoIssuer == "" {
			return cfg, errors.New("AUTH_COGNITO_ISSUER is required when AUTH_MODE=cognito_jwt")
		}
		return cfg, nil
	default:
		return cfg, errors.New("invalid AUTH_MODE: use none, jwt_hs256, or cognito_jwt")
	}
}

type Authenticator struct {
	config AuthConfig
	client *http.Client

	jwksMu      sync.Mutex
	jwks        map[string]*rsa.PublicKey
	jwksExpires time.Time
}

func NewAuthenticator(config AuthConfig) *Authenticator {
	return &Authenticator{
		config: config,
		client: &http.Client{Timeout: 6 * time.Second},
		jwks:   make(map[string]*rsa.PublicKey),
	}
}

func (a *Authenticator) Enabled() bool {
	return a != nil && a.config.Mode != "none"
}

func (a *Authenticator) Middleware(next http.Handler, protected func(*http.Request) bool) http.Handler {
	if !a.Enabled() {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if protected != nil && !protected(r) {
			next.ServeHTTP(w, r)
			return
		}

		token := bearerTokenFromRequest(r)
		if token == "" {
			writeUnauthorized(w, "missing bearer token")
			return
		}

		claims, err := a.validateToken(r.Context(), token)
		if err != nil {
			writeUnauthorized(w, "invalid token")
			logJSON(map[string]any{
				"event":      "auth_denied",
				"request_id": RequestIDFromContext(r.Context()),
				"trace_id":   TraceIDFromContext(r.Context()),
				"reason":     err.Error(),
				"path":       r.URL.Path,
			})
			return
		}

		ctx := context.WithValue(r.Context(), authClaimsContextKey, claims)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

type authClaimsContextKeyType string

const authClaimsContextKey authClaimsContextKeyType = "minilb_auth_claims"

func AuthClaimsFromContext(ctx context.Context) map[string]any {
	if ctx == nil {
		return nil
	}
	value, ok := ctx.Value(authClaimsContextKey).(map[string]any)
	if !ok {
		return nil
	}
	return value
}

func writeUnauthorized(w http.ResponseWriter, message string) {
	w.Header().Set("WWW-Authenticate", `Bearer realm="minilb"`)
	http.Error(w, message, http.StatusUnauthorized)
}

func bearerTokenFromRequest(r *http.Request) string {
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if auth == "" {
		return ""
	}
	const prefix = "Bearer "
	if len(auth) <= len(prefix) || !strings.EqualFold(auth[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(auth[len(prefix):])
}

func (a *Authenticator) validateToken(ctx context.Context, token string) (map[string]any, error) {
	header, claims, signingInput, signature, err := parseJWT(token)
	if err != nil {
		return nil, err
	}

	switch a.config.Mode {
	case "jwt_hs256":
		alg, _ := header["alg"].(string)
		if alg != "HS256" {
			return nil, errors.New("unsupported jwt algorithm")
		}
		if !verifyHS256Signature(signingInput, signature, a.config.JWTHMACSecret) {
			return nil, errors.New("jwt signature verification failed")
		}
		if err := validateRegisteredClaims(claims, "", a.config.CognitoAudience); err != nil {
			return nil, err
		}
		return claims, nil
	case "cognito_jwt":
		alg, _ := header["alg"].(string)
		if alg != "RS256" {
			return nil, errors.New("unsupported cognito jwt algorithm")
		}
		kid, _ := header["kid"].(string)
		if strings.TrimSpace(kid) == "" {
			return nil, errors.New("missing jwt kid")
		}

		pub, err := a.publicKeyForKid(ctx, kid)
		if err != nil {
			return nil, err
		}
		if err := verifyRS256Signature(signingInput, signature, pub); err != nil {
			return nil, err
		}
		if err := validateRegisteredClaims(claims, a.config.CognitoIssuer, a.config.CognitoAudience); err != nil {
			return nil, err
		}
		return claims, nil
	default:
		return nil, errors.New("auth disabled")
	}
}

func parseJWT(token string) (header map[string]any, claims map[string]any, signingInput string, signature []byte, err error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, nil, "", nil, errors.New("invalid jwt format")
	}
	signingInput = parts[0] + "." + parts[1]

	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, nil, "", nil, errors.New("invalid jwt header encoding")
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, nil, "", nil, errors.New("invalid jwt header")
	}

	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, nil, "", nil, errors.New("invalid jwt payload encoding")
	}
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return nil, nil, "", nil, errors.New("invalid jwt payload")
	}

	signature, err = base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, nil, "", nil, errors.New("invalid jwt signature encoding")
	}
	return header, claims, signingInput, signature, nil
}

func verifyHS256Signature(signingInput string, signature []byte, secret string) bool {
	h := hmac.New(sha256.New, []byte(secret))
	h.Write([]byte(signingInput))
	expected := h.Sum(nil)
	return hmac.Equal(signature, expected)
}

func verifyRS256Signature(signingInput string, signature []byte, publicKey *rsa.PublicKey) error {
	hash := sha256.Sum256([]byte(signingInput))
	return rsa.VerifyPKCS1v15(publicKey, crypto.SHA256, hash[:], signature)
}

func validateRegisteredClaims(claims map[string]any, expectedIssuer, expectedAudience string) error {
	now := time.Now().Unix()

	if exp, ok := numericClaim(claims, "exp"); ok && now >= exp {
		return errors.New("token expired")
	}
	if nbf, ok := numericClaim(claims, "nbf"); ok && now < nbf {
		return errors.New("token not yet valid")
	}
	if expectedIssuer != "" {
		iss, _ := claims["iss"].(string)
		if strings.TrimSpace(iss) != strings.TrimSpace(expectedIssuer) {
			return errors.New("invalid token issuer")
		}
	}
	if expectedAudience != "" && !audienceMatches(claims, expectedAudience) {
		return errors.New("invalid token audience")
	}
	return nil
}

func numericClaim(claims map[string]any, key string) (int64, bool) {
	value, found := claims[key]
	if !found {
		return 0, false
	}
	switch typed := value.(type) {
	case float64:
		return int64(typed), true
	case int64:
		return typed, true
	case json.Number:
		raw, err := typed.Int64()
		if err != nil {
			return 0, false
		}
		return raw, true
	default:
		return 0, false
	}
}

func audienceMatches(claims map[string]any, expected string) bool {
	expected = strings.TrimSpace(expected)
	if expected == "" {
		return true
	}

	// Cognito access token often uses client_id instead of aud.
	if clientID, ok := claims["client_id"].(string); ok && strings.TrimSpace(clientID) == expected {
		return true
	}

	aud, found := claims["aud"]
	if !found {
		return false
	}
	switch typed := aud.(type) {
	case string:
		return strings.TrimSpace(typed) == expected
	case []any:
		for _, item := range typed {
			value, ok := item.(string)
			if ok && strings.TrimSpace(value) == expected {
				return true
			}
		}
	}
	return false
}

func (a *Authenticator) publicKeyForKid(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	a.jwksMu.Lock()
	defer a.jwksMu.Unlock()

	now := time.Now()
	if now.After(a.jwksExpires) || len(a.jwks) == 0 {
		if err := a.refreshJWKS(ctx); err != nil {
			return nil, err
		}
	}

	key := a.jwks[kid]
	if key != nil {
		return key, nil
	}
	// Kid not found, force refresh once in case keys rotated.
	if err := a.refreshJWKS(ctx); err != nil {
		return nil, err
	}
	key = a.jwks[kid]
	if key == nil {
		return nil, errors.New("jwt key id not found")
	}
	return key, nil
}

func (a *Authenticator) refreshJWKS(ctx context.Context) error {
	issuer := strings.TrimRight(strings.TrimSpace(a.config.CognitoIssuer), "/")
	if issuer == "" {
		return errors.New("missing cognito issuer")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, issuer+"/.well-known/jwks.json", nil)
	if err != nil {
		return err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return errors.New("jwks request failed")
	}

	var parsed struct {
		Keys []struct {
			Kid string `json:"kid"`
			Kty string `json:"kty"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return err
	}

	keys := make(map[string]*rsa.PublicKey)
	for _, item := range parsed.Keys {
		if item.Kty != "RSA" || item.Kid == "" {
			continue
		}
		pub, err := rsaPublicKeyFromJWKS(item.N, item.E)
		if err != nil {
			continue
		}
		keys[item.Kid] = pub
	}
	if len(keys) == 0 {
		return errors.New("jwks contained no rsa keys")
	}

	a.jwks = keys
	a.jwksExpires = time.Now().Add(10 * time.Minute)
	return nil
}

func rsaPublicKeyFromJWKS(nEncoded, eEncoded string) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(nEncoded)
	if err != nil {
		return nil, err
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(eEncoded)
	if err != nil {
		return nil, err
	}
	if len(eBytes) == 0 {
		return nil, errors.New("invalid jwks exponent")
	}

	e := 0
	for _, b := range eBytes {
		e = (e << 8) + int(b)
	}
	if e <= 0 {
		return nil, errors.New("invalid rsa exponent")
	}
	return &rsa.PublicKey{
		N: new(big.Int).SetBytes(nBytes),
		E: e,
	}, nil
}

type RateLimitConfig struct {
	Enabled bool
	RPS     float64
	Burst   float64
}

func RateLimitConfigFromEnv() RateLimitConfig {
	cfg := RateLimitConfig{
		Enabled: true,
		RPS:     20,
		Burst:   40,
	}
	if raw := strings.TrimSpace(os.Getenv("RATE_LIMIT_ENABLED")); raw != "" {
		cfg.Enabled = strings.EqualFold(raw, "true") || raw == "1" || strings.EqualFold(raw, "yes")
	}
	if raw := strings.TrimSpace(os.Getenv("RATE_LIMIT_RPS")); raw != "" {
		if value, err := strconv.ParseFloat(raw, 64); err == nil && value > 0 {
			cfg.RPS = value
		}
	}
	if raw := strings.TrimSpace(os.Getenv("RATE_LIMIT_BURST")); raw != "" {
		if value, err := strconv.ParseFloat(raw, 64); err == nil && value > 0 {
			cfg.Burst = value
		}
	}
	return cfg
}

type tokenBucket struct {
	tokens     float64
	lastRefill time.Time
	lastSeen   time.Time
}

type RateLimiter struct {
	config      RateLimitConfig
	mu          sync.Mutex
	buckets     map[string]*tokenBucket
	lastCleanup time.Time
}

func NewRateLimiter(config RateLimitConfig) *RateLimiter {
	return &RateLimiter{
		config:      config,
		buckets:     make(map[string]*tokenBucket),
		lastCleanup: time.Now(),
	}
}

func withRateLimit(next http.Handler, limiter *RateLimiter) http.Handler {
	if limiter == nil || !limiter.config.Enabled {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Keep health endpoint available for platform probes.
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}

		ip := clientIPFromRequest(r)
		if !limiter.Allow(ip, time.Now()) {
			w.Header().Set("Retry-After", "1")
			http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
			logJSON(map[string]any{
				"event":      "rate_limited",
				"request_id": RequestIDFromContext(r.Context()),
				"trace_id":   TraceIDFromContext(r.Context()),
				"path":       r.URL.Path,
				"ip":         ip,
			})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (rl *RateLimiter) Allow(key string, now time.Time) bool {
	if !rl.config.Enabled {
		return true
	}
	if strings.TrimSpace(key) == "" {
		key = "unknown"
	}

	rl.mu.Lock()
	defer rl.mu.Unlock()

	bucket := rl.buckets[key]
	if bucket == nil {
		bucket = &tokenBucket{
			tokens:     math.Max(0, rl.config.Burst-1),
			lastRefill: now,
			lastSeen:   now,
		}
		rl.buckets[key] = bucket
		rl.cleanup(now)
		return true
	}

	elapsed := now.Sub(bucket.lastRefill).Seconds()
	if elapsed > 0 {
		refilled := bucket.tokens + elapsed*rl.config.RPS
		if refilled > rl.config.Burst {
			refilled = rl.config.Burst
		}
		bucket.tokens = refilled
		bucket.lastRefill = now
	}
	bucket.lastSeen = now

	allowed := bucket.tokens >= 1
	if allowed {
		bucket.tokens -= 1
	}
	rl.cleanup(now)
	return allowed
}

func (rl *RateLimiter) cleanup(now time.Time) {
	if now.Sub(rl.lastCleanup) < 1*time.Minute {
		return
	}
	ttl := 5 * time.Minute
	for key, bucket := range rl.buckets {
		if now.Sub(bucket.lastSeen) > ttl {
			delete(rl.buckets, key)
		}
	}
	rl.lastCleanup = now
}

func clientIPFromRequest(r *http.Request) string {
	if forwarded := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); forwarded != "" {
		parts := strings.Split(forwarded, ",")
		if len(parts) > 0 {
			ip := strings.TrimSpace(parts[0])
			if ip != "" {
				return ip
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return strings.TrimSpace(r.RemoteAddr)
}

func withRecovery(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				logJSON(map[string]any{
					"event":      "panic_recovered",
					"request_id": RequestIDFromContext(r.Context()),
					"trace_id":   TraceIDFromContext(r.Context()),
					"path":       r.URL.Path,
					"panic":      recovered,
					"stack":      string(debug.Stack()),
				})
				http.Error(w, "internal server error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func randomHex(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		// Fallback to time-based string if entropy source fails.
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(buf)
}
