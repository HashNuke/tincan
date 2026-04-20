package agent_adapters

import (
	tincanconfig "tincan-server/config"
	tincanrouter "tincan-server/router"
)

type Adapter interface {
	Backend() string
	ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error
	StartConversation(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, title string, message string) (ConversationStartResult, error)
	RunRouterPrompt(backend tincanconfig.AgentBackendDefinition, prompt string, rawTranscript string) (tincanrouter.RouteUserInputResult, error)
}

type ConversationStartResult struct {
	BackendConversationID string
	Status                string
}
