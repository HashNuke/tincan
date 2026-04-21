package config

import (
	"bytes"
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
	if string(data) != "{}\n" {
		t.Fatalf("unexpected default agent_profiles.json contents: %q", string(data))
	}
}

func TestNewAgentProfileStoreLoadsObjectShapedConfig(t *testing.T) {
	tempDir := t.TempDir()
	configDir := filepath.Join(tempDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}
	profilesPath := filepath.Join(configDir, "agent_profiles.json")

	if err := os.WriteFile(profilesPath, []byte(`{
  "atlas": {
    "name": "Atlas Display",
    "working_directory": "/tmp/atlas",
    "agent_backend": "opencode"
  }
}
`), 0o644); err != nil {
		t.Fatalf("write agent_profiles.json: %v", err)
	}

	store, err := NewAgentProfileStore(tempDir)
	if err != nil {
		t.Fatalf("NewAgentProfileStore returned error: %v", err)
	}

	profile, ok := store.Get("atlas")
	if !ok {
		t.Fatalf("expected profile to be loaded")
	}
	if profile.Name != "Atlas Display" {
		t.Fatalf("expected display name to be preserved, got %q", profile.Name)
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

func TestNewAppConfigStoreCreatesEmptyFileWhenMissing(t *testing.T) {
	tempDir := t.TempDir()

	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	if _, ok := store.RouterProfile(); ok {
		t.Fatalf("expected router_profile to be unset")
	}

	configPath := filepath.Join(tempDir, "config", "config.json")
	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("expected config.json to be created: %v", err)
	}
	if string(data) != "{}\n" {
		t.Fatalf("unexpected default config.json contents: %q", string(data))
	}
}

func TestAppConfigStoreLoadsAndUpdatesRouterProfile(t *testing.T) {
	tempDir := t.TempDir()
	configDir := filepath.Join(tempDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}

	configPath := filepath.Join(configDir, "config.json")
	if err := os.WriteFile(configPath, []byte(`{
  "router_profile": "Atlas",
  "transcription_backend": "parakeet"
}
`), 0o644); err != nil {
		t.Fatalf("write config.json: %v", err)
	}

	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	routerProfile, ok := store.RouterProfile()
	if !ok || routerProfile != "Atlas" {
		t.Fatalf("expected router_profile Atlas, got %q ok=%v", routerProfile, ok)
	}

	updated, err := store.UpdateRouterProfileReference("Atlas", "Atlas Updated")
	if err != nil {
		t.Fatalf("UpdateRouterProfileReference returned error: %v", err)
	}
	if !updated {
		t.Fatalf("expected router_profile reference to update")
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("read config.json: %v", err)
	}
	if string(data) == "" {
		t.Fatalf("expected config.json to contain data")
	}
	if routerProfile, ok := store.RouterProfile(); !ok || routerProfile != "Atlas Updated" {
		t.Fatalf("expected updated router_profile, got %q ok=%v", routerProfile, ok)
	}
	if !bytes.Contains(data, []byte(`"router_profile": "Atlas Updated"`)) {
		t.Fatalf("expected updated router_profile in config.json, got %s", string(data))
	}
	if !bytes.Contains(data, []byte(`"transcription_backend": "parakeet"`)) {
		t.Fatalf("expected unknown config keys to be preserved, got %s", string(data))
	}

	updated, err = store.UpdateRouterProfileReference("Atlas Updated", "")
	if err != nil {
		t.Fatalf("clear router_profile returned error: %v", err)
	}
	if !updated {
		t.Fatalf("expected router_profile reference to clear")
	}

	data, err = os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("read config.json after clear: %v", err)
	}
	if bytes.Contains(data, []byte(`"router_profile"`)) {
		t.Fatalf("expected router_profile to be removed from config.json, got %s", string(data))
	}
	if _, ok := store.RouterProfile(); ok {
		t.Fatalf("expected router_profile to be unset after clear")
	}
}

func TestNewAppConfigStoreMigratesLegacyRootConfigIntoConfigDirectory(t *testing.T) {
	tempDir := t.TempDir()
	legacyPath := filepath.Join(tempDir, "config.json")

	if err := os.WriteFile(legacyPath, []byte(`{
  "router_profile": "Atlas"
}
`), 0o644); err != nil {
		t.Fatalf("write legacy config.json: %v", err)
	}

	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	if routerProfile, ok := store.RouterProfile(); !ok || routerProfile != "Atlas" {
		t.Fatalf("expected migrated router_profile Atlas, got %q ok=%v", routerProfile, ok)
	}
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("expected legacy config.json to be moved, got err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(tempDir, "config", "config.json")); err != nil {
		t.Fatalf("expected migrated config file in config dir: %v", err)
	}
}

func TestSampleDataDirLoadsRuntimeConfig(t *testing.T) {
	sampleDataDir := filepath.Join("..", "testdata", "data-dir")

	appConfig, err := NewAppConfigStore(sampleDataDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	profiles, err := NewAgentProfileStore(sampleDataDir)
	if err != nil {
		t.Fatalf("NewAgentProfileStore returned error: %v", err)
	}

	backends, err := NewAgentBackendStore(sampleDataDir)
	if err != nil {
		t.Fatalf("NewAgentBackendStore returned error: %v", err)
	}

	routerProfile, ok := appConfig.RouterProfile()
	if !ok || routerProfile != "emma" {
		t.Fatalf("expected router_profile emma, got %q ok=%v", routerProfile, ok)
	}

	if _, ok := profiles.Get("emma"); !ok {
		t.Fatalf("expected emma profile in sample data dir")
	}
	if _, ok := profiles.Get("atlas"); !ok {
		t.Fatalf("expected atlas profile in sample data dir")
	}
	if _, ok := backends.Get("opencode-1"); !ok {
		t.Fatalf("expected opencode-1 backend in sample data dir")
	}
	if _, ok := backends.Get("__router__"); !ok {
		t.Fatalf("expected __router__ backend in sample data dir")
	}
}
