package main

import "github.com/prometheus/client_golang/prometheus"

var (
	metricNodes = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "fss_nodes",
		Help: "Number of GPU nodes with a known fabric location.",
	})
	metricCostRequests = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "fss_cost_requests_total",
		Help: "Total cost/score API requests served.",
	})
	metricScrapeErrors = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "fss_telemetry_scrape_errors_total",
		Help: "Total Prometheus telemetry scrape errors.",
	})
	metricLinkUtil = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "fss_link_utilization",
		Help: "Normalized [0,1] utilization per fabric node (busiest egress link).",
	}, []string{"node"})
)

func registerMetrics(r prometheus.Registerer) {
	r.MustRegister(metricNodes, metricCostRequests, metricScrapeErrors, metricLinkUtil)
}
