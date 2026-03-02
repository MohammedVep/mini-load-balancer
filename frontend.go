package main

import (
	"embed"
	"io/fs"
	"net/http"
	"net/url"
	"path"
	"strings"
)

//go:embed web/*
var frontendAssets embed.FS

type FrontendHandler struct {
	fileServer  http.Handler
	indexHTML   []byte
	proxyPrefix string
}

func NewFrontendHandler(proxyPrefix string) http.Handler {
	root, err := fs.Sub(frontendAssets, "web")
	if err != nil {
		return http.NotFoundHandler()
	}
	indexHTML, err := fs.ReadFile(root, "index.html")
	if err != nil {
		return http.NotFoundHandler()
	}
	return &FrontendHandler{
		fileServer:  http.FileServer(http.FS(root)),
		indexHTML:   indexHTML,
		proxyPrefix: proxyPrefix,
	}
}

func (h *FrontendHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/":
		h.serveIndex(w)
	case r.URL.Path == "/app.js":
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		h.serveFile(w, r, "/app.js")
	case r.URL.Path == "/styles.css":
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		h.serveFile(w, r, "/styles.css")
	case r.URL.Path == "/robots.txt":
		h.serveFile(w, r, "/robots.txt")
	case strings.HasPrefix(r.URL.Path, h.proxyPrefix+"/"):
		http.NotFound(w, r)
	default:
		// Single-page-app fallback to index for recruiter-facing routes.
		h.serveIndex(w)
	}
}

func (h *FrontendHandler) serveIndex(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	w.Write(h.indexHTML)
}

func (h *FrontendHandler) serveFile(w http.ResponseWriter, r *http.Request, requestedPath string) {
	clean := path.Clean(requestedPath)
	if clean == "." || clean == "/" {
		clean = "/index.html"
	}
	clone := r.Clone(r.Context())
	clone.URL = copyURL(r.URL)
	clone.URL.Path = clean
	h.fileServer.ServeHTTP(w, clone)
}

func copyURL(src *url.URL) *url.URL {
	if src == nil {
		return &url.URL{}
	}
	copy := *src
	return &copy
}
