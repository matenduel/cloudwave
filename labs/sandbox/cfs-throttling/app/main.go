package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	requestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "End-to-end request duration. CFS scheduling delay is included.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 30},
		},
		[]string{"route", "status"},
	)
	requestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{Name: "http_requests_total", Help: "HTTP requests completed."},
		[]string{"route", "status"},
	)
	logMu sync.Mutex
)

func main() {
	// Keep several runnable goroutines during a burst. The 0.50 CPU cgroup quota,
	// not application serialization, is deliberately the limiting scheduler.
	runtime.GOMAXPROCS(4)

	mux := http.NewServeMux()
	mux.HandleFunc("/work", workHandler)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.Handle("/metrics", promhttp.Handler())

	log.Println("cfs-throttling app listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}

func workHandler(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	cpuMS := parseCPUMS(r.URL.Query().Get("cpu_ms"))
	busyFor(time.Duration(cpuMS) * time.Millisecond)

	duration := time.Since(started)
	requestDuration.WithLabelValues("/work", "200").Observe(duration.Seconds())
	requestsTotal.WithLabelValues("/work", "200").Inc()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "cpu_ms": cpuMS})

	writeJSONLog(map[string]any{
		"ts":          time.Now().UTC().Format(time.RFC3339Nano),
		"component":   "app",
		"event":       "request",
		"route":       "/work",
		"cpu_work_ms": cpuMS,
		"duration_ms": float64(duration.Microseconds()) / 1000,
		"status":      200,
	})
}

func parseCPUMS(raw string) int {
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return 20
	}
	if value > 500 {
		return 500
	}
	return value
}

// busyFor consumes CPU instead of sleeping. The volatile-looking accumulator is
// returned to a package variable so the compiler cannot discard the loop.
var sink uint64

func busyFor(d time.Duration) {
	// Wall time is wrong under CFS: a throttled goroutine's deadline expires
	// while it is descheduled. Pin it and use Linux RUSAGE_THREAD so every
	// request really consumes the requested CPU time before it completes.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	target := threadCPUTime() + d
	var x uint64 = uint64(time.Now().UnixNano())
	for threadCPUTime() < target {
		x = x*1664525 + 1013904223
	}
	sink = x
}

func threadCPUTime() time.Duration {
	var usage syscall.Rusage
	// RUSAGE_THREAD is 1 in the Linux kernel ABI. This image is Linux-only.
	if err := syscall.Getrusage(1, &usage); err != nil {
		return 0
	}
	return time.Duration(usage.Utime.Sec)*time.Second +
		time.Duration(usage.Utime.Usec)*time.Microsecond +
		time.Duration(usage.Stime.Sec)*time.Second +
		time.Duration(usage.Stime.Usec)*time.Microsecond
}

func writeJSONLog(entry map[string]any) {
	path := os.Getenv("LOG_PATH")
	if path == "" {
		path = "/logs/app.jsonl"
	}
	line, err := json.Marshal(entry)
	if err != nil {
		return
	}

	logMu.Lock()
	defer logMu.Unlock()
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err == nil {
		_, _ = file.Write(append(line, '\n'))
		_ = file.Close()
	}
}
