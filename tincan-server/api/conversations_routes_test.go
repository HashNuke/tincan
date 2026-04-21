package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"tincan-server/conversations"
)

func TestRoutesListConversationsIncludesPreviewAndPendingState(t *testing.T) {
	routes := testRoutes(t)
	store, db := newTestConversationStore(t)
	routes.Conversations = store

	firstUpdatedAt := time.Date(2026, 4, 21, 9, 0, 0, 0, time.UTC)
	secondUpdatedAt := time.Date(2026, 4, 21, 10, 0, 0, 0, time.UTC)

	mustCreateConversation(t, db, conversations.Conversation{
		ID:                 "conv-1",
		DisplayHandle:      "Atlas#1",
		AgentProfileName:   "Atlas",
		ConversationNumber: 1,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/atlas-1",
		Status:             "running",
		CreatedAt:          firstUpdatedAt.Add(-time.Hour),
		UpdatedAt:          firstUpdatedAt,
	})
	mustCreateConversation(t, db, conversations.Conversation{
		ID:                 "conv-2",
		DisplayHandle:      "Atlas#2",
		AgentProfileName:   "Atlas",
		ConversationNumber: 2,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/atlas-2",
		Status:             "idle",
		CreatedAt:          secondUpdatedAt.Add(-time.Hour),
		UpdatedAt:          secondUpdatedAt,
	})
	update, changed, err := store.CreateMessage(conversations.Message{
		ConversationID:     "conv-1",
		ConversationHandle: "Atlas#1",
		SummaryText:        "Finished the routing work.",
		DetailText:         "Finished the routing work and queued the deploy.",
		NotificationText:   "I finished the task.",
		Status:             "pending",
	})
	if err != nil {
		t.Fatalf("create message: %v", err)
	}
	if !changed {
		t.Fatalf("expected create message to report changed")
	}

	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/conversations?page_size=10", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var response conversationsResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if response.NextCursor != "" {
		t.Fatalf("expected no next cursor, got %q", response.NextCursor)
	}
	if len(response.Conversations) != 2 {
		t.Fatalf("expected 2 conversations, got %d", len(response.Conversations))
	}

	first := response.Conversations[0]
	if first.ID != "conv-1" {
		t.Fatalf("expected conv-1 first, got %q", first.ID)
	}
	if first.Handle != "Atlas#1" {
		t.Fatalf("unexpected first handle: %q", first.Handle)
	}
	if first.PreviewText != "Finished the routing work." {
		t.Fatalf("unexpected first preview: %q", first.PreviewText)
	}
	if !first.HasPendingUpdate {
		t.Fatalf("expected first conversation to have pending update")
	}
	if !first.UpdatedAt.Equal(update.UpdatedAt) {
		t.Fatalf("expected first updated_at %s, got %s", update.UpdatedAt, first.UpdatedAt)
	}

	second := response.Conversations[1]
	if second.ID != "conv-2" {
		t.Fatalf("expected conv-2 second, got %q", second.ID)
	}
	if second.PreviewText != "" {
		t.Fatalf("expected empty preview for second conversation, got %q", second.PreviewText)
	}
	if second.HasPendingUpdate {
		t.Fatalf("expected second conversation to have no pending update")
	}
	if !second.UpdatedAt.Equal(secondUpdatedAt) {
		t.Fatalf("expected second updated_at %s, got %s", secondUpdatedAt, second.UpdatedAt)
	}
}

