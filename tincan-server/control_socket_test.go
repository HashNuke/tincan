package main

import (
	"encoding/json"
	"net"
	"strings"
	"testing"
)

func TestServerControlSocketSecretsActionAppliesCredentialUpdate(t *testing.T) {
	store := newServiceCredentialStore(nil)
	controlSocket := newServerControlSocket("/tmp/tincan-server.sock", store)

	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()

	done := make(chan struct{})
	go func() {
		controlSocket.handleConnection(serverConn)
		close(done)
	}()

	value := " secret-key-1234 "
	if err := json.NewEncoder(clientConn).Encode(serverControlRequest{
		Action: "secrets",
		Data: map[string]*string{
			grokAPIKeyEnvVar: &value,
		},
	}); err != nil {
		t.Fatalf("encode request: %v", err)
	}

	var response serverControlResponse
	if err := json.NewDecoder(clientConn).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	<-done

	if !response.OK {
		t.Fatalf("expected success response, got %#v", response)
	}

	got, err := store.APIKey(grokAPIKeyEnvVar)
	if err != nil {
		t.Fatalf("expected runtime secret to be available: %v", err)
	}
	if got != "secret-key-1234" {
		t.Fatalf("expected trimmed runtime secret, got %q", got)
	}
}

func TestServerControlSocketRejectsUnknownActions(t *testing.T) {
	store := newServiceCredentialStore(nil)
	controlSocket := newServerControlSocket("/tmp/tincan-server.sock", store)

	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()

	done := make(chan struct{})
	go func() {
		controlSocket.handleConnection(serverConn)
		close(done)
	}()

	if err := json.NewEncoder(clientConn).Encode(serverControlRequest{Action: "nope"}); err != nil {
		t.Fatalf("encode request: %v", err)
	}

	var response serverControlResponse
	if err := json.NewDecoder(clientConn).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	<-done

	if response.OK {
		t.Fatalf("expected failure response, got %#v", response)
	}
	if !strings.Contains(response.Error, "unsupported control action") {
		t.Fatalf("expected unsupported action error, got %#v", response)
	}
}
