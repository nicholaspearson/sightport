package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/yaml"
)

type inspectionDiagnostic string

func (e inspectionDiagnostic) Error() string { return string(e) }

const (
	invalidSelection    inspectionDiagnostic = "resource-invalid-selection"
	changedSelection    inspectionDiagnostic = "resource-selection-changed"
	unmanagedPod        inspectionDiagnostic = "node-drain-unmanaged-pod"
	localDataPod        inspectionDiagnostic = "node-drain-local-data"
	schedulingEnabled   inspectionDiagnostic = "node-drain-scheduling-enabled"
	evictionUnavailable inspectionDiagnostic = "node-drain-eviction-unavailable"
	drainBudgetTimeout  inspectionDiagnostic = "node-drain-budget-timeout"
)

func inspectOrManage(ctx context.Context, cfg *rest.Config, o options, args []string, out io.Writer) error {
	if len(args) != 2 || o.allNamespaces || strings.TrimSpace(o.uid) == "" || strings.ContainsAny(o.uid, "/\x00") {
		return invalidSelection
	}
	target := args[1]
	resource := "nodes"
	if args[0] == "inspect-resource" {
		var ok bool
		resource, target, ok = strings.Cut(target, "/")
		if !ok || resource != "nodes" && resource != "pods" && resource != "serviceaccounts" {
			return invalidSelection
		}
	}
	if len(validation.IsDNS1123Subdomain(target)) > 0 || resource == "nodes" && o.namespace != "" ||
		resource != "nodes" && len(validation.IsDNS1123Label(o.namespace)) > 0 {
		return invalidSelection
	}
	client, err := coreClient(cfg)
	if err != nil {
		return err
	}
	httpClient := *client.Client
	httpClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	client.Client = &httpClient
	uid := types.UID(o.uid)
	switch args[0] {
	case "inspect-resource":
		return inspectResource(ctx, client, resource, o.namespace, target, uid, o.output, out)
	case "delete-node":
		body, err := json.Marshal(metav1.DeleteOptions{Preconditions: &metav1.Preconditions{UID: &uid}})
		if err != nil {
			return err
		}
		err = client.Delete().Resource("nodes").Name(target).Body(body).MaxRetries(0).Do(ctx).Error()
		if apierrors.IsConflict(err) || apierrors.IsNotFound(err) {
			return changedSelection
		}
		return err
	case "drain-node":
		return drainNode(ctx, client, target, uid, 3*time.Second)
	}
	return invalidSelection
}

// Read the raw object so a manifest preserves fields unknown to this version of client-go.
func inspectResource(ctx context.Context, client *rest.RESTClient, resource, namespace, name string, uid types.UID, format string, out io.Writer) error {
	if format != "yaml" && format != "details" || resource == "serviceaccounts" && format != "details" ||
		resource == "pods" && format != "yaml" {
		return invalidSelection
	}
	req := client.Get().Resource(resource).Name(name).SetHeader("Accept", "application/json")
	if namespace != "" {
		req = req.Namespace(namespace)
	}
	raw, err := req.DoRaw(ctx)
	if apierrors.IsNotFound(err) {
		return changedSelection
	}
	if err != nil {
		return err
	}
	var meta struct {
		Metadata metav1.ObjectMeta `json:"metadata"`
	}
	if err := json.Unmarshal(raw, &meta); err != nil {
		return err
	}
	if meta.Metadata.UID != uid || meta.Metadata.Name != name || meta.Metadata.Namespace != namespace {
		return changedSelection
	}
	if format == "yaml" {
		manifest, err := yaml.JSONToYAML(raw)
		if err != nil {
			return err
		}
		_, err = out.Write(manifest)
		return err
	}
	if resource == "serviceaccounts" {
		if meta.Metadata.Annotations == nil {
			meta.Metadata.Annotations = map[string]string{}
		}
		return json.NewEncoder(out).Encode(meta.Metadata.Annotations)
	}
	var node corev1.Node
	if err := json.Unmarshal(raw, &node); err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(map[string]any{
		"unschedulable": node.Spec.Unschedulable, "addresses": node.Status.Addresses,
		"system": node.Status.NodeInfo, "conditions": node.Status.Conditions,
		"capacity": node.Status.Capacity, "allocatable": node.Status.Allocatable, "labels": node.Labels, "taints": node.Spec.Taints,
	})
}

func selectedNode(ctx context.Context, client *rest.RESTClient, name string, uid types.UID) (*corev1.Node, error) {
	var node corev1.Node
	err := client.Get().Resource("nodes").Name(name).Do(ctx).Into(&node)
	if apierrors.IsNotFound(err) {
		return nil, changedSelection
	}
	if err != nil {
		return nil, err
	}
	if node.UID != uid || node.Name != name || node.DeletionTimestamp != nil {
		return nil, changedSelection
	}
	return &node, nil
}