func TestRoutesListConversationsSupportsCursorPagination(t *testing.T) {
	routes := testRoutes(t)
	store, db := newTestConversationStore(t)
	routes.Conversations = store

	firstUpdatedAt := time.Date(2026, 4, 21, 12, 0, 0, 0, time.UTC)
	secondUpdatedAt := time.Date(2026, 4, 21, 11, 0, 0, 0, time.UTC)
	thirdUpdatedAt := time.Date(2026, 4, 21, 10, 0, 0, 0, time.UTC)

	mustCreateConversation(t, db, conversations.Conversation{
		ID:                 "conv-c",
		DisplayHandle:      "Atlas#3",
		AgentProfileName:   "Atlas",
		ConversationNumber: 3,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/atlas-3",
		Status:             "running",
		CreatedAt:          firstUpdatedAt.Add(-time.Hour),
		UpdatedAt:          firstUpdatedAt,
	})
	mustCreateConversation(t, db, conversations.Conversation{
		ID:                 "conv-b",
		DisplayHandle:      "Atlas#2",
		AgentProfileName:   "Atlas",
		ConversationNumber: 2,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/atlas-2",
		Status:             "running",
		CreatedAt:          secondUpdatedAt.Add(-time.Hour),
		UpdatedAt:          secondUpdatedAt,
	})
	mustCreateConversation(t, db, conversations.Conversation{
		ID:                 "conv-a",
		DisplayHandle:      "Atlas#1",
		AgentProfileName:   "Atlas",
		ConversationNumber: 1,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/atlas-1",
		Status:             "running",
		CreatedAt:          thirdUpdatedAt.Add(-time.Hour),
		UpdatedAt:          thirdUpdatedAt,
	})

	mux := http.NewServeMux()
	routes.Register(mux)

	firstPage := httptest.NewRecorder()
	mux.ServeHTTP(firstPage, httptest.NewRequest(http.MethodGet, "/api/v1/conversations?page_size=2", nil))
	if firstPage.Code != http.StatusOK {
		t.Fatalf("expected first page 200, got %d: %s", firstPage.Code, firstPage.Body.String())
	}

	var firstResponse conversationsResponse
	if err := json.Unmarshal(firstPage.Body.Bytes(), &firstResponse); err != nil {
		t.Fatalf("decode first page: %v", err)
	}
	if len(firstResponse.Conversations) != 2 {
		t.Fatalf("expected 2 conversations on first page, got %d", len(firstResponse.Conversations))
	}
	if firstResponse.Conversations[0].ID != "conv-c" || firstResponse.Conversations[1].ID != "conv-b" {
		t.Fatalf("unexpected first page ordering: %#v", firstResponse.Conversations)
	}
	if firstResponse.NextCursor == "" {
		t.Fatalf("expected next cursor on first page")
	}

	secondPage := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/conversations?page_size=2&cursor="+firstResponse.NextCursor, nil)
	mux.ServeHTTP(secondPage, req)
	if secondPage.Code != http.StatusOK {
		t.Fatalf("expected second page 200, got %d: %s", secondPage.Code, secondPage.Body.String())
	}

	var secondResponse conversationsResponse
	if err := json.Unmarshal(secondPage.Body.Bytes(), &secondResponse); err != nil {
		t.Fatalf("decode second page: %v", err)
	}
	if len(secondResponse.Conversations) != 1 {
		t.Fatalf("expected 1 conversation on second page, got %d", len(secondResponse.Conversations))
	}
	if secondResponse.Conversations[0].ID != "conv-a" {
		t.Fatalf("expected conv-a on second page, got %#v", secondResponse.Conversations)
	}
	if secondResponse.NextCursor != "" {
		t.Fatalf("expected empty next cursor on last page, got %q", secondResponse.NextCursor)
	}
}

func TestRoutesListConversationsRejectsInvalidCursor(t *testing.T) {
	routes := testRoutes(t)
	store, _ := newTestConversationStore(t)
	routes.Conversations = store

	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/conversations?cursor=not-base64", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

func TestRoutesListConversationMessagesReturnsNewestFirst(t *testing.T) {
	routes := testRoutes(t)
	store, db := newTestConversationStore(t)
	routes.Conversations = store

	conversationUpdatedAt := time.Date(2026, 4, 21, 10, 0, 0, 0, time.UTC)
	mustCreateConversation(t, db, conversations.Conversation{
		ID:                 "conv-1",
		DisplayHandle:      "Atlas#1",
		AgentProfileName:   "Atlas",
		ConversationNumber: 1,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/atlas-1",
		Status:             "running",
		CreatedAt:          conversationUpdatedAt.Add(-time.Hour),
		UpdatedAt:          conversationUpdatedAt,
		PreviewText:        "Finished the patch.",
	})

	firstCreatedAt := time.Date(2026, 4, 21, 10, 5, 0, 0, time.UTC)
	secondCreatedAt := time.Date(2026, 4, 21, 10, 10, 0, 0, time.UTC)
	mustCreateUpdate(t, db, conversations.Message{
		ID:                 "msg-1",
		ConversationID:     "conv-1",
		ConversationHandle: "Atlas#1",
		SummaryText:        "Started the patch.",
		DetailText:         "Started the patch and updated the tests.",
		NotificationText:   "I have an update.",
		Status:             "consumed",
		CreatedAt:          firstCreatedAt,
		UpdatedAt:          firstCreatedAt,
	})
	mustCreateUpdate(t, db, conversations.Message{
		ID:                 "msg-2",
		ConversationID:     "conv-1",
		ConversationHandle: "Atlas#1",
		SummaryText:        "Finished the patch.",
		DetailText:         "Finished the patch and all tests passed.",
		NotificationText:   "I finished the task.",
		Status:             "pending",
		CreatedAt:          secondCreatedAt,
		UpdatedAt:          secondCreatedAt,
	})

	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/conversations/conv-1/messages?page_size=10", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var response conversationMessagesResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if response.Conversation.ID != "conv-1" {
		t.Fatalf("expected conversation conv-1, got %q", response.Conversation.ID)
	}
	if response.Conversation.Handle != "Atlas#1" {
		t.Fatalf("unexpected conversation handle: %q", response.Conversation.Handle)
	}
	if !response.Conversation.HasPendingUpdate {
		t.Fatalf("expected pending update flag to be true")
	}
	if len(response.Messages) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(response.Messages))
	}
	if response.Messages[0].ID != "msg-2" || response.Messages[1].ID != "msg-1" {
		t.Fatalf("unexpected message ordering: %#v", response.Messages)
	}
	if response.Messages[0].Kind != "agent_update" {
		t.Fatalf("unexpected message kind: %q", response.Messages[0].Kind)
	}
}

