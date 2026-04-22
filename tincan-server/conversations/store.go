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
WITH pending_updates AS (
  SELECT DISTINCT conversation_id
  FROM messages
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
      WHEN c.last_message_at IS NOT NULL THEN
        CASE
          WHEN c.last_message_at >= c.updated_at THEN c.last_message_at
          ELSE c.updated_at
        END
      ELSE c.updated_at
    END AS updated_at,
    c.preview_text AS preview_text,
    CASE
      WHEN pu.conversation_id IS NOT NULL THEN TRUE
      ELSE FALSE
    END AS has_pending_update
  FROM conversations c
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

func (s *Store) GetConversationByID(id string) (Conversation, bool, error) {
	var conversation Conversation
	err := s.db.Where("id = ?", id).First(&conversation).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return Conversation{}, false, nil
		}
		return Conversation{}, false, fmt.Errorf("get conversation by id: %w", err)
	}
	return conversation, true, nil
}

func (s *Store) GetConversationSummaryByID(id string) (ConversationSummary, bool, error) {
	conversation, ok, err := s.GetConversationByID(id)
	if err != nil || !ok {
		return ConversationSummary{}, ok, err
	}

	hasPendingUpdate := false
	if _, found, err := s.GetLatestPendingMessageByConversationID(id); err != nil {
		return ConversationSummary{}, false, err
	} else if found {
		hasPendingUpdate = true
	}

	updatedAt := conversation.UpdatedAt.UTC()
	if conversation.LastMessageAt != nil && conversation.LastMessageAt.UTC().After(updatedAt) {
		updatedAt = conversation.LastMessageAt.UTC()
	}

	return ConversationSummary{
		ID:               conversation.ID,
		Handle:           conversation.DisplayHandle,
		AgentProfileName: conversation.AgentProfileName,
		AgentBackend:     conversation.AgentBackend,
		WorkingDirectory: conversation.WorkingDirectory,
		Status:           conversation.Status,
		UpdatedAt:        updatedAt,
		PreviewText:      conversation.PreviewText,
		HasPendingUpdate: hasPendingUpdate,
	}, true, nil
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

func (s *Store) GetMostRecentConversationByIDs(conversationIDs []string) (Conversation, bool, error) {
	filteredIDs := make([]string, 0, len(conversationIDs))
	for _, conversationID := range conversationIDs {
		if conversationID != "" {
			filteredIDs = append(filteredIDs, conversationID)
		}
	}
	if len(filteredIDs) == 0 {
		return Conversation{}, false, nil
	}

	var conversation Conversation
	err := s.db.
		Where("id IN ?", filteredIDs).
		Order("updated_at desc").
		First(&conversation).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return Conversation{}, false, nil
		}
		return Conversation{}, false, fmt.Errorf("get most recent conversation by ids: %w", err)
	}
	return conversation, true, nil
}

func (s *Store) BindBackendConversationID(conversationID string, backendConversationID string) (Conversation, bool, error) {
	trimmedBackendConversationID := strings.TrimSpace(backendConversationID)
	if strings.TrimSpace(conversationID) == "" || trimmedBackendConversationID == "" {
		return Conversation{}, false, fmt.Errorf("bind backend conversation id requires conversation id and backend conversation id")
	}

	now := time.Now().UTC()
	var (
		conversation Conversation
		changed      bool
	)
	err := s.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("id = ?", conversationID).First(&conversation).Error; err != nil {
			if err == gorm.ErrRecordNotFound {
				return fmt.Errorf("conversation %q not found", conversationID)
			}
			return fmt.Errorf("lookup conversation for backend bind: %w", err)
		}
		if strings.TrimSpace(conversation.BackendConversationID) == trimmedBackendConversationID {
			return nil
		}
		if strings.TrimSpace(conversation.BackendConversationID) != "" {
			return fmt.Errorf("conversation %q is already bound to backend conversation id %q", conversationID, conversation.BackendConversationID)
		}
		if err := tx.Model(&Conversation{}).
			Where("id = ?", conversationID).
			Updates(map[string]any{
				"backend_conversation_id": trimmedBackendConversationID,
				"updated_at":              now,
			}).Error; err != nil {
			return fmt.Errorf("bind backend conversation id: %w", err)
		}
		conversation.BackendConversationID = trimmedBackendConversationID
		conversation.UpdatedAt = now
		changed = true
		return nil
	})
	if err != nil {
		return Conversation{}, false, err
	}
	return conversation, changed, nil
}

