package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sort"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/rest"
)

type logContainer struct {
	Name         string `json:"name"`
	RestartCount int32  `json:"restartCount"`
}

type logPod struct {
	ID         types.UID      `json:"id"`
	Name       string         `json:"name"`
	Containers []logContainer `json:"containers"`
}

func deploymentLogPods(ctx context.Context, cfg *rest.Config, namespace, name, uid string, out io.Writer) error {
	if len(validation.IsDNS1123Label(namespace)) != 0 || len(validation.IsDNS1123Subdomain(name)) != 0 || uid == "" {
		return errors.New("invalid deployment")
	}
	client, err := coreClient(cfg)
	if err != nil {
		return err
	}
	apps := func() *rest.Request { return client.Get().AbsPath("/apis/apps/v1").Namespace(namespace) }

	var deployment struct {
		Metadata metav1.ObjectMeta
		Spec     struct{ Selector *metav1.LabelSelector }
	}
	raw, err := apps().Resource("deployments").Name(name).SetHeader("Accept", "application/json").Do(ctx).Raw()
	if err != nil {
		return err
	}
	if err := json.Unmarshal(raw, &deployment); err != nil {
		return err
	}
	if string(deployment.Metadata.UID) != uid {
		return apierrors.NewNotFound(schema.GroupResource{Group: "apps", Resource: "deployments"}, name)
	}
	if deployment.Spec.Selector == nil {
		return errors.New("missing deployment selector")
	}
	selector, err := metav1.LabelSelectorAsSelector(deployment.Spec.Selector)
	if err != nil {
		return err
	}
	// Labels narrow the server-side lists. Only controller UIDs establish ownership,
	// including old ReplicaSets that still own pods during a rollout.
	owners := map[types.UID]bool{}
	err = listLogCandidates(ctx, func() *rest.Request { return apps().Resource("replicasets") }, selector.String(), func(rs metav1.PartialObjectMetadata) {
		if owner := metav1.GetControllerOfNoCopy(&rs); owner != nil && owner.Kind == "Deployment" && string(owner.UID) == uid {
			owners[rs.UID] = true
		}
	})
	if err != nil {
		return err
	}
	pods := []logPod{}
	if len(owners) > 0 {
		err = listLogCandidates(ctx, func() *rest.Request { return client.Get().Namespace(namespace).Resource("pods") }, selector.String(), func(pod corev1.Pod) {
			if owner := metav1.GetControllerOfNoCopy(&pod); owner != nil && owner.Kind == "ReplicaSet" && owners[owner.UID] {
				pods = append(pods, podLogOption(&pod))
			}
		})
		if err != nil {
			return err
		}
	}
	sort.Slice(pods, func(i, j int) bool { return pods[i].Name < pods[j].Name })
	return json.NewEncoder(out).Encode(pods)
}

func listLogCandidates[T any](ctx context.Context, request func() *rest.Request, selector string, accept func(T)) error {
	token := ""
	for {
		req := request().SetHeader("Accept", "application/json").Param("labelSelector", selector).Param("limit", "250")
		if token != "" {
			req.Param("continue", token)
		}
		raw, err := req.Do(ctx).Raw()
		if err != nil {
			return err
		}
		var page struct {
			Metadata metav1.ListMeta
			Items    []T
		}
		if err := json.Unmarshal(raw, &page); err != nil {
			return err
		}
		for _, item := range page.Items {
			accept(item)
		}
		token = page.Metadata.Continue
		if token == "" {
			return nil
		}
	}
}

func podLogOption(pod *corev1.Pod) logPod {
	restarts := map[string]int32{}
	for _, statuses := range [][]corev1.ContainerStatus{pod.Status.ContainerStatuses, pod.Status.InitContainerStatuses, pod.Status.EphemeralContainerStatuses} {
		for _, s := range statuses {
			restarts[s.Name] = s.RestartCount
		}
	}
	result := logPod{ID: pod.UID, Name: pod.Name, Containers: []logContainer{}}
	add := func(name string) { result.Containers = append(result.Containers, logContainer{name, restarts[name]}) }
	for _, c := range pod.Spec.Containers {
		add(c.Name)
	}
	for _, c := range pod.Spec.InitContainers {
		add(c.Name)
	}
	for _, c := range pod.Spec.EphemeralContainers {
		add(c.Name)
	}
	return result
}
