package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	tincanconfig "tincan-server/config"
)

type fakeAdapter struct {
	supportsModelDiscovery bool
	models                 []string
	err                    error
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
	t.Helper()

	dataDir := t.TempDir()
	configDir := filepath.Join(dataDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "agent_profiles.json"), []byte(`[
  {
    "name": "Atlas",
    "working_directory": "/Users/akash/Library/Application Support/tincan",
    "agent_backend": "opencode"
  }
]`), 0o644); err != nil {
		t.Fatalf("write agent_profiles.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "agent_backends.json"), []byte(`{
  "__router__": {
    "type": "opencode",
    "options": {
      "connection_type": "server",
      "model": "openai/gpt-5.3-codex-spark",
      "base_url": "http://127.0.0.1:4096"
    }
  },
  "opencode": {
    "type": "opencode",
    "options": {
      "connection_type": "server",
      "model": "anthropic/claude-sonnet-4",
      "base_url": "http://127.0.0.1:4096"
    }
  }
}`), 0o644); err != nil {
		t.Fatalf("write agent_backends.json: %v", err)
	}

	profiles, err := tincanconfig.NewAgentProfileStore(dataDir)
	if err != nil {
		t.Fatalf("NewAgentProfileStore: %v", err)
	}
	backends, err := tincanconfig.NewAgentBackendStore(dataDir)
	if err != nil {
		t.Fatalf("NewAgentBackendStore: %v", err)
	}

	return Routes{
		Profiles: profiles,
		Backends: backends,
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
	}
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
