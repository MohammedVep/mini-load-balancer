package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

type backendDemoServer struct {
	name      string
	startedAt time.Time
	requests  atomic.Uint64
}

func runBackendDemoServer(addr, backendName string) {
	demo := &backendDemoServer{
		name:      backendName,
		startedAt: time.Now().UTC(),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", demo.rootHandler)
	mux.HandleFunc("/whoami", demo.rootHandler)
	mux.HandleFunc("/health", demo.healthHandler)
	mux.HandleFunc("/healthz", demo.healthHandler)

	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
		<-signals

		shutdownCtx, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("backend demo shutdown error: %v", err)
		}
	}()

	log.Printf("backend demo service listening on %s name=%s", addr, backendName)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (d *backendDemoServer) rootHandler(w http.ResponseWriter, r *http.Request) {
	seq := d.requests.Add(1)
	clientIP := strings.TrimSpace(r.RemoteAddr)
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		clientIP = host
	}

	writeJSON(w, map[string]any{
		"service":          "backend_demo",
		"backend_name":     d.name,
		"request_sequence": seq,
		"method":           r.Method,
		"path":             r.URL.Path,
		"query":            r.URL.RawQuery,
		"remote_addr":      r.RemoteAddr,
		"client_ip":        clientIP,
		"x_forwarded_for":  r.Header.Get("X-Forwarded-For"),
		"timestamp_utc":    time.Now().UTC().Format(time.RFC3339),
		"uptime_seconds":   int(time.Since(d.startedAt).Seconds()),
	})
}

func (d *backendDemoServer) healthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{
		"status":         "ok",
		"service":        "backend_demo",
		"backend_name":   d.name,
		"uptime_seconds": int(time.Since(d.startedAt).Seconds()),
	})
}

func writeJSON(w http.ResponseWriter, payload map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.Encode(payload)
}
