//go:build gie

// Custom EPP binary = stock GIE Endpoint Picker + our fabric scorer registered
// so it can be referenced from EndpointPickerConfig as "fabric-congestion-scorer".
//
// Build:  go build -tags gie -o epp ./cmd/epp
//
// Version note: GIE exposes both a plugin registry and a runner entrypoint.
// The exact symbols move between releases; after `go mod tidy` confirm:
//   - plugins.Register(...) (or the equivalent factory registration API)
//   - the runner entrypoint used by GIE's own cmd/epp/main.go
// then mirror them here.
package main

import (
	"github.com/prometheus/client_golang/prometheus"

	fabric "ai-fabric/llm-d-epp-fabric/plugins/fabric"

	"sigs.k8s.io/gateway-api-inference-extension/pkg/epp/plugins"
	runner "sigs.k8s.io/gateway-api-inference-extension/pkg/epp/runner"
)

func main() {
	// Expose the fabric scorer's metrics on the EPP metrics endpoint.
	fabric.Register(prometheus.DefaultRegisterer)

	// Register the plugin under the type name used in EndpointPickerConfig.
	plugins.Register("fabric-congestion-scorer", func(_ map[string]any) (any, error) {
		return fabric.NewFabricScorer(), nil
	})

	// Hand off to the standard GIE EPP runner (parses --pool-name, --config-file, etc).
	runner.Run()
}
