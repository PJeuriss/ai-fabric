module ai-fabric/llm-d-epp-fabric

go 1.23.0

// The fabric scorer plugs into the Gateway API Inference Extension EPP plugin
// framework. The dependency-light `plugins/fabric` package (client.go) builds
// and tests WITHOUT GIE; the GIE glue (scorer.go, cmd/epp) is behind the `gie`
// build tag and is only pulled by the Docker build (`go mod tidy` + `-tags gie`).
//
// GIE >= v1.5.0 requires Go 1.25 and may have moved the plugin interfaces from
// the paths referenced in scorer.go / cmd/epp/main.go. On tcow, run:
//   go mod tidy && go build -tags gie ./cmd/epp
// and adjust the import paths / framework.Scorer signature if the compiler
// complains (both spots are commented).

require github.com/prometheus/client_golang v1.20.5

require (
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/prometheus/client_model v0.6.1 // indirect
	github.com/prometheus/common v0.55.0 // indirect
	github.com/prometheus/procfs v0.15.1 // indirect
	golang.org/x/sys v0.22.0 // indirect
	google.golang.org/protobuf v1.34.2 // indirect
)
