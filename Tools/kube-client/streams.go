package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/client-go/transport/spdy"
	"k8s.io/streaming/pkg/httpstream"
)

// The app's native terminal provides a PTY and signals the helper when its size changes.
type terminalSizes struct {
	ctx     context.Context
	fd      int
	changes chan os.Signal
}

func (s *terminalSizes) Next() *remotecommand.TerminalSize {
	select {
	case <-s.ctx.Done():
		return nil
	case <-s.changes:
		width, height, err := term.GetSize(s.fd)
		if err != nil {
			return nil
		}
		return &remotecommand.TerminalSize{Width: uint16(width), Height: uint16(height)}
	}
}

func upgradeFailed(err error) bool {
	return httpstream.IsUpgradeFailure(err) || httpstream.IsHTTPSProxyError(err)
}

func podTerminal(ctx context.Context, cfg *rest.Config, namespace, pod, container string, command []string) error {
	client, err := coreClient(cfg)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	fd := int(os.Stdin.Fd())
	tty := term.IsTerminal(fd)
	options := corev1.PodExecOptions{Container: container, Command: command, Stdin: true, Stdout: true, Stderr: !tty, TTY: tty}
	request := client.Post().Namespace(namespace).Resource("pods").Name(pod).SubResource("exec").VersionedParams(&options, coreParams)
	if err := request.Error(); err != nil {
		return err
	}
	target := request.URL()
	ws, err := remotecommand.NewWebSocketExecutor(cfg, http.MethodGet, target.String())
	if err != nil {
		return err
	}
	sp, err := remotecommand.NewSPDYExecutor(cfg, http.MethodPost, target)
	if err != nil {
		return err
	}
	executor, err := remotecommand.NewFallbackExecutor(ws, sp, upgradeFailed)
	if err != nil {
		return err
	}

	streams := remotecommand.StreamOptions{Stdin: os.Stdin, Stdout: os.Stdout, Tty: tty}
	if tty {
		state, err := term.MakeRaw(fd)
		if err != nil {
			return err
		}
		defer term.Restore(fd, state)
		changes := make(chan os.Signal, 1)
		changes <- syscall.SIGWINCH // Send the initial PTY size on connection.
		signal.Notify(changes, syscall.SIGWINCH)
		defer signal.Stop(changes)
		streams.TerminalSizeQueue = &terminalSizes{ctx: ctx, fd: fd, changes: changes}
	} else {
		streams.Stderr = os.Stderr
	}
	return executor.StreamWithContext(ctx, streams)
}

func forwardPort(ctx context.Context, cfg *rest.Config, namespace, target, ports string) error {
	kind, name, ok := strings.Cut(target, "/")
	local, remote, hasPorts := strings.Cut(ports, ":")
	if !ok || name == "" || !hasPorts || remote == "" {
		return errors.New("invalid port forward target")
	}
	client, err := coreClient(cfg)
	if err != nil {
		return err
	}
	pod, service, err := forwardPod(ctx, client, namespace, kind, name)
	if err != nil {
		return err
	}
	port, err := targetPort(pod, service, remote)
	if err != nil {
		return err
	}
	request := client.Post().Namespace(namespace).Resource("pods").Name(pod.Name).SubResource("portforward")
	if err := request.Error(); err != nil {
		return err
	}
	url := request.URL()
	ws, err := portforward.NewSPDYOverWebsocketDialerForStreaming(url, cfg)
	if err != nil {
		return err
	}
	transport, upgrader, err := spdy.RoundTripperFor(cfg)
	if err != nil {
		return err
	}
	sp := spdy.NewDialerForStreaming(upgrader, &http.Client{Transport: transport}, http.MethodPost, url)
	dialer := portforward.NewFallbackDialerForStreaming(ws, sp, upgradeFailed)
	forward, err := portforward.NewOnAddressesForStreamingWithContext(ctx, dialer, []string{"127.0.0.1"},
		[]string{local + ":" + strconv.Itoa(port)}, nil, os.Stdout, os.Stderr)
	if err != nil {
		return err
	}
	return forward.ForwardPorts()
}

