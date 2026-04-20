package db

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func OpenAndMigrate() (*gorm.DB, error) {
	dataDir := filepath.Join("data")
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}

	dbPath := filepath.Join(dataDir, "tincan.sqlite")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		return nil, fmt.Errorf("open sqlite db: %w", err)
	}

	if err := runMigrations(db, time.Now().UTC()); err != nil {
		return nil, err
	}

	return db, nil
}
