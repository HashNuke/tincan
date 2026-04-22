package controllers

import (
	"fmt"
	"log"
	"strings"

	"tincan-server/calls"
	"tincan-server/conversations"
	"tincan-server/output"
	tincanrouter "tincan-server/router"
)

type Router interface {
	RouteUserInput(input tincanrouter.RouteUserInputRequest) (tincanrouter.RouteUserInputResult, error)
}

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

type ConversationSendResult struct {
	ConversationID string `json:"conversation_id"`
	DisplayHandle  string `json:"display_handle"`
	Queued         bool   `json:"queued"`
}

type ConversationCreator interface {
	CreateConversation(profileName string, title string, message string) (ConversationCreateResult, error)
}

type ConversationMessenger interface {
	ContinueConversation(conversation conversations.Conversation, message string) (ConversationSendResult, error)
}

type CallState interface {
	LinkConversation(transportSessionID string, conversationID string, conversationHandle string)
	AppendClarificationExchange(transportSessionID string, userText string, agentQuestion string) bool
	ClearClarificationHistory(transportSessionID string) bool
	CurrentConversationHandleForSession(transportSessionID string) (string, bool)
	CurrentConversationIDForSession(transportSessionID string) (string, bool)
	ClarificationHistoryForSession(transportSessionID string) []calls.ClarificationMessage
}

type HandleResult struct {
	RouteRequest tincanrouter.RouteUserInputRequest
	RouteResult  tincanrouter.RouteUserInputResult
	ResponseBody map[string]any
	OutputEvents []output.Event
}

type UserInputController struct {
	Router             Router
	Calls              CallState
	Conversations      *conversations.Store
	ConversationCreate ConversationCreator
	ConversationSend   ConversationMessenger
}

func (c *UserInputController) HandleTranscript(sessionID string, transcript string) (HandleResult, error) {
	routeRequest, err := c.buildRouteUserInputRequest(sessionID, transcript)
	if err != nil {
		return HandleResult{}, err
	}

	routeResult, err := c.Router.RouteUserInput(routeRequest)
	if err != nil {
		return HandleResult{}, err
	}
	routeResult = normalizeImmediateFeedback(routeRequest, routeResult)

	result := HandleResult{
		RouteRequest: routeRequest,
		RouteResult:  routeResult,
		ResponseBody: map[string]any{
			"text":   transcript,
			"router": routeResult,
		},
	}

	dispatchResult, err := c.dispatchUserInput(sessionID, routeRequest, routeResult)
	if err != nil {
		return HandleResult{}, err
	}
	for key, value := range dispatchResult.ResponseBody {
		result.ResponseBody[key] = value
	}
	result.OutputEvents = append(result.OutputEvents, dispatchResult.OutputEvents...)

	if strings.TrimSpace(dispatchResult.ImmediateFeedbackOverride) != "" {
		routeResult.ImmediateFeedback = dispatchResult.ImmediateFeedbackOverride
	}
	result.RouteResult = routeResult
	result.ResponseBody["router"] = routeResult

	if strings.TrimSpace(routeResult.ImmediateFeedback) != "" {
		result.OutputEvents = append([]output.Event{{
			SessionID: sessionID,
			Kind:      output.KindImmediateFeedback,
			Text:      routeResult.ImmediateFeedback,
		}}, result.OutputEvents...)
	}

	if conversationValue, ok := result.ResponseBody["conversation"]; ok && strings.TrimSpace(routeResult.ConversationNotes) != "" {
		if conversation, ok := conversationValue.(ConversationCreateResult); ok {
			if _, err := c.Conversations.UpsertConversationNotes(conversation.ID, routeResult.ConversationNotes); err != nil {
				return HandleResult{}, err
			}
		}
	}

	return result, nil
}

func normalizeImmediateFeedback(
	routeRequest tincanrouter.RouteUserInputRequest,
	routeResult tincanrouter.RouteUserInputResult,
) tincanrouter.RouteUserInputResult {
	if strings.TrimSpace(routeResult.ImmediateFeedback) != "" {
		return routeResult
	}

	switch routeResult.Action {
	case "new_conversation":
		agentProfile := strings.TrimSpace(routeResult.AgentProfile)
		if agentProfile == "" {
			routeResult.ImmediateFeedback = "Starting a new conversation."
		} else {
			routeResult.ImmediateFeedback = fmt.Sprintf("Starting %s.", agentProfile)
		}
	case "message":
		targetHandle := strings.TrimSpace(routeResult.ConversationHandle)
		if targetHandle == "" {
			targetHandle = strings.TrimSpace(routeRequest.CurrentConversationHandle)
		}
		if targetHandle == "" {
			routeResult.ImmediateFeedback = "Sending that now."
		} else {
			routeResult.ImmediateFeedback = fmt.Sprintf("Sending that to %s.", targetHandle)
		}
	}

	return routeResult
}

