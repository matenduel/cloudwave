package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
)

const (
	cacheTTL = 90 * time.Second
)

var hotKeys = []string{
	"hot-1", "hot-2", "hot-3", "hot-4", "hot-5", "hot-6",
	"hot-7", "hot-8", "hot-9", "hot-10", "hot-11", "hot-12",
}

var (
	redisClient *redis.Client
	backendURL  string
	httpClient  = &http.Client{Timeout: 30 * time.Second}
	logMu       sync.Mutex

	cacheRequests = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "app_cache_requests_total",
			Help: "Application cache requests by outcome.",
		},
		[]string{"outcome"},
	)

	requestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "app_request_duration_seconds",
			Help:    "Application request duration by cache outcome.",
			Buckets: prometheus.ExponentialBuckets(0.001, 2, 14),
		},
		[]string{"outcome"},
	)
)

func main() {
	redisAddr := envOr("REDIS_ADDR", "redis:6379")
	backendURL = envOr("BACKEND_URL", "http://backend:8081")

	redisClient = redis.NewClient(&redis.Options{
		Addr: redisAddr,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := redisClient.Ping(ctx).Err(); err != nil {
		log.Printf("initial Redis ping failed (will retry per request): %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/data", dataHandler)
	mux.HandleFunc("/admin/warm", warmHandler)
	mux.Handle("/metrics", promhttp.Handler())

	server := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Println("app listening on :8080")
	log.Fatal(server.ListenAndServe())
}

func dataHandler(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	key := r.URL.Query().Get("key")
	if key == "" {
		key = "hot-1"
	}

	ctx := r.Context()
	cacheKey := redisCacheKey(key)
	payload, err := redisClient.Get(ctx, cacheKey).Bytes()

	if err == nil {
		cacheRequests.WithLabelValues("hit").Inc()
		requestDuration.WithLabelValues("hit").Observe(time.Since(started).Seconds())

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Cache", "HIT")
		_, _ = w.Write(payload)

		writeJSONLog(map[string]any{
			"ts":          time.Now().UTC().Format(time.RFC3339Nano),
			"component":   "app",
			"event":       "request",
			"key":         key,
			"cache_status": "hit",
			"duration_ms": float64(time.Since(started).Microseconds()) / 1000,
		})
		return
	}

	if err != redis.Nil {
		http.Error(w, fmt.Sprintf("redis GET failed: %v", err), http.StatusServiceUnavailable)
		return
	}

	// Intentionally no singleflight, lock, double-check, stale response, or request coalescing.
	cacheRequests.WithLabelValues("miss").Inc()

	payload, err = fetchBackend(ctx, key)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	if err := redisClient.Set(ctx, cacheKey, payload, cacheTTL).Err(); err != nil {
		http.Error(w, fmt.Sprintf("redis SET failed: %v", err), http.StatusServiceUnavailable)
		return
	}

	requestDuration.WithLabelValues("miss").Observe(time.Since(started).Seconds())
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Cache", "MISS")
	_, _ = w.Write(payload)

	writeJSONLog(map[string]any{
		"ts":           time.Now().UTC().Format(time.RFC3339Nano),
		"component":    "app",
		"event":        "request",
		"key":          key,
		"cache_status": "miss",
		"duration_ms":  float64(time.Since(started).Microseconds()) / 1000,
	})
}

func warmHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	expiresAtMs, err := strconv.ParseInt(r.URL.Query().Get("expires_at_ms"), 10, 64)
	if err != nil || expiresAtMs <= time.Now().UnixMilli() {
		http.Error(w, "expires_at_ms must be a future Unix timestamp in milliseconds", http.StatusBadRequest)
		return
	}

	keys := parseKeys(r.URL.Query().Get("keys"))
	for _, key := range keys {
		payload, err := fetchBackend(ctx, key)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}

		// PXAT deliberately gives every key the exact same absolute expiry time.
		err = redisClient.Do(
			ctx,
			"SET",
			redisCacheKey(key),
			payload,
			"PXAT",
			strconv.FormatInt(expiresAtMs, 10),
		).Err()
		if err != nil {
			http.Error(w, fmt.Sprintf("redis PXAT SET failed: %v", err), http.StatusServiceUnavailable)
			return
		}
	}

	writeJSONLog(map[string]any{
		"ts":            time.Now().UTC().Format(time.RFC3339Nano),
		"component":     "app",
		"event":         "admin_warm",
		"keys":          keys,
		"expires_at_ms": expiresAtMs,
	})

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"status":        "warmed",
		"keys":          keys,
		"expires_at_ms": expiresAtMs,
	})
}

func fetchBackend(ctx context.Context, key string) ([]byte, error) {
	endpoint := backendURL + "/query?key=" + url.QueryEscape(key)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}

	response, err := httpClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	payload, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("backend returned %s: %s", response.Status, string(payload))
	}
	return payload, nil
}

func redisCacheKey(key string) string {
	return "cache:data:" + key
}

func parseKeys(raw string) []string {
	if raw == "" {
		return hotKeys
	}

	parts := strings.Split(raw, ",")
	keys := make([]string, 0, len(parts))
	for _, part := range parts {
		if key := strings.TrimSpace(part); key != "" {
			keys = append(keys, key)
		}
	}
	if len(keys) == 0 {
		return hotKeys
	}
	return keys
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func writeJSONLog(entry map[string]any) {
	path := envOr("LOG_PATH", "/logs/app.jsonl")
	line, err := json.Marshal(entry)
	if err != nil {
		return
	}

	logMu.Lock()
	defer logMu.Unlock()

	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer file.Close()

	_, _ = file.Write(append(line, '\n'))
}
