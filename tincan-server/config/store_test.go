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

	profilesPath := filepath.Join(tempDir, "agent_profiles.json")
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

	backendsPath := filepath.Join(tempDir, "agent_backends.json")
	data, err := os.ReadFile(backendsPath)
	if err != nil {
		t.Fatalf("expected agent_backends.json to be created: %v", err)
	}
	if string(data) != "{}\n" {
		t.Fatalf("unexpected default agent_backends.json contents: %q", string(data))
	}
}
