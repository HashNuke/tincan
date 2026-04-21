package controllers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"tincan-server/conversations"
	"tincan-server/output"
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

type HookHandleResult struct {
	OutputEvents []output.Event
}

type HookController struct {
	Conversations *conversations.Store
	Backends      BackendLookup
	Sessions      SessionResolver
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
		changed    bool
		detailText string
	)
	switch event.EventType {
	case "session.idle":
		detailText, changed, err = c.createConversationUpdateFromLatestAssistant(conversation)
	case "session.error":
		detailText = latestPendingUpdateDetail(conversation.DisplayHandle, event.ErrorMessage)
		_, changed, err = c.Conversations.UpsertPendingUpdate(conversations.ConversationUpdate{
			ConversationID:     conversation.ID,
			ConversationHandle: conversation.DisplayHandle,
			SummaryText:        detailText,
			NotificationText:   conversation.DisplayHandle + " has an update.",
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
			SessionID:  sessionID,
			Kind:       output.KindNotification,
			Text:       conversation.DisplayHandle + " has an update.",
			DetailText: detailText,
		}},
	}, true, nil
}

func (c *HookController) createConversationUpdateFromLatestAssistant(conversation conversations.Conversation) (string, bool, error) {
	baseURLString, ok := c.Backends.BackendBaseURL(conversation.AgentBackend)
	if !ok || baseURLString == "" {
		return "", false, fmt.Errorf("conversation backend does not support OpenCode message fetch")
	}

	baseURL, err := url.Parse(baseURLString)
	if err != nil {
		return "", false, err
	}
	messageURL := baseURL.ResolveReference(&url.URL{Path: strings.TrimRight(baseURL.Path, "/") + "/session/" + conversation.BackendConversationID + "/message"})
	query := messageURL.Query()
	query.Set("directory", conversation.WorkingDirectory)
	messageURL.RawQuery = query.Encode()

	resp, err := http.Get(messageURL.String())
	if err != nil {
		return "", false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false, fmt.Errorf("fetch session messages failed with status %d", resp.StatusCode)
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
		return "", false, err
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
		latestText = "The agent has an update."
	}

	_, changed, err := c.Conversations.UpsertPendingUpdate(conversations.ConversationUpdate{
		ConversationID:     conversation.ID,
		ConversationHandle: conversation.DisplayHandle,
		SummaryText:        latestText,
		NotificationText:   conversation.DisplayHandle + " has an update.",
		RawUpdateJSON:      mustMarshalJSON(messages),
		Status:             "pending",
	})
	return latestText, changed, err
}

func latestPendingUpdateDetail(conversationHandle string, updateText string) string {
	trimmed := strings.TrimSpace(updateText)
	if trimmed != "" {
		return trimmed
	}
	if strings.TrimSpace(conversationHandle) == "" {
		return "The agent has an update."
	}
	return conversationHandle + " has an update."
}

func mustMarshalJSON(v any) string {
	data, err := json.Marshal(v)
	if err != nil {
		return "{}"
	}
	return string(data)
}
