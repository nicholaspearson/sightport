package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/rest"
)

func TestResourceInspectionIdentityAndShape(t *testing.T) {
	for _, tc := range []struct{ resource, ns, format, uid, object, want string }{
		{"pods", "demo", "yaml", "a", `"kind":"Pod","spec":{"futureField":"preserved"}`, "futureField: preserved"},
		{"nodes", "", "yaml", "a", `"kind":"Node","spec":{"podCIDR":"10.0.1.0/24"}`, "podCIDR: 10.0.1.0/24"},
		{"nodes", "", "details", "a", `"kind":"Node","status":{"nodeInfo":{"architecture":"arm64"}}`, `"architecture":"arm64"`},
		{"serviceaccounts", "demo", "details", "a", `"kind":"ServiceAccount","imagePullSecrets":[{"name":"private"}]`, `{"eks.amazonaws.com/role-arn":"arn:example"}`},
		{"pods", "demo", "yaml", "replaced", `"kind":"Pod"`, ""},
	} {
		t.Run(tc.resource+tc.format+tc.uid, func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				prefix := "/api/v1/"
				if tc.ns != "" {
					prefix += "namespaces/" + tc.ns + "/"
				}
				if r.Method != "GET" || r.URL.Path != prefix+tc.resource+"/example" {
					t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
				}
				w.Header().Set("Content-Type", "application/json")
				fmt.Fprintf(w, `{"apiVersion":"v1",%s,"metadata":{"name":"example","namespace":%q,"uid":"a","annotations":{"eks.amazonaws.com/role-arn":"arn:example"}}}`, tc.object, tc.ns)
			}))
			defer server.Close()
			var out bytes.Buffer
			err := run(context.Background(), []string{"--kubeconfig=" + writeKubeconfig(t, server), "--context=selected", "inspect-resource", tc.resource + "/example", "-o", tc.format, "--namespace=" + tc.ns, "--uid=" + tc.uid}, nil, &out)
			if tc.want == "" {
				if err != changedSelection || out.Len() != 0 {
					t.Fatalf("expected replaced selection with no output, got %v", err)
				}
			} else if err != nil || !strings.Contains(out.String(), tc.want) || strings.Contains(out.String(), "private") {
				t.Fatalf("unexpected result: %v, %q", err, out.String())
			}
		})
	}
}

func TestDeleteNodeSendsUIDPrecondition(t *testing.T) {
	calls := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != "DELETE" || r.URL.Path != "/api/v1/nodes/worker" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		var options metav1.DeleteOptions
		if err := json.NewDecoder(r.Body).Decode(&options); err != nil || options.Preconditions == nil || options.Preconditions.UID == nil || *options.Preconditions.UID != "original" {
			t.Error("missing UID precondition")
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		io.WriteString(w, `{"apiVersion":"v1","kind":"Status","reason":"Conflict","status":"Failure","code":409}`)
	}))
	defer server.Close()
	err := run(context.Background(), []string{"--kubeconfig=" + writeKubeconfig(t, server), "--context=selected", "delete-node", "worker", "--uid=original"}, nil, io.Discard)
	if err != changedSelection || calls != 1 {
		t.Fatalf("got %v, %d calls", err, calls)
	}
}

