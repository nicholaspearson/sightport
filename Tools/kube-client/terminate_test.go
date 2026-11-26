package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync/atomic"
	"testing"
)

func TestGracefulPodTerminationIsScopedAndNeverReplayed(t *testing.T) {
	for _, tc := range []struct {
		name      string
		status    int
		reason    string
		wantError error
	}{
		{"accepted", 202, "", nil},
		{"forbidden", 403, "Forbidden", podDeleteDenied},
		{"missing", 404, "NotFound", podDeleteMissing},
		{"replaced", 409, "Conflict", podDeleteConflict},
		{"retry-after", 503, "ServiceUnavailable", podDeleteUnconfirmed},
		{"redirect", 307, "", podDeleteUnconfirmed},
		{"lost-response", 0, "", podDeleteUnconfirmed},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if r.Method != http.MethodDelete || r.URL.Path != "/api/v1/namespaces/sandbox/pods/web-0" {
					t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
					w.WriteHeader(400)
					return
				}
				if r.Header.Get("Authorization") != "Bearer fixture-token" {
					t.Error("selected context credential missing")
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				want := map[string]any{"kind": "DeleteOptions", "apiVersion": "v1", "preconditions": map[string]any{"uid": "selected-uid"}}
				if !reflect.DeepEqual(want, body) {
					t.Errorf("unexpected DELETE options %v", body)
				}
				switch tc.status {
				case 0:
					// Simulate an API server receiving the delete and disappearing
					// before it tells the client whether it accepted the request.
					conn, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Error(err)
						return
					}
					conn.Close()
					return
				case 503:
					w.Header().Set("Retry-After", "1")
				case 307:
					w.Header().Set("Location", "/other-target")
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.status)
				if tc.status == 202 {
					io.WriteString(w, `{"apiVersion":"v1","kind":"Status","status":"Success","code":202}`)
				} else {
					fmt.Fprintf(w, `{"apiVersion":"v1","kind":"Status","status":"Failure","message":"private API diagnostic","reason":%q,"code":%d}`, tc.reason, tc.status)
				}
			}))
			defer server.Close()
			var out bytes.Buffer
			err := run(context.Background(), []string{"--kubeconfig=" + writeKubeconfig(t, server), "--context=selected", "--request-timeout=3s", "terminate-pod", "web-0", "--namespace=sandbox", "--uid=selected-uid"}, nil, &out)
			if err != tc.wantError || out.Len() != 0 || calls.Load() != 1 {
				t.Fatalf("got %v with %d calls and %d output bytes", err, calls.Load(), out.Len())
			}
			if err != nil && diagnostic(err) != tc.wantError.Error() {
				t.Fatal("unexpected public diagnostic")
			}
		})
	}
}

func TestInvalidTerminationIdentityMakesNoAPIRequest(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("unexpected API request %s", r.URL.Path)
		w.WriteHeader(400)
	}))
	defer server.Close()
	kubeconfig := writeKubeconfig(t, server)
	for _, args := range [][]string{
		{"web", "--namespace=demo"}, {"web", "--uid=id"}, {"web", "--namespace=demo", "--uid=demo/web"},
		{"services/web", "--namespace=demo", "--uid=id"}, {"web", "--namespace=demo", "--uid=id", "--all-namespaces"},
		{"..", "--namespace=demo", "--uid=id"},
	} {
		argv := append([]string{"--kubeconfig=" + kubeconfig, "--context=selected", "terminate-pod"}, args...)
		err := run(context.Background(), argv, nil, io.Discard)
		if err != podDeleteInvalid {
			t.Fatalf("%v: unexpected error %v", args, err)
		}
	}
}