func (s *Store) UpdateConversationStatus(conversationID string, status string) (Conversation, error) {
	now := time.Now().UTC()
	if err := s.db.Model(&Conversation{}).
		Where("id = ?", conversationID).
		Updates(map[string]any{
			"status":     status,
			"updated_at": now,
		}).Error; err != nil {
		return Conversation{}, fmt.Errorf("update conversation status: %w", err)
	}
	conversation, ok, err := s.GetConversationByID(conversationID)
	if err != nil {
		return Conversation{}, err
	}
	if !ok {
		return Conversation{}, fmt.Errorf("conversation %q not found", conversationID)
	}
	return conversation, nil
}

func (s *Store) EnqueueConversationInput(conversationID string, userText string) (ConversationInput, error) {
	now := time.Now().UTC()
	input := ConversationInput{
		ID:             uuid.NewString(),
		ConversationID: conversationID,
		UserText:       strings.TrimSpace(userText),
		Status:         "pending",
		BatchIndex:     0,
		ErrorText:      "",
		CreatedAt:      now,
		UpdatedAt:      now,
	}
	if err := s.db.Create(&input).Error; err != nil {
		return ConversationInput{}, fmt.Errorf("enqueue conversation input: %w", err)
	}
	return input, nil
}

func (s *Store) ListPendingConversationInputs(conversationID string) ([]ConversationInput, error) {
	var inputs []ConversationInput
	if err := s.db.
		Where("conversation_id = ? AND status = ?", conversationID, "pending").
		Order("created_at asc, id asc").
		Find(&inputs).Error; err != nil {
		return nil, fmt.Errorf("list pending conversation inputs: %w", err)
	}
	return inputs, nil
}

func (s *Store) GetRunningConversationInputs(conversationID string) ([]ConversationInput, error) {
	var inputs []ConversationInput
	if err := s.db.
		Where("conversation_id = ? AND status = ?", conversationID, "running").
		Order("batch_index asc, created_at asc, id asc").
		Find(&inputs).Error; err != nil {
		return nil, fmt.Errorf("get running conversation inputs: %w", err)
	}
	return inputs, nil
}

func (s *Store) DrainPendingConversationInputs(conversationID string) ([]ConversationInput, string, error) {
	now := time.Now().UTC()
	dispatchID := uuid.NewString()
	inputs := []ConversationInput{}

	err := s.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.
			Where("conversation_id = ? AND status = ?", conversationID, "pending").
			Order("created_at asc, id asc").
			Find(&inputs).Error; err != nil {
			return fmt.Errorf("load pending conversation inputs: %w", err)
		}
		if len(inputs) == 0 {
			return nil
		}
		for index := range inputs {
			startedAt := now
			updates := map[string]any{
				"status":      "running",
				"dispatch_id": dispatchID,
				"batch_index": index,
				"error_text":  "",
				"updated_at":  now,
				"started_at":  &startedAt,
				"finished_at": nil,
			}
			if err := tx.Model(&ConversationInput{}).
				Where("id = ?", inputs[index].ID).
				Updates(updates).Error; err != nil {
				return fmt.Errorf("mark conversation input running: %w", err)
			}
			inputs[index].Status = "running"
			inputs[index].DispatchID = dispatchID
			inputs[index].BatchIndex = index
			inputs[index].ErrorText = ""
			inputs[index].UpdatedAt = now
			inputs[index].StartedAt = &startedAt
			inputs[index].FinishedAt = nil
		}
		return nil
	})
	if err != nil {
		return nil, "", err
	}
	if len(inputs) == 0 {
		return nil, "", nil
	}
	return inputs, dispatchID, nil
}

