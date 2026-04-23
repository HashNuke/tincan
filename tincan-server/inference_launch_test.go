package main

import (
	"os"
	"path/filepath"
	"testing"

	tincanconfig "tincan-server/config"
)

func TestConfiguredInferenceModelsUsesAppConfigWhenEnvironmentUnset(t *testing.T) {
	appConfig := testAppConfigStore(t, `{
  "stt_model": "macos/custom-parakeet",
  "tts_model": "macos/custom-kitten"
}
`)

	sttModel, ttsModel := configuredInferenceModels(appConfig)
	if sttModel != "custom-parakeet" {
		t.Fatalf("expected stt_model from app config, got %q", sttModel)
	}
	if ttsModel != "custom-kitten" {
		t.Fatalf("expected tts_model from app config, got %q", ttsModel)
	}
}

func TestConfiguredInferenceModelsFallsBackWhenProviderIsRemote(t *testing.T) {
	appConfig := testAppConfigStore(t, `{
  "stt_model": "grok/grok-stt-v1",
  "tts_model": "grok/grok-tts-v1"
}
`)

	sttModel, ttsModel := configuredInferenceModels(appConfig)
	if sttModel != defaultBundledSTTModel {
		t.Fatalf("expected default stt_model %q for remote provider, got %q", defaultBundledSTTModel, sttModel)
	}
	if ttsModel != defaultBundledTTSModel {
		t.Fatalf("expected default tts_model %q for remote provider, got %q", defaultBundledTTSModel, ttsModel)
	}
}

func TestConfiguredInferenceModelsIgnoresMissingAppConfigFields(t *testing.T) {
	appConfig := testAppConfigStore(t, `{
  "router_profile": "atlas"
}
`)

	sttModel, ttsModel := configuredInferenceModels(appConfig)
	if sttModel != defaultBundledSTTModel {
		t.Fatalf("expected default stt_model %q, got %q", defaultBundledSTTModel, sttModel)
	}
	if ttsModel != defaultBundledTTSModel {
		t.Fatalf("expected default tts_model %q, got %q", defaultBundledTTSModel, ttsModel)
	}
}

func TestConfiguredInferenceModelsFallsBackToBundledDefaults(t *testing.T) {
	sttModel, ttsModel := configuredInferenceModels(nil)
	if sttModel != defaultBundledSTTModel {
		t.Fatalf("expected default stt_model %q, got %q", defaultBundledSTTModel, sttModel)
	}
	if ttsModel != defaultBundledTTSModel {
		t.Fatalf("expected default tts_model %q, got %q", defaultBundledTTSModel, ttsModel)
	}
}

func TestResolveActiveInferenceSocketPathPrefersRenamedSocket(t *testing.T) {
	preferredPath := inferenceSocketPath()
	legacyPath := legacyInferenceSocketPath()

	got := resolveActiveInferenceSocketPath(func(path string) bool {
		return path == preferredPath || path == legacyPath
	})
	if got != preferredPath {
		t.Fatalf("expected preferred inference socket path %q, got %q", preferredPath, got)
	}
}

func TestResolveActiveInferenceSocketPathFallsBackToLegacySocket(t *testing.T) {
	preferredPath := inferenceSocketPath()
	legacyPath := legacyInferenceSocketPath()

	got := resolveActiveInferenceSocketPath(func(path string) bool {
		return path == legacyPath
	})
	if got != legacyPath {
		t.Fatalf("expected legacy inference socket path %q, got %q", legacyPath, got)
	}
	if got == preferredPath {
		t.Fatalf("expected to fall back away from preferred path %q", preferredPath)
	}
}

func TestResolveActiveInferenceSocketPathUsesRenamedSocketWhenNeitherExists(t *testing.T) {
	preferredPath := inferenceSocketPath()

	got := resolveActiveInferenceSocketPath(func(string) bool { return false })
	if got != preferredPath {
		t.Fatalf("expected renamed inference socket path %q, got %q", preferredPath, got)
	}
}

func testAppConfigStore(t *testing.T, configJSON string) *tincanconfig.AppConfigStore {
	t.Helper()

	dataDir := t.TempDir()
	configDir := filepath.Join(dataDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "config.json"), []byte(configJSON), 0o644); err != nil {
		t.Fatalf("write config.json: %v", err)
	}

	appConfig, err := tincanconfig.NewAppConfigStore(dataDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore: %v", err)
	}
	return appConfig
}
