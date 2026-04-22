package db

import (
	"fmt"
	"time"

	"gorm.io/gorm"
)

type migration struct {
	name string
	sql  string
}

func runMigrations(db *gorm.DB, now time.Time) error {
	if err := db.Exec(`
CREATE TABLE IF NOT EXISTS schema_migrations (
  name TEXT PRIMARY KEY,
  applied_at DATETIME NOT NULL
)
`).Error; err != nil {
		return fmt.Errorf("create schema_migrations table: %w", err)
	}

	migrations := []migration{
		{
			name: "2026_04_20_create_conversations",
			sql: `
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
`,
		},
		{
			name: "2026_04_20_create_conversation_updates",
			sql: `
CREATE TABLE IF NOT EXISTS conversation_updates (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  conversation_handle TEXT NOT NULL,
  summary_text TEXT NOT NULL,
  notification_text TEXT NOT NULL,
  raw_update_json TEXT,
  status TEXT NOT NULL,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL,
  consumed_at DATETIME
);
CREATE INDEX IF NOT EXISTS idx_conversation_updates_conversation ON conversation_updates(conversation_id);
CREATE INDEX IF NOT EXISTS idx_conversation_updates_handle ON conversation_updates(conversation_handle);
CREATE INDEX IF NOT EXISTS idx_conversation_updates_status ON conversation_updates(status);
`,
		},
		{
			name: "2026_04_21_add_detail_text_to_conversation_updates",
			sql: `
ALTER TABLE conversation_updates ADD COLUMN detail_text TEXT NOT NULL DEFAULT '';
UPDATE conversation_updates
SET detail_text = summary_text
WHERE detail_text = '';
`,
		},
		{
			name: "2026_04_21_add_preview_text_to_conversations",
			sql: `
ALTER TABLE conversations ADD COLUMN preview_text TEXT NOT NULL DEFAULT '';
UPDATE conversations
SET preview_text = COALESCE((
  SELECT COALESCE(NULLIF(cu.summary_text, ''), NULLIF(cu.detail_text, ''), '')
  FROM conversation_updates cu
  WHERE cu.conversation_id = conversations.id
  ORDER BY cu.updated_at DESC, cu.id DESC
  LIMIT 1
), '')
WHERE preview_text = '';
`,
		},
		{
			name: "2026_04_21_replace_conversation_updates_with_messages",
			sql: `
ALTER TABLE conversation_updates RENAME TO messages;
DROP INDEX IF EXISTS idx_conversation_updates_conversation;
DROP INDEX IF EXISTS idx_conversation_updates_handle;
DROP INDEX IF EXISTS idx_conversation_updates_status;
CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_messages_handle ON messages(conversation_handle);
CREATE INDEX IF NOT EXISTS idx_messages_status ON messages(status);
`,
		},
		{
			name: "2026_04_20_create_conversation_notes",
			sql: `
CREATE TABLE IF NOT EXISTS conversation_notes (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL UNIQUE,
  notes_text TEXT NOT NULL,
  updated_at DATETIME NOT NULL
);
`,
		},
		{
			name: "2026_04_22_create_conversation_inputs",
			sql: `
CREATE TABLE IF NOT EXISTS conversation_inputs (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  user_text TEXT NOT NULL,
  status TEXT NOT NULL,
  dispatch_id TEXT,
  batch_index INTEGER NOT NULL DEFAULT 0,
  error_text TEXT NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL,
  started_at DATETIME,
  finished_at DATETIME
);
CREATE INDEX IF NOT EXISTS idx_conversation_inputs_conversation ON conversation_inputs(conversation_id);
CREATE INDEX IF NOT EXISTS idx_conversation_inputs_status ON conversation_inputs(status);
CREATE INDEX IF NOT EXISTS idx_conversation_inputs_dispatch ON conversation_inputs(dispatch_id);
`,
		},
	}

	for _, migration := range migrations {
		var count int64
		if err := db.Raw(`SELECT COUNT(1) FROM schema_migrations WHERE name = ?`, migration.name).Scan(&count).Error; err != nil {
			return fmt.Errorf("check migration %s: %w", migration.name, err)
		}
		if count > 0 {
			continue
		}

		if err := db.Transaction(func(tx *gorm.DB) error {
			if err := tx.Exec(migration.sql).Error; err != nil {
				return err
			}
			return tx.Exec(`INSERT INTO schema_migrations (name, applied_at) VALUES (?, ?)`, migration.name, now).Error
		}); err != nil {
			return fmt.Errorf("apply migration %s: %w", migration.name, err)
		}
	}

	return nil
}