func (s *Store) MarkConversationDispatchCompleted(conversationID string, dispatchID string) error {
	now := time.Now().UTC()
	if err := s.db.Model(&ConversationInput{}).
		Where("conversation_id = ? AND dispatch_id = ? AND status = ?", conversationID, dispatchID, "running").
		Updates(map[string]any{
			"status":      "completed",
			"updated_at":  now,
			"finished_at": &now,
		}).Error; err != nil {
		return fmt.Errorf("mark conversation dispatch completed: %w", err)
	}
	return nil
}

func (s *Store) MarkConversationDispatchFailed(conversationID string, dispatchID string, errorText string) error {
	now := time.Now().UTC()
	if err := s.db.Model(&ConversationInput{}).
		Where("conversation_id = ? AND dispatch_id = ? AND status = ?", conversationID, dispatchID, "running").
		Updates(map[string]any{
			"status":      "failed",
			"error_text":  strings.TrimSpace(errorText),
			"updated_at":  now,
			"finished_at": &now,
		}).Error; err != nil {
		return fmt.Errorf("mark conversation dispatch failed: %w", err)
	}
	return nil
}

func (s *Store) CreateMessage(message Message) (Message, bool, error) {
	now := time.Now().UTC()
	previewText := buildPreviewText(message.SummaryText, message.DetailText)

	var (
		result  Message
		changed bool
	)
	err := s.db.Transaction(func(tx *gorm.DB) error {
		var existing Message
		err := tx.Where("conversation_id = ?", message.ConversationID).
			Order("created_at desc, id desc").
			First(&existing).Error
		if err != nil && err != gorm.ErrRecordNotFound {
			return fmt.Errorf("lookup latest conversation message: %w", err)
		}

		if err == nil {
			changed = existing.ConversationHandle != message.ConversationHandle ||
				existing.SummaryText != message.SummaryText ||
				existing.DetailText != message.DetailText ||
				existing.NotificationText != message.NotificationText ||
				existing.RawUpdateJSON != message.RawUpdateJSON ||
				existing.Status != message.Status
			if !changed {
				result = existing
				return nil
			}
		}

		message.ID = uuid.NewString()
		if strings.TrimSpace(message.Status) == "" {
			message.Status = "pending"
		}
		message.CreatedAt = now
		message.UpdatedAt = now
		message.ConsumedAt = nil
		if err := tx.Create(&message).Error; err != nil {
			return fmt.Errorf("create conversation message: %w", err)
		}
		if err := updateConversationSummary(tx, message.ConversationID, previewText, now); err != nil {
			return err
		}
		result = message
		changed = true
		return nil
	})
	if err != nil {
		return Message{}, false, err
	}
	return result, changed, nil
}

func buildPreviewText(summaryText string, detailText string) string {
	trimmedSummary := strings.TrimSpace(summaryText)
	if trimmedSummary != "" {
		return trimmedSummary
	}
	return strings.TrimSpace(detailText)
}

func updateConversationSummary(tx *gorm.DB, conversationID string, previewText string, now time.Time) error {
	if err := tx.Model(&Conversation{}).
		Where("id = ?", conversationID).
		Updates(map[string]any{
			"preview_text":    previewText,
			"updated_at":      now,
			"last_message_at": now,
		}).Error; err != nil {
		return fmt.Errorf("update conversation summary: %w", err)
	}
	return nil
}

func (s *Store) ListMessagesByConversationID(conversationID string, limit int) ([]Message, error) {
	if limit <= 0 {
		limit = 50
	}
	var messages []Message
	if err := s.db.
		Where("conversation_id = ?", conversationID).
		Order("created_at desc, id desc").
		Limit(limit).
		Find(&messages).Error; err != nil {
		return nil, fmt.Errorf("list conversation messages: %w", err)
	}
	return messages, nil
}

