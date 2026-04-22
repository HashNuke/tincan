package controllers

import (
	"encoding/json"
	"log"
	"strings"

	"tincan-server/conversations"
	"tincan-server/output"
	tincanrouter "tincan-server/router"
)

type OpenCodeHookEvent struct {
	ConversationID string `json:"conversation_id"`
	EventType      string `json:"event_type"`
	SessionID      string `json:"session_id,omitempty"`
	MessageID      string `json:"message_id,omitempty"`
	PartID         string `json:"part_id,omitempty"`
	Text           string `json:"text,omitempty"`
	StatusType     string `json:"status_type,omitempty"`
	ErrorName      string `json:"error_name,omitempty"`
	ErrorMessage   string `json:"error_message,omitempty"`
}

type SessionResolver interface {
	SessionIDForConversation(conversationID string) (string, bool)
}

type ConversationUpdateProcessor interface {
	ProcessConversationUpdate(input tincanrouter.ProcessConversationUpdateRequest) (tincanrouter.ProcessConversationUpdateResult, error)
}

type HookHandleResult struct {
	ConversationID string
	MessageID      string
	OutputEvents   []output.Event
}

type HookController struct {
	Conversations   *conversations.Store
	Sessions        SessionResolver
	UpdateProcessor ConversationUpdateProcessor
}

type processedConversationUpdate struct {
	NotificationText string
	SummaryText      string
	DetailText       string
}

func (c *HookController) HandleOpenCodeHook(event OpenCodeHookEvent) (HookHandleResult, bool, error) {
	conversationID := strings.TrimSpace(event.ConversationID)
	if conversationID == "" {
		return HookHandleResult{}, false, nil
	}

	conversation, ok, err := c.Conversations.GetConversationByID(conversationID)
	if err != nil {
		return HookHandleResult{}, false, err
	}
	if !ok {
		return HookHandleResult{}, false, nil
	}

	if strings.TrimSpace(event.SessionID) != "" && strings.TrimSpace(conversation.BackendConversationID) == "" {
		updatedConversation, updated, err := c.Conversations.BindBackendConversationID(conversation.ID, event.SessionID)
		if err != nil {
			return HookHandleResult{}, true, err
		}
		if updated {
			conversation = updatedConversation
		}
	}

	switch event.EventType {
	case "message.part.updated":
		return c.handleCompletedTextPart(conversation, event)
	case "session.idle", "session.error", "session.status":
		return HookHandleResult{ConversationID: conversation.ID}, true, nil
	default:
		return HookHandleResult{}, true, nil
	}
}

func (c *HookController) handleCompletedTextPart(conversation conversations.Conversation, event OpenCodeHookEvent) (HookHandleResult, bool, error) {
	detailText := strings.TrimSpace(event.Text)
	if detailText == "" {
		return HookHandleResult{ConversationID: conversation.ID}, true, nil
	}

	processedUpdate := c.processConversationUpdate(conversation.DisplayHandle, detailText)
	message, changed, err := c.Conversations.CreateMessage(conversations.Message{
		ConversationID:     conversation.ID,
		ConversationHandle: conversation.DisplayHandle,
		SummaryText:        processedUpdate.SummaryText,
		DetailText:         processedUpdate.DetailText,
		NotificationText:   processedUpdate.NotificationText,
		RawUpdateJSON:      mustMarshalJSON(event),
		Status:             "pending",
	})
	if err != nil {
		return HookHandleResult{}, true, err
	}
	if !changed {
		return HookHandleResult{ConversationID: conversation.ID}, true, nil
	}

	result := HookHandleResult{
		ConversationID: conversation.ID,
		MessageID:      message.ID,
	}

	sessionID, hasSession := c.Sessions.SessionIDForConversation(conversation.ID)
	if hasSession {
		result.OutputEvents = append(result.OutputEvents, output.Event{
			SessionID:   sessionID,
			Kind:        output.KindNotification,
			Text:        processedUpdate.NotificationText,
			SummaryText: processedUpdate.SummaryText,
		})
	}

	return result, true, nil
}

func (c *HookController) processConversationUpdate(conversationHandle string, detailText string) processedConversationUpdate {
	defaultedDetailText := defaultConversationUpdateDetail(detailText)
	fallback := fallbackConversationUpdatePresentation(defaultedDetailText)
	if c == nil || c.UpdateProcessor == nil {
		return fallback
	}

	result, err := c.UpdateProcessor.ProcessConversationUpdate(tincanrouter.ProcessConversationUpdateRequest{
		ConversationHandle: conversationHandle,
		DetailText:         defaultedDetailText,
	})
	if err != nil {
		log.Printf("conversation update processor failed for %s: %v", conversationHandle, err)
		return fallback
	}

	notificationText := strings.TrimSpace(result.NotificationText)
	if notificationText == "" {
		notificationText = fallback.NotificationText
	}
	summaryText := strings.TrimSpace(result.SummaryText)
	if summaryText == "" {
		summaryText = fallback.SummaryText
	}

	return processedConversationUpdate{
		NotificationText: notificationText,
		SummaryText:      summaryText,
		DetailText:       defaultedDetailText,
	}
}

func defaultConversationUpdateDetail(detailText string) string {
	trimmed := normalizeConversationUpdateText(detailText)
	if trimmed != "" {
		return trimmed
	}
	return "The agent has an update."
}

func fallbackConversationUpdatePresentation(detailText string) processedConversationUpdate {
	normalizedDetailText := defaultConversationUpdateDetail(detailText)
	return processedConversationUpdate{
		NotificationText: fallbackConversationUpdateNotification(normalizedDetailText),
		SummaryText:      fallbackConversationUpdateSummary(normalizedDetailText),
		DetailText:       normalizedDetailText,
	}
}

func fallbackConversationUpdateNotification(detailText string) string {
	lowerDetailText := strings.ToLower(detailText)
	switch {
	case strings.Contains(detailText, "?") || containsAny(lowerDetailText, "need more info", "need more information", "need clarification", "please provide", "can you", "could you", "what should", "which "):
		return "I need more info."
	case containsAny(lowerDetailText, "approval", "approve", "permission"):
		return "I need approval."
	case containsAny(lowerDetailText, "error", "failed", "failure", "blocked", "stuck", "issue", "unable to", "could not", "couldn't", "can't", "cannot"):
		return "I hit an issue."
	case containsAny(lowerDetailText, "done", "finished", "completed", "implemented", "fixed", "resolved", "committed", "pushed", "shipped"):
		return "I finished the task."
	default:
		return "I have an update."
	}
}

func fallbackConversationUpdateSummary(detailText string) string {
	const maxSummaryLength = 180

	normalizedDetailText := normalizeConversationUpdateText(detailText)
	if len(normalizedDetailText) <= maxSummaryLength {
		return normalizedDetailText
	}

	truncated := normalizedDetailText[:maxSummaryLength]
	if lastSpaceIndex := strings.LastIndex(truncated, " "); lastSpaceIndex >= maxSummaryLength/2 {
		truncated = truncated[:lastSpaceIndex]
	}
	return strings.TrimSpace(truncated) + "..."
}

func normalizeConversationUpdateText(detailText string) string {
	return strings.TrimSpace(strings.Join(strings.Fields(strings.TrimSpace(detailText)), " "))
}

func containsAny(haystack string, needles ...string) bool {
	for _, needle := range needles {
		if strings.Contains(haystack, needle) {
			return true
		}
	}
	return false
}

func mustMarshalJSON(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		return ""
	}
	return string(data)
}
