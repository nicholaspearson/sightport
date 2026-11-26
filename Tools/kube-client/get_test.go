package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeKubeconfig(t *testing.T, server *httptest.Server) string {
	t.Helper()
	dir := t.TempDir()
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	// Exercise an actual exec plugin through client-go. It lives next to the
	// kubeconfig, like relative-path credential plugins on a user's Mac.
	cred := filepath.Join(dir, "auth")
	if err := os.WriteFile(cred, []byte("#!/bin/sh\necho '{\"kind\":\"ExecCredential\",\"apiVersion\":\"client.authentication.k8s.io/v1\",\"status\":{\"token\":\"fixture-token\"}}'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "config")
	config := fmt.Sprintf(`apiVersion: v1
kind: Config
clusters:
- name: fixture
  cluster:
    server: %s
    certificate-authority-data: %s
users:
- name: operator
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: ./auth
      interactiveMode: Never
contexts:
- name: selected
  context: {cluster: fixture, user: operator, namespace: sandbox}
- name: other
  context: {cluster: invalid, user: operator}
current-context: other
`, server.URL, base64.StdEncoding.EncodeToString(ca))
	if err := os.WriteFile(file, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	return file
}

func coreDiscovery(w io.Writer) {
	io.WriteString(w, `{"kind":"APIResourceList","apiVersion":"v1","groupVersion":"v1","resources":[{"name":"pods","singularName":"pod","namespaced":true,"kind":"Pod","verbs":["list","watch","get"]}]}`)
}

func TestScopedSDKListAndWatchAtConsistentVersion(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "Bearer fixture-token" {
			t.Error("missing selected exec credential")
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/api/v1":
			coreDiscovery(w)
		case "/api/v1/namespaces/sandbox/pods":
			q := r.URL.Query()
			if q.Get("labelSelector") != "app=api" || q.Get("fieldSelector") != "status.phase=Running" {
				t.Errorf("missing selectors: %v", q)
			}
			if q.Get("watch") == "true" {
				if q.Get("resourceVersion") != "29" {
					t.Errorf("watch started at %q", q.Get("resourceVersion"))
				}
				for _, ev := range []string{"MODIFIED", "DELETED"} {
					fmt.Fprintf(w, `{"type":%q,"object":{"kind":"Pod","apiVersion":"v1","metadata":{"name":"beta","resourceVersion":"33"}}}`+"\n", ev)
				}
				return
			}
			name, next := "alpha", "page2"
			if q.Get("continue") == next {
				name, next = "beta", ""
			}
			fmt.Fprintf(w, `{"kind":"PodList","apiVersion":"v1","metadata":{"resourceVersion":"29","continue":%q},"items":[{"kind":"Pod","apiVersion":"v1","metadata":{"name":%q}}]}`, next, name)
		default:
			t.Errorf("unexpected request %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	cfg := writeKubeconfig(t, server)
	var out bytes.Buffer
	project := `go-template={{.type}} {{.object.metadata.name}}{{"\n"}}`
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := run(ctx, []string{"--kubeconfig=" + cfg, "--context=selected", "get", "pods", "--namespace=sandbox", "--watch", "--output-watch-events", "--initial-snapshot", "--selector=app=api", "--field-selector=status.phase=Running", "-o", project}, nil, &out)
	if err != nil {
		t.Fatal(err)
	}
	if want := "ADDED alpha\nADDED beta\nSYNC\nMODIFIED beta\nDELETED beta\n"; out.String() != want {
		t.Fatalf("got %q; want %q", out.String(), want)
	}
}

func TestEmptyInitialListIsPublishedBeforeWatchDenied(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1":
			coreDiscovery(w)
		case "/api/v1/pods":
			if r.URL.Query().Get("watch") == "true" {
				w.WriteHeader(403)
				io.WriteString(w, `{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"Forbidden","message":"sensitive message","code":403}`)
				return
			}
			io.WriteString(w, `{"kind":"PodList","apiVersion":"v1","metadata":{"resourceVersion":"99"},"items":[]}`)
		default:
			t.Errorf("unexpected request %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	var out bytes.Buffer
	err := run(context.Background(), []string{"--kubeconfig=" + writeKubeconfig(t, server), "--context=selected", "get", "pods", "--all-namespaces", "--watch", "--initial-snapshot", "--output-watch-events", "-o", "go-template={{.type}}"}, nil, &out)
	if err == nil || diagnostic(err) != "Forbidden" || out.String() != "SYNC\n" {
		t.Fatalf("unexpected result %q, %v", out.String(), err)
	}
}

func TestGetNamedSingularAndVersionThroughSelectedContext(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1":
			coreDiscovery(w)
		case "/api/v1/namespaces/sandbox/pods/alpha":
			io.WriteString(w, `{"apiVersion":"v1","kind":"Pod","metadata":{"name":"alpha"},"spec":{"value":"must stay private"}}`)
		case "/version":
			io.WriteString(w, `{"gitVersion":"v1.fixture"}`)
		case "/apis/metrics.k8s.io/v1beta1/namespaces/sandbox/pods":
			io.WriteString(w, `{"items":[{"metadata":{"namespace":"sandbox","name":"worker"},"containers":[{"usage":{"cpu":"1m","memory":"2Mi"}}]}]}`)
		default:
			t.Errorf("unexpected request %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	config := writeKubeconfig(t, server)
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"get", "pod/alpha", "--namespace=sandbox", "-o", "go-template={{.metadata.name}}"}, "alpha"},
		{[]string{"get", "--raw=/version"}, `{"gitVersion":"v1.fixture"}`},
		{[]string{"metrics", "--namespace=sandbox"}, "worker\t1m\t2Mi\n"},
	} {
		var out bytes.Buffer
		err := run(context.Background(), append([]string{"--context=selected", "--kubeconfig=" + config}, tc.args...), nil, &out)
		if err != nil || out.String() != tc.want {
			t.Errorf("got %q, %v; want %q", out.String(), err, tc.want)
		}
	}
}

func TestProjectionPreservesIntegerFieldsAndKubernetesTemplateFunctions(t *testing.T) {
	const input = `{"count":9007199254740993,"nested":[{"decimal":1e6}],"data":"dGVzdA=="}`
	for _, tc := range []struct{ source, want string }{
		{`{{if eq .count 9007199254740993}}{{.count}}{{end}}`, "9007199254740993"},
		{`{{with index .nested 0}}{{if eq .decimal 1000000}}{{.decimal}}{{end}}{{end}}`, "1000000"},
		{`{{base64decode .data}}`, "test"},
	} {
		var out bytes.Buffer
		err := run(context.Background(), []string{"render", "-o", "go-template=" + tc.source}, strings.NewReader(input), &out)
		if err != nil || out.String() != tc.want {
			t.Errorf("got %q, %v; want %q", out.String(), err, tc.want)
		}
	}
}

func TestFailedTemplateDoesNotPrintSourceObject(t *testing.T) {
	var out bytes.Buffer
	input := strings.NewReader(`{"data":{"private":"fixture-secret"}}`)
	err := run(context.Background(), []string{"render", "-o", `go-template={{index .data.private "invalid"}}`}, input, &out)
	if err == nil || out.Len() != 0 || strings.Contains(err.Error(), "fixture-secret") {
		t.Fatal("invalid projection exposed object data or succeeded")
	}
}

func TestReparentedHelperCancelsItsSession(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	watchParent(ctx, cancel, os.Getppid()+1)
	if ctx.Err() != context.Canceled {
		t.Fatal("orphaned session remained active")
	}
}

func TestExplicitAndPreferredCustomResourceVersionsAndScope(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/apis/example.org":
			io.WriteString(w, `{"kind":"APIGroup","apiVersion":"v1","name":"example.org","preferredVersion":{"groupVersion":"example.org/v1","version":"v1"},"versions":[{"groupVersion":"example.org/v1","version":"v1"},{"groupVersion":"example.org/v1beta1","version":"v1beta1"}]}`)
		case "/apis/example.org/removed":
			w.WriteHeader(404)
			io.WriteString(w, `{"kind":"Status","apiVersion":"v1","reason":"NotFound","code":404}`)
		case "/apis/example.org/v1", "/apis/example.org/v1beta1":
			fmt.Fprintf(w, `{"kind":"APIResourceList","apiVersion":"v1","groupVersion":%q,"resources":[{"name":"shards","singularName":"shard","kind":"Shard","namespaced":false}]}`, strings.TrimPrefix(r.URL.Path, "/apis/"))
		case "/apis/example.org/v1/shards", "/apis/example.org/v1beta1/shards":
			json.NewEncoder(w).Encode(map[string]any{"kind": "ShardList", "apiVersion": "example.org/v1", "metadata": map[string]string{"resourceVersion": "4"}, "items": []any{map[string]any{"metadata": map[string]string{"name": strings.Split(r.URL.Path, "/")[3]}}}})
		default:
			t.Errorf("unexpected request %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	config := writeKubeconfig(t, server)
	for _, tc := range []struct{ resource, version, want string }{
		{"shards.example.org", "", "v1"}, {"shards.v1beta1.example.org", "v1beta1", "v1beta1"}, {"shards.removed.example.org", "removed", ""},
	} {
		var out bytes.Buffer
		err := run(context.Background(), []string{"--kubeconfig=" + config, "--context=selected", "get", tc.resource, "--api-version=" + tc.version, "--namespace=ignored-for-cluster-scoped", "-o", "go-template={{range .items}}{{.metadata.name}}{{end}}"}, nil, &out)
		if tc.want == "" {
			if err == nil || diagnostic(err) != "doesn't have a resource type" {
				t.Errorf("missing version silently substituted: %q, %v", out.String(), err)
			}
		} else if err != nil || out.String() != tc.want {
			t.Errorf("resource %q got %q, %v", tc.resource, out.String(), err)
		}
	}
}
