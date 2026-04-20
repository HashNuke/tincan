package main

import (
	"fmt"

	"tincan-server/agent_adapters"
	tincanconfig "tincan-server/config"
	tincanrouter "tincan-server/router"
)

type Router struct {
	backend tincanconfig.AgentBackendDefinition
	adapter agent_adapters.Adapter
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

func NewRouter(backend tincanconfig.AgentBackendDefinition, adapter agent_adapters.Adapter) *Router {
	return &Router{backend: backend, adapter: adapter}
}

func (r *Router) RouteUserTranscript(input tincanrouter.UserRouterInput) (tincanrouter.UserRouterResult, error) {
	result, err := r.adapter.RouteUser(r.backend, input)
	if err != nil {
		return tincanrouter.UserRouterResult{}, fmt.Errorf("route transcript: %w", err)
	}
	return result, nil
}
