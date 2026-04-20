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
