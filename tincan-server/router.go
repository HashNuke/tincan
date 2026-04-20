package main

import "fmt"

type Router struct {
	backend AgentBackendDefinition
	adapter AgentAdapter
}

type UserRouterInput struct {
	Transcript string
}

type UserRouterResult struct {
	Action             string `json:"action"`
	Message            string `json:"message,omitempty"`
	Agent              string `json:"agent,omitempty"`
	ConversationHandle string `json:"conversation_handle,omitempty"`
	ConversationTitle  string `json:"conversation_title,omitempty"`
	ImmediateFeedback  string `json:"immediate_feedback,omitempty"`
	RawTranscript      string `json:"raw_transcript"`
}

func NewRouter(backend AgentBackendDefinition, adapter AgentAdapter) *Router {
	return &Router{backend: backend, adapter: adapter}
}

func (r *Router) RouteUserTranscript(input UserRouterInput) (UserRouterResult, error) {
	result, err := r.adapter.RouteUser(r.backend, input)
	if err != nil {
		return UserRouterResult{}, fmt.Errorf("route transcript: %w", err)
	}
	return result, nil
}