func TestRoutesListConversationMessagesSupportsCursorPagination(t *testing.T) {
	routes := testRoutes(t)
	store, db := newTestConversationStore(t)
	routes.Conversations = store

	mustCreateConversation(t, db, conversations.Conversation{
		ID:                 "conv-1",
		DisplayHandle:      "Atlas#1",
		AgentProfileName:   "Atlas",
		ConversationNumber: 1,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/atlas-1",
		Status:             "running",
		CreatedAt:          time.Date(2026, 4, 21, 9, 0, 0, 0, time.UTC),
		UpdatedAt:          time.Date(2026, 4, 21, 10, 0, 0, 0, time.UTC),
	})

	for idx, id := range []string{"msg-3", "msg-2", "msg-1"} {
		createdAt := time.Date(2026, 4, 21, 10, 10-idx, 0, 0, time.UTC)
		mustCreateUpdate(t, db, conversations.Message{
			ID:                 id,
			ConversationID:     "conv-1",
			ConversationHandle: "Atlas#1",
			SummaryText:        id,
			DetailText:         id + " detail",
			NotificationText:   "I have an update.",
			Status:             "pending",
			CreatedAt:          createdAt,
			UpdatedAt:          createdAt,
		})
	}

	mux := http.NewServeMux()
	routes.Register(mux)

	firstPage := httptest.NewRecorder()
	mux.ServeHTTP(firstPage, httptest.NewRequest(http.MethodGet, "/api/v1/conversations/conv-1/messages?page_size=2", nil))
	if firstPage.Code != http.StatusOK {
		t.Fatalf("expected first page 200, got %d: %s", firstPage.Code, firstPage.Body.String())
	}

	var firstResponse conversationMessagesResponse
	if err := json.Unmarshal(firstPage.Body.Bytes(), &firstResponse); err != nil {
		t.Fatalf("decode first page: %v", err)
	}
	if len(firstResponse.Messages) != 2 {
		t.Fatalf("expected 2 messages on first page, got %d", len(firstResponse.Messages))
	}
	if firstResponse.Messages[0].ID != "msg-3" || firstResponse.Messages[1].ID != "msg-2" {
		t.Fatalf("unexpected first page ordering: %#v", firstResponse.Messages)
	}
	if firstResponse.NextCursor == "" {
		t.Fatalf("expected next cursor on first page")
	}

	secondPage := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/conversations/conv-1/messages?page_size=2&cursor="+firstResponse.NextCursor, nil)
	mux.ServeHTTP(secondPage, req)
	if secondPage.Code != http.StatusOK {
		t.Fatalf("expected second page 200, got %d: %s", secondPage.Code, secondPage.Body.String())
	}

	var secondResponse conversationMessagesResponse
	if err := json.Unmarshal(secondPage.Body.Bytes(), &secondResponse); err != nil {
		t.Fatalf("decode second page: %v", err)
	}
	if len(secondResponse.Messages) != 1 {
		t.Fatalf("expected 1 message on second page, got %d", len(secondResponse.Messages))
	}
	if secondResponse.Messages[0].ID != "msg-1" {
		t.Fatalf("expected msg-1 on second page, got %#v", secondResponse.Messages)
	}
	if secondResponse.NextCursor != "" {
		t.Fatalf("expected empty next cursor on last page, got %q", secondResponse.NextCursor)
	}
}

func TestRoutesListConversationMessagesRejectsInvalidCursor(t *testing.T) {
	routes := testRoutes(t)
	store, db := newTestConversationStore(t)
	routes.Conversations = store

	mustCreateConversation(t, db, conversations.Conversation{
		ID:                 "conv-1",
		DisplayHandle:      "Atlas#1",
		AgentProfileName:   "Atlas",
		ConversationNumber: 1,
		AgentBackend:       "opencode",
		WorkingDirectory:   "/tmp/atlas-1",
		Status:             "running",
		CreatedAt:          time.Now().UTC(),
		UpdatedAt:          time.Now().UTC(),
	})

	mux := http.NewServeMux()
	routes.Register(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/conversations/conv-1/messages?cursor=not-base64", nil)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

func newTestConversationStore(t *testing.T) (*conversations.Store, *gorm.DB) {
	t.Helper()

	dbPath := filepath.Join(t.TempDir(), "conversations.sqlite")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite db: %v", err)
	}
	if err := db.AutoMigrate(&conversations.Conversation{}, &conversations.Message{}, &conversations.ConversationNote{}); err != nil {
		t.Fatalf("migrate test db: %v", err)
	}
	return conversations.NewStore(db), db
}

func mustCreateConversation(t *testing.T, db *gorm.DB, conversation conversations.Conversation) {
	t.Helper()
	if err := db.Create(&conversation).Error; err != nil {
		t.Fatalf("create conversation: %v", err)
	}
}

func mustCreateUpdate(t *testing.T, db *gorm.DB, update conversations.Message) {
	t.Helper()
	if err := db.Create(&update).Error; err != nil {
		t.Fatalf("create update: %v", err)
	}
}
