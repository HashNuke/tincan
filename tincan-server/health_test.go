package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	tincanconfig "tincan-server/config"
)

func TestHandleHealthIncludesDisabledTailscaleState(t *testing.T) {
	tempDir := t.TempDir()
	appConfig, err := tincanconfig.NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	srv := &server{
		appConfig: appConfig,
		profiles:  mustAgentProfiles(t, tempDir),
	}

	payload := requestHealth(t, srv)
	tailscale := payload["tailscale"].(map[string]any)
	if tailscale["enabled"] != false {
		t.Fatalf("expected tailscale.enabled false, got %#v", tailscale)
	}
	if tailscale["active"] != false {
		t.Fatalf("expected tailscale.active false, got %#v", tailscale)
	}
}

func TestHandleHealthIncludesActiveTailscaleState(t *testing.T) {
	tempDir := t.TempDir()
	appConfig, err := tincanconfig.NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}
	if err := appConfig.SetTailscaleBootstrapResult("https://tincan-host.tail.ts.net"); err != nil {
		t.Fatalf("SetTailscaleBootstrapResult returned error: %v", err)
	}

	srv := &server{
		appConfig: appConfig,
		profiles:  mustAgentProfiles(t, tempDir),
		tailscale: tailscaleRuntimeState{
			Configured: true,
			Active:     true,
			NodeURL:    "https://tincan-host.tail.ts.net",
		},
	}

	payload := requestHealth(t, srv)
	tailscale := payload["tailscale"].(map[string]any)
	if tailscale["enabled"] != true || tailscale["active"] != true {
		t.Fatalf("expected active tailscale state, got %#v", tailscale)
	}
	if tailscale["node_url"] != "https://tincan-host.tail.ts.net" {
		t.Fatalf("expected node_url, got %#v", tailscale)
	}
}

func TestHandleHealthIncludesInactiveFallbackTailscaleState(t *testing.T) {
	tempDir := t.TempDir()
	appConfig, err := tincanconfig.NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}
	if err := appConfig.SetTailscaleBootstrapResult("https://tincan-host.tail.ts.net"); err != nil {
		t.Fatalf("SetTailscaleBootstrapResult returned error: %v", err)
	}

	srv := &server{
		appConfig: appConfig,
		profiles:  mustAgentProfiles(t, tempDir),
		tailscale: tailscaleRuntimeState{
			Configured: true,
			Active:     false,
			NodeURL:    "https://tincan-host.tail.ts.net",
			Message:    tailscaleFallbackMessage,
		},
	}

	payload := requestHealth(t, srv)
	tailscale := payload["tailscale"].(map[string]any)
	if tailscale["enabled"] != true || tailscale["active"] != false {
		t.Fatalf("expected inactive configured tailscale state, got %#v", tailscale)
	}
	if tailscale["message"] != tailscaleFallbackMessage {
		t.Fatalf("expected fallback message, got %#v", tailscale)
	}
}

func requestHealth(t *testing.T, srv *server) map[string]any {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()
	srv.handleHealth(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", response.Code)
	}
	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return payload
}

func mustAgentProfiles(t *testing.T, dataDir string) *tincanconfig.AgentProfileStore {
	t.Helper()
	profiles, err := tincanconfig.NewAgentProfileStore(dataDir)
	if err != nil {
		t.Fatalf("NewAgentProfileStore returned error: %v", err)
	}
	return profiles
}
