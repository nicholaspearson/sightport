package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/client-go/rest"
)

func TestDeploymentLogPodsFollowControllerUIDsAcrossRollout(t *testing.T) {
	var output bytes.Buffer
	metadata := func(uid, name, kind, owner string, controller bool) string {
		return fmt.Sprintf(`{"uid":%q,"name":%q,"namespace":"blue","ownerReferences":[{"kind":%q,"name":"same-name","uid":%q,"controller":%t}]}`, uid, name, kind, owner, controller)
	}
	pod := func(uid, name, kind, owner string) string {
		return fmt.Sprintf(`{"metadata":%s,"spec":{"containers":[{"name":"api","env":[{"name":"PASSWORD","value":"sensitive"}]}],"initContainers":[{"name":"init"}],"ephemeralContainers":[{"name":"debug"}]},"status":{"containerStatuses":[{"name":"api","restartCount":2}]}}`, metadata(uid, name, kind, owner, true))
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/cluster/apis/apps/v1/namespaces/blue/deployments/api" {
			fmt.Fprint(w, `{"metadata":{"uid":"d1"},"spec":{"selector":{"matchExpressions":[{"key":"app","operator":"In","values":["api"]}]}}}`)
			return
		}
		q := r.URL.Query()
		if q.Get("labelSelector") != "app in (api)" || q.Get("limit") == "" {
			t.Errorf("unexpected query %s", r.URL.RawQuery)
		}
		switch r.URL.Path {
		case "/cluster/apis/apps/v1/namespaces/blue/replicasets":
			if q.Get("continue") == "" {
				fmt.Fprintf(w, `{"metadata":{"continue":"next"},"items":[{"metadata":%s},{"metadata":%s}]}`, metadata("old", "r1", "Deployment", "d1", true), metadata("adopted", "r2", "Deployment", "d1", false))
			} else {
				fmt.Fprintf(w, `{"items":[{"metadata":%s},{"metadata":%s}]}`, metadata("new", "r3", "Deployment", "d1", true), metadata("other", "r4", "Deployment", "d2", true))
			}
		case "/cluster/api/v1/namespaces/blue/pods":
			if q.Get("continue") == "" {
				fmt.Fprintf(w, `{"metadata":{"continue":"next"},"items":[%s,%s,%s]}`, pod("p1", "old-pod", "ReplicaSet", "old"), pod("p2", "foreign", "ReplicaSet", "other"), pod("p3", "non-owner", "ReplicaSet", "adopted"))
			} else {
				fmt.Fprintf(w, `{"items":[%s,%s]}`, pod("p4", "new-pod", "ReplicaSet", "new"), pod("p5", "wrong-kind", "Job", "new"))
			}
		default:
			t.Errorf("unexpected API path %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	cfg := &rest.Config{Host: server.URL + "/cluster"}
	if err := deploymentLogPods(context.Background(), cfg, "blue", "api", "d1", &output); err != nil {
		t.Fatal(err)
	}
	var got []logPod
	if err := json.Unmarshal(output.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	containers := []logContainer{{"api", 2}, {"init", 0}, {"debug", 0}}
	want := []logPod{{"p4", "new-pod", containers}, {"p1", "old-pod", containers}}
	if !reflect.DeepEqual(got, want) || bytes.Contains(output.Bytes(), []byte("sensitive")) {
		t.Fatalf("unexpected log pod options %v", got)
	}
	output.Reset()
	if err := deploymentLogPods(context.Background(), cfg, "blue", "api", "replaced", &output); !apierrors.IsNotFound(err) || output.Len() != 0 {
		t.Fatalf("replaced deployment returned %v, %s", err, output.String())
	}
}
