package conversations

import (
	"fmt"
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

func (s *Store) UpsertPendingUpdate(update ConversationUpdate) (ConversationUpdate, error) {
	now := time.Now().UTC()
	var existing ConversationUpdate
	err := s.db.Where("conversation_id = ? AND status = ?", update.ConversationID, "pending").First(&existing).Error
	if err != nil && err != gorm.ErrRecordNotFound {
		return ConversationUpdate{}, fmt.Errorf("lookup pending conversation update: %w", err)
	}

	if err == gorm.ErrRecordNotFound {
		update.ID = uuid.NewString()
		update.Status = "pending"
		update.CreatedAt = now
		update.UpdatedAt = now
		if err := s.db.Create(&update).Error; err != nil {
			return ConversationUpdate{}, fmt.Errorf("create pending conversation update: %w", err)
		}
		return update, nil
	}

	existing.SummaryText = update.SummaryText
	existing.NotificationText = update.NotificationText
	existing.RawUpdateJSON = update.RawUpdateJSON
	existing.Status = "pending"
	existing.UpdatedAt = now
	existing.ConsumedAt = nil
	if err := s.db.Save(&existing).Error; err != nil {
		return ConversationUpdate{}, fmt.Errorf("update pending conversation update: %w", err)
	}
	return existing, nil
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
