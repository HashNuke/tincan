package conversations

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

type Store struct {
	db *gorm.DB
}

func NewStore(db *gorm.DB) *Store {
	return &Store{db: db}
}

func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	sqlDB, err := s.db.DB()
	if err != nil {
		return err
	}
	return sqlDB.Close()
}

func (s *Store) NextConversationNumber(agentProfileName string) (int, error) {
	const query = `
SELECT conversation_number, status
FROM conversations
WHERE agent_profile_name = ?
`

	var rows []Conversation
	if err := s.db.Select("conversation_number", "status").Where("agent_profile_name = ?", agentProfileName).Find(&rows).Error; err != nil {
		return 0, fmt.Errorf("query next conversation number: %w", err)
	}
	reserved := map[int]bool{}
	for _, row := range rows {
		if reservesConversationNumber(row.Status) {
			reserved[row.ConversationNumber] = true
		}
	}

	next := 1
	for reserved[next] {
		next++
	}
	return next, nil
}

func (s *Store) CreateConversation(conversation Conversation) (Conversation, error) {
	now := time.Now().UTC()
	conversation.ID = uuid.NewString()
	conversation.CreatedAt = now
	conversation.UpdatedAt = now

	if err := s.db.Create(&conversation).Error; err != nil {
		return Conversation{}, fmt.Errorf("insert conversation: %w", err)
	}

	return conversation, nil
}

func (s *Store) ListConversationSummaries(params ListConversationSummariesParams) (ListConversationSummariesResult, error) {
	pageSize := params.PageSize
	if pageSize <= 0 {
		pageSize = 20
	}

	var cursorUpdatedAt any
	var cursorID any
	if params.Cursor != nil {
		cursorTime := params.Cursor.UpdatedAt.UTC()
		cursorUpdatedAt = cursorTime
		cursorID = params.Cursor.ID
	}

	type conversationSummaryRow struct {
		ID               string `gorm:"column:id"`
		Handle           string `gorm:"column:handle"`
		AgentProfileName string `gorm:"column:agent_profile_name"`
		AgentBackend     string `gorm:"column:agent_backend"`
		WorkingDirectory string `gorm:"column:working_directory"`
		Status           string `gorm:"column:status"`
		UpdatedAt        string `gorm:"column:updated_at"`
		PreviewText      string `gorm:"column:preview_text"`
		HasPendingUpdate bool   `gorm:"column:has_pending_update"`
	}

	const query = `
WITH latest_updates AS (
  SELECT
    cu.conversation_id,
    cu.summary_text,
    cu.detail_text,
    cu.updated_at
  FROM conversation_updates cu
  WHERE cu.id = (
    SELECT cu2.id
    FROM conversation_updates cu2
    WHERE cu2.conversation_id = cu.conversation_id
    ORDER BY cu2.updated_at DESC, cu2.id DESC
    LIMIT 1
  )
),
pending_updates AS (
  SELECT DISTINCT conversation_id
  FROM conversation_updates
  WHERE status = 'pending'
),
conversation_summaries AS (
  SELECT
    c.id,
    c.display_handle AS handle,
    c.agent_profile_name,
    c.agent_backend,
    c.working_directory,
    c.status,
    CASE
      WHEN lu.updated_at IS NOT NULL AND c.last_message_at IS NOT NULL THEN
        CASE
          WHEN lu.updated_at >= c.last_message_at THEN lu.updated_at
          ELSE c.last_message_at
        END
      WHEN lu.updated_at IS NOT NULL THEN
        CASE
          WHEN lu.updated_at >= c.updated_at THEN lu.updated_at
          ELSE c.updated_at
        END
      WHEN c.last_message_at IS NOT NULL THEN
        CASE
          WHEN c.last_message_at >= c.updated_at THEN c.last_message_at
          ELSE c.updated_at
        END
      ELSE c.updated_at
    END AS updated_at,
    COALESCE(NULLIF(lu.summary_text, ''), NULLIF(lu.detail_text, ''), '') AS preview_text,
    CASE
      WHEN pu.conversation_id IS NOT NULL THEN TRUE
      ELSE FALSE
    END AS has_pending_update
  FROM conversations c
  LEFT JOIN latest_updates lu ON lu.conversation_id = c.id
  LEFT JOIN pending_updates pu ON pu.conversation_id = c.id
)
SELECT
  id,
  handle,
  agent_profile_name,
  agent_backend,
  working_directory,
  status,
  updated_at,
  preview_text,
  has_pending_update
FROM conversation_summaries
WHERE (
  ? IS NULL OR
  updated_at < ? OR
  (updated_at = ? AND id < ?)
)
ORDER BY updated_at DESC, id DESC
LIMIT ?
`

	var rows []conversationSummaryRow
	if err := s.db.Raw(query, cursorUpdatedAt, cursorUpdatedAt, cursorUpdatedAt, cursorID, pageSize+1).Scan(&rows).Error; err != nil {
		return ListConversationSummariesResult{}, fmt.Errorf("list conversation summaries: %w", err)
	}

	conversations := make([]ConversationSummary, 0, min(len(rows), pageSize))
	for _, row := range rows {
		updatedAt, err := parseConversationSummaryTime(row.UpdatedAt)
		if err != nil {
			return ListConversationSummariesResult{}, fmt.Errorf("parse conversation summary updated_at %q: %w", row.UpdatedAt, err)
		}
		conversations = append(conversations, ConversationSummary{
			ID:               row.ID,
			Handle:           row.Handle,
			AgentProfileName: row.AgentProfileName,
			AgentBackend:     row.AgentBackend,
			WorkingDirectory: row.WorkingDirectory,
			Status:           row.Status,
			UpdatedAt:        updatedAt,
			PreviewText:      row.PreviewText,
			HasPendingUpdate: row.HasPendingUpdate,
		})
	}

	result := ListConversationSummariesResult{
		Conversations: conversations,
	}
	if len(result.Conversations) <= pageSize {
		return result, nil
	}

	result.Conversations = result.Conversations[:pageSize]
	last := result.Conversations[len(result.Conversations)-1]
	result.NextCursor = &ConversationSummaryCursor{
		UpdatedAt: last.UpdatedAt.UTC(),
		ID:        last.ID,
	}
	return result, nil
}

