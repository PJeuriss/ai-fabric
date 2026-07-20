package main

import (
	"context"
	"sync"
	"time"

	promapi "github.com/prometheus/client_golang/api"
	promv1 "github.com/prometheus/client_golang/api/prometheus/v1"
	"github.com/prometheus/common/model"
	"k8s.io/klog/v2"
)

// Telemetry polls Prometheus for fabric link utilization (fed by gnmic) and
// keeps a normalized [0,1] utilization value per leaf switch.
type Telemetry struct {
	api          promv1.API
	interval     time.Duration
	linkCapacity float64 // bits/sec, for normalization

	mu   sync.RWMutex
	util map[string]float64 // key: clab node name (e.g. "leaf1") -> util [0,1]
}

func NewTelemetry(promURL string, interval time.Duration, linkCapacity float64) (*Telemetry, error) {
	c, err := promapi.NewClient(promapi.Config{Address: promURL})
	if err != nil {
		return nil, err
	}
	return &Telemetry{
		api:          promv1.NewAPI(c),
		interval:     interval,
		linkCapacity: linkCapacity,
		util:         map[string]float64{},
	}, nil
}

// LeafUtil returns the normalized utilization for a leaf's clab name, or 0.
func (t *Telemetry) LeafUtil(clabLeaf string) float64 {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.util[clabLeaf]
}

// MaxUtil returns the highest utilization across the fabric (spine congestion proxy).
func (t *Telemetry) MaxUtil() float64 {
	t.mu.RLock()
	defer t.mu.RUnlock()
	var mx float64
	for _, v := range t.util {
		if v > mx {
			mx = v
		}
	}
	return mx
}

// Snapshot returns a copy of the util map for the API/metrics.
func (t *Telemetry) Snapshot() map[string]float64 {
	t.mu.RLock()
	defer t.mu.RUnlock()
	out := make(map[string]float64, len(t.util))
	for k, v := range t.util {
		out[k] = v
	}
	return out
}

// Run polls until ctx is cancelled.
func (t *Telemetry) Run(ctx context.Context) {
	tick := time.NewTicker(t.interval)
	defer tick.Stop()
	t.scrape(ctx) // prime immediately
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			t.scrape(ctx)
		}
	}
}

// scrape queries the busiest egress link per fabric node and normalizes it.
// gnmic exposes: fabric_if_counters_out_octets{source="clab-fabric-leaf1",interface_name="ethernet-1/1"}
func (t *Telemetry) scrape(ctx context.Context) {
	q := `max by (source) (rate(fabric_if_counters_out_octets[1m]) * 8)`
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	val, warns, err := t.api.Query(cctx, q, time.Now())
	if err != nil {
		metricScrapeErrors.Inc()
		klog.Warningf("telemetry scrape failed: %v", err)
		return
	}
	if len(warns) > 0 {
		klog.Warningf("telemetry query warnings: %v", warns)
	}
	vec, ok := val.(model.Vector)
	if !ok {
		return
	}
	next := map[string]float64{}
	for _, s := range vec {
		src := string(s.Metric["source"]) // clab-fabric-leaf1
		name := stripClabPrefix(src)       // leaf1
		u := float64(s.Value) / t.linkCapacity
		if u > 1 {
			u = 1
		}
		next[name] = u
		metricLinkUtil.WithLabelValues(name).Set(u)
	}
	t.mu.Lock()
	t.util = next
	t.mu.Unlock()
}

// stripClabPrefix turns "clab-fabric-leaf1" into "leaf1".
func stripClabPrefix(s string) string {
	// format: clab-<labname>-<node>
	// take the substring after the last '-' group that starts with a role word.
	for _, role := range []string{"-leaf", "-spine"} {
		if i := lastIndex(s, role); i >= 0 {
			return s[i+1:]
		}
	}
	return s
}

func lastIndex(s, sub string) int {
	last := -1
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			last = i
		}
	}
	return last
}
