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

func reservesConversationNumber(status string) bool {
	switch status {
	case "starting", "running", "busy", "retry", "failed", "aborted":
		return true
	default:
		return false
	}
}
