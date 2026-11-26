package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/rest"
)

type workloadError string

func (e workloadError) Error() string { return string(e) }

const (
	workloadInvalid     workloadError = "workload-invalid-target"
	workloadChanged     workloadError = "workload-changed"
	workloadPaused      workloadError = "workload-paused"
	workloadSelector    workloadError = "workload-manual-selector"
	workloadRejected    workloadError = "workload-rejected"
	workloadUnconfirmed workloadError = "workload-unconfirmed"
)

func workloadCommand(ctx context.Context, cfg *rest.Config, o options, args []string, out io.Writer) error {
	if len(args) != 3 || o.allNamespaces || len(validation.IsDNS1123Label(o.namespace)) != 0 ||
		len(validation.IsDNS1123Subdomain(args[2])) != 0 || strings.TrimSpace(o.uid) == "" || strings.ContainsAny(o.uid, "/\x00") {
		return workloadInvalid
	}
	resource, name := args[1], args[2]
	groupVersion := "apps/v1"
	switch args[0] {
	case "restart-workload":
		if resource != "deployments" && resource != "statefulsets" && resource != "daemonsets" {
			return workloadInvalid
		}
	case "resume-job":
		if resource != "jobs" {
			return workloadInvalid
		}
		groupVersion = "batch/v1"
	case "start-job":
		if resource != "cronjobs" && resource != "jobs" {
			return workloadInvalid
		}
		groupVersion = "batch/v1"
	default:
		return workloadInvalid
	}

	client, err := coreClient(cfg)
	if err != nil {
		return err
	}
	httpClient := *client.Client
	httpClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	client.Client = &httpClient

	path := "/apis/" + groupVersion + "/namespaces/" + o.namespace + "/" + resource + "/" + name
	data, err := client.Get().AbsPath(path).SetHeader("Accept", "application/json").Do(ctx).Raw()
	if err != nil {
		return err
	}
	var source unstructured.Unstructured
	if err := source.UnmarshalJSON(data); err != nil {
		return workloadInvalid
	}
	if source.GetName() != name || source.GetNamespace() != o.namespace || string(source.GetUID()) != o.uid ||
		source.GetAPIVersion() != groupVersion || strings.ToLower(source.GetKind())+"s" != resource ||
		source.GetDeletionTimestamp() != nil || source.GetResourceVersion() == "" {
		return workloadChanged
	}
	if args[0] == "restart-workload" {
		paused, _, _ := unstructured.NestedBool(source.Object, "spec", "paused")
		if paused {
			return workloadPaused
		}
		// UID pins the incarnation; resourceVersion prevents a concurrent strategy
		// change or deployment pause from racing this patch.
		patch := map[string]any{
			"metadata": map[string]any{"uid": source.GetUID(), "resourceVersion": source.GetResourceVersion()},
			"spec": map[string]any{"template": map[string]any{"metadata": map[string]any{
				"annotations": map[string]string{"kubectl.kubernetes.io/restartedAt": time.Now().UTC().Format(time.RFC3339Nano)},
			}}},
		}
		_, err = submitWorkload(ctx, client.Patch(types.MergePatchType).AbsPath(path), patch)
		if err != nil {
			return err
		}
		strategy, _, _ := unstructured.NestedString(source.Object, "spec", "updateStrategy", "type")
		if strategy == "OnDelete" {
			_, err = io.WriteString(out, "OnDelete")
		}
		return err
	}

	if resource == "jobs" {
		suspended, _, err := unstructured.NestedBool(source.Object, "spec", "suspend")
		if err != nil {
			return workloadInvalid
		}
		if suspended != (args[0] == "resume-job") {
			return workloadChanged
		}
		if suspended {
			patch := map[string]any{
				"metadata": map[string]any{"uid": source.GetUID(), "resourceVersion": source.GetResourceVersion()},
				"spec":     map[string]any{"suspend": false},
			}
			_, err = submitWorkload(ctx, client.Patch(types.MergePatchType).AbsPath(path), patch)
			return err
		}
	}

	job, err := manualJob(source)
	if err != nil {
		return err
	}
	jobsPath := "/apis/batch/v1/namespaces/" + o.namespace + "/jobs"
	data, err = submitWorkload(ctx, client.Post().AbsPath(jobsPath).SetHeader("Content-Type", "application/json"), job)
	if err != nil {
		return err
	}
	var created unstructured.Unstructured
	if created.UnmarshalJSON(data) != nil || created.GetKind() != "Job" || created.GetNamespace() != o.namespace ||
		len(validation.IsDNS1123Subdomain(created.GetName())) != 0 {
		return workloadUnconfirmed
	}
	_, err = io.WriteString(out, created.GetName())
	return err
}

