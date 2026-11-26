package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/rest"
)

func TestContextDiscoveryOnlyWritesPickerMetadata(t *testing.T) {
	file := filepath.Join(t.TempDir(), "config")
	raw := `apiVersion: v1
kind: Config
current-context: zoo
clusters:
- name: local
  cluster:
    server: https://localhost
users:
- name: principal
  user:
    token: private-fixture-token
contexts:
- name: zoo
  context: {cluster: local, user: principal, namespace: tools}
- name: alpha
  context: {cluster: local, user: principal}
`
	if err := os.WriteFile(file, []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := run(context.Background(), []string{"--kubeconfig=" + file, "contexts"}, nil, &out); err != nil {
		t.Fatal(err)
	}
	want := `["zoo",[{"name":"alpha","context":{"cluster":"local"}},{"name":"zoo","context":{"cluster":"local","namespace":"tools"}}]]` + "\n"
	if out.String() != want {
		t.Fatalf("unexpected picker output %q", out.String())
	}
}

func TestScopedLogsAndMetrics(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/cluster/api/v1/namespaces/demo/pods/worker/log":
			q := r.URL.Query()
			if q.Get("container") != "web" || q.Get("previous") != "true" || q.Get("tailLines") != "200" || q.Get("limitBytes") != "5" {
				t.Errorf("unexpected log options %v", q)
			}
			fmt.Fprint(w, "hello world")
		case "/cluster/apis/metrics.k8s.io/v1beta1/namespaces/demo/pods", "/cluster/apis/metrics.k8s.io/v1beta1/pods":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"items":[{"metadata":{"namespace":"demo","name":"worker"},"containers":[{"usage":{"cpu":"1100u","memory":"1536Ki"}},{"usage":{"cpu":"900u","memory":"1536Ki"}}]}]}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	cfg := &rest.Config{Host: server.URL + "/cluster"}
	var out bytes.Buffer
	if err := podLogs(context.Background(), cfg, "demo", "worker", "web", true, 200, 5, &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != "hello" {
		t.Fatalf("log output %q", out.String())
	}
	for namespace, want := range map[string]string{"demo": "worker\t2m\t3Mi\n", "": "demo\tworker\t2m\t3Mi\n"} {
		out.Reset()
		if err := podMetrics(context.Background(), cfg, namespace, &out); err != nil {
			t.Fatal(err)
		}
		if out.String() != want {
			t.Fatalf("metrics output %q", out.String())
		}
	}
}

func TestForwardPortResolution(t *testing.T) {
	pod := &corev1.Pod{Spec: corev1.PodSpec{Containers: []corev1.Container{
		{Ports: []corev1.ContainerPort{{Name: "http", ContainerPort: 8080, Protocol: corev1.ProtocolTCP}, {Name: "dns", ContainerPort: 53, Protocol: corev1.ProtocolUDP}}},
	}}}
	service := &corev1.Service{Spec: corev1.ServiceSpec{Ports: []corev1.ServicePort{
		{Name: "web", Port: 80, TargetPort: intstr.FromString("http")},
	}}}
	for _, test := range []struct {
		service *corev1.Service
		port    string
		want    int
	}{
		{service, "80", 8080}, {service, "web", 8080}, {service, "8080", 0}, {nil, "http", 8080}, {nil, "443", 443}, {nil, "dns", 0}, {nil, "53", 0},
	} {
		port, err := targetPort(pod, test.service, test.port)
		if port != test.want || (err == nil) != (test.want > 0) {
			t.Errorf("%s => %d, %v", test.port, port, err)
		}
	}
}
