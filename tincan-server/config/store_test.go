package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNewAgentProfileStoreCreatesEmptyFileWhenMissing(t *testing.T) {
	tempDir := t.TempDir()

	store, err := NewAgentProfileStore(tempDir)
	if err != nil {
		t.Fatalf("NewAgentProfileStore returned error: %v", err)
	}

	if len(store.List()) != 0 {
		t.Fatalf("expected empty profile list, got %d entries", len(store.List()))
	}

	profilesPath := filepath.Join(tempDir, "config", "agent_profiles.json")
	data, err := os.ReadFile(profilesPath)
	if err != nil {
		t.Fatalf("expected agent_profiles.json to be created: %v", err)
	}
	if string(data) != "[]\n" {
		t.Fatalf("unexpected default agent_profiles.json contents: %q", string(data))
	}
}

func TestNewAgentBackendStoreCreatesEmptyFileWhenMissing(t *testing.T) {
	tempDir := t.TempDir()

	store, err := NewAgentBackendStore(tempDir)
	if err != nil {
		t.Fatalf("NewAgentBackendStore returned error: %v", err)
	}

	if _, ok := store.Get("__router__"); ok {
		t.Fatalf("expected empty backend store")
	}

	backendsPath := filepath.Join(tempDir, "config", "agent_backends.json")
	data, err := os.ReadFile(backendsPath)
	if err != nil {
		t.Fatalf("expected agent_backends.json to be created: %v", err)
	}
	if string(data) != "{}\n" {
		t.Fatalf("unexpected default agent_backends.json contents: %q", string(data))
	}
}

func TestNewAgentBackendStoreAllowsBackendsWithoutModel(t *testing.T) {
	tempDir := t.TempDir()
	configDir := filepath.Join(tempDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}
	backendsPath := filepath.Join(configDir, "agent_backends.json")

	if err := os.WriteFile(backendsPath, []byte(`{
  "opencode-default": {
    "type": "opencode",
    "options": {
      "connection_type": "server",
      "base_url": "http://127.0.0.1:4096"
    }
  }
}
`), 0o644); err != nil {
		t.Fatalf("write agent_backends.json: %v", err)
	}

	store, err := NewAgentBackendStore(tempDir)
	if err != nil {
		t.Fatalf("NewAgentBackendStore returned error: %v", err)
	}

	backend, ok := store.Get("opencode-default")
	if !ok {
		t.Fatalf("expected backend to be loaded")
	}
	if backend.Options.Model != "" {
		t.Fatalf("expected model to remain empty, got %q", backend.Options.Model)
	}
	if backend.Options.Agent != "build" {
		t.Fatalf("expected default agent, got %q", backend.Options.Agent)
	}
}

func TestNewAgentProfileStoreMigratesLegacyRootConfigIntoConfigDirectory(t *testing.T) {
	tempDir := t.TempDir()
	legacyPath := filepath.Join(tempDir, "agent_profiles.json")

	if err := os.WriteFile(legacyPath, []byte(`[
  {
    "name": "Atlas",
    "working_directory": "/tmp/atlas",
    "agent_backend": "opencode"
  }
]
`), 0o644); err != nil {
		t.Fatalf("write legacy agent_profiles.json: %v", err)
	}

	store, err := NewAgentProfileStore(tempDir)
	if err != nil {
		t.Fatalf("NewAgentProfileStore returned error: %v", err)
	}

	if _, ok := store.Get("Atlas"); !ok {
		t.Fatalf("expected migrated profile to be loaded")
	}
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("expected legacy agent_profiles.json to be moved, got err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(tempDir, "config", "agent_profiles.json")); err != nil {
		t.Fatalf("expected migrated config file in config dir: %v", err)
	}
}

func TestNewAgentBackendStoreMigratesLegacyRootConfigIntoConfigDirectory(t *testing.T) {
	tempDir := t.TempDir()
	legacyPath := filepath.Join(tempDir, "agent_backends.json")

	if err := os.WriteFile(legacyPath, []byte(`{
  "opencode-default": {
    "type": "opencode",
    "options": {
      "connection_type": "server",
      "base_url": "http://127.0.0.1:4096"
    }
  }
}
`), 0o644); err != nil {
		t.Fatalf("write legacy agent_backends.json: %v", err)
	}

	store, err := NewAgentBackendStore(tempDir)
	if err != nil {
		t.Fatalf("NewAgentBackendStore returned error: %v", err)
	}

	if _, ok := store.Get("opencode-default"); !ok {
		t.Fatalf("expected migrated backend to be loaded")
	}
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("expected legacy agent_backends.json to be moved, got err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(tempDir, "config", "agent_backends.json")); err != nil {
		t.Fatalf("expected migrated config file in config dir: %v", err)
	}
}