func (s *Store) GetMessageByID(id string) (Message, bool, error) {
	var message Message
	err := s.db.Where("id = ?", id).First(&message).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return Message{}, false, nil
		}
		return Message{}, false, fmt.Errorf("get message by id: %w", err)
	}
	return message, true, nil
}

func (s *Store) ListMessageHistory(params ListMessageHistoryParams) (ListMessageHistoryResult, error) {
	pageSize := params.PageSize
	if pageSize <= 0 {
		pageSize = 50
	}

	query := s.db.
		Where("conversation_id = ?", params.ConversationID).
		Order("created_at desc, id desc")
	if params.Cursor != nil {
		cursorCreatedAt := params.Cursor.CreatedAt.UTC()
		query = query.Where(
			"created_at < ? OR (created_at = ? AND id < ?)",
			cursorCreatedAt,
			cursorCreatedAt,
			params.Cursor.ID,
		)
	}

	var rows []Message
	if err := query.Limit(pageSize + 1).Find(&rows).Error; err != nil {
		return ListMessageHistoryResult{}, fmt.Errorf("list message history: %w", err)
	}

	result := ListMessageHistoryResult{
		Messages: make([]MessageSummary, 0, min(len(rows), pageSize)),
	}
	for _, row := range rows {
		result.Messages = append(result.Messages, MessageSummary{
			ID:               row.ID,
			Kind:             "agent_update",
			SummaryText:      row.SummaryText,
			DetailText:       row.DetailText,
			NotificationText: row.NotificationText,
			Status:           row.Status,
			CreatedAt:        row.CreatedAt.UTC(),
			UpdatedAt:        row.UpdatedAt.UTC(),
			ConsumedAt:       row.ConsumedAt,
		})
	}

	if len(result.Messages) <= pageSize {
		return result, nil
	}

	result.Messages = result.Messages[:pageSize]
	last := result.Messages[len(result.Messages)-1]
	result.NextCursor = &MessageHistoryCursor{
		CreatedAt: last.CreatedAt.UTC(),
		ID:        last.ID,
	}
	return result, nil
}

func (s *Store) ListPendingMessages(limit int) ([]Message, error) {
	if limit <= 0 {
		limit = 20
	}
	var messages []Message
	if err := s.db.Where("status = ?", "pending").Order("updated_at desc, id desc").Limit(limit).Find(&messages).Error; err != nil {
		return nil, fmt.Errorf("list pending conversation messages: %w", err)
	}
	return messages, nil
}

func (s *Store) GetLatestPendingMessageByConversationID(conversationID string) (Message, bool, error) {
	var message Message
	err := s.db.
		Where("conversation_id = ? AND status = ?", conversationID, "pending").
		Order("updated_at desc, id desc").
		First(&message).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return Message{}, false, nil
		}
		return Message{}, false, fmt.Errorf("get latest pending conversation message: %w", err)
	}
	return message, true, nil
}

func (s *Store) ListPendingUpdateHandles(limit int) ([]string, error) {
	messages, err := s.ListPendingMessages(limit)
	if err != nil {
		return nil, err
	}

	handles := make([]string, 0, len(messages))
	seen := make(map[string]struct{}, len(messages))
	for _, message := range messages {
		if message.ConversationHandle == "" {
			continue
		}
		if _, ok := seen[message.ConversationHandle]; ok {
			continue
		}
		seen[message.ConversationHandle] = struct{}{}
		handles = append(handles, message.ConversationHandle)
	}
	slices.Sort(handles)
	return handles, nil
}

func (s *Store) ConsumeMessage(id string) error {
	now := time.Now().UTC()
	if err := s.db.Model(&Message{}).
		Where("id = ?", id).
		Updates(map[string]any{"status": "consumed", "consumed_at": &now, "updated_at": now}).Error; err != nil {
		return fmt.Errorf("consume conversation message: %w", err)
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