func submitWorkload(ctx context.Context, req *rest.Request, body any) ([]byte, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return nil, workloadInvalid
	}
	// Do not replay a submitted start if the server creates the Job but loses its response.
	result, err := req.MaxRetries(0).SetHeader("Accept", "application/json").
		Body(io.NopCloser(bytes.NewReader(data))).Do(ctx).Raw()
	switch {
	case err == nil, apierrors.IsForbidden(err), apierrors.IsUnauthorized(err), apierrors.IsNotFound(err):
		return result, err
	case apierrors.IsConflict(err):
		return nil, workloadChanged
	case apierrors.IsInvalid(err), apierrors.IsBadRequest(err):
		return nil, workloadRejected
	default:
		return nil, workloadUnconfirmed
	}
}

func manualJob(source unstructured.Unstructured) (map[string]any, error) {
	template := source.Object
	if source.GetKind() == "CronJob" {
		var ok bool
		template, ok, _ = unstructured.NestedMap(source.Object, "spec", "jobTemplate")
		if !ok {
			return nil, workloadInvalid
		}
	}
	// Use the complete API spec so newer Job fields survive cloning. Only take
	// user metadata, never status, finalizers, owners, or the old object's identity.
	spec, ok, err := unstructured.NestedMap(template, "spec")
	if err != nil || !ok {
		return nil, workloadInvalid
	}
	if manual, _, _ := unstructured.NestedBool(spec, "manualSelector"); manual {
		return nil, workloadSelector
	}
	delete(spec, "selector")
	delete(spec, "manualSelector")
	delete(spec, "suspend")
	labels, _, _ := unstructured.NestedStringMap(template, "metadata", "labels")
	podLabels, hasPodLabels, _ := unstructured.NestedStringMap(spec, "template", "metadata", "labels")
	for _, key := range []string{"job-name", "controller-uid", batchv1.JobNameLabel, batchv1.ControllerUidLabel} {
		delete(labels, key)
		delete(podLabels, key)
	}
	if hasPodLabels {
		if err := unstructured.SetNestedStringMap(spec, podLabels, "template", "metadata", "labels"); err != nil {
			return nil, workloadInvalid
		}
	}
	annotations, _, _ := unstructured.NestedStringMap(template, "metadata", "annotations")
	if annotations == nil {
		annotations = make(map[string]string)
	}
	delete(annotations, "kubectl.kubernetes.io/last-applied-configuration")
	delete(annotations, batchv1.CronJobScheduledTimestampAnnotation)
	annotations["cronjob.kubernetes.io/instantiate"] = "manual"
	// Job names are limited to 63 characters. Reserve room for "-run-" and
	// the API server's five-character generateName suffix.
	base := source.GetName()
	if len(base) > 53 {
		base = strings.TrimRight(base[:53], ".-")
	}
	metadata := map[string]any{"generateName": base + "-run-", "namespace": source.GetNamespace(), "annotations": annotations}
	if len(labels) > 0 {
		metadata["labels"] = labels
	}
	return map[string]any{"apiVersion": "batch/v1", "kind": "Job", "metadata": metadata, "spec": spec}, nil
}
