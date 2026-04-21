package main

import (
	"fmt"
	"strings"

	"tincan-server/agent_adapters"
	tincanconfig "tincan-server/config"
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

	prompt := r.buildUserRouterPrompt(input)
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

	prompt := r.buildConversationUpdatePrompt(input)
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
  "conversation_notes": string,
  "immediate_feedback": string
}

Rules:
- Return only the fields relevant to the chosen action. Omit unused fields.
- Only choose new_conversation when the user explicitly asks for a new chat/session/conversation.
- If the transcript starts by directly addressing a defined agent profile name, treat that as a request to initiate a new conversation with that profile unless the user clearly asks to switch to an existing conversation handle instead.
- If the transcript addresses or names an existing conversation handle and asks for status, progress, updates, what it has, or what happened, prefer read_conversation_update over message.
- If a transcript names something that matches an existing conversation handle, prefer treating it as a conversation handle rather than an agent profile when the request is about updates or current work.
- Spoken handle variants may omit punctuation. For example, "Emma 10" may refer to the handle "emma#10".
- If ambiguous, use ask_clarifying_question.
- If unresolved clarification history is present, treat it as prior conversation context for the current user reply.
- If the current transcript appears to answer the last clarification question, use the full clarification history plus the current transcript to decide the next action.
- If no action should be taken, use ignore.
- For ignore, usually return only {"action":"ignore"}.
- conversation_title should be short and useful when action is new_conversation.
- conversation_notes is optional and should only be included when the stored conversation notes should be replaced.
- If conversation_notes is included, it replaces the existing stored notes completely. It is not additive.
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

func (r *Router) buildConversationUpdatePrompt(input tincanrouter.ProcessConversationUpdateRequest) string {
	return strings.TrimSpace(`You are the Tincan conversation update processor.

Your job is to turn a full agent update into two short audio-friendly strings.
Return JSON only. Do not wrap the response in markdown.

Response schema:
{
  "notification_text": string,
  "summary_text": string
}

Rules:
- notification_text should be short, first-person, and immediately useful when spoken aloud.
- notification_text should usually be 2-8 words.
- notification_text should reflect state when possible, for example: "I have an update.", "I need more info.", "I hit an issue.", "I finished the task.", "I need approval."
- summary_text should be a concise spoken summary, usually 1-2 short sentences.
- summary_text should stay brief enough for audio. Aim for roughly 12-35 words.
- summary_text should focus on the outcome, blocker, or next action rather than implementation trivia.
- If the full update asks the user a question or requests missing information, make notification_text indicate that.
- If the full update reports completion, make notification_text indicate completion.
- If the full update reports a blocker, failure, or issue, make notification_text indicate that.
- Do not use markdown, bullets, code fences, or file dumps.
- Do not mention the conversation handle unless it is necessary for clarity.
- Return valid JSON only.

Conversation handle:
` + input.ConversationHandle + `

Full update:
` + input.DetailText)
}
