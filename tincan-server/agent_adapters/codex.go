package agent_adapters

import (
	"fmt"

	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
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

func (a *CodexAdapter) ContinueConversation(conversation conversations.Conversation, backend tincanconfig.AgentBackendDefinition, message string) error {
	if err := a.ValidateBackend(conversation.AgentBackend, backend); err != nil {
		return err
	}
	if message == "" {
		return fmt.Errorf("continue conversation requires non-empty message")
	}
	return fmt.Errorf("codex adapter is not implemented yet")
}

func (a *CodexAdapter) RunRouterPrompt(backend tincanconfig.AgentBackendDefinition, prompt string, rawTranscript string) (tincanrouter.RouteUserInputResult, error) {
	if err := a.ValidateBackend("__router__", backend); err != nil {
		return tincanrouter.RouteUserInputResult{}, err
	}
	return tincanrouter.RouteUserInputResult{}, fmt.Errorf("codex adapter is not implemented yet")
}

func (a *CodexAdapter) RunConversationUpdatePrompt(backend tincanconfig.AgentBackendDefinition, prompt string, rawUpdate string) (tincanrouter.ProcessConversationUpdateResult, error) {
	if err := a.ValidateBackend("__router__", backend); err != nil {
		return tincanrouter.ProcessConversationUpdateResult{}, err
	}
	return tincanrouter.ProcessConversationUpdateResult{}, fmt.Errorf("codex adapter is not implemented yet")
}
