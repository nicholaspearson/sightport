package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/cli-runtime/pkg/printers"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

type projection struct {
	template *printers.GoTemplatePrinter
}

func newProjection(format string) (*projection, error) {
	source, ok := strings.CutPrefix(format, "go-template=")
	if !ok || source == "" {
		return nil, errors.New("missing projection")
	}
	printer, err := printers.NewGoTemplatePrinter([]byte(source))
	if err != nil {
		return nil, errors.New("invalid projection")
	}
	printer.AllowMissingKeys(true)
	return &projection{template: printer}, nil
}

func (p *projection) print(obj runtime.Object, out io.Writer) error {
	// The upstream printer writes the entire source object as diagnostics on
	// template errors. Only release successfully projected output to the app.
	var buf bytes.Buffer
	if err := p.template.PrintObj(obj, &buf); err != nil {
		return errors.New("invalid resource projection")
	}
	_, err := buf.WriteTo(out)
	return err
}

func rawGet(ctx context.Context, cfg *rest.Config, path string, out io.Writer) error {
	uri, err := url.ParseRequestURI(path)
	if err != nil || uri.IsAbs() || !strings.HasPrefix(path, "/") || strings.HasPrefix(path, "//") {
		return errors.New("invalid API path")
	}
	client, err := rest.UnversionedRESTClientFor(dynamic.ConfigFor(cfg))
	if err != nil {
		return err
	}
	body, err := client.Get().RequestURI(path).Stream(ctx)
	if err != nil {
		return err
	}
	defer body.Close()
	_, err = io.Copy(out, body)
	return err
}

func get(ctx context.Context, cfg *rest.Config, o options, target string, out io.Writer) error {
	resource, name, named := strings.Cut(target, "/")
	if resource == "" || (named && (name == "" || strings.Contains(name, "/"))) {
		return errors.New("invalid resource")
	}
	project, err := newProjection(o.output)
	if err != nil {
		return err
	}
	client, err := rest.UnversionedRESTClientFor(dynamic.ConfigFor(cfg))
	if err != nil {
		return err
	}
	mapping, err := resourceMapping(ctx, client, resource, o.apiVersion)
	if err != nil {
		return err
	}
	endpoint := dynamic.New(client).Resource(mapping.resource)
	var api dynamic.ResourceInterface = endpoint
	if mapping.namespaced {
		ns := o.namespace
		if ns == "" && !o.allNamespaces {
			ns = metav1.NamespaceDefault
		}
		if ns == "" && named {
			return errors.New("missing namespace")
		}
		api = endpoint.Namespace(ns)
	}
	if named {
		obj, err := api.Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return err
		}
		return project.print(obj, out)
	}
	return listAndWatch(ctx, api, o, project, out)
}

type mapping struct {
	resource   schema.GroupVersionResource
	namespaced bool
}

var errResourceType = errors.New("server doesn't have a resource type")

// Only discover versions of the requested group. An unavailable aggregated
// API elsewhere on the cluster must not delay a core or custom resource read.
func resourceMapping(ctx context.Context, client rest.Interface, resource, explicitVersion string) (*mapping, error) {
	name, group, _ := strings.Cut(resource, ".")
	if len(validation.IsDNS1123Label(name)) != 0 {
		return nil, errResourceType
	}
	if explicitVersion != "" {
		var ok bool
		group, ok = strings.CutPrefix(group, explicitVersion+".")
		if !ok || len(validation.IsDNS1123Label(explicitVersion)) != 0 || len(validation.IsDNS1123Subdomain(group)) != 0 {
			return nil, errResourceType
		}
		return mappingForVersion(ctx, client, name, schema.GroupVersion{Group: group, Version: explicitVersion})
	}
	if group == "" {
		return mappingForVersion(ctx, client, name, schema.GroupVersion{Version: "v1"})
	}
	if len(validation.IsDNS1123Subdomain(group)) != 0 {
		return nil, errResourceType
	}
	var apiGroup metav1.APIGroup
	if err := discover(ctx, client, []string{"apis", group}, &apiGroup); err != nil {
		return nil, err
	}
	versions := append([]metav1.GroupVersionForDiscovery{apiGroup.PreferredVersion}, apiGroup.Versions...)
	seen := make(map[string]bool)
	for _, gv := range versions {
		v := gv.Version
		if len(validation.IsDNS1123Label(v)) != 0 || seen[v] {
			continue
		}
		seen[v] = true
		found, err := mappingForVersion(ctx, client, name, schema.GroupVersion{Group: group, Version: v})
		if !errors.Is(err, errResourceType) {
			return found, err
		}
	}
	return nil, errResourceType
}

