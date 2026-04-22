package main

import (
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/net/websocket"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"tincan-server/calls"
	"tincan-server/conversations"
	"tincan-server/output"
)

func TestLiveWebSocketSendsSnapshotAndTextEvents(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "conversations.sqlite")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite db: %v", err)
	}
	if err := db.AutoMigrate(&conversations.Conversation{}, &conversations.ConversationInput{}, &conversations.Message{}, &conversations.ConversationNote{}); err != nil {
		t.Fatalf("migrate sqlite db: %v", err)
	}

	store := conversations.NewStore(db)
	updatedAt := time.Date(2026, 4, 21, 10, 0, 0, 0, time.UTC)
	if err := db.Create(&conversations.Conversation{
		ID:                    "conv-1",
		DisplayHandle:         "Atlas#1",
		AgentProfileName:      "Atlas",
		ConversationNumber:    1,
		AgentBackend:          "opencode",
		WorkingDirectory:      "/tmp/atlas-1",
		BackendConversationID: "backend-1",
		Status:                "running",
		CreatedAt:             updatedAt.Add(-time.Hour),
		UpdatedAt:             updatedAt,
	}).Error; err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	callManager := calls.NewManager()
	callManager.RegisterSession("session-1")
	callManager.LinkConversation("session-1", "conv-1", "Atlas#1")

	srv := &server{
		callManager:   callManager,
		conversations: store,
	}
	srv.liveHub = newLiveHub(srv)

	httpServer := httptest.NewServer(srv.liveHub.handler())
	defer httpServer.Close()

	wsURL, err := url.Parse(httpServer.URL)
	if err != nil {
		t.Fatalf("parse server url: %v", err)
	}
	wsURL.Scheme = "ws"

	ws, err := websocket.Dial(wsURL.String(), "", httpServer.URL)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	defer ws.Close()

	var snapshot liveSnapshot
	if err := websocket.JSON.Receive(ws, &snapshot); err != nil {
		t.Fatalf("receive snapshot: %v", err)
	}
	if snapshot.Type != "snapshot" {
		t.Fatalf("unexpected snapshot type: %q", snapshot.Type)
	}
	if !snapshot.HasActiveCall {
		t.Fatalf("expected active call in snapshot")
	}
	if snapshot.ActiveConversationID != "conv-1" {
		t.Fatalf("expected active conversation conv-1, got %q", snapshot.ActiveConversationID)
	}

	if err := srv.liveHub.HandleEvent(output.Event{
		SessionID: "session-1",
		Kind:      output.KindNotification,
		Text:      "I have an update.",
	}); err != nil {
		t.Fatalf("handle live event: %v", err)
	}

	var textEvent liveTextEvent
	if err := websocket.JSON.Receive(ws, &textEvent); err != nil {
		t.Fatalf("receive text event: %v", err)
	}
	if textEvent.Type != "text_event" {
		t.Fatalf("unexpected live event type: %q", textEvent.Type)
	}
	if textEvent.ConversationID != "conv-1" {
		t.Fatalf("expected conversation id conv-1, got %q", textEvent.ConversationID)
	}
	if textEvent.Event.Text != "I have an update." {
		t.Fatalf("unexpected event text: %q", textEvent.Event.Text)
	}
}
