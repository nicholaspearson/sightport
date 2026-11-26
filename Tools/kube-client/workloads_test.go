package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func runWorkloadFixture(t *testing.T, action, resource, name string, handle http.HandlerFunc) (string, error) {
	t.Helper()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fixture-token" {
			t.Error("expected selected context credential")
		}
		w.Header().Set("Content-Type", "application/json")
		handle(w, r)
	}))
	defer server.Close()
	var out bytes.Buffer
	err := run(context.Background(), []string{"--kubeconfig=" + writeKubeconfig(t, server), "--context=selected", action,
		resource, name, "--namespace=example", "--uid=uid-1", "--request-timeout=5s"}, nil, &out)
	return out.String(), err
}

func workloadSource(kind, name string) map[string]any {
	version := "apps/v1"
	if kind == "CronJob" || kind == "Job" {
		version = "batch/v1"
	}
	return map[string]any{
		"apiVersion": version, "kind": kind,
		"metadata": map[string]any{"name": name, "namespace": "example", "uid": "uid-1", "resourceVersion": "342"},
	}
}

func TestWorkloadRestartOnlyPatchesSelectedTemplate(t *testing.T) {
	for _, c := range []struct{ resource, kind, strategy string }{
		{"deployments", "Deployment", ""}, {"daemonsets", "DaemonSet", ""}, {"statefulsets", "StatefulSet", "OnDelete"},
	} {
		t.Run(c.resource, func(t *testing.T) {
			reads, writes := 0, 0
			output, err := runWorkloadFixture(t, "restart-workload", c.resource, "web", func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/apis/apps/v1/namespaces/example/"+c.resource+"/web" {
					t.Errorf("wrong path %s", r.URL.Path)
				}
				switch r.Method {
				case "GET":
					reads++
					obj := workloadSource(c.kind, "web")
					obj["spec"] = map[string]any{"updateStrategy": map[string]any{"type": c.strategy}}
					json.NewEncoder(w).Encode(obj)
				case "PATCH":
					writes++
					if r.Header.Get("Content-Type") != "application/merge-patch+json" {
						t.Error("wrong patch type")
					}
					var patch map[string]any
					if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
						t.Error(err)
					}
					uid, _, _ := unstructured.NestedString(patch, "metadata", "uid")
					version, _, _ := unstructured.NestedString(patch, "metadata", "resourceVersion")
					stamp, _, _ := unstructured.NestedString(patch, "spec", "template", "metadata", "annotations", "kubectl.kubernetes.io/restartedAt")
					spec, _, _ := unstructured.NestedMap(patch, "spec")
					if _, err := time.Parse(time.RFC3339Nano, stamp); err != nil || len(spec) != 1 || uid != "uid-1" || version != "342" {
						t.Errorf("invalid scoped patch %v", patch)
					}
					io.WriteString(w, "{}")
				default:
					t.Errorf("unexpected method %s", r.Method)
				}
			})
			if err != nil || output != c.strategy || reads != 1 || writes != 1 {
				t.Fatalf("%d reads, %d writes, output %q, error %v", reads, writes, output, err)
			}
		})
	}
}

