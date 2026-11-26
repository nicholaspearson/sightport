package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sort"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func contextMetadata(file string, out io.Writer) error {
	config, err := clientcmd.LoadFromFile(file)
	if err != nil {
		return err
	}
	type details struct {
		Cluster   string `json:"cluster"`
		Namespace string `json:"namespace,omitempty"`
	}
	type entry struct {
		Name    string  `json:"name"`
		Context details `json:"context"`
	}
	entries := make([]entry, 0, len(config.Contexts))
	for name, context := range config.Contexts {
		entries = append(entries, entry{name, details{context.Cluster, context.Namespace}})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name < entries[j].Name })
	// The context picker never needs to receive user credentials or cluster certificates.
	return json.NewEncoder(out).Encode([]any{config.CurrentContext, entries})
}

var coreScheme = runtime.NewScheme()
var coreCodecs = serializer.NewCodecFactory(coreScheme)
var coreParams = runtime.NewParameterCodec(coreScheme)

func init() {
	if err := corev1.AddToScheme(coreScheme); err != nil {
		panic(err)
	}
}

func coreClient(config *rest.Config) (*rest.RESTClient, error) {
	cfg := rest.CopyConfig(config)
	cfg.GroupVersion = &corev1.SchemeGroupVersion
	cfg.APIPath = "/api"
	cfg.NegotiatedSerializer = coreCodecs.WithoutConversion()
	return rest.RESTClientFor(cfg)
}

func podLogs(ctx context.Context, cfg *rest.Config, namespace, pod, container string, previous bool, tail, limit int64, out io.Writer) error {
	client, err := coreClient(cfg)
	if err != nil {
		return err
	}
	opts := corev1.PodLogOptions{Container: container, Previous: previous, TailLines: &tail, LimitBytes: &limit}
	stream, err := client.Get().Namespace(namespace).Resource("pods").Name(pod).SubResource("log").
		VersionedParams(&opts, coreParams).Stream(ctx)
	if err != nil {
		return err
	}
	defer stream.Close()
	_, err = io.Copy(out, io.LimitReader(stream, limit))
	return err
}

func podMetrics(ctx context.Context, cfg *rest.Config, namespace string, out io.Writer) error {
	client, err := coreClient(cfg)
	if err != nil {
		return err
	}
	data, err := client.Get().AbsPath("/apis/metrics.k8s.io/v1beta1").NamespaceIfScoped(namespace, namespace != "").
		Resource("pods").Do(ctx).Raw()
	if err != nil {
		return err
	}
	var list struct {
		Items []struct {
			Metadata   struct{ Namespace, Name string }
			Containers []struct{ Usage corev1.ResourceList }
		}
	}
	if err = json.Unmarshal(data, &list); err != nil {
		return err
	}
	for _, item := range list.Items {
		sum := make(corev1.ResourceList)
		for _, container := range item.Containers {
			for _, name := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory} {
				quantity := sum[name]
				quantity.Add(container.Usage[name])
				sum[name] = quantity
			}
		}
		if namespace == "" {
			if _, err := fmt.Fprint(out, item.Metadata.Namespace, "\t"); err != nil {
				return err
			}
		}
		if _, err := fmt.Fprintf(out, "%s\t%dm\t%dMi\n", item.Metadata.Name, sum.Cpu().MilliValue(), sum.Memory().Value()/(1<<20)); err != nil {
			return err
		}
	}
	return nil
}
