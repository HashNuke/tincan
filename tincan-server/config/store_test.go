package config

import (
	"bytes"
	"encoding/json"
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
      "connection_type": "command"
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

func TestNewAgentBackendStoreMigratesLegacyExecutablePathToCommand(t *testing.T) {
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
      "connection_type": "command",
      "executable_path": " /opt/homebrew/bin/opencode "
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
	if backend.Options.Command != "/opt/homebrew/bin/opencode" {
		t.Fatalf("expected command to be normalized from executable_path, got %q", backend.Options.Command)
	}
	if backend.Options.ExecutablePath != "" {
		t.Fatalf("expected legacy executable_path to be cleared after normalization, got %q", backend.Options.ExecutablePath)
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
      "connection_type": "command"
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
	if sttModel, ok := store.STTModel(); !ok || sttModel != SpeechProviderMacOS+"/"+DefaultSTTModel {
		t.Fatalf("expected default stt_model %q, got %q ok=%v", DefaultSTTModel, sttModel, ok)
	}
	if ttsModel, ok := store.TTSModel(); !ok || ttsModel != SpeechProviderMacOS+"/"+DefaultTTSModel {
		t.Fatalf("expected default tts_model %q, got %q ok=%v", DefaultTTSModel, ttsModel, ok)
	}

	configPath := filepath.Join(tempDir, "config", "config.json")
	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("expected config.json to be created: %v", err)
	}
	if string(data) != defaultAppConfigJSON {
		t.Fatalf("unexpected default config.json contents: %q", string(data))
	}
}

func TestAppConfigStoreLoadsOptionalServerAndTailscaleFieldsAsEmpty(t *testing.T) {
	tempDir := t.TempDir()

	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	if serverURL, ok := store.ServerURL(); ok || serverURL != "" {
		t.Fatalf("expected server_url to be unset, got %q ok=%v", serverURL, ok)
	}
	if store.TailscaleEnabled() {
		t.Fatalf("expected tailscale.enabled to default false")
	}
	if nodeURL, ok := store.TailscaleNodeURL(); ok || nodeURL != "" {
		t.Fatalf("expected tailscale.node_url to be unset, got %q ok=%v", nodeURL, ok)
	}
	if snapshot := store.Snapshot(); snapshot.ConnectTo != "local" {
		t.Fatalf("expected connect_to to default local, got %q", snapshot.ConnectTo)
	}
}

func TestAppConfigStoreLoadsConnectToServerURLAndTailscaleFields(t *testing.T) {
	tempDir := t.TempDir()
	configDir := filepath.Join(tempDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "config.json"), []byte(`{
  "connect_to": " remote ",
  "server_url": " https://phone.example.ts.net ",
  "tailscale": {
    "enabled": true,
    "node_url": " https://tincan-host.tail.ts.net "
  }
}
`), 0o644); err != nil {
		t.Fatalf("write config.json: %v", err)
	}

	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	if serverURL, ok := store.ServerURL(); !ok || serverURL != "https://phone.example.ts.net" {
		t.Fatalf("expected server_url to load trimmed value, got %q ok=%v", serverURL, ok)
	}
	if snapshot := store.Snapshot(); snapshot.ConnectTo != "remote" {
		t.Fatalf("expected connect_to to load trimmed value, got %q", snapshot.ConnectTo)
	}
	if !store.TailscaleEnabled() {
		t.Fatalf("expected tailscale.enabled to load true")
	}
	if nodeURL, ok := store.TailscaleNodeURL(); !ok || nodeURL != "https://tincan-host.tail.ts.net" {
		t.Fatalf("expected tailscale.node_url to load trimmed value, got %q ok=%v", nodeURL, ok)
	}
}