func TestManualJobCreatesFreshIdentityAndKeepsTemplate(t *testing.T) {
	for _, c := range []struct{ resource, kind string }{{"cronjobs", "CronJob"}, {"jobs", "Job"}} {
		t.Run(c.resource, func(t *testing.T) {
			name := strings.Repeat("a", 63)
			writes := 0
			output, err := runWorkloadFixture(t, "start-job", c.resource, name, func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "GET" {
					if r.URL.Path != "/apis/batch/v1/namespaces/example/"+c.resource+"/"+name {
						t.Error(r.URL.Path)
					}
					obj := workloadSource(c.kind, name)
					metadata := map[string]any{"labels": map[string]string{"app": "daily"}, "annotations": map[string]string{"custom.io/run": "batch"}}
					spec := map[string]any{
						"suspend": c.kind == "CronJob", "backoffLimit": 7, "selector": map[string]any{"matchLabels": map[string]string{"controller-uid": "old"}},
						"template": map[string]any{
							"metadata": map[string]any{"labels": map[string]string{"batch.kubernetes.io/job-name": name, "controller-uid": "old", "app": "daily"}},
							"spec":     map[string]any{"containers": []any{map[string]string{"name": "worker", "image": "example:1"}}, "restartPolicy": "Never"},
						},
					}
					if c.kind == "CronJob" {
						obj["spec"] = map[string]any{"schedule": "@daily", "jobTemplate": map[string]any{"metadata": metadata, "spec": spec}}
					} else {
						obj["spec"] = spec
						for k, v := range metadata {
							obj["metadata"].(map[string]any)[k] = v
						}
						obj["metadata"].(map[string]any)["finalizers"] = []string{"example.io/done"}
						obj["status"] = map[string]any{"succeeded": 1}
					}
					json.NewEncoder(w).Encode(obj)
					return
				}
				writes++
				if r.Method != "POST" || r.URL.Path != "/apis/batch/v1/namespaces/example/jobs" {
					t.Errorf("wrong submit %s %s", r.Method, r.URL.Path)
				}
				raw, _ := io.ReadAll(r.Body)
				var job unstructured.Unstructured
				if err := job.UnmarshalJSON(raw); err != nil {
					t.Error(err)
				}
				spec, _, _ := unstructured.NestedMap(job.Object, "spec")
				podLabels, _, _ := unstructured.NestedStringMap(spec, "template", "metadata", "labels")
				containers, _, _ := unstructured.NestedSlice(spec, "template", "spec", "containers")
				if job.GetGenerateName() != strings.Repeat("a", 53)+"-run-" || job.GetNamespace() != "example" ||
					job.GetName() != "" || job.GetUID() != "" || job.GetResourceVersion() != "" || len(job.GetFinalizers()) > 0 ||
					job.GetLabels()["app"] != "daily" || job.GetAnnotations()["custom.io/run"] != "batch" || job.Object["status"] != nil ||
					len(podLabels) != 1 || podLabels["app"] != "daily" || len(containers) != 1 || spec["selector"] != nil ||
					spec["suspend"] != nil || spec["backoffLimit"] != int64(7) {
					t.Errorf("incorrect Job: %s", raw)
				}
				json.NewEncoder(w).Encode(workloadSource("Job", "daily-run-test1"))
			})
			if err != nil || writes != 1 || output != "daily-run-test1" {
				t.Fatalf("output %q, writes %d, error %v", output, writes, err)
			}
		})
	}
}

func TestIneligibleWorkloadNeverMutates(t *testing.T) {
	for _, c := range []struct {
		test, verb, resource, kind string
		edit                       func(map[string]any)
		want                       workloadError
	}{
		{"paused deployment", "restart-workload", "deployments", "Deployment", func(obj map[string]any) { obj["spec"] = map[string]any{"paused": true} }, workloadPaused},
		{"already resumed Job", "resume-job", "jobs", "Job", func(obj map[string]any) { obj["spec"] = map[string]any{"suspend": false} }, workloadChanged},
		{"suspended before rerun", "start-job", "jobs", "Job", func(obj map[string]any) { obj["spec"] = map[string]any{"suspend": true} }, workloadChanged},
		{"recreated cronjob", "start-job", "cronjobs", "CronJob", func(obj map[string]any) { obj["metadata"].(map[string]any)["uid"] = "new-uid" }, workloadChanged},
		{"manual pod selector", "start-job", "jobs", "Job", func(obj map[string]any) { obj["spec"] = map[string]any{"manualSelector": true} }, workloadSelector},
	} {
		t.Run(c.test, func(t *testing.T) {
			_, err := runWorkloadFixture(t, c.verb, c.resource, "run", func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "GET" {
					t.Error("unexpected mutation", r.Method)
				}
				obj := workloadSource(c.kind, "run")
				c.edit(obj)
				json.NewEncoder(w).Encode(obj)
			})
			if err != c.want {
				t.Fatalf("got %v, want %v", err, c.want)
			}
		})
	}
}

