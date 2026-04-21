package controllers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"tincan-server/conversations"
	"tincan-server/output"
)

type fakeHookSessionResolver struct {
	sessionID string
}

func (f fakeHookSessionResolver) SessionIDForConversation(backendConversationID string) (string, bool) {
	if backendConversationID == "" || f.sessionID == "" {
		return "", false
	}
	return f.sessionID, true
}

type fakeHookBackendLookup struct {
	baseURL string
}

func (f fakeHookBackendLookup) BackendBaseURL(name string) (string, bool) {
	if name == "" || f.baseURL == "" {
		return "", false
	}
	return f.baseURL, true
}

func TestHookControllerSessionIdleEmitsNotificationDetailText(t *testing.T) {
	messageServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/session/backend-1/message" {
			t.Fatalf("unexpected message path: %s", r.URL.Path)
		}
		if got := r.URL.Query().Get("directory"); got != "/tmp/project" {
			t.Fatalf("unexpected message directory query: %q", got)
		}

		messages := []map[string]any{
			{
				"info": map[string]any{"role": "assistant"},
				"parts": []map[string]any{
					{"type": "text", "text": "The build finished and all tests passed."},
				},
			},
		}
		if err := json.NewEncoder(w).Encode(messages); err != nil {
			t.Fatalf("failed to encode messages: %v", err)
		}
	}))
	defer messageServer.Close()

	store := newTestConversationStore(t)
	conversation := createTestConversation(t, store, conversations.Conversation{
		ID:                    "conv-1",
		DisplayHandle:         "emma#14",
		AgentProfileName:      "emma",
		ConversationNumber:    14,
		AgentBackend:          "opencode-1",
		WorkingDirectory:      "/tmp/project",
		BackendConversationID: "backend-1",
		Status:                "running",
	})

	controller := &HookController{
		Conversations: store,
		Backends:      fakeHookBackendLookup{baseURL: messageServer.URL},
		Sessions:      fakeHookSessionResolver{sessionID: "session-1"},
	}

	result, handled, err := controller.HandleOpenCodeHook(OpenCodeHookEvent{
		EventType: "session.idle",
		SessionID: conversation.BackendConversationID,
	})
	if err != nil {
		t.Fatalf("HandleOpenCodeHook returned error: %v", err)
	}
	if !handled {
		t.Fatalf("expected hook to be handled")
	}
	if len(result.OutputEvents) != 1 {
		t.Fatalf("expected one output event, got %+v", result.OutputEvents)
	}

	event := result.OutputEvents[0]
	if event.Kind != output.KindNotification {
		t.Fatalf("expected notification output, got %q", event.Kind)
	}
	if event.Text != "emma#14 has an update." {
		t.Fatalf("unexpected notification text: %q", event.Text)
	}
	if event.DetailText != "The build finished and all tests passed." {
		t.Fatalf("unexpected notification detail text: %q", event.DetailText)
	}

	update, ok, err := store.GetLatestPendingUpdateByConversationID(conversation.ID)
	if err != nil {
		t.Fatalf("GetLatestPendingUpdateByConversationID returned error: %v", err)
	}
	if !ok {
		t.Fatalf("expected pending update to be stored")
	}
	if update.SummaryText != "The build finished and all tests passed." {
		t.Fatalf("unexpected stored summary text: %q", update.SummaryText)
	}
}
