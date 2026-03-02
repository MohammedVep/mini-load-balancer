package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"time"
)

type contextKey string

const (
	requestIDContextKey contextKey = "minilb_request_id"
	traceIDContextKey   contextKey = "minilb_trace_id"
)

var requestIDCounter atomic.Uint64

func RequestIDFromContext(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	raw := ctx.Value(requestIDContextKey)
	value, ok := raw.(string)
	if !ok {
		return ""
	}
	return value
}

func TraceIDFromContext(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	raw := ctx.Value(traceIDContextKey)
	value, ok := raw.(string)
	if !ok {
		return ""
	}
	return value
}

func withRequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestID := r.Header.Get("X-Request-ID")
		if requestID == "" {
			requestID = generateRequestID()
		}

		w.Header().Set("X-Request-ID", requestID)
		ctx := context.WithValue(r.Context(), requestIDContextKey, requestID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func withTraceContext(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		traceID := traceIDFromRequest(r)
		if traceID == "" {
			traceID = randomHex(16)
		}

		if r.Header.Get("X-Trace-ID") == "" {
			r.Header.Set("X-Trace-ID", traceID)
		}
		if r.Header.Get("traceparent") == "" {
			r.Header.Set("traceparent", traceparentFromTraceID(traceID))
		}
		w.Header().Set("X-Trace-ID", traceID)

		ctx := context.WithValue(r.Context(), traceIDContextKey, traceID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func withAccessLogAndMetrics(next http.Handler, metrics *LBMetrics, routeLabeler func(*http.Request) string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		route := routeLabeler(r)
		requestID := RequestIDFromContext(r.Context())
		traceID := TraceIDFromContext(r.Context())
		recorder := &statusRecorder{ResponseWriter: w, statusCode: http.StatusOK}

		if metrics != nil {
			metrics.IncInFlight()
			defer metrics.DecInFlight()
		}

		next.ServeHTTP(recorder, r)
		duration := time.Since(start)

		if metrics != nil {
			metrics.RecordRequest(r.Method, route, recorder.statusCode, duration)
		}

		logJSON(map[string]any{
			"event":       "http_request",
			"request_id":  requestID,
			"trace_id":    traceID,
			"method":      r.Method,
			"path":        r.URL.Path,
			"route":       route,
			"status":      recorder.statusCode,
			"bytes":       recorder.bytes,
			"duration_ms": duration.Milliseconds(),
			"remote_ip":   remoteIP(r.RemoteAddr),
		})
	})
}

type statusRecorder struct {
	http.ResponseWriter
	statusCode int
	bytes      int
}

func (sr *statusRecorder) WriteHeader(statusCode int) {
	sr.statusCode = statusCode
	sr.ResponseWriter.WriteHeader(statusCode)
}

func (sr *statusRecorder) Write(payload []byte) (int, error) {
	if sr.statusCode == 0 {
		sr.statusCode = http.StatusOK
	}
	n, err := sr.ResponseWriter.Write(payload)
	sr.bytes += n
	return n, err
}

func generateRequestID() string {
	return fmt.Sprintf("%x-%x", time.Now().UTC().UnixNano(), requestIDCounter.Add(1))
}

func traceIDFromRequest(r *http.Request) string {
	if r == nil {
		return ""
	}
	if traceID := normalizeTraceID(r.Header.Get("X-Trace-ID")); traceID != "" {
		return traceID
	}
	if traceID := parseTraceparentTraceID(r.Header.Get("traceparent")); traceID != "" {
		return traceID
	}
	if traceID := parseAmazonTraceID(r.Header.Get("X-Amzn-Trace-Id")); traceID != "" {
		return traceID
	}
	return ""
}

func parseTraceparentTraceID(header string) string {
	header = strings.TrimSpace(header)
	if header == "" {
		return ""
	}
	parts := strings.Split(header, "-")
	if len(parts) < 4 {
		return ""
	}
	return normalizeTraceID(parts[1])
}

func parseAmazonTraceID(header string) string {
	for _, token := range strings.Split(header, ";") {
		token = strings.TrimSpace(token)
		if !strings.HasPrefix(token, "Root=") {
			continue
		}
		root := strings.TrimPrefix(token, "Root=")
		parts := strings.Split(root, "-")
		if len(parts) != 3 {
			continue
		}
		return normalizeTraceID(parts[1] + parts[2])
	}
	return ""
}

func normalizeTraceID(raw string) string {
	value := strings.ToLower(strings.TrimSpace(raw))
	if value == "" {
		return ""
	}
	value = strings.ReplaceAll(value, "-", "")
	switch len(value) {
	case 16:
		if isLowerHex(value) {
			return strings.Repeat("0", 16) + value
		}
	case 32:
		if isLowerHex(value) {
			return value
		}
	}
	return ""
}

func isLowerHex(value string) bool {
	for _, ch := range value {
		if (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') {
			continue
		}
		return false
	}
	return true
}

func traceparentFromTraceID(traceID string) string {
	traceID = normalizeTraceID(traceID)
	if traceID == "" {
		traceID = randomHex(16)
	}
	return "00-" + traceID + "-" + randomHex(8) + "-01"
}

func remoteIP(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err == nil {
		return host
	}
	return remoteAddr
}

func logJSON(fields map[string]any) {
	fields["timestamp_utc"] = time.Now().UTC().Format(time.RFC3339Nano)
	payload, err := json.Marshal(fields)
	if err != nil {
		log.Printf("{\"event\":\"log_error\",\"error\":%q}", err.Error())
		return
	}
	log.Print(string(payload))
}