func TestRestartDoesNotRepeatRejectedOrUnconfirmedRequest(t *testing.T) {
	for _, c := range []struct {
		code               int
		reason, diagnostic string
	}{
		{403, "Forbidden", "Forbidden"}, {409, "Conflict", "workload-changed"}, {422, "Invalid", "workload-rejected"},
		{503, "ServiceUnavailable", "workload-unconfirmed"}, {307, "", "workload-unconfirmed"},
	} {
		t.Run(fmt.Sprint(c.code), func(t *testing.T) {
			writes := 0
			_, err := runWorkloadFixture(t, "restart-workload", "deployments", "api", func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "GET" {
					json.NewEncoder(w).Encode(workloadSource("Deployment", "api"))
					return
				}
				writes++
				if c.code == 307 {
					w.Header().Set("Location", "/other")
				}
				if c.code == 503 {
					w.Header().Set("Retry-After", "1")
				}
				w.WriteHeader(c.code)
				fmt.Fprintf(w, `{"apiVersion":"v1","kind":"Status","status":"Failure","reason":%q,"code":%d}`, c.reason, c.code)
			})
			if err == nil || diagnostic(err) != c.diagnostic || writes != 1 {
				t.Fatalf("%d writes, error %v", writes, err)
			}
		})
	}
}

func TestStartJobFailureNeverCreatesASecondJob(t *testing.T) {
	for _, resource := range []string{"jobs", "cronjobs"} {
		t.Run(resource, func(t *testing.T) {
			writes := 0
			output, err := runWorkloadFixture(t, "start-job", resource, "backup", func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "GET" {
					source := workloadSource("Job", "backup")
					spec := map[string]any{"template": map[string]any{"spec": map[string]any{"restartPolicy": "Never"}}}
					if resource == "cronjobs" {
						source["kind"] = "CronJob"
						spec = map[string]any{"jobTemplate": map[string]any{"spec": spec}}
					}
					source["spec"] = spec
					json.NewEncoder(w).Encode(source)
					return
				}
				writes++
				// The API received the create; the response never reaches the helper.
				io.Copy(io.Discard, r.Body)
				conn, _, err := w.(http.Hijacker).Hijack()
				if err != nil {
					t.Error(err)
					return
				}
				conn.Close()
			})
			if err != workloadUnconfirmed || output != "" || writes != 1 {
				t.Fatalf("output %q, writes %d, error %v", output, writes, err)
			}
		})
	}
}

func TestStartSuspendedJobPatchesOriginal(t *testing.T) {
	writes := 0
	output, err := runWorkloadFixture(t, "resume-job", "jobs", "backup", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/apis/batch/v1/namespaces/example/jobs/backup" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if r.Method == "GET" {
			obj := workloadSource("Job", "backup")
			obj["spec"] = map[string]any{"suspend": true}
			json.NewEncoder(w).Encode(obj)
			return
		}
		writes++
		if r.Method != "PATCH" || r.Header.Get("Content-Type") != "application/merge-patch+json" {
			t.Errorf("unexpected request %s %s", r.Method, r.Header.Get("Content-Type"))
		}
		var patch map[string]any
		if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
			t.Error(err)
			return
		}
		uid, _, _ := unstructured.NestedString(patch, "metadata", "uid")
		version, _, _ := unstructured.NestedString(patch, "metadata", "resourceVersion")
		suspended, ok, _ := unstructured.NestedBool(patch, "spec", "suspend")
		spec, _, _ := unstructured.NestedMap(patch, "spec")
		if uid != "uid-1" || version != "342" || !ok || suspended || len(spec) != 1 {
			t.Errorf("unexpected resume patch %v", patch)
		}
		io.WriteString(w, "{}")
	})
	if err != nil || writes != 1 || output != "" {
		t.Fatalf("output %q, writes %d, error %v", output, writes, err)
	}
}