func parseConversationSummaryTime(raw string) (time.Time, error) {
	layouts := []string{
		time.RFC3339Nano,
		"2006-01-02 15:04:05.999999999-07:00",
		"2006-01-02 15:04:05.999999999Z07:00",
		"2006-01-02 15:04:05-07:00",
		"2006-01-02 15:04:05Z07:00",
		"2006-01-02 15:04:05.999999999",
		"2006-01-02 15:04:05",
	}
	for _, layout := range layouts {
		parsed, err := time.Parse(layout, raw)
		if err == nil {
			return parsed.UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("unsupported time format")
}

func (s *Store) ListConversationHandles() ([]string, error) {
	var conversations []Conversation
	if err := s.db.Select("display_handle").Order("created_at desc").Find(&conversations).Error; err != nil {
		return nil, fmt.Errorf("list conversation handles: %w", err)
	}

	handles := make([]string, 0, len(conversations))
	seen := make(map[string]struct{}, len(conversations))
	for _, conversation := range conversations {
		if conversation.DisplayHandle == "" {
			continue
		}
		if _, ok := seen[conversation.DisplayHandle]; ok {
			continue
		}
		seen[conversation.DisplayHandle] = struct{}{}
		handles = append(handles, conversation.DisplayHandle)
	}
	return handles, nil
}

func (s *Store) GetConversationByBackendConversationID(backendConversationID string) (Conversation, bool, error) {
	var conversation Conversation
	err := s.db.Where("backend_conversation_id = ?", backendConversationID).First(&conversation).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return Conversation{}, false, nil
		}
		return Conversation{}, false, fmt.Errorf("get conversation by backend id: %w", err)
	}
	return conversation, true, nil
}

func (s *Store) GetConversationByHandle(handle string) (Conversation, bool, error) {
	normalizedHandle := normalizeConversationHandle(handle)
	var conversations []Conversation
	if err := s.db.Find(&conversations).Error; err != nil {
		return Conversation{}, false, fmt.Errorf("get conversation by handle: %w", err)
	}
	for _, candidate := range conversations {
		if normalizeConversationHandle(candidate.DisplayHandle) == normalizedHandle {
			return candidate, true, nil
		}
	}
	return Conversation{}, false, nil
}

var conversationHandleNormalizer = regexp.MustCompile(`[^a-z0-9]+`)

func normalizeConversationHandle(handle string) string {
	normalized := strings.ToLower(strings.TrimSpace(handle))
	normalized = strings.ReplaceAll(normalized, "#", "")
	return conversationHandleNormalizer.ReplaceAllString(normalized, "")
}

func (s *Store) GetMostRecentConversationByBackendConversationIDs(backendConversationIDs []string) (Conversation, bool, error) {
	filteredIDs := make([]string, 0, len(backendConversationIDs))
	for _, backendConversationID := range backendConversationIDs {
		if backendConversationID != "" {
			filteredIDs = append(filteredIDs, backendConversationID)
		}
	}
	if len(filteredIDs) == 0 {
		return Conversation{}, false, nil
	}

	var conversation Conversation
	err := s.db.
		Where("backend_conversation_id IN ?", filteredIDs).
		Order("updated_at desc").
		First(&conversation).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return Conversation{}, false, nil
		}
		return Conversation{}, false, fmt.Errorf("get most recent conversation by backend ids: %w", err)
	}
	return conversation, true, nil
}

