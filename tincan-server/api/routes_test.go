package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tincanconfig "tincan-server/config"
)

type fakeAdapter struct {
	supportsModelDiscovery bool
	models                 []string
	err                    error
}

func (f fakeAdapter) ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error {
	if f.err != nil {
		return f.err
	}
	return nil
}

func (f fakeAdapter) SupportsModelDiscovery() bool {
	return f.supportsModelDiscovery
}

func (f fakeAdapter) ListModels(backend tincanconfig.AgentBackendDefinition) ([]string, error) {
	if f.err != nil {
		return nil, f.err
	}
	return append([]string(nil), f.models...), nil
}

func TestRoutesRegisterAgentBackendsSortedArray(t *testing.T) {
	routes := testRoutes(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/agent-backends", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var response struct {
		Backends []backendResponse `json:"backends"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if len(response.Backends) != 2 {
		t.Fatalf("expected 2 backends, got %d", len(response.Backends))
	}
	if response.Backends[0].Name != "__router__" || response.Backends[1].Name != "opencode" {
		t.Fatalf("unexpected backend ordering: %#v", response.Backends)
	}
}

func TestRoutesRegisterBackendTypeModels(t *testing.T) {
	routes := testRoutes(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/backend-types/opencode/models", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var response struct {
		BackendType string   `json:"backend_type"`
		Models      []string `json:"models"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if response.BackendType != "opencode" {
		t.Fatalf("unexpected backend type: %q", response.BackendType)
	}
	if len(response.Models) != 2 || response.Models[0] != "anthropic/claude-sonnet-4" || response.Models[1] != "openai/gpt-5.3-codex-spark" {
		t.Fatalf("unexpected models: %#v", response.Models)
	}
}

func TestRoutesRejectUnsupportedModelDiscovery(t *testing.T) {
	routes := testRoutes(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/backend-types/codex/models", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusNotImplemented {
		t.Fatalf("expected 501, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

func testRoutes(t *testing.T) Routes {
	routes, _ := testRoutesWithDataDir(t)
	return routes
}

func testRoutesWithDataDir(t *testing.T) (Routes, string) {
	t.Helper()

	dataDir := t.TempDir()
	configDir := filepath.Join(dataDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "agent_profiles.json"), []byte(`{
  "atlas": {
    "name": "Atlas",
    "working_directory": "/Users/akash/Library/Application Support/tincan",
    "agent_backend": "opencode"
  }
}`), 0o644); err != nil {
		t.Fatalf("write agent_profiles.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "config.json"), []byte(`{
  "router_profile": "Atlas"
}
`), 0o644); err != nil {
		t.Fatalf("write config.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "agent_backends.json"), []byte(`{
  "__router__": {
    "type": "opencode",
    "options": {
      "connection_type": "command",
      "model": "openai/gpt-5.3-codex-spark"
    }
  },
  "opencode": {
    "type": "opencode",
    "options": {
      "connection_type": "command",
      "model": "anthropic/claude-sonnet-4"
    }
  }
}`), 0o644); err != nil {
		t.Fatalf("write agent_backends.json: %v", err)
	}

	profiles, err := tincanconfig.NewAgentProfileStore(dataDir)
	if err != nil {
		t.Fatalf("NewAgentProfileStore: %v", err)
	}
	appConfig, err := tincanconfig.NewAppConfigStore(dataDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore: %v", err)
	}
	backends, err := tincanconfig.NewAgentBackendStore(dataDir)
	if err != nil {
		t.Fatalf("NewAgentBackendStore: %v", err)
	}

	return Routes{
		AppConfig: appConfig,
		Profiles:  profiles,
		Backends:  backends,
		Adapters: map[string]ModelDiscoveringAdapter{
			"codex": fakeAdapter{
				supportsModelDiscovery: false,
			},
			"opencode": fakeAdapter{
				supportsModelDiscovery: true,
				models: []string{
					"anthropic/claude-sonnet-4",
					"openai/gpt-5.3-codex-spark",
				},
			},
		},
	}, dataDir
}

func TestRoutesPropagatesModelDiscoveryFailure(t *testing.T) {
	routes := testRoutes(t)
	routes.Adapters["opencode"] = fakeAdapter{
		supportsModelDiscovery: true,
		err:                    fmt.Errorf("boom"),
	}

	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/backend-types/opencode/models", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

func TestRoutesCreateAgentProfilePersistsToConfig(t *testing.T) {
	routes, dataDir := testRoutesWithDataDir(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	body := []byte(`{
  "name": "Emma",
  "working_directory": "/tmp/emma",
  "agent_backend": "opencode"
}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/agent-profiles", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", recorder.Code, recorder.Body.String())
	}

	profile, ok := routes.Profiles.Get("Emma")
	if !ok {
		t.Fatalf("expected profile to be created in store")
	}
	if profile.WorkingDirectory != "/tmp/emma" {
		t.Fatalf("unexpected profile working directory: %q", profile.WorkingDirectory)
	}

	data, err := os.ReadFile(filepath.Join(dataDir, "config", "agent_profiles.json"))
	if err != nil {
		t.Fatalf("read agent_profiles.json: %v", err)
	}
	if !bytes.Contains(data, []byte(`"emma": {`)) {
		t.Fatalf("expected profile key to be persisted, got %s", string(data))
	}
	if !bytes.Contains(data, []byte(`"name": "Emma"`)) {
		t.Fatalf("expected profile to be persisted, got %s", string(data))
	}
}

func TestRoutesCreateAgentProfileRejectsUnknownBackend(t *testing.T) {
	routes := testRoutes(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	body := []byte(`{
  "name": "Emma",
  "working_directory": "/tmp/emma",
  "agent_backend": "missing"
}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/agent-profiles", bytes.NewReader(body))
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

func TestRoutesPatchAgentProfileUpdatesConfig(t *testing.T) {
	routes, dataDir := testRoutesWithDataDir(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	body := []byte(`{
  "name": "Atlas Updated",
  "working_directory": "/tmp/updated",
  "agent_backend": "opencode"
}`)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/agent-profiles/Atlas", bytes.NewReader(body))
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	if _, ok := routes.Profiles.Get("Atlas"); ok {
		t.Fatalf("expected old profile key to be removed after rename")
	}
	profile, ok := routes.Profiles.Get("Atlas Updated")
	if !ok {
		t.Fatalf("expected renamed profile to be available under new key")
	}
	if profile.WorkingDirectory != "/tmp/updated" {
		t.Fatalf("expected updated working directory, got %q", profile.WorkingDirectory)
	}
	if profile.Name != "Atlas Updated" {
		t.Fatalf("expected updated display name, got %q", profile.Name)
	}

	data, err := os.ReadFile(filepath.Join(dataDir, "config", "agent_profiles.json"))
	if err != nil {
		t.Fatalf("read agent_profiles.json: %v", err)
	}
	if bytes.Contains(data, []byte(`"atlas": {`)) {
		t.Fatalf("expected old profile key to be removed, got %s", string(data))
	}
	if !bytes.Contains(data, []byte(`"atlas updated": {`)) {
		t.Fatalf("expected renamed profile key, got %s", string(data))
	}
	if !bytes.Contains(data, []byte(`"working_directory": "/tmp/updated"`)) {
		t.Fatalf("expected updated config, got %s", string(data))
	}
	if !bytes.Contains(data, []byte(`"name": "Atlas Updated"`)) {
		t.Fatalf("expected updated display name in config, got %s", string(data))
	}

	configData, err := os.ReadFile(filepath.Join(dataDir, "config", "config.json"))
	if err != nil {
		t.Fatalf("read config.json: %v", err)
	}
	if !bytes.Contains(configData, []byte(`"router_profile": "Atlas Updated"`)) {
		t.Fatalf("expected router_profile to follow renamed router profile, got %s", string(configData))
	}
}

func TestRoutesDeleteAgentProfileRemovesConfig(t *testing.T) {
	routes, dataDir := testRoutesWithDataDir(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodDelete, "/api/v1/agent-profiles/Atlas", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", recorder.Code, recorder.Body.String())
	}
	if _, ok := routes.Profiles.Get("Atlas"); ok {
		t.Fatalf("expected profile to be removed from store")
	}

	data, err := os.ReadFile(filepath.Join(dataDir, "config", "agent_profiles.json"))
	if err != nil {
		t.Fatalf("read agent_profiles.json: %v", err)
	}
	if bytes.Contains(data, []byte(`"name": "Atlas"`)) {
		t.Fatalf("expected profile to be removed from config, got %s", string(data))
	}

	configData, err := os.ReadFile(filepath.Join(dataDir, "config", "config.json"))
	if err != nil {
		t.Fatalf("read config.json: %v", err)
	}
	if bytes.Contains(configData, []byte(`"router_profile"`)) {
		t.Fatalf("expected router_profile to be cleared after deleting router profile, got %s", string(configData))
	}
}

func TestRoutesCreateAgentBackendPersistsToConfig(t *testing.T) {
	routes, dataDir := testRoutesWithDataDir(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	body := []byte(`{
  "name": "codex-local",
  "type": "codex",
  "options": {
    "connection_type": "command"
  }
}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/agent-backends", bytes.NewReader(body))
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", recorder.Code, recorder.Body.String())
	}

	backend, ok := routes.Backends.Get("codex-local")
	if !ok {
		t.Fatalf("expected backend to be created in store")
	}
	if backend.Options.Agent != "build" {
		t.Fatalf("expected default agent to be applied, got %q", backend.Options.Agent)
	}

	data, err := os.ReadFile(filepath.Join(dataDir, "config", "agent_backends.json"))
	if err != nil {
		t.Fatalf("read agent_backends.json: %v", err)
	}
	if !bytes.Contains(data, []byte(`"codex-local"`)) {
		t.Fatalf("expected backend to be persisted, got %s", string(data))
	}
}

func TestRoutesCreateAgentBackendRejectsUnknownType(t *testing.T) {
	routes := testRoutes(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	body := []byte(`{
  "name": "mystery",
  "type": "unknown",
  "options": {}
}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/agent-backends", bytes.NewReader(body))
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

func TestRoutesPatchAgentBackendUpdatesConfig(t *testing.T) {
	routes, dataDir := testRoutesWithDataDir(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	body := []byte(`{
  "name": "opencode",
  "type": "opencode",
  "options": {
    "connection_type": "command",
    "model": "openai/gpt-5.3-codex-spark",
    "agent": "review"
  }
}`)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/agent-backends/opencode", bytes.NewReader(body))
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	backend, _ := routes.Backends.Get("opencode")
	if backend.Options.Agent != "review" {
		t.Fatalf("expected updated agent, got %q", backend.Options.Agent)
	}

	data, err := os.ReadFile(filepath.Join(dataDir, "config", "agent_backends.json"))
	if err != nil {
		t.Fatalf("read agent_backends.json: %v", err)
	}
	if !bytes.Contains(data, []byte(`"agent": "review"`)) {
		t.Fatalf("expected updated backend config, got %s", string(data))
	}
}

func TestRoutesPatchAgentBackendRejectsLegacyBaseURLField(t *testing.T) {
	routes := testRoutes(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	body := []byte(`{
  "name": "opencode",
  "type": "opencode",
  "options": {
    "connection_type": "command",
    "base_url": "http://127.0.0.1:4096"
  }
}`)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/agent-backends/opencode", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", recorder.Code, recorder.Body.String())
	}
	if !strings.Contains(recorder.Body.String(), "base_url") {
		t.Fatalf("expected response to mention unknown base_url field, got %q", recorder.Body.String())
	}
}

func TestRoutesDeleteAgentBackendRejectsReferencedBackend(t *testing.T) {
	routes := testRoutes(t)
	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodDelete, "/api/v1/agent-backends/opencode", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

func TestRoutesDeleteAgentBackendRemovesConfig(t *testing.T) {
	routes, dataDir := testRoutesWithDataDir(t)
	if err := routes.Profiles.Delete("Atlas"); err != nil {
		t.Fatalf("delete dependent profile: %v", err)
	}

	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodDelete, "/api/v1/agent-backends/opencode", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", recorder.Code, recorder.Body.String())
	}
	if _, ok := routes.Backends.Get("opencode"); ok {
		t.Fatalf("expected backend to be removed from store")
	}

	data, err := os.ReadFile(filepath.Join(dataDir, "config", "agent_backends.json"))
	if err != nil {
		t.Fatalf("read agent_backends.json: %v", err)
	}
	if bytes.Contains(data, []byte(`"opencode": {`)) {
		t.Fatalf("expected backend to be removed from config, got %s", string(data))
	}
}
