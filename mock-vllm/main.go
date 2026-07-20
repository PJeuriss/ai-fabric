// mock-vLLM — a GPU-less stand-in for a vLLM model server.
//
// It speaks the OpenAI completions API and exposes vLLM-style Prometheus metrics
// (vllm:num_requests_waiting, etc.) so the llm-d EPP can score it. Crucially,
// each pod is pinned to a *simulated* fabric node (FABRIC_NODE) and asks the
// Fabric State Service how good its network position is; it then adds latency
// proportional to network distance/congestion. Result: routing to well-placed
// pods is measurably faster, which is exactly what the fabric scorer optimizes.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
func envF(k string, def float64) float64 {
	if v := os.Getenv(k); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

type server struct {
	fabricNode  string
	ingressNode string
	fssURL      string
	model       string

	baseMS    float64
	queueMS   float64 // per in-flight request
	fabricMS  float64 // scaled by (1 - fabricScore)
	kvMS      float64 // scaled by kv usage
	maxConc   float64

	running int64
	waiting int64

	// fabric score cache (updated in the background)
	scoreMu sync.RWMutex
	score   float64

	// latency histogram (manual, so we can also emit vllm: colon metrics)
	hMu      sync.Mutex
	buckets  []float64
	counts   []int64
	sum      float64
	count    int64
}

func newServer() *server {
	return &server{
		fabricNode:  env("FABRIC_NODE", "gpu-0001"),
		ingressNode: env("INGRESS_NODE", "gpu-0001"),
		fssURL:      env("FSS_URL", "http://fabric-state-service.ai-fabric-system:8080"),
		model:       env("MODEL_NAME", "meta-llama/Llama-3.1-8B-Instruct"),
		baseMS:      envF("BASE_LATENCY_MS", 40),
		queueMS:     envF("QUEUE_PENALTY_MS", 8),
		fabricMS:    envF("FABRIC_PENALTY_MS", 300),
		kvMS:        envF("KV_PENALTY_MS", 60),
		maxConc:     envF("MAX_CONCURRENCY", 32),
		score:       0.5,
		buckets:     []float64{0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
	}
	// counts sized in run()
}

// pollFabricScore refreshes the cached network score for this pod's location.
func (s *server) pollFabricScore(ctx context.Context) {
	client := &http.Client{Timeout: 3 * time.Second}
	url := fmt.Sprintf("%s/api/v1/cost?from=%s&to=%s", s.fssURL, s.ingressNode, s.fabricNode)
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	refresh := func() {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		resp, err := client.Do(req)
		if err != nil {
			return
		}
		defer resp.Body.Close()
		var cr struct {
			Score float64 `json:"score"`
		}
		if json.NewDecoder(resp.Body).Decode(&cr) == nil {
			s.scoreMu.Lock()
			s.score = cr.Score
			s.scoreMu.Unlock()
		}
	}
	refresh()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			refresh()
		}
	}
}

func (s *server) fabricScore() float64 {
	s.scoreMu.RLock()
	defer s.scoreMu.RUnlock()
	return s.score
}

func (s *server) kvUsage() float64 {
	r := float64(atomic.LoadInt64(&s.running))
	u := r / s.maxConc
	if u > 1 {
		u = 1
	}
	return u
}

func (s *server) observe(sec float64) {
	s.hMu.Lock()
	defer s.hMu.Unlock()
	s.sum += sec
	s.count++
	for i, b := range s.buckets {
		if sec <= b {
			s.counts[i]++
		}
	}
}