func TestAppConfigStoreSetServerURLWritesConfig(t *testing.T) {
	tempDir := t.TempDir()

	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}
	if err := store.SetServerURL(" https://example.ts.net "); err != nil {
		t.Fatalf("SetServerURL returned error: %v", err)
	}

	if serverURL, ok := store.ServerURL(); !ok || serverURL != "https://example.ts.net" {
		t.Fatalf("expected trimmed server_url, got %q ok=%v", serverURL, ok)
	}
	data, err := os.ReadFile(filepath.Join(tempDir, "config", "config.json"))
	if err != nil {
		t.Fatalf("read config.json: %v", err)
	}
	if !bytes.Contains(data, []byte(`"server_url": "https://example.ts.net"`)) {
		t.Fatalf("expected server_url in config, got %s", string(data))
	}
}

func TestAppConfigStoreApplyPatchUpdatesConnectTo(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	err = store.ApplyPatch(map[string]json.RawMessage{
		"connect_to": json.RawMessage(`"remote"`),
		"server_url": json.RawMessage(`"https://phone.example.ts.net"`),
	})
	if err != nil {
		t.Fatalf("ApplyPatch returned error: %v", err)
	}

	if snapshot := store.Snapshot(); snapshot.ConnectTo != "remote" {
		t.Fatalf("expected connect_to from patch, got %q", snapshot.ConnectTo)
	}
}

func TestAppConfigStoreRejectsInvalidConnectTo(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	if err := store.ApplyPatch(map[string]json.RawMessage{
		"connect_to": json.RawMessage(`"elsewhere"`),
	}); err == nil {
		t.Fatalf("expected invalid connect_to patch to fail")
	}
}

func TestAppConfigStoreRejectsRemoteConnectToWithoutServerURL(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	if err := store.ApplyPatch(map[string]json.RawMessage{
		"connect_to": json.RawMessage(`"remote"`),
	}); err == nil {
		t.Fatalf("expected remote connect_to without server_url to fail")
	}
}

func TestAppConfigStoreRejectsInvalidServerURL(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	for _, value := range []string{"https:///missing-host", "ftp://example.com", "/relative"} {
		t.Run(value, func(t *testing.T) {
			if err := store.SetServerURL(value); err == nil {
				t.Fatalf("expected SetServerURL(%q) to fail", value)
			}
		})
	}
}

func TestAppConfigStoreSetTailscaleBootstrapResult(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	if err := store.SetTailscaleBootstrapResult(" https://tincan-host.tail.ts.net "); err != nil {
		t.Fatalf("SetTailscaleBootstrapResult returned error: %v", err)
	}

	if !store.TailscaleEnabled() {
		t.Fatalf("expected tailscale.enabled true")
	}
	if nodeURL, ok := store.TailscaleNodeURL(); !ok || nodeURL != "https://tincan-host.tail.ts.net" {
		t.Fatalf("expected tailscale.node_url to be stored, got %q ok=%v", nodeURL, ok)
	}
}

func TestAppConfigStoreSetTailscaleDisabledKeepsNodeURL(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}
	if err := store.SetTailscaleBootstrapResult("https://tincan-host.tail.ts.net"); err != nil {
		t.Fatalf("SetTailscaleBootstrapResult returned error: %v", err)
	}
	if err := store.SetTailscaleDisabled(); err != nil {
		t.Fatalf("SetTailscaleDisabled returned error: %v", err)
	}

	if store.TailscaleEnabled() {
		t.Fatalf("expected tailscale.enabled false")
	}
	if nodeURL, ok := store.TailscaleNodeURL(); !ok || nodeURL != "https://tincan-host.tail.ts.net" {
		t.Fatalf("expected tailscale.node_url to be preserved, got %q ok=%v", nodeURL, ok)
	}
}

func TestAppConfigStoreRejectsInvalidTailscaleNodeURL(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	for _, value := range []string{"http://tincan-host.tail.ts.net", "https://tincan-host.tail.ts.net:443", "https:///missing-host"} {
		t.Run(value, func(t *testing.T) {
			if err := store.SetTailscaleNodeURL(value); err == nil {
				t.Fatalf("expected SetTailscaleNodeURL(%q) to fail", value)
			}
		})
	}
}

