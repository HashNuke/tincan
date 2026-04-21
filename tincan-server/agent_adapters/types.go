package agent_adapters

import (
	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
	tincanrouter "tincan-server/router"
)

type Adapter interface {
	Backend() string
	ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error
	StartConversation(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, title string, message string) (ConversationStartResult, error)
	ContinueConversation(conversation conversations.Conversation, backend tincanconfig.AgentBackendDefinition, message string) error
	RunRouterPrompt(backend tincanconfig.AgentBackendDefinition, prompt string, rawTranscript string) (tincanrouter.RouteUserInputResult, error)
}

type ConversationStartResult struct {
	BackendConversationID string
	Status                string
}
