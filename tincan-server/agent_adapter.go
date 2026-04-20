package main

import (
	"fmt"

	"github.com/google/uuid"
)

type AgentAdapter interface {
	Backend() string
	ValidateProfile(profile AgentProfile) error
	StartConversation(profile AgentProfile, message string) (AgentConversationStartResult, error)
}

type AgentConversationStartResult struct {
	BackendConversationID string
	Status                string
}

type OpenCodeServerAdapter struct{}

func (a *OpenCodeServerAdapter) Backend() string {
	return "opencode-server"
}

func (a *OpenCodeServerAdapter) ValidateProfile(profile AgentProfile) error {
	if profile.AgentBackendOptions.BaseURL == "" {
		return fmt.Errorf("profile %q requires agent_backend_options.base_url for opencode-server", profile.Name)
	}
	return nil
}

func (a *OpenCodeServerAdapter) StartConversation(profile AgentProfile, message string) (AgentConversationStartResult, error) {
	if err := a.ValidateProfile(profile); err != nil {
		return AgentConversationStartResult{}, err
	}
	if message == "" {
		return AgentConversationStartResult{}, fmt.Errorf("start conversation requires non-empty message")
	}

	return AgentConversationStartResult{
		BackendConversationID: "opencode-" + uuid.NewString(),
		Status:                "starting",
	}, nil
}

func DefaultAgentAdapters() map[string]AgentAdapter {
	return map[string]AgentAdapter{
		"opencode-server": &OpenCodeServerAdapter{},
	}
}
