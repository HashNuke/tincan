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
