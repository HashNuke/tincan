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
	BuildConversationCommand(input ConversationCommandInput) (ManagedCommand, error)
	RunRouterPrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt Prompt, rawTranscript string) (tincanrouter.RouteUserInputResult, error)
	RunConversationUpdatePrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt Prompt, rawUpdate string) (tincanrouter.ProcessConversationUpdateResult, error)
}

type ConversationCommandInput struct {
	Conversation conversations.Conversation
	Backend      tincanconfig.AgentBackendDefinition
	Title        string
	Inputs       []conversations.ConversationInput
}

type ManagedCommand struct {
	Program string
	Args    []string
	Stdin   string
}
