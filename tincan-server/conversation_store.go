package main

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/google/uuid"

	_ "modernc.org/sqlite"
)

type ConversationStore struct {
	db *sql.DB
}

type Conversation struct {
	ID                   string
	DisplayHandle        string
	AgentProfileName     string
	ConversationNumber   int
	AgentBackend         string
	WorkingDirectory     string
	BackendConversationID string
	Status               string
	CreatedAt            time.Time
	UpdatedAt            time.Time
	LastMessageAt        sql.NullTime
	EndedAt              sql.NullTime
}

func NewConversationStore() (*ConversationStore, error) {
	dataDir := filepath.Join("data")
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}

	dbPath := filepath.Join(dataDir, "tincan.sqlite")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("open sqlite db: %w", err)
	}

	store := &ConversationStore{db: db}
	if err := store.initSchema(); err != nil {
		_ = db.Close()
		return nil, err
	}

	return store, nil
}

func (s *ConversationStore) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *ConversationStore) initSchema() error {
	const schema = `
CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY,
  display_handle TEXT NOT NULL,
  agent_profile_name TEXT NOT NULL,
  conversation_number INTEGER NOT NULL,
  agent_backend TEXT NOT NULL,
  working_directory TEXT NOT NULL,
  backend_conversation_id TEXT,
  status TEXT NOT NULL,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL,
  last_message_at DATETIME,
  ended_at DATETIME
);

CREATE INDEX IF NOT EXISTS idx_conversations_profile ON conversations(agent_profile_name);
CREATE INDEX IF NOT EXISTS idx_conversations_backend_id ON conversations(backend_conversation_id);
`

	if _, err := s.db.Exec(schema); err != nil {
		return fmt.Errorf("init conversation schema: %w", err)
	}
	return nil
}

func (s *ConversationStore) NextConversationNumber(agentProfileName string) (int, error) {
	const query = `
SELECT conversation_number, status
FROM conversations
WHERE agent_profile_name = ?
`

	rows, err := s.db.Query(query, agentProfileName)
	if err != nil {
		return 0, fmt.Errorf("query next conversation number: %w", err)
	}
	defer rows.Close()

	reserved := map[int]bool{}
	for rows.Next() {
		var conversationNumber int
		var status string
		if err := rows.Scan(&conversationNumber, &status); err != nil {
			return 0, fmt.Errorf("scan conversation row: %w", err)
		}
		if reservesConversationNumber(status) {
			reserved[conversationNumber] = true
		}
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("iterate conversation rows: %w", err)
	}

	next := 1
	for reserved[next] {
		next++
	}
	return next, nil
}

func (s *ConversationStore) CreateConversation(conversation Conversation) (Conversation, error) {
	now := time.Now().UTC()
	conversation.ID = uuid.NewString()
	conversation.CreatedAt = now
	conversation.UpdatedAt = now

	const query = `
INSERT INTO conversations (
  id,
  display_handle,
  agent_profile_name,
  conversation_number,
  agent_backend,
  working_directory,
  backend_conversation_id,
  status,
  created_at,
  updated_at,
  last_message_at,
  ended_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
`

	_, err := s.db.Exec(
		query,
		conversation.ID,
		conversation.DisplayHandle,
		conversation.AgentProfileName,
		conversation.ConversationNumber,
		conversation.AgentBackend,
		conversation.WorkingDirectory,
		conversation.BackendConversationID,
		conversation.Status,
		conversation.CreatedAt,
		conversation.UpdatedAt,
		conversation.LastMessageAt,
		conversation.EndedAt,
	)
	if err != nil {
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