func (c *UserInputController) buildRouteUserInputRequest(sessionID string, transcript string) (tincanrouter.RouteUserInputRequest, error) {
	request := tincanrouter.RouteUserInputRequest{Transcript: transcript}

	conversationHandles, err := c.Conversations.ListConversationHandles()
	if err != nil {
		return tincanrouter.RouteUserInputRequest{}, err
	}
	request.ConversationHandles = conversationHandles

	pendingUpdateHandles, err := c.Conversations.ListPendingUpdateHandles(20)
	if err != nil {
		return tincanrouter.RouteUserInputRequest{}, err
	}
	request.PendingUpdateHandles = pendingUpdateHandles

	currentConversationHandle, hasCurrentHandle := c.Calls.CurrentConversationHandleForSession(sessionID)
	currentConversationID, hasCurrentConversationID := c.Calls.CurrentConversationIDForSession(sessionID)
	if !hasCurrentHandle && !hasCurrentConversationID {
		return request, nil
	}
	request.CurrentConversationHandle = currentConversationHandle

	for _, message := range c.Calls.ClarificationHistoryForSession(sessionID) {
		request.ClarificationHistory = append(request.ClarificationHistory, tincanrouter.ClarificationMessage{
			Role: message.Role,
			Text: message.Text,
		})
	}

	if !hasCurrentConversationID {
		return request, nil
	}

	currentConversation, ok, err := c.Conversations.GetConversationByID(currentConversationID)
	if err != nil {
		return tincanrouter.RouteUserInputRequest{}, err
	}
	if !ok {
		return request, nil
	}

	note, ok, err := c.Conversations.GetConversationNotes(currentConversation.ID)
	if err != nil {
		return tincanrouter.RouteUserInputRequest{}, err
	}
	if ok {
		request.CurrentConversationNotes = note.NotesText
	}

	return request, nil
}

type dispatchResult struct {
	ResponseBody              map[string]any
	OutputEvents              []output.Event
	ImmediateFeedbackOverride string
}

func (c *UserInputController) dispatchUserInput(sessionID string, routeRequest tincanrouter.RouteUserInputRequest, routeResult tincanrouter.RouteUserInputResult) (dispatchResult, error) {
	switch routeResult.Action {
	case "new_conversation":
		result, err := c.dispatchNewConversation(sessionID, routeResult)
		if err == nil {
			c.Calls.ClearClarificationHistory(sessionID)
		}
		return result, err
	case "read_conversation_update":
		result, err := c.dispatchReadConversationUpdate(sessionID, routeRequest, routeResult)
		if err == nil {
			c.Calls.ClearClarificationHistory(sessionID)
		}
		return result, err
	case "switch_context":
		result, err := c.dispatchSwitchContext(sessionID, routeRequest, routeResult)
		if err == nil {
			c.Calls.ClearClarificationHistory(sessionID)
		}
		return result, err
	case "message":
		result, err := c.dispatchMessage(sessionID, routeRequest, routeResult)
		if err == nil {
			c.Calls.ClearClarificationHistory(sessionID)
		}
		return result, err
	case "ask_clarifying_question":
		return c.dispatchAskClarifyingQuestion(sessionID, routeRequest, routeResult), nil
	case "ignore", "":
		return dispatchResult{}, nil
	default:
		return dispatchResult{}, fmt.Errorf("unknown router action %q", routeResult.Action)
	}
}

func (c *UserInputController) dispatchNewConversation(sessionID string, routeResult tincanrouter.RouteUserInputResult) (dispatchResult, error) {
	log.Printf(
		"peer %s scheduling new conversation: agent_profile=%q title=%q message=%q",
		sessionID,
		routeResult.AgentProfile,
		routeResult.ConversationTitle,
		routeResult.Message,
	)
	conversation, err := c.ConversationCreate.CreateConversation(routeResult.AgentProfile, routeResult.ConversationTitle, routeResult.Message)
	if err != nil {
		return dispatchResult{}, err
	}
	c.Calls.LinkConversation(sessionID, conversation.ID, conversation.DisplayHandle)
	log.Printf(
		"peer %s linked conversation: handle=%q conversation_id=%q status=%q",
		sessionID,
		conversation.DisplayHandle,
		conversation.ID,
		conversation.Status,
	)

	return dispatchResult{
		ResponseBody: map[string]any{
			"conversation": conversation,
		},
	}, nil
}