func (s *server) handleCompletion(w http.ResponseWriter, r *http.Request) {
	atomic.AddInt64(&s.waiting, 1)
	start := time.Now()
	// simulate admission: move from waiting -> running
	atomic.AddInt64(&s.waiting, -1)
	running := atomic.AddInt64(&s.running, 1)
	defer atomic.AddInt64(&s.running, -1)

	score := s.fabricScore()
	delayMS := s.baseMS +
		s.queueMS*float64(running-1) +
		s.fabricMS*(1-score) +
		s.kvMS*s.kvUsage()
	// +-10% jitter
	delayMS *= 0.9 + 0.2*rand.Float64()
	time.Sleep(time.Duration(delayMS) * time.Millisecond)

	latency := time.Since(start).Seconds()
	s.observe(latency)

	resp := map[string]interface{}{
		"id":      fmt.Sprintf("cmpl-%d", time.Now().UnixNano()),
		"object":  "text_completion",
		"created": time.Now().Unix(),
		"model":   s.model,
		"choices": []map[string]interface{}{{
			"index": 0, "text": " (simulated response)", "finish_reason": "stop",
		}},
		"usage": map[string]int{"prompt_tokens": 32, "completion_tokens": 16, "total_tokens": 48},
		"x_fabric": map[string]interface{}{
			"node": s.fabricNode, "score": score, "latency_ms": math.Round(delayMS),
		},
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func (s *server) handleModels(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, map[string]interface{}{
		"object": "list",
		"data":   []map[string]interface{}{{"id": s.model, "object": "model", "owned_by": "ai-fabric"}},
	})
}

// handleMetrics writes both vLLM-compatible (colon) metrics and our dashboard
// metrics in Prometheus text exposition format.
func (s *server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	running := atomic.LoadInt64(&s.running)
	waiting := atomic.LoadInt64(&s.waiting)
	kv := s.kvUsage()
	score := s.fabricScore()
	lbl := fmt.Sprintf(`{model_name=%q,pod=%q,fabric_node=%q}`, s.model, os.Getenv("POD_NAME"), s.fabricNode)

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	p := func(format string, a ...interface{}) { fmt.Fprintf(w, format, a...) }

	// ---- vLLM-compatible metrics (what the EPP scrapes) ----
	p("# TYPE vllm:num_requests_running gauge\nvllm:num_requests_running%s %d\n", lbl, running)
	p("# TYPE vllm:num_requests_waiting gauge\nvllm:num_requests_waiting%s %d\n", lbl, waiting)
	p("# TYPE vllm:gpu_cache_usage_perc gauge\nvllm:gpu_cache_usage_perc%s %g\n", lbl, kv)

	// ---- dashboard metrics ----
	p("# TYPE mock_vllm_num_requests_running gauge\nmock_vllm_num_requests_running%s %d\n", lbl, running)
	p("# TYPE mock_vllm_num_requests_waiting gauge\nmock_vllm_num_requests_waiting%s %d\n", lbl, waiting)
	p("# TYPE mock_vllm_gpu_cache_usage_perc gauge\nmock_vllm_gpu_cache_usage_perc%s %g\n", lbl, kv)
	p("# TYPE mock_vllm_fabric_score gauge\nmock_vllm_fabric_score%s %g\n", lbl, score)

	// latency histogram
	s.hMu.Lock()
	p("# TYPE mock_vllm_request_latency_seconds histogram\n")
	var cum int64
	for i, b := range s.buckets {
		cum = s.counts[i]
		p("mock_vllm_request_latency_seconds_bucket{le=%q} %d\n", strconv.FormatFloat(b, 'g', -1, 64), cum)
	}
	p("mock_vllm_request_latency_seconds_bucket{le=\"+Inf\"} %d\n", s.count)
	p("mock_vllm_request_latency_seconds_sum %g\n", s.sum)
	p("mock_vllm_request_latency_seconds_count %d\n", s.count)
	s.hMu.Unlock()
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	s := newServer()
	s.counts = make([]int64, len(s.buckets))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.pollFabricScore(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/completions", s.handleCompletion)
	mux.HandleFunc("/v1/chat/completions", s.handleCompletion)
	mux.HandleFunc("/v1/models", s.handleModels)
	mux.HandleFunc("/metrics", s.handleMetrics)
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })

	addr := env("LISTEN", ":8000")
	fmt.Printf("mock-vllm on %s node=%s ingress=%s fss=%s\n", addr, s.fabricNode, s.ingressNode, s.fssURL)
	if err := http.ListenAndServe(addr, mux); err != nil {
		panic(err)
	}
}