func TestAppConfigStoreApplyPatchUpdatesTailscaleFields(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	err = store.ApplyPatch(map[string]json.RawMessage{
		"server_url": json.RawMessage(`"https://phone.example.ts.net"`),
		"tailscale":  json.RawMessage(`{"enabled":true,"node_url":"https://tincan-host.tail.ts.net"}`),
	})
	if err != nil {
		t.Fatalf("ApplyPatch returned error: %v", err)
	}

	if serverURL, ok := store.ServerURL(); !ok || serverURL != "https://phone.example.ts.net" {
		t.Fatalf("expected server_url from patch, got %q ok=%v", serverURL, ok)
	}
	if !store.TailscaleEnabled() {
		t.Fatalf("expected tailscale.enabled true from patch")
	}
	if nodeURL, ok := store.TailscaleNodeURL(); !ok || nodeURL != "https://tincan-host.tail.ts.net" {
		t.Fatalf("expected tailscale.node_url from patch, got %q ok=%v", nodeURL, ok)
	}
}

func TestAppConfigStoreApplyPatchRejectsUnknownTailscaleRelatedFields(t *testing.T) {
	tempDir := t.TempDir()
	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	if err := store.ApplyPatch(map[string]json.RawMessage{
		"tailscale_node_url": json.RawMessage(`"https://tincan-host.tail.ts.net"`),
	}); err == nil {
		t.Fatalf("expected unknown tailscale field patch to fail")
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
  "stt_model": "macos/parakeet-tdt-0.6b-v3-coreml",
  "tts_model": "grok/grok-tts-v1",
  "services": {
    "grok": {
      "enabled": true,
      "base_url": "https://api.x.ai/v1"
    }
  },
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
	if sttModel, ok := store.STTModel(); !ok || sttModel != "macos/parakeet-tdt-0.6b-v3-coreml" {
		t.Fatalf("expected stt_model macos/parakeet-tdt-0.6b-v3-coreml, got %q ok=%v", sttModel, ok)
	}
	if ttsModel, ok := store.TTSModel(); !ok || ttsModel != "grok/grok-tts-v1" {
		t.Fatalf("expected tts_model grok/grok-tts-v1, got %q ok=%v", ttsModel, ok)
	}
	if services := store.Services(); services.Grok.BaseURL != "https://api.x.ai/v1" {
		t.Fatalf("expected grok base_url to load, got %#v", services)
	}
	if services := store.Services(); services.Grok.Enabled == nil || !*services.Grok.Enabled {
		t.Fatalf("expected grok enabled flag to load, got %#v", services)
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
	if !bytes.Contains(data, []byte(`"stt_model": "macos/parakeet-tdt-0.6b-v3-coreml"`)) {
		t.Fatalf("expected stt_model to be preserved, got %s", string(data))
	}
	if !bytes.Contains(data, []byte(`"tts_model": "grok/grok-tts-v1"`)) {
		t.Fatalf("expected tts_model to be preserved, got %s", string(data))
	}
	if !bytes.Contains(data, []byte(`"services": {`)) {
		t.Fatalf("expected services to be preserved, got %s", string(data))
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
	if sttModel, ok := store.STTModel(); !ok || sttModel != "macos/parakeet-tdt-0.6b-v3-coreml" {
		t.Fatalf("expected stt_model to remain set, got %q ok=%v", sttModel, ok)
	}
	if ttsModel, ok := store.TTSModel(); !ok || ttsModel != "grok/grok-tts-v1" {
		t.Fatalf("expected tts_model to remain set, got %q ok=%v", ttsModel, ok)
	}
}

func TestNewAppConfigStoreNormalizesLegacySpeechModels(t *testing.T) {
	tempDir := t.TempDir()
	configDir := filepath.Join(tempDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}

	configPath := filepath.Join(configDir, "config.json")
	if err := os.WriteFile(configPath, []byte(`{
  "stt_model": "parakeet-tdt-0.6b-v3-coreml",
  "tts_model": "kitten-tts-mini-0.8"
}
`), 0o644); err != nil {
		t.Fatalf("write config.json: %v", err)
	}

	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	if sttModel, ok := store.STTModel(); !ok || sttModel != "macos/parakeet-tdt-0.6b-v3-coreml" {
		t.Fatalf("expected legacy stt_model to normalize, got %q ok=%v", sttModel, ok)
	}
	if ttsModel, ok := store.TTSModel(); !ok || ttsModel != "macos/kitten-tts-mini-0.8" {
		t.Fatalf("expected legacy tts_model to normalize, got %q ok=%v", ttsModel, ok)
	}
}

func TestAppConfigStoreApplyPatchUpdatesSpeechSettings(t *testing.T) {
	tempDir := t.TempDir()

	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	err = store.ApplyPatch(map[string]json.RawMessage{
		"stt_model": json.RawMessage(`"grok/grok-stt-v1"`),
		"tts_model": json.RawMessage(`"grok/grok-tts-v1"`),
		"services": json.RawMessage(`{
		  "grok": {
		    "enabled": false,
		    "base_url": "https://api.x.ai/v1",
		    "tts": {
		      "voice_id": "eve",
		      "language": "en",
		      "output_format": {
		        "codec": "wav",
		        "sample_rate": 44100
		      }
		    }
		  }
		}`),
	})
	if err != nil {
		t.Fatalf("ApplyPatch returned error: %v", err)
	}

	if sttModel, ok := store.STTModel(); !ok || sttModel != "grok/grok-stt-v1" {
		t.Fatalf("expected patched stt_model, got %q ok=%v", sttModel, ok)
	}
	if ttsModel, ok := store.TTSModel(); !ok || ttsModel != "grok/grok-tts-v1" {
		t.Fatalf("expected patched tts_model, got %q ok=%v", ttsModel, ok)
	}

	snapshot := store.Snapshot()
	if snapshot.Services.Grok.BaseURL != "https://api.x.ai/v1" {
		t.Fatalf("expected grok base_url in snapshot, got %#v", snapshot.Services)
	}
	if snapshot.Services.Grok.Enabled == nil || *snapshot.Services.Grok.Enabled {
		t.Fatalf("expected disabled grok flag in snapshot, got %#v", snapshot.Services)
	}

	configData, err := os.ReadFile(filepath.Join(tempDir, "config", "config.json"))
	if err != nil {
		t.Fatalf("read config.json: %v", err)
	}
	if !bytes.Contains(configData, []byte(`"enabled": false`)) {
		t.Fatalf("expected grok enabled flag to persist, got %s", string(configData))
	}
}

func TestAppConfigStoreApplyPatchPreservesExplicitEnabledFlagWithoutBaseURL(t *testing.T) {
	tempDir := t.TempDir()

	store, err := NewAppConfigStore(tempDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore returned error: %v", err)
	}

	err = store.ApplyPatch(map[string]json.RawMessage{
		"services": json.RawMessage(`{
		  "grok": {
		    "enabled": true
		  }
		}`),
	})
	if err != nil {
		t.Fatalf("ApplyPatch returned error: %v", err)
	}

	if services := store.Services(); services.Grok.Enabled == nil || !*services.Grok.Enabled {
		t.Fatalf("expected enabled grok flag to persist, got %#v", services)
	}

	configData, err := os.ReadFile(filepath.Join(tempDir, "config", "config.json"))
	if err != nil {
		t.Fatalf("read config.json: %v", err)
	}
	if !bytes.Contains(configData, []byte(`"enabled": true`)) {
		t.Fatalf("expected grok enabled true in config, got %s", string(configData))
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
	if sttModel, ok := appConfig.STTModel(); !ok || sttModel != "macos/parakeet-tdt-0.6b-v3-coreml" {
		t.Fatalf("expected stt_model parakeet-tdt-0.6b-v3-coreml, got %q ok=%v", sttModel, ok)
	}
	if ttsModel, ok := appConfig.TTSModel(); !ok || ttsModel != "macos/kitten-tts-mini-0.8" {
		t.Fatalf("expected tts_model kitten-tts-mini-0.8, got %q ok=%v", ttsModel, ok)
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
