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
	return nil
}

func (a *CodexAdapter) SupportsModelDiscovery() bool {
	return false
}

func (a *CodexAdapter) ListModels(backend tincanconfig.AgentBackendDefinition) ([]string, error) {
	return nil, fmt.Errorf("codex adapter model discovery is not implemented yet")
}

func (a *CodexAdapter) BuildConversationCommand(input ConversationCommandInput) (ManagedCommand, error) {
	if err := a.ValidateBackend(input.Conversation.AgentBackend, input.Backend); err != nil {
		return ManagedCommand{}, err
	}
	if len(input.Inputs) == 0 {
		return ManagedCommand{}, fmt.Errorf("managed conversation command requires at least one input")
	}
	return ManagedCommand{}, fmt.Errorf("codex adapter is not implemented yet")
}

func (a *CodexAdapter) RunRouterPrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt Prompt, rawTranscript string) (tincanrouter.RouteUserInputResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return tincanrouter.RouteUserInputResult{}, err
	}
	return tincanrouter.RouteUserInputResult{}, fmt.Errorf("codex adapter is not implemented yet")
}

func (a *CodexAdapter) RunConversationUpdatePrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt Prompt, rawUpdate string) (tincanrouter.ProcessConversationUpdateResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return tincanrouter.ProcessConversationUpdateResult{}, err
	}
	return tincanrouter.ProcessConversationUpdateResult{}, fmt.Errorf("codex adapter is not implemented yet")
}
