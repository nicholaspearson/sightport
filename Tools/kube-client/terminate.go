package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/rest"
)

type podDeleteError string

const (
	podDeleteInvalid     podDeleteError = "pod-delete-invalid-target"
	podDeleteDenied      podDeleteError = "pod-delete-forbidden"
	podDeleteMissing     podDeleteError = "pod-delete-not-found"
	podDeleteConflict    podDeleteError = "pod-delete-conflict"
	podDeleteUnconfirmed podDeleteError = "pod-delete-unconfirmed"
)

func (err podDeleteError) Error() string { return string(err) }

func terminatePod(ctx context.Context, cfg *rest.Config, namespace, name, uid string) error {
	if len(validation.IsDNS1123Label(namespace)) != 0 || len(validation.IsDNS1123Subdomain(name)) != 0 ||
		strings.TrimSpace(uid) == "" || strings.ContainsAny(uid, "/\x00") {
		return podDeleteInvalid
	}
	client, err := coreClient(cfg)
	if err != nil {
		return err
	}

	// A redirect could replay the DELETE at another URL. Copy the HTTP client
	// so only this operation declines redirects.
	httpClient := *client.Client
	httpClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	client.Client = &httpClient

	selectedUID := types.UID(uid)
	options := metav1.DeleteOptions{
		TypeMeta:      metav1.TypeMeta{APIVersion: "v1", Kind: "DeleteOptions"},
		Preconditions: &metav1.Preconditions{UID: &selectedUID},
	}
	body, err := json.Marshal(options)
	if err != nil {
		return err
	}
	// An unrewindable body also prevents the HTTP transport replaying a sent
	// request after a connection failure. Leave the pod's grace period intact.
	req := client.Delete().Namespace(namespace).Resource("pods").Name(name).MaxRetries(0).
		SetHeader("Content-Type", "application/json").Body(io.NopCloser(bytes.NewReader(body)))
	err = req.Do(ctx).Error()
	switch {
	case err == nil:
		return nil
	case apierrors.IsUnauthorized(err):
		return err
	case apierrors.IsForbidden(err):
		return podDeleteDenied
	case apierrors.IsNotFound(err):
		return podDeleteMissing
	case apierrors.IsConflict(err):
		return podDeleteConflict
	default:
		return podDeleteUnconfirmed
	}
}
