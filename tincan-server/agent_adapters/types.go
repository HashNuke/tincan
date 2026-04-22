package agent_adapters

import (
	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
	tincanrouter "tincan-server/router"
)

type Prompt struct {
	System string
	User   string
}

type Adapter interface {
	Backend() string
	ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error
	SupportsModelDiscovery() bool
	ListModels(backend tincanconfig.AgentBackendDefinition) ([]string, error)
	StartConversation(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, title string, message string) (ConversationStartResult, error)
	ContinueConversation(conversation conversations.Conversation, backend tincanconfig.AgentBackendDefinition, message string) error
	RunRouterPrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt Prompt, rawTranscript string) (tincanrouter.RouteUserInputResult, error)
	RunConversationUpdatePrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt Prompt, rawUpdate string) (tincanrouter.ProcessConversationUpdateResult, error)
}

type ConversationStartResult struct {
	BackendConversationID string
	Status                string
}
