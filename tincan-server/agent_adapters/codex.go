package agent_adapters

import (
	"fmt"

	tincanconfig "tincan-server/config"
	tincanrouter "tincan-server/router"
)

type CodexAdapter struct{}

func (a *CodexAdapter) Backend() string {
	return "codex"
}

func (a *CodexAdapter) ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error {
	if backend.Options.Model == "" {
		return fmt.Errorf("agent backend %q requires options.model for codex", name)
	}
	return nil
}

func (a *CodexAdapter) StartConversation(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, title string, message string) (ConversationStartResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return ConversationStartResult{}, err
	}
	if title == "" {
		return ConversationStartResult{}, fmt.Errorf("start conversation requires non-empty title")
	}
	if message == "" {
		return ConversationStartResult{}, fmt.Errorf("start conversation requires non-empty message")
	}
	return ConversationStartResult{}, fmt.Errorf("codex adapter is not implemented yet")
}

func (a *CodexAdapter) RunUserRouterPrompt(backend tincanconfig.AgentBackendDefinition, prompt string, rawTranscript string) (tincanrouter.UserRouterResult, error) {
	if err := a.ValidateBackend("__router__", backend); err != nil {
		return tincanrouter.UserRouterResult{}, err
	}
	return tincanrouter.UserRouterResult{}, fmt.Errorf("codex adapter is not implemented yet")
}
