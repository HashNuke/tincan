package main

type AgentAdapter interface {
	Backend() string
	ValidateBackend(name string, backend AgentBackendDefinition) error
	StartConversation(profile AgentProfile, backend AgentBackendDefinition, title string, message string) (AgentConversationStartResult, error)
	RouteUser(backend AgentBackendDefinition, input UserRouterInput) (UserRouterResult, error)
}

type AgentConversationStartResult struct {
	BackendConversationID string
	Status                string
}
