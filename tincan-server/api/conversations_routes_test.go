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
	latestUpdateAt := time.Date(2026, 4, 21, 11, 0, 0, 0, time.UTC)

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
	mustCreateUpdate(t, db, conversations.ConversationUpdate{
		ID:                 "update-1",
		ConversationID:     "conv-1",
		ConversationHandle: "Atlas#1",
		SummaryText:        "Finished the routing work.",
		DetailText:         "Finished the routing work and queued the deploy.",
		NotificationText:   "I finished the task.",
		Status:             "pending",
		CreatedAt:          latestUpdateAt,
		UpdatedAt:          latestUpdateAt,
	})

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
	if !first.UpdatedAt.Equal(latestUpdateAt) {
		t.Fatalf("expected first updated_at %s, got %s", latestUpdateAt, first.UpdatedAt)
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

func newTestConversationStore(t *testing.T) (*conversations.Store, *gorm.DB) {
	t.Helper()

	dbPath := filepath.Join(t.TempDir(), "conversations.sqlite")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite db: %v", err)
	}
	if err := db.AutoMigrate(&conversations.Conversation{}, &conversations.ConversationUpdate{}, &conversations.ConversationNote{}); err != nil {
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

func mustCreateUpdate(t *testing.T, db *gorm.DB, update conversations.ConversationUpdate) {
	t.Helper()
	if err := db.Create(&update).Error; err != nil {
		t.Fatalf("create update: %v", err)
	}
}
