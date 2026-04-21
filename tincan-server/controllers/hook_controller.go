package controllers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"

	"tincan-server/conversations"
	"tincan-server/output"
	tincanrouter "tincan-server/router"
)

type OpenCodeHookEvent struct {
	EventType    string `json:"event_type"`
	SessionID    string `json:"session_id"`
	StatusType   string `json:"status_type,omitempty"`
	ErrorName    string `json:"error_name,omitempty"`
	ErrorMessage string `json:"error_message,omitempty"`
}

type SessionResolver interface {
	SessionIDForConversation(backendConversationID string) (string, bool)
}

type BackendLookup interface {
	BackendBaseURL(name string) (string, bool)
}

type ConversationUpdateProcessor interface {
	ProcessConversationUpdate(input tincanrouter.ProcessConversationUpdateRequest) (tincanrouter.ProcessConversationUpdateResult, error)
}

type HookHandleResult struct {
	OutputEvents []output.Event
}

type HookController struct {
	Conversations   *conversations.Store
	Backends        BackendLookup
	Sessions        SessionResolver
	UpdateProcessor ConversationUpdateProcessor
}

type processedConversationUpdate struct {
	NotificationText string
	SummaryText      string
	DetailText       string
}

func (c *HookController) HandleOpenCodeHook(event OpenCodeHookEvent) (HookHandleResult, bool, error) {
	conversation, ok, err := c.Conversations.GetConversationByBackendConversationID(event.SessionID)
	if err != nil {
		return HookHandleResult{}, false, err
	}
	if !ok {
		return HookHandleResult{}, false, nil
	}

	var (
		changed         bool
		processedUpdate processedConversationUpdate
	)
	switch event.EventType {
	case "session.idle":
		processedUpdate, changed, err = c.createConversationUpdateFromLatestAssistant(conversation)
	case "session.error":
		processedUpdate = c.processConversationUpdate(conversation.DisplayHandle, event.ErrorMessage)
		_, changed, err = c.Conversations.UpsertPendingUpdate(conversations.ConversationUpdate{
			ConversationID:     conversation.ID,
			ConversationHandle: conversation.DisplayHandle,
			SummaryText:        processedUpdate.SummaryText,
			DetailText:         processedUpdate.DetailText,
			NotificationText:   processedUpdate.NotificationText,
			RawUpdateJSON:      mustMarshalJSON(event),
			Status:             "pending",
		})
	default:
		return HookHandleResult{}, true, nil
	}
	if err != nil {
		return HookHandleResult{}, true, err
	}
	if !changed {
		return HookHandleResult{}, true, nil
	}

	sessionID, hasSession := c.Sessions.SessionIDForConversation(conversation.BackendConversationID)
	if !hasSession {
		return HookHandleResult{}, true, nil
	}

	return HookHandleResult{
		OutputEvents: []output.Event{{
			SessionID:   sessionID,
			Kind:        output.KindNotification,
			Text:        processedUpdate.NotificationText,
			SummaryText: processedUpdate.SummaryText,
		}},
	}, true, nil
}

func (c *HookController) createConversationUpdateFromLatestAssistant(conversation conversations.Conversation) (processedConversationUpdate, bool, error) {
	baseURLString, ok := c.Backends.BackendBaseURL(conversation.AgentBackend)
	if !ok || baseURLString == "" {
		return processedConversationUpdate{}, false, fmt.Errorf("conversation backend does not support OpenCode message fetch")
	}

	baseURL, err := url.Parse(baseURLString)
	if err != nil {
		return processedConversationUpdate{}, false, err
	}
	messageURL := baseURL.ResolveReference(&url.URL{Path: strings.TrimRight(baseURL.Path, "/") + "/session/" + conversation.BackendConversationID + "/message"})
	query := messageURL.Query()
	query.Set("directory", conversation.WorkingDirectory)
	messageURL.RawQuery = query.Encode()

	resp, err := http.Get(messageURL.String())
	if err != nil {
		return processedConversationUpdate{}, false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return processedConversationUpdate{}, false, fmt.Errorf("fetch session messages failed with status %d", resp.StatusCode)
	}

	var messages []struct {
		Info struct {
			Role string `json:"role"`
		} `json:"info"`
		Parts []struct {
			Type string `json:"type"`
			Text string `json:"text,omitempty"`
		} `json:"parts"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&messages); err != nil {
		return processedConversationUpdate{}, false, err
	}

	latestText := ""
	for i := len(messages) - 1; i >= 0; i-- {
		if messages[i].Info.Role != "assistant" {
			continue
		}
		for _, part := range messages[i].Parts {
			if part.Type == "text" && strings.TrimSpace(part.Text) != "" {
				latestText = strings.TrimSpace(part.Text)
				break
			}
		}
		if latestText != "" {
			break
		}
	}
	if latestText == "" {
		latestText = defaultConversationUpdateDetail("")
	}

	processedUpdate := c.processConversationUpdate(conversation.DisplayHandle, latestText)

	_, changed, err := c.Conversations.UpsertPendingUpdate(conversations.ConversationUpdate{
		ConversationID:     conversation.ID,
		ConversationHandle: conversation.DisplayHandle,
		SummaryText:        processedUpdate.SummaryText,
		DetailText:         processedUpdate.DetailText,
		NotificationText:   processedUpdate.NotificationText,
		RawUpdateJSON:      mustMarshalJSON(messages),
		Status:             "pending",
	})
	return processedUpdate, changed, err
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

func normalizeConversationUpdateText(text string) string {
	return strings.Join(strings.Fields(strings.TrimSpace(text)), " ")
}

func containsAny(text string, patterns ...string) bool {
	for _, pattern := range patterns {
		if strings.Contains(text, pattern) {
			return true
		}
	}
	return false
}

func mustMarshalJSON(v any) string {
	data, err := json.Marshal(v)
	if err != nil {
		return "{}"
	}
	return string(data)
}