func forwardPod(ctx context.Context, client *rest.RESTClient, namespace, kind, name string) (*corev1.Pod, *corev1.Service, error) {
	var service *corev1.Service
	switch kind {
	case "service":
		service = &corev1.Service{}
		if err := client.Get().Namespace(namespace).Resource("services").Name(name).Do(ctx).Into(service); err != nil {
			return nil, nil, err
		}
		if len(service.Spec.Selector) == 0 {
			return nil, nil, errors.New("service is defined without a selector")
		}
	case "pod":
	default:
		return nil, nil, errors.New("port forward requires a pod or service")
	}

	var selected *corev1.Pod
	err := wait.PollUntilContextTimeout(ctx, time.Second, 15*time.Second, true, func(ctx context.Context) (bool, error) {
		pods := client.Get().Namespace(namespace).Resource("pods")
		if service == nil {
			pod := &corev1.Pod{}
			if err := pods.Name(name).Do(ctx).Into(pod); err != nil {
				return false, err
			}
			if pod.DeletionTimestamp != nil || pod.Status.Phase == corev1.PodFailed || pod.Status.Phase == corev1.PodSucceeded {
				return false, errors.New("pod is not running")
			}
			selected = pod
			return pod.Status.Phase == corev1.PodRunning, nil
		}
		var list corev1.PodList
		if err := pods.Param("labelSelector", labels.SelectorFromSet(service.Spec.Selector).String()).
			Param("fieldSelector", "status.phase=Running").Do(ctx).Into(&list); err != nil {
			return false, err
		}
		for i := range list.Items {
			pod := &list.Items[i]
			if pod.DeletionTimestamp != nil || pod.Status.Phase != corev1.PodRunning {
				continue
			}
			if selected == nil {
				selected = pod
			}
			for _, condition := range pod.Status.Conditions {
				if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
					selected = pod
					return true, nil
				}
			}
		}
		return selected != nil, nil
	})
	if errors.Is(err, context.DeadlineExceeded) {
		return nil, nil, errors.New("timed out waiting for a running pod")
	}
	return selected, service, err
}

func targetPort(pod *corev1.Pod, service *corev1.Service, remote string) (int, error) {
	if service != nil {
		servicePort, _ := strconv.Atoi(remote)
		var port *corev1.ServicePort
		for i := range service.Spec.Ports {
			candidate := &service.Spec.Ports[i]
			if (candidate.Protocol == corev1.ProtocolTCP || candidate.Protocol == "") &&
				(int(candidate.Port) == servicePort || candidate.Name == remote) {
				port = candidate
				break
			}
		}
		if port == nil {
			return 0, fmt.Errorf("service does not have TCP port %s", remote)
		}
		if service.Spec.ClusterIP == corev1.ClusterIPNone {
			return int(port.Port), nil
		}
		if port.TargetPort.Type == intstr.Int {
			if port.TargetPort.IntVal == 0 {
				return int(port.Port), nil
			}
			return int(port.TargetPort.IntVal), nil
		}
		remote = port.TargetPort.StrVal
	}
	number, numericErr := strconv.Atoi(remote)
	// A numeric pod port need not be declared. A named port must resolve to a TCP port.
	onlyNonTCP := false
	resolve := func(container corev1.Container) int {
		for _, p := range container.Ports {
			if (numericErr == nil && int(p.ContainerPort) == number) || p.Name == remote {
				if p.Protocol == corev1.ProtocolTCP || p.Protocol == "" {
					return int(p.ContainerPort)
				}
				onlyNonTCP = true
			}
		}
		return 0
	}
	for _, container := range pod.Spec.Containers {
		if port := resolve(container); port != 0 {
			return port, nil
		}
	}
	for _, container := range pod.Spec.InitContainers {
		if container.RestartPolicy != nil && *container.RestartPolicy == corev1.ContainerRestartPolicyAlways {
			if port := resolve(container); port != 0 {
				return port, nil
			}
		}
	}
	if numericErr == nil && !onlyNonTCP && number > 0 && number <= 65535 {
		return number, nil
	}
	return 0, fmt.Errorf("pod does not have TCP port %s", remote)
}
