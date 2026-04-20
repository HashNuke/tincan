package conversations

import "time"

type Conversation struct {
	ID                    string     `gorm:"primaryKey;type:text"`
	DisplayHandle         string     `gorm:"column:display_handle;not null"`
	AgentProfileName      string     `gorm:"column:agent_profile_name;not null;index:idx_conversations_profile"`
	ConversationNumber    int        `gorm:"column:conversation_number;not null"`
	AgentBackend          string     `gorm:"column:agent_backend;not null"`
	WorkingDirectory      string     `gorm:"column:working_directory;not null"`
	BackendConversationID string     `gorm:"column:backend_conversation_id;index:idx_conversations_backend_id"`
	Status                string     `gorm:"column:status;not null"`
	CreatedAt             time.Time  `gorm:"column:created_at;not null"`
	UpdatedAt             time.Time  `gorm:"column:updated_at;not null"`
	LastMessageAt         *time.Time `gorm:"column:last_message_at"`
	EndedAt               *time.Time `gorm:"column:ended_at"`
}

func (Conversation) TableName() string {
	return "conversations"
}

type ConversationUpdate struct {
	ID                 string     `gorm:"primaryKey;type:text"`
	ConversationID     string     `gorm:"column:conversation_id;not null;index:idx_conversation_updates_conversation"`
	ConversationHandle string     `gorm:"column:conversation_handle;not null;index:idx_conversation_updates_handle"`
	SummaryText        string     `gorm:"column:summary_text;not null"`
	NotificationText   string     `gorm:"column:notification_text;not null"`
	RawUpdateJSON      string     `gorm:"column:raw_update_json"`
	Status             string     `gorm:"column:status;not null;index:idx_conversation_updates_status"`
	CreatedAt          time.Time  `gorm:"column:created_at;not null"`
	UpdatedAt          time.Time  `gorm:"column:updated_at;not null"`
	ConsumedAt         *time.Time `gorm:"column:consumed_at"`
}

func (ConversationUpdate) TableName() string {
	return "conversation_updates"
}
