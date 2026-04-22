package main

import (
	"fmt"
	"strings"

	"tincan-server/agent_adapters"
	tincanconfig "tincan-server/config"
	"tincan-server/prompts"
	tincanrouter "tincan-server/router"
)

type Router struct {
	config   *tincanconfig.AppConfigStore
	profiles *tincanconfig.AgentProfileStore
	backends *tincanconfig.AgentBackendStore
	adapters map[string]agent_adapters.Adapter
}

func NewRouter(config *tincanconfig.AppConfigStore, profiles *tincanconfig.AgentProfileStore, backends *tincanconfig.AgentBackendStore, adapters map[string]agent_adapters.Adapter) *Router {
	return &Router{
		config:   config,
		profiles: profiles,
		backends: backends,
		adapters: adapters,
	}
}

func (r *Router) RouteUserInput(input tincanrouter.RouteUserInputRequest) (tincanrouter.RouteUserInputResult, error) {
	profile, backend, adapter, err := r.resolveRuntime()
	if err != nil {
		return tincanrouter.RouteUserInputResult{}, err
	}

	prompt, err := r.buildUserRouterPrompt(profile.Name, input)
	if err != nil {
		return tincanrouter.RouteUserInputResult{}, fmt.Errorf("build router prompt: %w", err)
	}
	result, err := adapter.RunRouterPrompt(profile, backend, prompt, input.Transcript)
	if err != nil {
		return tincanrouter.RouteUserInputResult{}, fmt.Errorf("route user input: %w", err)
	}
	return result, nil
}

func (r *Router) ProcessConversationUpdate(input tincanrouter.ProcessConversationUpdateRequest) (tincanrouter.ProcessConversationUpdateResult, error) {
	profile, backend, adapter, err := r.resolveRuntime()
	if err != nil {
		return tincanrouter.ProcessConversationUpdateResult{}, err
	}

	prompt, err := r.buildConversationUpdatePrompt(input)
	if err != nil {
		return tincanrouter.ProcessConversationUpdateResult{}, fmt.Errorf("build conversation update prompt: %w", err)
	}
	result, err := adapter.RunConversationUpdatePrompt(profile, backend, prompt, input.DetailText)
	if err != nil {
		return tincanrouter.ProcessConversationUpdateResult{}, fmt.Errorf("process conversation update: %w", err)
	}
	return result, nil
}

func (r *Router) ValidateConfiguration() error {
	_, _, _, err := r.resolveRuntime()
	return err
}

func (r *Router) resolveRuntime() (tincanconfig.AgentProfile, tincanconfig.AgentBackendDefinition, agent_adapters.Adapter, error) {
	if r == nil || r.config == nil || r.profiles == nil || r.backends == nil {
		return tincanconfig.AgentProfile{}, tincanconfig.AgentBackendDefinition{}, nil, fmt.Errorf("router is not configured")
	}

	routerProfileName, ok := r.config.RouterProfile()
	if !ok {
		return tincanconfig.AgentProfile{}, tincanconfig.AgentBackendDefinition{}, nil, fmt.Errorf("router_profile is not configured")
	}

	profile, ok := r.profiles.Get(routerProfileName)
	if !ok {
		return tincanconfig.AgentProfile{}, tincanconfig.AgentBackendDefinition{}, nil, fmt.Errorf("router profile %q was not found", routerProfileName)
	}

	backend, ok := r.backends.Get(profile.AgentBackend)
	if !ok {
		return tincanconfig.AgentProfile{}, tincanconfig.AgentBackendDefinition{}, nil, fmt.Errorf("router profile %q references unknown agent backend %q", profile.Name, profile.AgentBackend)
	}

	adapter, ok := r.adapters[backend.Type]
	if !ok {
		return tincanconfig.AgentProfile{}, tincanconfig.AgentBackendDefinition{}, nil, fmt.Errorf("no agent adapter registered for router backend type %q", backend.Type)
	}
	if err := adapter.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return tincanconfig.AgentProfile{}, tincanconfig.AgentBackendDefinition{}, nil, fmt.Errorf("validate router backend: %w", err)
	}

	return profile, backend, adapter, nil
}

func (r *Router) buildUserRouterPrompt(routerProfileName string, input tincanrouter.RouteUserInputRequest) (string, error) {
	var profileNames []string
	for _, profile := range r.profiles.List() {
		profileNames = append(profileNames, profile.Name)
	}
	var clarificationHistory []string
	for _, message := range input.ClarificationHistory {
		if strings.TrimSpace(message.Text) == "" {
			continue
		}
		clarificationHistory = append(clarificationHistory, fmt.Sprintf("%s: %s", message.Role, message.Text))
	}

	return prompts.RenderRouterUserPrompt(prompts.RouterUserPromptData{
		RouterProfileName:            routerProfileName,
		DefinedAgentProfiles:         profileNames,
		KnownConversationHandles:     input.ConversationHandles,
		CurrentConversationHandle:    input.CurrentConversationHandle,
		CurrentConversationNotes:     input.CurrentConversationNotes,
		PendingUpdateHandles:         input.PendingUpdateHandles,
		UnresolvedClarificationLines: clarificationHistory,
		UserTranscript:               input.Transcript,
	})
}

func (r *Router) buildConversationUpdatePrompt(input tincanrouter.ProcessConversationUpdateRequest) (string, error) {
	return prompts.RenderConversationUpdatePrompt(prompts.ConversationUpdatePromptData{
		ConversationHandle: input.ConversationHandle,
		DetailText:         input.DetailText,
	})
}
