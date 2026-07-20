package main

import (
	"regexp"
	"strings"
	"sync"
)

// FabricLocation is where a (simulated) GPU node sits in the network fabric.
// Populated from node labels written by scripts/13-gen-kwok-nodes.sh.
type FabricLocation struct {
	Node       string `json:"node"`
	Leaf       string `json:"leaf"`       // e.g. "leaf-1"
	Rack       string `json:"rack"`       // e.g. "rack-1"
	Rail       string `json:"rail"`       // e.g. "rail-3"
	SpineGroup string `json:"spineGroup"` // e.g. "spine-1"
}

// Label keys (kept in sync with kwok/node-template.yaml).
const (
	labelLeaf  = "ai-fabric.io/leaf"
	labelRack  = "ai-fabric.io/rack"
	labelRail  = "ai-fabric.io/rail"
	labelSpine = "ai-fabric.io/spine-group"
)

// Topology is a thread-safe registry of node -> FabricLocation.
type Topology struct {
	mu   sync.RWMutex
	locs map[string]FabricLocation
}

func NewTopology() *Topology { return &Topology{locs: map[string]FabricLocation{}} }

func (t *Topology) Upsert(loc FabricLocation) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.locs[loc.Node] = loc
}

func (t *Topology) Delete(node string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.locs, node)
}

func (t *Topology) Get(node string) (FabricLocation, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	l, ok := t.locs[node]
	return l, ok
}

func (t *Topology) Count() int {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return len(t.locs)
}

// LeafSet returns the distinct leaf names currently known.
func (t *Topology) LeafSet() map[string]struct{} {
	t.mu.RLock()
	defer t.mu.RUnlock()
	s := map[string]struct{}{}
	for _, l := range t.locs {
		if l.Leaf != "" {
			s[l.Leaf] = struct{}{}
		}
	}
	return s
}

// Hops returns the number of fabric links traversed between two locations in a
// two-tier (leaf/spine) CLOS. Lower is closer.
//
//	same node                 -> 0
//	same leaf (via ToR)       -> 2
//	diff leaf, same spine grp -> 4
//	diff spine group          -> 6
func Hops(a, b FabricLocation) int {
	switch {
	case a.Node == b.Node:
		return 0
	case a.Leaf == b.Leaf && a.Leaf != "":
		return 2
	case a.SpineGroup == b.SpineGroup && a.SpineGroup != "":
		return 4
	default:
		return 6
	}
}

// RailMismatch adds cost for cross-rail traffic (rail-optimized fabrics prefer
// same-rail GPU-to-GPU paths).
func RailMismatch(a, b FabricLocation) int {
	if a.Rail != "" && b.Rail != "" && a.Rail != b.Rail {
		return 1
	}
	return 0
}

var digits = regexp.MustCompile(`\d+`)

// leafToClab maps a node-label leaf name ("leaf-1") to the containerlab node
// name ("leaf1") used as the telemetry `source` label suffix.
func leafToClab(leaf string) string {
	if leaf == "" {
		return ""
	}
	if m := digits.FindString(leaf); m != "" {
		return "leaf" + m
	}
	return strings.ReplaceAll(leaf, "-", "")
}