func mappingForVersion(ctx context.Context, client rest.Interface, name string, version schema.GroupVersion) (*mapping, error) {
	path := []string{"api", version.Version}
	if version.Group != "" {
		path = []string{"apis", version.Group, version.Version}
	}
	var list metav1.APIResourceList
	if err := discover(ctx, client, path, &list); err != nil {
		return nil, err
	}
	for _, item := range list.APIResources {
		if !strings.Contains(item.Name, "/") && (item.Name == name || item.SingularName == name || strings.EqualFold(item.Kind, name)) {
			return &mapping{resource: version.WithResource(item.Name), namespaced: item.Namespaced}, nil
		}
	}
	return nil, errResourceType
}

func discover(ctx context.Context, client rest.Interface, path []string, into any) error {
	data, err := client.Get().AbsPath(path...).SetHeader("Accept", "application/json").Do(ctx).Raw()
	if apierrors.IsNotFound(err) {
		return errResourceType
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(data, into)
}

func listAndWatch(ctx context.Context, api dynamic.ResourceInterface, o options, project *projection, out io.Writer) error {
	selectors := metav1.ListOptions{LabelSelector: o.selector, FieldSelector: o.fieldSelector}
	pageOptions := selectors
	pageOptions.Limit = 500
	var snapshot *unstructured.UnstructuredList
	var version string
	for {
		page, err := api.List(ctx, pageOptions)
		if err != nil {
			return err
		}
		if pageOptions.Continue == "" {
			version = page.GetResourceVersion()
		}
		if o.watch {
			for i := range page.Items {
				if err := printEvent(project, out, watch.Added, &page.Items[i], o.watchEvents); err != nil {
					return err
				}
			}
		} else if snapshot == nil {
			snapshot = page
		} else {
			snapshot.Items = append(snapshot.Items, page.Items...)
		}
		pageOptions.Continue = page.GetContinue()
		if pageOptions.Continue == "" {
			break
		}
	}
	if !o.watch {
		snapshot.SetContinue("")
		snapshot.SetRemainingItemCount(nil)
		return project.print(snapshot, out)
	}
	// stdout is an unbuffered *os.File. The Swift reader can publish a whole
	// snapshot even if the list is empty or RBAC rejects the subsequent watch.
	if o.initialSnapshot {
		if _, err := io.WriteString(out, "SYNC\n"); err != nil {
			return err
		}
	}
	if version == "" {
		return errors.New("resource list omitted its resource version")
	}
	selectors.ResourceVersion = version
	selectors.AllowWatchBookmarks = true
	stream, err := api.Watch(ctx, selectors)
	if err != nil {
		return err
	}
	defer stream.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event, open := <-stream.ResultChan():
			if !open {
				return ctx.Err()
			}
			switch event.Type {
			case watch.Bookmark:
				continue
			case watch.Error:
				return apierrors.FromObject(event.Object)
			case watch.Added, watch.Modified, watch.Deleted:
				if err := printEvent(project, out, event.Type, event.Object, o.watchEvents); err != nil {
					return err
				}
			default:
				return errors.New("unexpected resource watch event")
			}
		}
	}
}

func printEvent(project *projection, out io.Writer, typ watch.EventType, obj runtime.Object, envelope bool) error {
	if !envelope {
		return project.print(obj, out)
	}
	if obj == nil {
		return fmt.Errorf("empty %s event", typ)
	}
	return project.print(&metav1.WatchEvent{Type: string(typ), Object: runtime.RawExtension{Object: obj}}, out)
}