func (s *Store) UpsertPendingUpdate(update ConversationUpdate) (ConversationUpdate, bool, error) {
	now := time.Now().UTC()
	var existing ConversationUpdate
	err := s.db.Where("conversation_id = ? AND status = ?", update.ConversationID, "pending").First(&existing).Error
	if err != nil && err != gorm.ErrRecordNotFound {
		return ConversationUpdate{}, false, fmt.Errorf("lookup pending conversation update: %w", err)
	}

	if err == gorm.ErrRecordNotFound {
		update.ID = uuid.NewString()
		update.Status = "pending"
		update.CreatedAt = now
		update.UpdatedAt = now
		if err := s.db.Create(&update).Error; err != nil {
			return ConversationUpdate{}, false, fmt.Errorf("create pending conversation update: %w", err)
		}
		return update, true, nil
	}

	changed := existing.SummaryText != update.SummaryText ||
		existing.DetailText != update.DetailText ||
		existing.NotificationText != update.NotificationText ||
		existing.RawUpdateJSON != update.RawUpdateJSON ||
		existing.Status != "pending" ||
		existing.ConsumedAt != nil
	if !changed {
		return existing, false, nil
	}

	existing.SummaryText = update.SummaryText
	existing.DetailText = update.DetailText
	existing.NotificationText = update.NotificationText
	existing.RawUpdateJSON = update.RawUpdateJSON
	existing.Status = "pending"
	existing.UpdatedAt = now
	existing.ConsumedAt = nil
	if err := s.db.Save(&existing).Error; err != nil {
		return ConversationUpdate{}, false, fmt.Errorf("update pending conversation update: %w", err)
	}
	return existing, true, nil
}

func (s *Store) ListPendingUpdates(limit int) ([]ConversationUpdate, error) {
	if limit <= 0 {
		limit = 20
	}
	var updates []ConversationUpdate
	if err := s.db.Where("status = ?", "pending").Order("updated_at desc").Limit(limit).Find(&updates).Error; err != nil {
		return nil, fmt.Errorf("list pending conversation updates: %w", err)
	}
	return updates, nil
}

func (s *Store) GetLatestPendingUpdateByConversationID(conversationID string) (ConversationUpdate, bool, error) {
	var update ConversationUpdate
	err := s.db.
		Where("conversation_id = ? AND status = ?", conversationID, "pending").
		Order("updated_at desc").
		First(&update).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return ConversationUpdate{}, false, nil
		}
		return ConversationUpdate{}, false, fmt.Errorf("get latest pending conversation update: %w", err)
	}
	return update, true, nil
}

func (s *Store) ListPendingUpdateHandles(limit int) ([]string, error) {
	updates, err := s.ListPendingUpdates(limit)
	if err != nil {
		return nil, err
	}

	handles := make([]string, 0, len(updates))
	seen := make(map[string]struct{}, len(updates))
	for _, update := range updates {
		if update.ConversationHandle == "" {
			continue
		}
		if _, ok := seen[update.ConversationHandle]; ok {
			continue
		}
		seen[update.ConversationHandle] = struct{}{}
		handles = append(handles, update.ConversationHandle)
	}
	slices.Sort(handles)
	return handles, nil
}

func (s *Store) ConsumeUpdate(id string) error {
	now := time.Now().UTC()
	if err := s.db.Model(&ConversationUpdate{}).
		Where("id = ?", id).
		Updates(map[string]any{"status": "consumed", "consumed_at": &now, "updated_at": now}).Error; err != nil {
		return fmt.Errorf("consume conversation update: %w", err)
	}
	return nil
}

func (s *Store) GetConversationNotes(conversationID string) (ConversationNote, bool, error) {
	var note ConversationNote
	err := s.db.Where("conversation_id = ?", conversationID).First(&note).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return ConversationNote{}, false, nil
		}
		return ConversationNote{}, false, fmt.Errorf("get conversation note: %w", err)
	}
	return note, true, nil
}

func (s *Store) UpsertConversationNotes(conversationID string, notesText string) (ConversationNote, error) {
	now := time.Now().UTC()
	var existing ConversationNote
	err := s.db.Where("conversation_id = ?", conversationID).First(&existing).Error
	if err != nil && err != gorm.ErrRecordNotFound {
		return ConversationNote{}, fmt.Errorf("lookup conversation note: %w", err)
	}
	if err == gorm.ErrRecordNotFound {
		note := ConversationNote{
			ID:             uuid.NewString(),
			ConversationID: conversationID,
			NotesText:      notesText,
			UpdatedAt:      now,
		}
		if err := s.db.Create(&note).Error; err != nil {
			return ConversationNote{}, fmt.Errorf("create conversation note: %w", err)
		}
		return note, nil
	}
	existing.NotesText = notesText
	existing.UpdatedAt = now
	if err := s.db.Save(&existing).Error; err != nil {
		return ConversationNote{}, fmt.Errorf("update conversation note: %w", err)
	}
	return existing, nil
}

func reservesConversationNumber(status string) bool {
	switch status {
	case "starting", "running", "busy", "retry", "failed", "aborted":
		return true
	default:
		return false
	}
}
