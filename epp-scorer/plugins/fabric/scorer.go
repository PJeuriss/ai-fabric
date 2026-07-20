//go:build gie

// This file wires the fabric scoring logic into the Gateway API Inference
// Extension (GIE) EPP plugin framework. It is behind the `gie` build tag so the
// dependency-light client.go can be built/tested without the GIE module.
//
// Build with:  go build -tags gie ./...
//
// IMPORTANT: GIE's plugin interface evolves between releases. After `go mod tidy`
// pins the version matching GIE_VERSION, confirm these two things against the
// vendored source and adjust if needed:
//   1. the Scorer interface signature (framework.Scorer)
//   2. how to read a pod's labels from types.Pod (GetPod())
package fabric

import (
	"context"

	"sigs.k8s.io/gateway-api-inference-extension/pkg/epp/scheduling/framework"
	"sigs.k8s.io/gateway-api-inference-extension/pkg/epp/scheduling/types"
)

// FabricScorer scores endpoints by network proximity/congestion to the ingress.
type FabricScorer struct {
	client *Client
}

// Compile-time assertion that we satisfy the framework Scorer interface.
var _ framework.Scorer = (*FabricScorer)(nil)

func NewFabricScorer() *FabricScorer {
	return &FabricScorer{client: NewClient(ConfigFromEnv())}
}

func (f *FabricScorer) Name() string { return "fabric-congestion-scorer" }

// Score returns a [0,1] score per pod; higher = better network position.
func (f *FabricScorer) Score(
	ctx context.Context,
	_ *types.CycleState,
	_ *types.LLMRequest,
	pods []types.Pod,
) map[types.Pod]float64 {

	label := f.client.cfg.FabricNodeLabel

	// Map each candidate pod -> its simulated fabric node (from a pod label).
	podToNode := make(map[types.Pod]string, len(pods))
	nodes := make([]string, 0, len(pods))
	for _, p := range pods {
		fabricNode := podLabel(p, label)
		podToNode[p] = fabricNode
		if fabricNode != "" {
			nodes = append(nodes, fabricNode)
		}
	}

	scores := f.client.ScoreNodes(ctx, nodes) // node -> [0,1]
	norm := normalize(nodes, scores)

	out := make(map[types.Pod]float64, len(pods))
	for _, p := range pods {
		if n := podToNode[p]; n != "" {
			out[p] = norm[n]
		} else {
			out[p] = 0.5 // unknown location: neutral
		}
	}
	return out
}

// podLabel extracts a label from a GIE pod. The accessor path depends on the
// GIE version; adjust if `go mod tidy` selects a version with a different shape.
func podLabel(p types.Pod, key string) string {
	bp := p.GetPod()
	if bp == nil {
		return ""
	}
	if bp.Labels != nil {
		return bp.Labels[key]
	}
	return ""
}
