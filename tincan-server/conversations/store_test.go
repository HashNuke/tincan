package conversations

import (
	"path/filepath"
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestStoreCreateMessageAppendsHistory(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "conversations.sqlite")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite db: %v", err)
	}
	if err := db.AutoMigrate(&Conversation{}, &Message{}, &ConversationNote{}); err != nil {
		t.Fatalf("migrate sqlite db: %v", err)
	}

	store := NewStore(db)
	conversation, err := store.CreateConversation(Conversation{
		DisplayHandle:      "emma#1",
		AgentProfileName:   "emma",
		ConversationNumber: 1,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/project",
		Status:             "running",
	})
	if err != nil {
		t.Fatalf("CreateConversation returned error: %v", err)
	}

	first, changed, err := store.CreateMessage(Message{
		ConversationID:     conversation.ID,
		ConversationHandle: conversation.DisplayHandle,
		SummaryText:        "Started the patch.",
		DetailText:         "Started the patch and updated the failing test.",
		NotificationText:   "I have an update.",
		Status:             "pending",
	})
	if err != nil {
		t.Fatalf("CreateMessage first returned error: %v", err)
	}
	if !changed {
		t.Fatalf("expected first message to be created")
	}

	second, changed, err := store.CreateMessage(Message{
		ConversationID:     conversation.ID,
		ConversationHandle: conversation.DisplayHandle,
		SummaryText:        "Finished the patch.",
		DetailText:         "Finished the patch and all tests passed.",
		NotificationText:   "I finished the task.",
		Status:             "pending",
	})
	if err != nil {
		t.Fatalf("CreateMessage second returned error: %v", err)
	}
	if !changed {
		t.Fatalf("expected second message to be created")
	}

	messages, err := store.ListMessagesByConversationID(conversation.ID, 10)
	if err != nil {
		t.Fatalf("ListMessagesByConversationID returned error: %v", err)
	}
	if len(messages) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(messages))
	}
	if messages[0].ID != second.ID || messages[1].ID != first.ID {
		t.Fatalf("expected messages newest first, got %+v", messages)
	}

	if err := store.ConsumeMessage(second.ID); err != nil {
		t.Fatalf("ConsumeMessage returned error: %v", err)
	}

	latestPending, ok, err := store.GetLatestPendingMessageByConversationID(conversation.ID)
	if err != nil {
		t.Fatalf("GetLatestPendingMessageByConversationID returned error: %v", err)
	}
	if !ok {
		t.Fatalf("expected an older pending message to remain after consuming the newest one")
	}
	if latestPending.ID != first.ID {
		t.Fatalf("expected first message to remain pending, got %q", latestPending.ID)
	}

	refetched, err := store.ListMessagesByConversationID(conversation.ID, 10)
	if err != nil {
		t.Fatalf("ListMessagesByConversationID after consume returned error: %v", err)
	}
	if len(refetched) != 2 {
		t.Fatalf("expected consumed message to remain in history, got %d rows", len(refetched))
	}
}

func TestStoreCreateMessageSkipsDuplicateLatestMessage(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "conversations.sqlite")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite db: %v", err)
	}
	if err := db.AutoMigrate(&Conversation{}, &Message{}, &ConversationNote{}); err != nil {
		t.Fatalf("migrate sqlite db: %v", err)
	}

	store := NewStore(db)
	conversation, err := store.CreateConversation(Conversation{
		DisplayHandle:      "emma#2",
		AgentProfileName:   "emma",
		ConversationNumber: 2,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/project",
		Status:             "running",
	})
	if err != nil {
		t.Fatalf("CreateConversation returned error: %v", err)
	}

	first, changed, err := store.CreateMessage(Message{
		ConversationID:     conversation.ID,
		ConversationHandle: conversation.DisplayHandle,
		SummaryText:        "Need approval for the deploy.",
		DetailText:         "Need approval for the deploy to production.",
		NotificationText:   "I need approval.",
		Status:             "pending",
	})
	if err != nil {
		t.Fatalf("CreateMessage first returned error: %v", err)
	}
	if !changed {
		t.Fatalf("expected first message creation to report changed")
	}

	duplicate, changed, err := store.CreateMessage(Message{
		ConversationID:     conversation.ID,
		ConversationHandle: conversation.DisplayHandle,
		SummaryText:        "Need approval for the deploy.",
		DetailText:         "Need approval for the deploy to production.",
		NotificationText:   "I need approval.",
		Status:             "pending",
	})
	if err != nil {
		t.Fatalf("CreateMessage duplicate returned error: %v", err)
	}
	if changed {
		t.Fatalf("expected duplicate latest message to be ignored")
	}
	if duplicate.ID != first.ID {
		t.Fatalf("expected duplicate call to return existing message %q, got %q", first.ID, duplicate.ID)
	}

	messages, err := store.ListMessagesByConversationID(conversation.ID, 10)
	if err != nil {
		t.Fatalf("ListMessagesByConversationID returned error: %v", err)
	}
	if len(messages) != 1 {
		t.Fatalf("expected 1 stored message after duplicate insert, got %d", len(messages))
	}
}
