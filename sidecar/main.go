package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	metricsv "k8s.io/metrics/pkg/client/clientset/versioned"
)

var (
	clientset     *kubernetes.Clientset
	metricsClient *metricsv.Clientset
)

// Managed namespaces for restart operations
var managedNamespaces = map[string]bool{
	"stackforge": true,
	"traefik":    true,
	"portainer":  true,
	"monitoring": true,
}

// Service definitions for health checking
type serviceCheck struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Port      int    `json:"port"`
	Path      string `json:"path"`
	Proto     string `json:"proto"`
}

var servicesToCheck = []serviceCheck{
	{Name: "Portainer", Namespace: "portainer", Port: 9443, Path: "/", Proto: "https"},
	{Name: "Grafana", Namespace: "monitoring", Port: 80, Path: "/api/health", Proto: "http"},
	{Name: "Prometheus", Namespace: "monitoring", Port: 9090, Path: "/-/healthy", Proto: "http"},
	{Name: "Uptime Kuma", Namespace: "monitoring", Port: 3001, Path: "/", Proto: "http"},
	{Name: "Traefik", Namespace: "traefik", Port: 80, Path: "/", Proto: "http"},
}

// --- Response types ---

type NodeInfo struct {
	Name    string  `json:"name"`
	Role    string  `json:"role"`
	Status  string  `json:"status"`
	CPU     float64 `json:"cpu"`
	Memory  float64 `json:"mem"`
	Disk    float64 `json:"disk"`
	Version string  `json:"version"`
	Created string  `json:"created"`
}

type PodStats struct {
	Namespace string `json:"namespace"`
	Running   int    `json:"running"`
	Pending   int    `json:"pending"`
	Failed    int    `json:"failed"`
	Total     int    `json:"total"`
}

type ClusterMetrics struct {
	CPUPercent    float64 `json:"cpuPercent"`
	MemoryPercent float64 `json:"memPercent"`
	TotalPods     int     `json:"totalPods"`
	TotalNodes    int     `json:"totalNodes"`
}

type ServiceHealth struct {
	Name   string `json:"name"`
	Status string `json:"status"` // "up", "down", "degraded"
	Latency int64  `json:"latency"` // ms
}

type EventInfo struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Reason    string `json:"reason"`
	Message   string `json:"message"`
	Namespace string `json:"namespace"`
	Object    string `json:"object"`
}

type RestartRequest struct {
	Deployment string `json:"deployment"`
	Namespace  string `json:"namespace"`
}

func main() {
	config, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("Failed to get in-cluster config: %v", err)
	}

	clientset, err = kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Failed to create clientset: %v", err)
	}

	metricsClient, err = metricsv.NewForConfig(config)
	if err != nil {
		log.Printf("Warning: metrics client not available (metrics-server may not be installed): %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/nodes", handleNodes)
	mux.HandleFunc("/api/pods", handlePods)
	mux.HandleFunc("/api/metrics", handleMetrics)
	mux.HandleFunc("/api/services", handleServices)
	mux.HandleFunc("/api/events", handleEvents)
	mux.HandleFunc("/api/restart", handleRestart)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("sf-api starting on :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func writeJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// GET /api/nodes — real node list with metrics
func handleNodes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx := context.Background()
	nodeList, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to list nodes: %v", err))
		return
	}

	// Try to get node metrics
	var nodeMetrics map[string][2]float64 // name -> [cpuPercent, memPercent]
	if metricsClient != nil {
		nodeMetrics = getNodeMetrics(ctx)
	}

	var result []NodeInfo
	for _, node := range nodeList.Items {
		role := "worker"
		if _, ok := node.Labels["node-role.kubernetes.io/master"]; ok {
			role = "master"
		} else if _, ok := node.Labels["node-role.kubernetes.io/control-plane"]; ok {
			role = "master"
		}

		status := "NotReady"
		for _, cond := range node.Status.Conditions {
			if cond.Type == corev1.NodeReady && cond.Status == corev1.ConditionTrue {
				status = "Ready"
				break
			}
		}

		cpu, mem := 0.0, 0.0
		if nodeMetrics != nil {
			if m, ok := nodeMetrics[node.Name]; ok {
				cpu = m[0]
				mem = m[1]
			}
		}

		// Disk usage from allocatable vs capacity
		disk := 0.0
		if cap, ok := node.Status.Capacity[corev1.ResourceEphemeralStorage]; ok {
			if alloc, ok2 := node.Status.Allocatable[corev1.ResourceEphemeralStorage]; ok2 {
				capVal := cap.Value()
				allocVal := alloc.Value()
				if capVal > 0 {
					disk = float64(capVal-allocVal) / float64(capVal) * 100
				}
			}
		}

		result = append(result, NodeInfo{
			Name:    node.Name,
			Role:    role,
			Status:  status,
			CPU:     cpu,
			Memory:  mem,
			Disk:    disk,
			Version: node.Status.NodeInfo.KubeletVersion,
			Created: node.CreationTimestamp.Format(time.RFC3339),
		})
	}

	writeJSON(w, result)
}

