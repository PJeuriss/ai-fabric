package fabric

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestScoreNodesAndNormalize(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			From       string   `json:"from"`
			Candidates []string `json:"candidates"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		if req.From != "gpu-0001" {
			t.Errorf("unexpected from: %s", req.From)
		}
		_ = json.NewEncoder(w).Encode(scoreResponse{
			From:   req.From,
			Scores: map[string]float64{"gpu-0001": 1.0, "gpu-0002": 0.4},
		})
	}))
	defer srv.Close()

	c := NewClient(Config{FSSURL: srv.URL, IngressNode: "gpu-0001", FabricNodeLabel: "x"})
	scores := c.ScoreNodes(context.Background(), []string{"gpu-0001", "gpu-0002", "gpu-9999"})
	if scores["gpu-0001"] != 1.0 || scores["gpu-0002"] != 0.4 {
		t.Fatalf("bad scores: %+v", scores)
	}

	norm := normalize([]string{"gpu-0001", "gpu-0002", "gpu-9999"}, scores)
	if norm["gpu-9999"] != 0.5 {
		t.Errorf("missing node should default to neutral 0.5, got %v", norm["gpu-9999"])
	}
	if norm["gpu-0001"] <= norm["gpu-0002"] {
		t.Errorf("closer node should score higher: %+v", norm)
	}
}
