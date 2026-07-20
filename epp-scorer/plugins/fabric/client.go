// Package fabric implements a network-aware llm-d EPP scorer.
//
// It scores candidate serving pods by their network proximity/congestion to the
// request source, using the Fabric State Service. This file holds the transport
// + scoring math and is dependency-light (stdlib + prometheus) so it can be unit
// tested independently of the GIE plugin interface (see scorer.go for the glue).
package fabric

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// Config for the scorer, populated from EPP env.
type Config struct {
	FSSURL          string // Fabric State Service base URL
	IngressNode     string // reference "source" fabric node for distance
	FabricNodeLabel string // pod label that carries the simulated fabric node
	Timeout         time.Duration
}

func ConfigFromEnv() Config {
	get := func(k, d string) string {
		if v := os.Getenv(k); v != "" {
			return v
		}
		return d
	}
	return Config{
		FSSURL:          get("FSS_URL", "http://fabric-state-service.ai-fabric-system:8080"),
		IngressNode:     get("INGRESS_NODE", "gpu-0001"),
		FabricNodeLabel: get("FABRIC_NODE_LABEL", "ai-fabric.io/fabric-node"),
		Timeout:         3 * time.Second,
	}
}

// Client talks to the Fabric State Service.
type Client struct {
	cfg  Config
	http *http.Client
}

func NewClient(cfg Config) *Client {
	return &Client{cfg: cfg, http: &http.Client{Timeout: cfg.Timeout}}
}

type scoreResponse struct {
	From   string             `json:"from"`
	Scores map[string]float64 `json:"scores"`
}

// ScoreNodes asks the FSS for network scores of candidate fabric nodes relative
// to the ingress node. Returns node -> score in [0,1] (higher = closer/less
// congested). On error, returns nil so the caller can fall back to neutral.
func (c *Client) ScoreNodes(ctx context.Context, fabricNodes []string) map[string]float64 {
	body, _ := json.Marshal(map[string]interface{}{
		"from":       c.cfg.IngressNode,
		"candidates": fabricNodes,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.cfg.FSSURL+"/api/v1/score", bytes.NewReader(body))
	if err != nil {
		metricErrors.Inc()
		return nil
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		metricErrors.Inc()
		return nil
	}
	defer resp.Body.Close()
	var sr scoreResponse
	if err := json.NewDecoder(resp.Body).Decode(&sr); err != nil {
		metricErrors.Inc()
		return nil
	}
	return sr.Scores
}

// Prometheus metrics (exposed on the EPP metrics endpoint).
var (
	metricScored = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "fabric_scorer_scored_total",
		Help: "Total candidate pods scored by the fabric scorer.",
	})
	metricSelected = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "fabric_scorer_selected_total",
		Help: "Total times the fabric scorer's top pick was the highest scorer.",
	})
	metricErrors = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "fabric_scorer_errors_total",
		Help: "Total Fabric State Service call errors (fell back to neutral).",
	})
)

// Register wires the metrics into the given registerer (call once at startup).
func Register(r prometheus.Registerer) {
	r.MustRegister(metricScored, metricSelected, metricErrors)
}

// normalize maps FSS scores onto the candidate set, defaulting missing entries
// to a neutral 0.5 so unknown-location pods don't get unfairly penalized.
func normalize(fabricNodes []string, scores map[string]float64) map[string]float64 {
	out := make(map[string]float64, len(fabricNodes))
	var best float64 = -1
	var bestNode string
	for _, n := range fabricNodes {
		s, ok := scores[n]
		if !ok {
			s = 0.5
		}
		out[n] = s
		metricScored.Inc()
		if s > best {
			best, bestNode = s, n
		}
	}
	if bestNode != "" {
		metricSelected.Inc()
	}
	return out
}

var _ = context.Background // keep context imported for scorer.go builds