func getNodeMetrics(ctx context.Context) map[string][2]float64 {
	result := make(map[string][2]float64)

	nodeMetrics, err := metricsClient.MetricsV1beta1().NodeMetricses().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Warning: failed to get node metrics: %v", err)
		return nil
	}

	nodeList, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil
	}

	// Build allocatable map
	allocatable := make(map[string][2]int64) // [cpuMillis, memBytes]
	for _, node := range nodeList.Items {
		cpuAlloc := node.Status.Allocatable[corev1.ResourceCPU]
		memAlloc := node.Status.Allocatable[corev1.ResourceMemory]
		allocatable[node.Name] = [2]int64{cpuAlloc.MilliValue(), memAlloc.Value()}
	}

	for _, nm := range nodeMetrics.Items {
		if alloc, ok := allocatable[nm.Name]; ok {
			cpuUsed := nm.Usage[corev1.ResourceCPU]
			memUsed := nm.Usage[corev1.ResourceMemory]

			cpuPct := 0.0
			if alloc[0] > 0 {
				cpuPct = float64(cpuUsed.MilliValue()) / float64(alloc[0]) * 100
			}
			memPct := 0.0
			if alloc[1] > 0 {
				memPct = float64(memUsed.Value()) / float64(alloc[1]) * 100
			}

			result[nm.Name] = [2]float64{cpuPct, memPct}
		}
	}

	return result
}

// GET /api/pods — pod count by namespace
func handlePods(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx := context.Background()
	podList, err := clientset.CoreV1().Pods("").List(ctx, metav1.ListOptions{})
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to list pods: %v", err))
		return
	}

	nsMap := make(map[string]*PodStats)
	for _, pod := range podList.Items {
		ns := pod.Namespace
		if _, ok := nsMap[ns]; !ok {
			nsMap[ns] = &PodStats{Namespace: ns}
		}
		stats := nsMap[ns]
		stats.Total++
		switch pod.Status.Phase {
		case corev1.PodRunning:
			stats.Running++
		case corev1.PodPending:
			stats.Pending++
		case corev1.PodFailed:
			stats.Failed++
		}
	}

	var result []PodStats
	for _, s := range nsMap {
		result = append(result, *s)
	}
	sort.Slice(result, func(i, j int) bool {
		return result[i].Namespace < result[j].Namespace
	})

	writeJSON(w, result)
}

// GET /api/metrics — cluster-wide CPU & memory
func handleMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx := context.Background()

	nodeList, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to list nodes: %v", err))
		return
	}

	podList, err := clientset.CoreV1().Pods("").List(ctx, metav1.ListOptions{})
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to list pods: %v", err))
		return
	}

	totalPods := 0
	for _, p := range podList.Items {
		if p.Status.Phase == corev1.PodRunning {
			totalPods++
		}
	}

	metrics := ClusterMetrics{
		TotalPods:  totalPods,
		TotalNodes: len(nodeList.Items),
	}

	// Try metrics-server for real CPU/memory
	if metricsClient != nil {
		nodeMetrics := getNodeMetrics(ctx)
		if nodeMetrics != nil && len(nodeMetrics) > 0 {
			var totalCPU, totalMem float64
			for _, m := range nodeMetrics {
				totalCPU += m[0]
				totalMem += m[1]
			}
			metrics.CPUPercent = totalCPU / float64(len(nodeMetrics))
			metrics.MemoryPercent = totalMem / float64(len(nodeMetrics))
		}
	}

	writeJSON(w, metrics)
}

