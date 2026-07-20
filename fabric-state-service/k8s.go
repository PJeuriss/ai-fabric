package main

import (
	"context"
	"os"
	"path/filepath"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"
)

func buildConfig() (*rest.Config, error) {
	if c, err := rest.InClusterConfig(); err == nil {
		return c, nil
	}
	kubeconfig := os.Getenv("KUBECONFIG")
	if kubeconfig == "" {
		if home, _ := os.UserHomeDir(); home != "" {
			kubeconfig = filepath.Join(home, ".kube", "config")
		}
	}
	return clientcmd.BuildConfigFromFlags("", kubeconfig)
}

func locationFromNode(n *corev1.Node) (FabricLocation, bool) {
	l := n.Labels
	leaf, ok := l[labelLeaf]
	if !ok {
		return FabricLocation{}, false
	}
	return FabricLocation{
		Node:       n.Name,
		Leaf:       leaf,
		Rack:       l[labelRack],
		Rail:       l[labelRail],
		SpineGroup: l[labelSpine],
	}, true
}

// startNodeInformer watches Nodes and keeps the Topology in sync.
func startNodeInformer(ctx context.Context, cs kubernetes.Interface, topo *Topology) {
	factory := informers.NewSharedInformerFactory(cs, 10*time.Minute)
	ni := factory.Core().V1().Nodes().Informer()

	upsert := func(obj interface{}) {
		n, ok := obj.(*corev1.Node)
		if !ok {
			return
		}
		if loc, ok := locationFromNode(n); ok {
			topo.Upsert(loc)
			metricNodes.Set(float64(topo.Count()))
		}
	}
	_, _ = ni.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    upsert,
		UpdateFunc: func(_, n interface{}) { upsert(n) },
		DeleteFunc: func(obj interface{}) {
			if n, ok := obj.(*corev1.Node); ok {
				topo.Delete(n.Name)
				metricNodes.Set(float64(topo.Count()))
			}
		},
	})
	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())
	klog.Infof("node informer synced: %d GPU nodes with fabric locations", topo.Count())
}

var networkFabricGVR = schema.GroupVersionResource{
	Group:    "fabric.ai-fabric.io",
	Version:  "v1alpha1",
	Resource: "networkfabrics",
}

// reconcileNetworkFabric best-effort writes a summary NetworkFabric CR so the
// fabric state is inspectable via `kubectl get networkfabric`.
func reconcileNetworkFabric(ctx context.Context, dyn dynamic.Interface, topo *Topology, tele *Telemetry) {
	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	name := "default"
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		leaves := topo.LeafSet()
		obj := &unstructured.Unstructured{Object: map[string]interface{}{
			"apiVersion": "fabric.ai-fabric.io/v1alpha1",
			"kind":       "NetworkFabric",
			"metadata":   map[string]interface{}{"name": name},
			"spec": map[string]interface{}{
				"topology": "leaf-spine",
			},
			"status": map[string]interface{}{
				"nodes":       int64(topo.Count()),
				"leaves":      int64(len(leaves)),
				"maxLinkUtil": tele.MaxUtil(),
				"observedAt":  time.Now().UTC().Format(time.RFC3339),
			},
		}}
		cur, err := dyn.Resource(networkFabricGVR).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			if _, err := dyn.Resource(networkFabricGVR).Create(ctx, obj, metav1.CreateOptions{}); err != nil {
				klog.V(2).Infof("networkfabric create skipped: %v", err)
			}
			continue
		}
		obj.SetResourceVersion(cur.GetResourceVersion())
		if _, err := dyn.Resource(networkFabricGVR).Update(ctx, obj, metav1.UpdateOptions{}); err != nil {
			klog.V(2).Infof("networkfabric update skipped: %v", err)
		}
	}
}
