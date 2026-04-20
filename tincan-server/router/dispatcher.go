package router

import (
	"fmt"
	"strings"

	"tincan-server/conversations"
)

type ConversationCreateResult struct {
	ID                    string `json:"id"`
	DisplayHandle         string `json:"display_handle"`
	ConversationNumber    int    `json:"conversation_number"`
	AgentProfileName      string `json:"agent_profile_name"`
	AgentBackend          string `json:"agent_backend"`
	WorkingDirectory      string `json:"working_directory"`
	BackendConversationID string `json:"backend_conversation_id"`
	Status                string `json:"status"`
}

type ConversationCreator interface {
	CreateConversation(profileName string, title string, message string) (ConversationCreateResult, error)
}

type CallState interface {
	LinkConversation(transportSessionID string, backendConversationID string, conversationHandle string)
	AppendClarificationExchange(transportSessionID string, userText string, agentQuestion string) bool
	ClearClarificationHistory(transportSessionID string) bool
}

type AudioNotifier interface {
	Speak(sessionID string, text string) error
}

type DispatchResult struct {
	Fields map[string]any
}

type Dispatcher struct {
	Calls              CallState
	Conversations      *conversations.Store
	ConversationCreate ConversationCreator
	Audio              AudioNotifier
}

func (d *Dispatcher) DispatchUserInput(sessionID string, routeRequest RouteUserInputRequest, routeResult RouteUserInputResult) (DispatchResult, error) {
	switch routeResult.Action {
	case "new_conversation":
		result, err := d.dispatchNewConversation(sessionID, routeResult)
		if err == nil {
			d.Calls.ClearClarificationHistory(sessionID)
		}
		return result, err
	case "read_conversation_update":
		result, err := d.dispatchReadConversationUpdate(sessionID, routeRequest, routeResult)
		if err == nil {
			d.Calls.ClearClarificationHistory(sessionID)
		}
		return result, err
	case "switch_context":
		result, err := d.dispatchSwitchContext(sessionID, routeRequest, routeResult)
		if err == nil {
			d.Calls.ClearClarificationHistory(sessionID)
		}
		return result, err
	case "message":
		return DispatchResult{}, fmt.Errorf("message dispatch is not implemented yet")
	case "ask_clarifying_question":
		return d.dispatchAskClarifyingQuestion(sessionID, routeRequest, routeResult), nil
	case "ignore", "":
		return DispatchResult{}, nil
	default:
		return DispatchResult{}, fmt.Errorf("unknown router action %q", routeResult.Action)
	}
}

func (d *Dispatcher) dispatchNewConversation(sessionID string, routeResult RouteUserInputResult) (DispatchResult, error) {
	conversation, err := d.ConversationCreate.CreateConversation(routeResult.AgentProfile, routeResult.ConversationTitle, routeResult.Message)
	if err != nil {
		return DispatchResult{}, err
	}
	d.Calls.LinkConversation(sessionID, conversation.BackendConversationID, conversation.DisplayHandle)

	fields := map[string]any{
		"conversation": conversation,
	}
	return DispatchResult{Fields: fields}, nil
}

func (d *Dispatcher) dispatchReadConversationUpdate(sessionID string, routeRequest RouteUserInputRequest, routeResult RouteUserInputResult) (DispatchResult, error) {
	conversation, err := d.resolveConversation(routeRequest, routeResult)
	if err != nil {
		return DispatchResult{}, err
	}

	update, ok, err := d.Conversations.GetLatestPendingUpdateByConversationID(conversation.ID)
	if err != nil {
		return DispatchResult{}, err
	}
	if !ok {
		text := fmt.Sprintf("There is no pending update for %s.", conversation.DisplayHandle)
		if d.Audio != nil {
			_ = d.Audio.Speak(sessionID, text)
		}
		return DispatchResult{Fields: map[string]any{
			"resolved_conversation_handle": conversation.DisplayHandle,
		}}, nil
	}

	if d.Audio != nil {
		_ = d.Audio.Speak(sessionID, update.SummaryText)
	}
	if err := d.Conversations.ConsumeUpdate(update.ID); err != nil {
		return DispatchResult{}, err
	}
	return DispatchResult{Fields: map[string]any{
		"resolved_conversation_handle": conversation.DisplayHandle,
		"update":                       update,
	}}, nil
}

func (d *Dispatcher) dispatchSwitchContext(sessionID string, routeRequest RouteUserInputRequest, routeResult RouteUserInputResult) (DispatchResult, error) {
	conversation, err := d.resolveConversation(routeRequest, routeResult)
	if err != nil {
		return DispatchResult{}, err
	}

	d.Calls.LinkConversation(sessionID, conversation.BackendConversationID, conversation.DisplayHandle)
	text := fmt.Sprintf("Switched to %s.", conversation.DisplayHandle)
	if d.Audio != nil {
		_ = d.Audio.Speak(sessionID, text)
	}
	return DispatchResult{Fields: map[string]any{
		"current_conversation_handle": conversation.DisplayHandle,
	}}, nil
}

func (d *Dispatcher) dispatchAskClarifyingQuestion(sessionID string, routeRequest RouteUserInputRequest, routeResult RouteUserInputResult) DispatchResult {
	questionText := strings.TrimSpace(routeResult.ImmediateFeedback)
	if questionText == "" {
		questionText = strings.TrimSpace(routeResult.Message)
	}
	d.Calls.AppendClarificationExchange(sessionID, routeRequest.Transcript, questionText)
	return DispatchResult{}
}

func (d *Dispatcher) resolveConversation(routeRequest RouteUserInputRequest, routeResult RouteUserInputResult) (conversations.Conversation, error) {
	handle := strings.TrimSpace(routeResult.ConversationHandle)
	if handle == "" {
		handle = strings.TrimSpace(routeRequest.CurrentConversationHandle)
	}
	if handle == "" {
		return conversations.Conversation{}, fmt.Errorf("no target conversation handle available")
	}

	conversation, ok, err := d.Conversations.GetConversationByHandle(handle)
	if err != nil {
		return conversations.Conversation{}, err
	}
	if !ok {
		return conversations.Conversation{}, fmt.Errorf("unknown conversation handle %q", handle)
	}
	return conversation, nil
}
