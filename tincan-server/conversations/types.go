package conversations

import (
	"database/sql"
	"time"
)

type Conversation struct {
	ID                    string
	DisplayHandle         string
	AgentProfileName      string
	ConversationNumber    int
	AgentBackend          string
	WorkingDirectory      string
	BackendConversationID string
	Status                string
	CreatedAt             time.Time
	UpdatedAt             time.Time
	LastMessageAt         sql.NullTime
	EndedAt               sql.NullTime
}
