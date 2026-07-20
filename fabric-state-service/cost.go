package main

// CostModel turns topology + live telemetry into a scalar network cost and a
// normalized routing score. This is the signal the EPP scorer and the training
// scheduler consume.
type CostModel struct {
	topo *Topology
	tele *Telemetry

	// tunables
	hopWeight        float64 // cost per fabric link hop
	railPenalty      float64 // extra cost for cross-rail traffic
	congestionWeight float64 // multiplier on link utilization [0,1]
}

func NewCostModel(topo *Topology, tele *Telemetry) *CostModel {
	return &CostModel{
		topo:             topo,
		tele:             tele,
		hopWeight:        1.0,
		railPenalty:      1.0,
		congestionWeight: 6.0,
	}
}

// CostResult is returned by the API.
type CostResult struct {
	From       string  `json:"from"`
	To         string  `json:"to"`
	Hops       int     `json:"hops"`
	RailMiss   bool    `json:"railMismatch"`
	Congestion float64 `json:"congestion"` // [0,1] worst link on the path
	Cost       float64 `json:"cost"`       // lower is better
	Score      float64 `json:"score"`      // [0,1] higher is better (EPP-friendly)
	Known      bool    `json:"known"`      // false if either node has no location
}

// Cost computes the network cost between two nodes.
func (m *CostModel) Cost(from, to string) CostResult {
	a, oka := m.topo.Get(from)
	b, okb := m.topo.Get(to)
	res := CostResult{From: from, To: to}
	if !oka || !okb {
		// Unknown location: neutral score so routing falls back to other scorers.
		res.Score = 0.5
		res.Known = false
		return res
	}
	res.Known = true
	res.Hops = Hops(a, b)
	railMiss := RailMismatch(a, b)
	res.RailMiss = railMiss > 0

	// Congestion along the path ~ worst utilization of the involved leaves
	// (and, for cross-leaf paths, the fabric max as a spine proxy).
	cong := 0.0
	if u := m.tele.LeafUtil(leafToClab(a.Leaf)); u > cong {
		cong = u
	}
	if u := m.tele.LeafUtil(leafToClab(b.Leaf)); u > cong {
		cong = u
	}
	if res.Hops >= 4 {
		if u := m.tele.MaxUtil(); u > cong {
			cong = u
		}
	}
	res.Congestion = cong

	res.Cost = float64(res.Hops)*m.hopWeight +
		float64(railMiss)*m.railPenalty +
		cong*m.congestionWeight

	// Normalize to a [0,1] score where higher = better. The worst realistic
	// cost is ~ 6 hops + 1 rail + congestionWeight => use that as the scale.
	worst := 6*m.hopWeight + m.railPenalty + m.congestionWeight
	s := 1.0 - res.Cost/worst
	if s < 0 {
		s = 0
	}
	if s > 1 {
		s = 1
	}
	res.Score = s
	return res
}

// Score is a convenience returning just the [0,1] score.
func (m *CostModel) Score(from, to string) float64 { return m.Cost(from, to).Score }
