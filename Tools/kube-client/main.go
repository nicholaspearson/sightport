// sightport-kube is the app's private transport for Kubernetes API operations.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/pflag"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	_ "k8s.io/client-go/plugin/pkg/client/auth"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/json"
)

type options struct {
	file, context, namespace, output, raw, selector, fieldSelector, container, address, apiVersion, uid string
	watch, watchEvents, initialSnapshot, allNamespaces, previous, stdin, tty                            bool
	tail, limit                                                                                         int64
	timeout                                                                                             time.Duration
}

func parse(args []string) (options, []string, error) {
	var o options
	f := pflag.NewFlagSet("sightport-kube", pflag.ContinueOnError)
	f.SetOutput(io.Discard)
	f.StringVar(&o.file, "kubeconfig", "", "")
	f.StringVar(&o.context, "context", "", "")
	f.StringVar(&o.namespace, "namespace", "", "")
	f.StringVarP(&o.output, "output", "o", "", "")
	f.StringVar(&o.raw, "raw", "", "")
	f.StringVar(&o.apiVersion, "api-version", "", "")
	f.StringVar(&o.selector, "selector", "", "")
	f.StringVar(&o.fieldSelector, "field-selector", "", "")
	f.StringVar(&o.container, "container", "", "")
	f.StringVar(&o.uid, "uid", "", "")
	f.StringVar(&o.address, "address", "127.0.0.1", "")
	f.DurationVar(&o.timeout, "request-timeout", 0, "")
	f.BoolVar(&o.watch, "watch", false, "")
	f.BoolVar(&o.watchEvents, "output-watch-events", false, "")
	f.BoolVar(&o.initialSnapshot, "initial-snapshot", false, "")
	f.BoolVar(&o.allNamespaces, "all-namespaces", false, "")
	f.BoolVar(&o.previous, "previous", false, "")
	f.BoolVar(&o.stdin, "stdin", false, "")
	f.BoolVar(&o.tty, "tty", false, "")
	f.Int64Var(&o.tail, "tail", 200, "")
	f.Int64Var(&o.limit, "limit-bytes", 256*1024, "")
	if err := f.Parse(args); err != nil {
		return o, nil, err
	}
	if len(f.Args()) == 0 {
		return o, nil, errors.New("missing operation")
	}
	return o, f.Args(), nil
}

func selectedConfig(o options) (*rest.Config, error) {
	if o.file == "" || o.context == "" {
		return nil, errors.New("context not found")
	}
	// An explicit file preserves relative CA, client key and exec paths, and
	// keeps requests tied to the context selected in this window.
	loader := clientcmd.NewDefaultClientConfigLoadingRules()
	loader.ExplicitPath = o.file
	client := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(loader, &clientcmd.ConfigOverrides{CurrentContext: o.context})
	cfg, err := client.ClientConfig()
	if err != nil {
		return nil, err
	}
	cfg.UserAgent = "Sightport"
	cfg.Timeout = o.timeout
	return cfg, nil
}

// AppKit may exit before it tears down a window's idle streams. A reparented
// helper cancels its API request and closes its listening sockets.
func watchParent(ctx context.Context, cancel context.CancelFunc, expected int) {
	if os.Getppid() != expected {
		cancel()
		return
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if os.Getppid() != expected {
				cancel()
				return
			}
		}
	}
}