func (c *UserInputController) dispatchReadConversationUpdate(sessionID string, routeRequest tincanrouter.RouteUserInputRequest, routeResult tincanrouter.RouteUserInputResult) (dispatchResult, error) {
	conversation, err := c.resolveConversation(routeRequest, routeResult)
	if err != nil {
		return dispatchResult{}, err
	}

	message, ok, err := c.Conversations.GetLatestPendingMessageByConversationID(conversation.ID)
	if err != nil {
		return dispatchResult{}, err
	}
	if !ok {
		return dispatchResult{
			ResponseBody: map[string]any{
				"resolved_conversation_handle": conversation.DisplayHandle,
			},
			OutputEvents: []output.Event{{
				SessionID: sessionID,
				Kind:      output.KindUpdateSummary,
				Text:      fmt.Sprintf("There is no pending update for %s.", conversation.DisplayHandle),
			}},
		}, nil
	}

	if err := c.Conversations.ConsumeMessage(message.ID); err != nil {
		return dispatchResult{}, err
	}
	return dispatchResult{
		ResponseBody: map[string]any{
			"resolved_conversation_handle": conversation.DisplayHandle,
			"update":                       message,
		},
		OutputEvents: []output.Event{{
			SessionID: sessionID,
			Kind:      output.KindUpdateSummary,
			Text:      message.SummaryText,
		}},
	}, nil
}

func (c *UserInputController) dispatchSwitchContext(sessionID string, routeRequest tincanrouter.RouteUserInputRequest, routeResult tincanrouter.RouteUserInputResult) (dispatchResult, error) {
	conversation, err := c.resolveConversation(routeRequest, routeResult)
	if err != nil {
		return dispatchResult{}, err
	}

	c.Calls.LinkConversation(sessionID, conversation.ID, conversation.DisplayHandle)
	return dispatchResult{
		ResponseBody: map[string]any{
			"current_conversation_handle": conversation.DisplayHandle,
		},
		OutputEvents: []output.Event{{
			SessionID: sessionID,
			Kind:      output.KindContextSwitch,
			Text:      fmt.Sprintf("Switched to %s.", conversation.DisplayHandle),
		}},
	}, nil
}

func (c *UserInputController) dispatchMessage(sessionID string, routeRequest tincanrouter.RouteUserInputRequest, routeResult tincanrouter.RouteUserInputResult) (dispatchResult, error) {
	conversation, err := c.resolveConversation(routeRequest, routeResult)
	if err != nil {
		return dispatchResult{}, err
	}
	if c.ConversationSend == nil {
		return dispatchResult{}, fmt.Errorf("conversation messaging is not configured")
	}
	log.Printf(
		"peer %s scheduling message: handle=%q conversation_id=%q message=%q",
		sessionID,
		conversation.DisplayHandle,
		conversation.ID,
		routeResult.Message,
	)
	sendResult, err := c.ConversationSend.ContinueConversation(conversation, routeResult.Message)
	if err != nil {
		return dispatchResult{}, err
	}
	c.Calls.LinkConversation(sessionID, conversation.ID, conversation.DisplayHandle)
	log.Printf(
		"peer %s refreshed conversation context: handle=%q conversation_id=%q queued=%t",
		sessionID,
		conversation.DisplayHandle,
		conversation.ID,
		sendResult.Queued,
	)

	result := dispatchResult{
		ResponseBody: map[string]any{
			"resolved_conversation_handle": conversation.DisplayHandle,
			"conversation_send":            sendResult,
		},
	}
	if sendResult.Queued {
		result.ImmediateFeedbackOverride = fmt.Sprintf("Queued that for %s.", conversation.DisplayHandle)
	}
	return result, nil
}

func (c *UserInputController) dispatchAskClarifyingQuestion(sessionID string, routeRequest tincanrouter.RouteUserInputRequest, routeResult tincanrouter.RouteUserInputResult) dispatchResult {
	questionText := strings.TrimSpace(routeResult.ImmediateFeedback)
	if questionText == "" {
		questionText = strings.TrimSpace(routeResult.Message)
	}
	c.Calls.AppendClarificationExchange(sessionID, routeRequest.Transcript, questionText)
	if questionText == "" {
		return dispatchResult{}
	}
	return dispatchResult{
		OutputEvents: []output.Event{{
			SessionID: sessionID,
			Kind:      output.KindClarificationQuestion,
			Text:      questionText,
		}},
	}
}

func (c *UserInputController) resolveConversation(routeRequest tincanrouter.RouteUserInputRequest, routeResult tincanrouter.RouteUserInputResult) (conversations.Conversation, error) {
	handle := strings.TrimSpace(routeResult.ConversationHandle)
	if handle == "" {
		handle = strings.TrimSpace(routeRequest.CurrentConversationHandle)
	}
	if handle == "" {
		return conversations.Conversation{}, fmt.Errorf("no target conversation handle available")
	}

	conversation, ok, err := c.Conversations.GetConversationByHandle(handle)
	if err != nil {
		return conversations.Conversation{}, err
	}
	if !ok {
		return conversations.Conversation{}, fmt.Errorf("unknown conversation handle %q", handle)
	}
	return conversation, nil
}
