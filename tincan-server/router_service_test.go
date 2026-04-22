package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tincan-server/agent_adapters"
	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
	tincanrouter "tincan-server/router"
)

type routerTestAdapter struct {
	lastRouteProfile  tincanconfig.AgentProfile
	lastRouteBackend  tincanconfig.AgentBackendDefinition
	lastUpdateProfile tincanconfig.AgentProfile
	lastRoutePrompt   agent_adapters.Prompt
	lastUpdatePrompt  agent_adapters.Prompt
}

func (a *routerTestAdapter) Backend() string {
	return "test"
}

func (a *routerTestAdapter) ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error {
	return nil
}

func (a *routerTestAdapter) SupportsModelDiscovery() bool {
	return false
}

func (a *routerTestAdapter) ListModels(backend tincanconfig.AgentBackendDefinition) ([]string, error) {
	return nil, nil
}

func (a *routerTestAdapter) StartConversation(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, title string, message string) (agent_adapters.ConversationStartResult, error) {
	return agent_adapters.ConversationStartResult{}, nil
}

func (a *routerTestAdapter) ContinueConversation(conversation conversations.Conversation, backend tincanconfig.AgentBackendDefinition, message string) error {
	return nil
}

func (a *routerTestAdapter) RunRouterPrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt agent_adapters.Prompt, rawTranscript string) (tincanrouter.RouteUserInputResult, error) {
	a.lastRouteProfile = profile
	a.lastRouteBackend = backend
	a.lastRoutePrompt = prompt
	return tincanrouter.RouteUserInputResult{Action: "ignore"}, nil
}

func (a *routerTestAdapter) RunConversationUpdatePrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt agent_adapters.Prompt, rawUpdate string) (tincanrouter.ProcessConversationUpdateResult, error) {
	a.lastUpdateProfile = profile
	a.lastUpdatePrompt = prompt
	return tincanrouter.ProcessConversationUpdateResult{
		NotificationText: "I have an update.",
		SummaryText:      "Updated.",
	}, nil
}

func TestRouterUsesConfiguredRouterProfile(t *testing.T) {
	dataDir := t.TempDir()
	configDir := filepath.Join(dataDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}

	if err := os.WriteFile(filepath.Join(configDir, "config.json"), []byte(`{
  "router_profile": "Atlas"
}
`), 0o644); err != nil {
		t.Fatalf("write config.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "agent_profiles.json"), []byte(`{
  "atlas": {
    "name": "Atlas",
    "working_directory": "/tmp/atlas",
    "agent_backend": "router-backend"
  }
}
`), 0o644); err != nil {
		t.Fatalf("write agent_profiles.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "agent_backends.json"), []byte(`{
  "router-backend": {
    "type": "test",
    "options": {
      "connection_type": "command"
    }
  }
}
`), 0o644); err != nil {
		t.Fatalf("write agent_backends.json: %v", err)
	}

	appConfig, err := tincanconfig.NewAppConfigStore(dataDir)
	if err != nil {
		t.Fatalf("NewAppConfigStore: %v", err)
	}
	profiles, err := tincanconfig.NewAgentProfileStore(dataDir)
	if err != nil {
		t.Fatalf("NewAgentProfileStore: %v", err)
	}
	backends, err := tincanconfig.NewAgentBackendStore(dataDir)
	if err != nil {
		t.Fatalf("NewAgentBackendStore: %v", err)
	}

	adapter := &routerTestAdapter{}
	router := NewRouter(appConfig, profiles, backends, map[string]agent_adapters.Adapter{
		"test": adapter,
	})

	if err := router.ValidateConfiguration(); err != nil {
		t.Fatalf("ValidateConfiguration: %v", err)
	}

	if _, err := router.RouteUserInput(tincanrouter.RouteUserInputRequest{Transcript: "hello"}); err != nil {
		t.Fatalf("RouteUserInput: %v", err)
	}
	if adapter.lastRouteProfile.Name != "Atlas" {
		t.Fatalf("expected router to use Atlas profile, got %q", adapter.lastRouteProfile.Name)
	}
	if adapter.lastRouteProfile.WorkingDirectory != "/tmp/atlas" {
		t.Fatalf("expected router to use Atlas working directory, got %q", adapter.lastRouteProfile.WorkingDirectory)
	}
	if adapter.lastRouteBackend.Type != "test" {
		t.Fatalf("expected router backend type test, got %q", adapter.lastRouteBackend.Type)
	}
	if !strings.HasPrefix(adapter.lastRoutePrompt.System, "You are Atlas. You are a router for Tincan agents.") {
		t.Fatalf("expected router system prompt to start with %q, got %q", "You are Atlas. You are a router for Tincan agents.", adapter.lastRoutePrompt.System)
	}
	if !strings.Contains(adapter.lastRoutePrompt.User, "User transcript:\nhello") {
		t.Fatalf("expected router user prompt to include transcript, got %q", adapter.lastRoutePrompt.User)
	}

	if _, err := profiles.Update("Atlas", tincanconfig.AgentProfile{
		Name:             "Atlas Updated",
		WorkingDirectory: "/tmp/atlas-updated",
		AgentBackend:     "router-backend",
	}); err != nil {
		t.Fatalf("rename router profile: %v", err)
	}
	if _, err := appConfig.UpdateRouterProfileReference("Atlas", "Atlas Updated"); err != nil {
		t.Fatalf("update router_profile: %v", err)
	}

	if _, err := router.ProcessConversationUpdate(tincanrouter.ProcessConversationUpdateRequest{
		ConversationHandle: "atlas#1",
		DetailText:         "done",
	}); err != nil {
		t.Fatalf("ProcessConversationUpdate: %v", err)
	}
	if adapter.lastUpdateProfile.Name != "Atlas Updated" {
		t.Fatalf("expected router update processor to use renamed profile, got %q", adapter.lastUpdateProfile.Name)
	}
	if adapter.lastUpdateProfile.WorkingDirectory != "/tmp/atlas-updated" {
		t.Fatalf("expected renamed profile working directory to be used, got %q", adapter.lastUpdateProfile.WorkingDirectory)
	}
	if !strings.HasPrefix(adapter.lastUpdatePrompt.System, "You are the Tincan conversation update processor.") {
		t.Fatalf("expected update system prompt to start with %q, got %q", "You are the Tincan conversation update processor.", adapter.lastUpdatePrompt.System)
	}
	if !strings.Contains(adapter.lastUpdatePrompt.User, "Conversation handle:\natlas#1") {
		t.Fatalf("expected update user prompt to include conversation handle, got %q", adapter.lastUpdatePrompt.User)
	}
}