func run(ctx context.Context, argv []string, in io.Reader, out io.Writer) error {
	o, args, err := parse(argv)
	if err != nil {
		return err
	}
	switch args[0] {
	case "render":
		project, err := newProjection(o.output)
		if err != nil {
			return err
		}
		var object map[string]any
		if err := json.NewDecoderCaseSensitivePreserveInts(in).Decode(&object); err != nil {
			return err
		}
		return project.print(object, out)
	case "contexts":
		if len(args) != 1 || o.file == "" {
			return errors.New("invalid context request")
		}
		return contextMetadata(o.file, out)
	}

	if o.watch || args[0] == "drain-node" || args[0] == "exec" || args[0] == "port-forward" {
		if pid, err := strconv.Atoi(os.Getenv("SIGHTPORT_PARENT_PID")); err == nil && pid > 0 {
			var cancel context.CancelFunc
			ctx, cancel = context.WithCancel(ctx)
			defer cancel()
			go watchParent(ctx, cancel, pid)
		}
	}
	cfg, err := selectedConfig(o)
	if err != nil {
		return err
	}
	if o.timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, o.timeout)
		defer cancel()
	}
	switch args[0] {
	case "get":
		if o.raw != "" && len(args) == 1 {
			return rawGet(ctx, cfg, o.raw, out)
		}
		if len(args) == 2 {
			return get(ctx, cfg, o, args[1], out)
		}
	case "restart-workload", "start-job", "resume-job":
		return workloadCommand(ctx, cfg, o, args, out)
	case "drain-node", "delete-node", "inspect-resource":
		return inspectOrManage(ctx, cfg, o, args, out)
	case "terminate-pod":
		if len(args) != 2 || o.allNamespaces {
			return podDeleteInvalid
		}
		return terminatePod(ctx, cfg, o.namespace, args[1], o.uid)
	case "deployment-log-pods":
		if len(args) == 2 && !o.allNamespaces {
			return deploymentLogPods(ctx, cfg, o.namespace, args[1], o.uid, out)
		}
	case "metrics":
		if len(args) == 1 {
			return podMetrics(ctx, cfg, o.namespace, out)
		}
	case "logs":
		if len(args) == 2 && strings.HasPrefix(args[1], "pod/") {
			return podLogs(ctx, cfg, o.namespace, strings.TrimPrefix(args[1], "pod/"), o.container, o.previous, o.tail, o.limit, out)
		}
	case "exec":
		if len(args) >= 3 && o.tty && o.stdin && strings.HasPrefix(args[1], "pod/") {
			return podTerminal(ctx, cfg, o.namespace, strings.TrimPrefix(args[1], "pod/"), o.container, args[2:])
		}
	case "port-forward":
		if len(args) == 3 && o.address == "127.0.0.1" {
			return forwardPort(ctx, cfg, o.namespace, args[1], args[2])
		}
	}
	return errors.New("invalid operation")
}

// Emit error categories only. The server, templates and credential plugins may
// include object contents or credential fields in their error text.
func diagnostic(err error) string {
	var workload workloadError
	if errors.As(err, &workload) {
		return string(workload)
	}
	var inspection inspectionDiagnostic
	if errors.As(err, &inspection) {
		return string(inspection)
	}
	var deletion podDeleteError
	if errors.As(err, &deletion) {
		return string(deletion)
	}
	var status apierrors.APIStatus
	if errors.As(err, &status) {
		switch status.Status().Reason {
		case metav1.StatusReasonForbidden:
			return "Forbidden"
		case metav1.StatusReasonUnauthorized:
			return "Unauthorized"
		case metav1.StatusReasonNotFound:
			if d := status.Status().Details; d != nil && d.Kind == "namespaces" {
				return "namespaces not found"
			}
			return "not found"
		}
	}
	message := strings.ToLower(err.Error())
	if strings.Contains(message, "context") && (strings.Contains(message, "not exist") || strings.Contains(message, "not found")) {
		return "context not found"
	}
	if strings.Contains(message, "does not have") {
		return "target does not have requested port"
	}
	for _, reason := range []string{"address already in use", "without a selector", "not running", "timed out waiting", "forbidden", "unauthorized", "doesn't have a resource type", "could not find the requested resource", "previous terminated container", "waiting to start", "is not valid for pod", "not found", "deadline exceeded", "timeout", "x509", "certificate", "getting credentials", "exec plugin"} {
		if strings.Contains(message, reason) {
			return reason
		}
	}
	return "Kubernetes request failed"
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, os.Args[1:], os.Stdin, os.Stdout)
	cancel()
	if err != nil {
		fmt.Fprintln(os.Stderr, diagnostic(err))
		var exited interface{ ExitStatus() int }
		if errors.As(err, &exited) && exited.ExitStatus() > 0 {
			os.Exit(exited.ExitStatus())
		}
		os.Exit(1)
	}
}