func TestNodeDrainPreflightAndEviction(t *testing.T) {
	for _, tc := range []struct {
		mode string
		want error
	}{
		{"evict", nil}, {"local-data", localDataPod}, {"unmanaged", unmanagedPod}, {"replacement", changedSelection}, {"budget-timeout", drainBudgetTimeout},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			var cordoned, finished bool
			evictions, lists := 0, 0
			controller := true
			managed := corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: "worker-pod", Namespace: "demo", UID: "pod-uid", OwnerReferences: []metav1.OwnerReference{{Kind: "ReplicaSet", APIVersion: "apps/v1", Controller: &controller}}}, Spec: corev1.PodSpec{NodeName: "worker"}}
			daemon := managed.DeepCopy()
			daemon.Name = "daemon"
			daemon.OwnerReferences[0].Kind = "DaemonSet"
			mirror := managed.DeepCopy()
			mirror.Name = "mirror"
			mirror.Annotations = map[string]string{corev1.MirrorPodAnnotationKey: "hash"}
			switch tc.mode {
			case "unmanaged":
				managed.OwnerReferences = nil
			case "local-data":
				managed.Spec.Volumes = []corev1.Volume{{VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}}}
			}
			// All calls are synchronous and sequential through client-go.
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				switch {
				case r.Method == "GET" && r.URL.Path == "/api/v1/pods":
					lists++
					if r.URL.Query().Get("fieldSelector") != "spec.nodeName=worker" {
						t.Error("missing node filter")
					}
					items := []corev1.Pod{*daemon, *mirror}
					if !finished {
						items = append(items, managed)
					}
					json.NewEncoder(w).Encode(corev1.PodList{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "PodList"}, Items: items})
				case r.Method == "GET" && r.URL.Path == "/api/v1/nodes/worker":
					node := corev1.Node{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Node"}, ObjectMeta: metav1.ObjectMeta{Name: "worker", UID: "node-uid", ResourceVersion: "7"}, Spec: corev1.NodeSpec{Unschedulable: cordoned}}
					if tc.mode == "replacement" && cordoned {
						node.UID = "new-node"
					}
					json.NewEncoder(w).Encode(node)
				case r.Method == "PATCH" && r.URL.Path == "/api/v1/nodes/worker":
					var patch corev1.Node
					if err := json.NewDecoder(r.Body).Decode(&patch); err != nil || patch.UID != "node-uid" || patch.ResourceVersion != "7" || !patch.Spec.Unschedulable {
						t.Error("cordon was not preconditioned")
					}
					cordoned = true
					io.WriteString(w, `{"kind":"Node","apiVersion":"v1"}`)
				case r.Method == "POST" && r.URL.Path == "/api/v1/namespaces/demo/pods/worker-pod/eviction":
					if !cordoned {
						t.Error("eviction before cordon")
					}
					var ev policyv1.Eviction
					if err := json.NewDecoder(r.Body).Decode(&ev); err != nil || ev.APIVersion != "policy/v1" || ev.DeleteOptions == nil || ev.DeleteOptions.Preconditions == nil || ev.DeleteOptions.Preconditions.UID == nil || *ev.DeleteOptions.Preconditions.UID != "pod-uid" || ev.DeleteOptions.GracePeriodSeconds != nil {
						t.Error("invalid eviction")
					}
					evictions++
					if evictions == 1 || tc.mode == "budget-timeout" {
						w.WriteHeader(429)
						io.WriteString(w, `{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"TooManyRequests","code":429}`)
					} else {
						finished = true
						io.WriteString(w, `{"kind":"Status","apiVersion":"v1","status":"Success"}`)
					}
				default:
					t.Errorf("unexpected API request %s %s", r.Method, r.URL.Path)
					w.WriteHeader(400)
				}
			}))
			defer server.Close()
			cfg := &rest.Config{Host: server.URL, TLSClientConfig: rest.TLSClientConfig{Insecure: true}, QPS: 1000, Burst: 1000}
			client, err := coreClient(cfg)
			if err != nil {
				t.Fatal(err)
			}
			deadline := 2 * time.Second
			interval := time.Millisecond
			if tc.mode == "budget-timeout" {
				deadline = 250 * time.Millisecond
				interval = time.Second
			}
			ctx, cancel := context.WithTimeout(context.Background(), deadline)
			defer cancel()
			err = drainNode(ctx, client, "worker", "node-uid", interval)
			if !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
			if tc.mode == "evict" && (!finished || evictions != 2 || lists < 3) {
				t.Fatal("expected budget retry and final pod list")
			}
			if (tc.mode == "unmanaged" || tc.mode == "local-data") && (cordoned || evictions > 0) {
				t.Fatal("unsafe drain had side effects")
			}
			if tc.mode == "replacement" && evictions > 0 {
				t.Fatal("evicted from replacement node")
			}
		})
	}
}
