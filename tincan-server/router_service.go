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

func (r *Router) RouteUserInput(input tincanrouter.RouteUserInputRequest) (tincanrouter.RouteUserInputResult, error) {
	prompt := r.buildUserRouterPrompt(input)
	result, err := r.adapter.RunRouterPrompt(r.backend, prompt, input.Transcript)
	if err != nil {
		return tincanrouter.RouteUserInputResult{}, fmt.Errorf("route user input: %w", err)
	}
	return result, nil
}

func (r *Router) buildUserRouterPrompt(input tincanrouter.RouteUserInputRequest) string {
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
- If the transcript starts by directly addressing a defined agent profile name, treat that as a request to initiate a new conversation with that profile unless the user clearly asks to switch to an existing conversation handle instead.
- If ambiguous, use ask_clarifying_question.
- If no action should be taken, use ignore.
- conversation_title should be short and useful when action is new_conversation.
- If the user says "start a conversation with Emma" or "open a chat with Emma", treat "Emma" as an agent profile name when it matches one of the defined agent profiles.
- When the user asks to start a conversation with a defined agent profile, set action to new_conversation and set agent_profile to that exact profile name.
- If the user says "Emma, start a conversation" and Emma is a defined agent profile, set action to new_conversation and set agent_profile to "Emma".
- If the user says "Emma, do xyz" and Emma is a defined agent profile, set action to new_conversation, set agent_profile to "Emma", and put the requested work in message.

Examples:
- "start a conversation with Emma" => action=new_conversation, agent_profile="Emma"
- "open a chat with Emma about the build error" => action=new_conversation, agent_profile="Emma", message should carry the user's request
- "Emma, start a conversation" => action=new_conversation, agent_profile="Emma"
- "Emma, do the iOS signing fix" => action=new_conversation, agent_profile="Emma", message="do the iOS signing fix"
- "switch to MS7" => action=switch_context, conversation_handle="MS7"

Defined agent profiles:
- ` + strings.Join(profileNames, "\n- ") + `

Known conversation handles:
- ` + strings.Join(input.ConversationHandles, "\n- ") + `

Current conversation handle:
` + input.CurrentConversationHandle + `

Current conversation notes:
` + input.CurrentConversationNotes + `

Pending update handles:
- ` + strings.Join(input.PendingUpdateHandles, "\n- ") + `

User transcript:
` + input.Transcript)
}
