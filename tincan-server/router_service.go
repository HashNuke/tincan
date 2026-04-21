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
	profiles *tincanconfig.AgentProfileStore
}

func NewRouter(backend tincanconfig.AgentBackendDefinition, adapter agent_adapters.Adapter, profiles *tincanconfig.AgentProfileStore) *Router {
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
	var clarificationHistory []string
	for _, message := range input.ClarificationHistory {
		if strings.TrimSpace(message.Text) == "" {
			continue
		}
		clarificationHistory = append(clarificationHistory, fmt.Sprintf("- %s: %s", message.Role, message.Text))
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
- If the transcript addresses or names an existing conversation handle and asks for status, progress, updates, what it has, or what happened, prefer read_conversation_update over message.
- If a transcript names something that matches an existing conversation handle, prefer treating it as a conversation handle rather than an agent profile when the request is about updates or current work.
- Spoken handle variants may omit punctuation. For example, "Emma 10" may refer to the handle "emma#10".
- If ambiguous, use ask_clarifying_question.
- If unresolved clarification history is present, treat it as prior conversation context for the current user reply.
- If the current transcript appears to answer the last clarification question, use the full clarification history plus the current transcript to decide the next action.
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
- "Emma 10 what do you have for me" => action=read_conversation_update, conversation_handle="emma#10"
- "what update do you have for emma 10" => action=read_conversation_update, conversation_handle="emma#10"
- "read the latest update from emma#10" => action=read_conversation_update, conversation_handle="emma#10"

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

Unresolved clarification history:
` + strings.Join(clarificationHistory, "\n") + `

User transcript:
` + input.Transcript)
}
