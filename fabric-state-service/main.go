// Fabric State Service — the "networking controller".
//
// It watches GPU nodes to learn their fabric location, ingests containerlab
// link telemetry from Prometheus (fed by gnmic), computes a network cost/score
// between any two nodes, and serves that as an HTTP API for the llm-d EPP scorer
// and the training scheduler. It also publishes a summary NetworkFabric CR.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/klog/v2"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envFloat(k string, def float64) float64 {
	if v := os.Getenv(k); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

func main() {
	klog.InitFlags(nil)
	flag.Parse()

	var (
		listen       = env("LISTEN", ":8080")
		promURL      = env("PROM_URL", "http://kps-kube-prometheus-stack-prometheus.monitoring:9090")
		scrapeEvery  = env("SCRAPE_INTERVAL", "10s")
		linkCapacity = envFloat("LINK_CAPACITY_BPS", 100e9) // 100 Gbps default
	)
	interval, err := time.ParseDuration(scrapeEvery)
	if err != nil {
		interval = 10 * time.Second
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	reg := prometheus.NewRegistry()
	registerMetrics(reg)

	topo := NewTopology()

	tele, err := NewTelemetry(promURL, interval, linkCapacity)
	if err != nil {
		klog.Fatalf("telemetry init: %v", err)
	}
	go tele.Run(ctx)

	cost := NewCostModel(topo, tele)

	// Kubernetes wiring (best-effort: the API still serves topology-only cost
	// if the cluster is unreachable, useful for local testing).
	if cfg, err := buildConfig(); err != nil {
		klog.Warningf("no kube config (%v); running without node informer", err)
	} else {
		cs, err := kubernetes.NewForConfig(cfg)
		if err != nil {
			klog.Fatalf("clientset: %v", err)
		}
		startNodeInformer(ctx, cs, topo)
		if dyn, err := dynamic.NewForConfig(cfg); err == nil {
			go reconcileNetworkFabric(ctx, dyn, topo, tele)
		}
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ready")) })

	mux.HandleFunc("/api/v1/location", func(w http.ResponseWriter, r *http.Request) {
		node := r.URL.Query().Get("node")
		loc, ok := topo.Get(node)
		if !ok {
			http.Error(w, `{"error":"unknown node"}`, http.StatusNotFound)
			return
		}
		writeJSON(w, loc)
	})

	mux.HandleFunc("/api/v1/cost", func(w http.ResponseWriter, r *http.Request) {
		metricCostRequests.Inc()
		q := r.URL.Query()
		writeJSON(w, cost.Cost(q.Get("from"), q.Get("to")))
	})

	// Batch scoring for the EPP scorer: POST {"from":"<node>","candidates":[...]}.
	mux.HandleFunc("/api/v1/score", func(w http.ResponseWriter, r *http.Request) {
		metricCostRequests.Inc()
		var req struct {
			From       string   `json:"from"`
			Candidates []string `json:"candidates"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"bad request"}`, http.StatusBadRequest)
			return
		}
		scores := make(map[string]float64, len(req.Candidates))
		for _, c := range req.Candidates {
			scores[c] = cost.Score(req.From, c)
		}
		writeJSON(w, map[string]interface{}{"from": req.From, "scores": scores})
	})

	mux.HandleFunc("/api/v1/util", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, tele.Snapshot())
	})

	srv := &http.Server{Addr: listen, Handler: mux}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()

	klog.Infof("fabric-state-service listening on %s (prometheus=%s, linkCap=%.0f bps)", listen, promURL, linkCapacity)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		klog.Fatalf("http server: %v", err)
	}
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
