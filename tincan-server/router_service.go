package main

import (
	"fmt"
	"strings"

	"tincan-server/agent_adapters"
	tincanconfig "tincan-server/config"
	tincanrouter "tincan-server/router"
)

type Router struct {
	backend  tincanconfig.AgentBackendDefinition
	adapter  agent_adapters.Adapter
	profiles *AgentProfileStore
}

func NewRouter(backend tincanconfig.AgentBackendDefinition, adapter agent_adapters.Adapter, profiles *AgentProfileStore) *Router {
	return &Router{backend: backend, adapter: adapter, profiles: profiles}
}

func (r *Router) RouteUserTranscript(input tincanrouter.UserRouterInput) (tincanrouter.UserRouterResult, error) {
	prompt := r.buildUserRouterPrompt(input)
	result, err := r.adapter.RunRouterPrompt(r.backend, prompt, input.Transcript)
	if err != nil {
		return tincanrouter.UserRouterResult{}, fmt.Errorf("route transcript: %w", err)
	}
	return result, nil
}

func (r *Router) buildUserRouterPrompt(input tincanrouter.UserRouterInput) string {
	var profileNames []string
	for _, profile := range r.profiles.List() {
		profileNames = append(profileNames, profile.Name)
	}

	return strings.TrimSpace(`You are the Tincan router.

Your job is to decide what to do with a user's transcript.
Return JSON only. Do not wrap the response in markdown.

Allowed actions:
- new_conversation
- message
- read_conversation_update
- switch_context
- ask_clarifying_question
- ignore

Response schema:
{
  "action": string,
  "message": string,
  "agent_profile": string,
  "conversation_handle": string,
  "conversation_title": string,
  "updated_conversation_notes": string,
  "immediate_feedback": string,
  "raw_transcript": string
}

Rules:
- Only choose new_conversation when the user explicitly asks for a new chat/session/conversation.
- If ambiguous, use ask_clarifying_question.
- If no action should be taken, use ignore.
- conversation_title should be short and useful when action is new_conversation.

Defined agent profiles:
- ` + strings.Join(profileNames, "\n- ") + `

Known conversation handles:
- ` + strings.Join(input.ConversationHandles, "\n- ") + `

Current conversation handle:
` + input.CurrentConversationHandle + `

Current conversation notes:
` + input.CurrentConversationNotes + `

User transcript:
` + input.Transcript)
}
