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
	PreviewText           string     `gorm:"column:preview_text;not null"`
	LastMessageAt         *time.Time `gorm:"column:last_message_at"`
	EndedAt               *time.Time `gorm:"column:ended_at"`
}

func (Conversation) TableName() string {
	return "conversations"
}

type Message struct {
	ID                 string     `gorm:"primaryKey;type:text"`
	ConversationID     string     `gorm:"column:conversation_id;not null;index:idx_messages_conversation"`
	ConversationHandle string     `gorm:"column:conversation_handle;not null;index:idx_messages_handle"`
	SummaryText        string     `gorm:"column:summary_text;not null"`
	DetailText         string     `gorm:"column:detail_text;not null"`
	NotificationText   string     `gorm:"column:notification_text;not null"`
	RawUpdateJSON      string     `gorm:"column:raw_update_json"`
	Status             string     `gorm:"column:status;not null;index:idx_messages_status"`
	CreatedAt          time.Time  `gorm:"column:created_at;not null"`
	UpdatedAt          time.Time  `gorm:"column:updated_at;not null"`
	ConsumedAt         *time.Time `gorm:"column:consumed_at"`
}

func (Message) TableName() string {
	return "messages"
}

type ConversationNote struct {
	ID             string    `gorm:"primaryKey;type:text"`
	ConversationID string    `gorm:"column:conversation_id;not null;uniqueIndex:idx_conversation_notes_conversation"`
	NotesText      string    `gorm:"column:notes_text;not null"`
	UpdatedAt      time.Time `gorm:"column:updated_at;not null"`
}

func (ConversationNote) TableName() string {
	return "conversation_notes"
}

type ConversationSummary struct {
	ID               string    `json:"id"`
	Handle           string    `json:"handle"`
	AgentProfileName string    `json:"agent_profile_name"`
	AgentBackend     string    `json:"agent_backend"`
	WorkingDirectory string    `json:"working_directory"`
	Status           string    `json:"status"`
	UpdatedAt        time.Time `json:"updated_at"`
	PreviewText      string    `json:"preview_text"`
	HasPendingUpdate bool      `json:"has_pending_update"`
}

type ConversationSummaryCursor struct {
	UpdatedAt time.Time `json:"updated_at"`
	ID        string    `json:"id"`
}

type ListConversationSummariesParams struct {
	Cursor   *ConversationSummaryCursor
	PageSize int
}

type ListConversationSummariesResult struct {
	Conversations []ConversationSummary
	NextCursor    *ConversationSummaryCursor
}

type MessageSummary struct {
	ID               string     `json:"id"`
	Kind             string     `json:"kind"`
	SummaryText      string     `json:"summary_text"`
	DetailText       string     `json:"detail_text"`
	NotificationText string     `json:"notification_text"`
	Status           string     `json:"status"`
	CreatedAt        time.Time  `json:"created_at"`
	UpdatedAt        time.Time  `json:"updated_at"`
	ConsumedAt       *time.Time `json:"consumed_at,omitempty"`
}

type MessageHistoryCursor struct {
	CreatedAt time.Time `json:"created_at"`
	ID        string    `json:"id"`
}

type ListMessageHistoryParams struct {
	ConversationID string
	Cursor         *MessageHistoryCursor
	PageSize       int
}

type ListMessageHistoryResult struct {
	Messages   []MessageSummary
	NextCursor *MessageHistoryCursor
}
