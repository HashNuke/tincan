package main

import "fmt"

type CodexAdapter struct{}

func (a *CodexAdapter) Backend() string {
	return "codex"
}

func (a *CodexAdapter) ValidateBackend(name string, backend AgentBackendDefinition) error {
	if backend.Options.Model == "" {
		return fmt.Errorf("agent backend %q requires options.model for codex", name)
	}
	return nil
}

func (a *CodexAdapter) StartConversation(profile AgentProfile, backend AgentBackendDefinition, title string, message string) (AgentConversationStartResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return AgentConversationStartResult{}, err
	}
	if title == "" {
		return AgentConversationStartResult{}, fmt.Errorf("start conversation requires non-empty title")
	}
	if message == "" {
		return AgentConversationStartResult{}, fmt.Errorf("start conversation requires non-empty message")
	}
	return AgentConversationStartResult{}, fmt.Errorf("codex adapter is not implemented yet")
}

func (a *CodexAdapter) RouteUser(backend AgentBackendDefinition, input UserRouterInput) (UserRouterResult, error) {
	if err := a.ValidateBackend("__router__", backend); err != nil {
		return UserRouterResult{}, err
	}
	return UserRouterResult{}, fmt.Errorf("codex adapter is not implemented yet")
}
