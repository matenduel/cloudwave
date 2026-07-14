package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	workerCount   = 5
	executionTime = 20 * time.Millisecond
)

type queryJob struct {
	Key      string
	QueuedAt time.Time
	Done     chan queryResult
}

type queryResult struct {
	Payload []byte
	Err     error
}

var (
	jobs = make(chan queryJob, 10000)

	queryDuration = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "db_query_duration_seconds",
			Help:    "End-to-end backend query duration, including FIFO worker queue waiting time.",
			Buckets: prometheus.ExponentialBuckets(0.005, 2, 12),
		},
	)

	executionDuration = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "db_query_execution_duration_seconds",
			Help:    "Pure backend execution duration after a worker starts processing. This remains near 20ms.",
			Buckets: prometheus.ExponentialBuckets(0.005, 1.5, 10),
		},
	)

	queueDepth = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "db_worker_queue_depth",
			Help: "Current number of requests waiting in the backend FIFO queue.",
		},
	)

	logMu sync.Mutex
)

func main() {
	prometheus.MustRegister(queryDuration, executionDuration, queueDepth)

	for i := 0; i < workerCount; i++ {
		go worker(i)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/query", queryHandler)
	mux.Handle("/metrics", promhttp.Handler())

	server := &http.Server{
		Addr:              ":8081",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Println("mock backend listening on :8081 with 5 FIFO workers")
	log.Fatal(server.ListenAndServe())
}

func worker(id int) {
	for job := range jobs {
		queueDepth.Set(float64(len(jobs)))

		workerStart := time.Now()
		queueWait := workerStart.Sub(job.QueuedAt)

		executionStart := time.Now()
		time.Sleep(executionTime)
		executionElapsed := time.Since(executionStart)
		totalElapsed := time.Since(job.QueuedAt)

		executionDuration.Observe(executionElapsed.Seconds())
		queryDuration.Observe(totalElapsed.Seconds())

		payload, err := json.Marshal(map[string]any{
			"key":       job.Key,
			"value":     "backend-value-for-" + job.Key,
			"worker_id": id,
		})

		writeJSONLog(map[string]any{
			"ts":                   time.Now().UTC().Format(time.RFC3339Nano),
			"component":            "backend",
			"event":                "query_complete",
			"key":                  job.Key,
			"worker_id":            id,
			"queue_wait_ms":        float64(queueWait.Microseconds()) / 1000,
			"execution_duration_ms": float64(executionElapsed.Microseconds()) / 1000,
			"total_duration_ms":    float64(totalElapsed.Microseconds()) / 1000,
		})

		job.Done <- queryResult{Payload: payload, Err: err}
	}
}

func queryHandler(w http.ResponseWriter, r *http.Request) {
	key := r.URL.Query().Get("key")
	if key == "" {
		key = "hot-1"
	}

	done := make(chan queryResult, 1)
	job := queryJob{
		Key:      key,
		QueuedAt: time.Now(),
		Done:     done,
	}

	jobs <- job
	queueDepth.Set(float64(len(jobs)))

	result := <-done
	if result.Err != nil {
		http.Error(w, result.Err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Backend-Workers", strconv.Itoa(workerCount))
	_, _ = w.Write(result.Payload)
}

func writeJSONLog(entry map[string]any) {
	path := os.Getenv("LOG_PATH")
	if path == "" {
		path = "/logs/backend.jsonl"
	}

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