func drainNode(ctx context.Context, client *rest.RESTClient, name string, uid types.UID, interval time.Duration) error {
	node, err := selectedNode(ctx, client, name, uid)
	if err != nil {
		return err
	}
	if !node.Spec.Unschedulable {
		// Check the complete set before changing scheduling or evicting the first pod.
		if _, err := drainCandidates(ctx, client, name); err != nil {
			return err
		}
		if node.ResourceVersion == "" {
			return changedSelection
		}
		patch, err := json.Marshal(map[string]any{
			"metadata": map[string]string{"uid": string(uid), "resourceVersion": node.ResourceVersion},
			"spec":     map[string]bool{"unschedulable": true},
		})
		if err != nil {
			return err
		}
		err = client.Patch(types.MergePatchType).Resource("nodes").Name(name).Body(patch).MaxRetries(0).Do(ctx).Error()
		if apierrors.IsNotFound(err) || apierrors.IsConflict(err) {
			return changedSelection
		}
		if err != nil {
			return err
		}
	}

	accepted := make(map[types.UID]bool)
	for {
		pods, err := drainCandidates(ctx, client, name)
		if err != nil {
			return err
		}
		// A new node can register under the same name. Check the UID after listing
		// pods and bind each ensuing eviction to the listed pod UID.
		node, err := selectedNode(ctx, client, name, uid)
		if err != nil {
			return err
		}
		if !node.Spec.Unschedulable {
			return schedulingEnabled
		}
		if len(pods) == 0 {
			return nil
		}
		budgetBlocked := false
		for _, pod := range pods {
			if accepted[pod.UID] || pod.DeletionTimestamp != nil {
				continue
			}
			eviction := policyv1.Eviction{
				TypeMeta:      metav1.TypeMeta{APIVersion: "policy/v1", Kind: "Eviction"},
				ObjectMeta:    metav1.ObjectMeta{Name: pod.Name, Namespace: pod.Namespace},
				DeleteOptions: &metav1.DeleteOptions{Preconditions: &metav1.Preconditions{UID: &pod.UID}},
			}
			body, err := json.Marshal(eviction)
			if err != nil {
				return err
			}
			err = client.Post().Resource("pods").Namespace(pod.Namespace).Name(pod.Name).SubResource("eviction").
				Body(body).MaxRetries(0).Do(ctx).Error()
			switch {
			case err == nil:
				accepted[pod.UID] = true
			case apierrors.IsTooManyRequests(err):
				budgetBlocked = true
			case apierrors.IsNotFound(err):
				// Distinguish a replaced/deleted pod from an unsupported eviction API.
				var current corev1.Pod
				readErr := client.Get().Resource("pods").Namespace(pod.Namespace).Name(pod.Name).Do(ctx).Into(&current)
				if readErr == nil && current.UID == pod.UID {
					return evictionUnavailable
				}
				if readErr != nil && !apierrors.IsNotFound(readErr) {
					return readErr
				}
			case apierrors.IsConflict(err):
				return changedSelection
			default:
				return err
			}
		}
		select {
		case <-ctx.Done():
			if budgetBlocked && errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return drainBudgetTimeout
			}
			return ctx.Err()
		case <-time.After(interval):
		}
	}
}

func drainCandidates(ctx context.Context, client *rest.RESTClient, node string) ([]metav1.ObjectMeta, error) {
	opts := metav1.ListOptions{FieldSelector: "spec.nodeName=" + node, Limit: 500}
	var pods []metav1.ObjectMeta
	for {
		var list corev1.PodList
		if err := client.Get().Resource("pods").VersionedParams(&opts, coreParams).Do(ctx).Into(&list); err != nil {
			return nil, err
		}
		for i := range list.Items {
			pod := &list.Items[i]
			if pod.Spec.NodeName != node {
				continue
			}
			if _, mirror := pod.Annotations[corev1.MirrorPodAnnotationKey]; mirror {
				continue
			}
			owner := metav1.GetControllerOfNoCopy(pod)
			if owner != nil && owner.Kind == "DaemonSet" && (owner.APIVersion == "apps/v1" || owner.APIVersion == "extensions/v1beta1") {
				continue
			}
			if pod.DeletionTimestamp == nil && pod.Status.Phase != corev1.PodSucceeded && pod.Status.Phase != corev1.PodFailed {
				if owner == nil {
					return nil, unmanagedPod
				}
				for _, volume := range pod.Spec.Volumes {
					if volume.EmptyDir != nil {
						return nil, localDataPod
					}
				}
			}
			if pod.UID == "" || pod.Name == "" || pod.Namespace == "" {
				return nil, invalidSelection
			}
			pods = append(pods, metav1.ObjectMeta{UID: pod.UID, Name: pod.Name, Namespace: pod.Namespace, DeletionTimestamp: pod.DeletionTimestamp})
		}
		if list.Continue == "" {
			return pods, nil
		}
		opts.Continue = list.Continue
	}
}