// GET /api/services — health check all stackforge services
func handleServices(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx := context.Background()
	var results []ServiceHealth

	for _, svc := range servicesToCheck {
		health := ServiceHealth{Name: svc.Name, Status: "down"}

		// Find the service ClusterIP in the namespace
		svcList, err := clientset.CoreV1().Services(svc.Namespace).List(ctx, metav1.ListOptions{})
		if err != nil {
			results = append(results, health)
			continue
		}

		// Find a service with the matching port
		var targetIP string
		var targetPort int32
		for _, s := range svcList.Items {
			for _, p := range s.Spec.Ports {
				if int(p.Port) == svc.Port || int(p.TargetPort.IntValue()) == svc.Port {
					targetIP = s.Spec.ClusterIP
					targetPort = p.Port
					break
				}
			}
			if targetIP != "" {
				break
			}
		}

		if targetIP == "" || targetIP == "None" {
			results = append(results, health)
			continue
		}

		// HTTP health check via ClusterIP
		url := fmt.Sprintf("http://%s:%d%s", targetIP, targetPort, svc.Path)
		client := &http.Client{
			Timeout: 3 * time.Second,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		}

		start := time.Now()
		resp, err := client.Get(url)
		latency := time.Since(start).Milliseconds()
		health.Latency = latency

		if err != nil {
			// Try HTTPS if configured
			if svc.Proto == "https" {
				url = fmt.Sprintf("https://%s:%d%s", targetIP, targetPort, svc.Path)
				start = time.Now()
				resp, err = client.Get(url)
				latency = time.Since(start).Milliseconds()
				health.Latency = latency
			}
			if err != nil {
				results = append(results, health)
				continue
			}
		}
		resp.Body.Close()

		if resp.StatusCode < 500 {
			health.Status = "up"
		} else {
			health.Status = "degraded"
		}

		results = append(results, health)
	}

	writeJSON(w, results)
}

// GET /api/events — recent k8s events
func handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx := context.Background()
	eventList, err := clientset.CoreV1().Events("").List(ctx, metav1.ListOptions{})
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to list events: %v", err))
		return
	}

	// Filter to stackforge-related namespaces and sort by time
	var filtered []EventInfo
	sfNamespaces := map[string]bool{
		"stackforge": true, "traefik": true, "portainer": true,
		"monitoring": true, "kube-system": true,
	}

	for _, ev := range eventList.Items {
		if !sfNamespaces[ev.Namespace] {
			continue
		}

		ts := ev.LastTimestamp.Format(time.RFC3339)
		if ev.LastTimestamp.IsZero() && ev.EventTime.Time != (time.Time{}) {
			ts = ev.EventTime.Format(time.RFC3339)
		}

		filtered = append(filtered, EventInfo{
			Timestamp: ts,
			Type:      ev.Type,
			Reason:    ev.Reason,
			Message:   ev.Message,
			Namespace: ev.Namespace,
			Object:    fmt.Sprintf("%s/%s", strings.ToLower(ev.InvolvedObject.Kind), ev.InvolvedObject.Name),
		})
	}

	// Sort by timestamp descending, take last 50
	sort.Slice(filtered, func(i, j int) bool {
		return filtered[i].Timestamp > filtered[j].Timestamp
	})

	if len(filtered) > 50 {
		filtered = filtered[:50]
	}

	writeJSON(w, filtered)
}

// POST /api/restart — restart a deployment
func handleRestart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req RestartRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	if req.Deployment == "" || req.Namespace == "" {
		writeError(w, http.StatusBadRequest, "deployment and namespace are required")
		return
	}

	if !managedNamespaces[req.Namespace] {
		writeError(w, http.StatusForbidden, fmt.Sprintf("namespace %q is not managed by stackforge", req.Namespace))
		return
	}

	ctx := context.Background()

	// Verify deployment exists
	_, err := clientset.AppsV1().Deployments(req.Namespace).Get(ctx, req.Deployment, metav1.GetOptions{})
	if err != nil {
		writeError(w, http.StatusNotFound, fmt.Sprintf("deployment %q not found in namespace %q", req.Deployment, req.Namespace))
		return
	}

	// Trigger rollout restart by patching the deployment template annotation
	patch := fmt.Sprintf(`{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"%s"}}}}}`, time.Now().Format(time.RFC3339))
	_, err = clientset.AppsV1().Deployments(req.Namespace).Patch(ctx, req.Deployment, types.StrategicMergePatchType, []byte(patch), metav1.PatchOptions{})
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("failed to restart deployment: %v", err))
		return
	}

	writeJSON(w, map[string]string{
		"status":  "ok",
		"message": fmt.Sprintf("deployment %s/%s restart initiated", req.Namespace, req.Deployment),
	})

	// Suppress unused import warnings at compile time
	_ = appsv1.SchemeGroupVersion
}
