package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"sync/atomic"
	"time"
)

type contextKey string

const requestIDContextKey contextKey = "minilb_request_id"

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

func withAccessLogAndMetrics(next http.Handler, metrics *LBMetrics, routeLabeler func(*http.Request) string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		route := routeLabeler(r)
		requestID := RequestIDFromContext(r.Context())
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
