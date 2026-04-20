## Status

DONE

## Problem

Database initialization and explicit migration logic had been living inside `conversations/service.go`.

That mixed database bootstrap concerns with conversation-specific persistence operations.

## Solution

Moved the generic database setup into a dedicated `db` package:

- added `tincan-server/db/store.go`
- added `tincan-server/db/migrations.go`
- moved SQLite opening and explicit migration running there
- updated the root server startup to use `db.OpenAndMigrate()`
- simplified `conversations.NewStore(...)` to accept an already-initialized `*gorm.DB`

## Notes

This leaves `conversations/service.go` focused on conversation persistence operations, while the `db` package owns database bootstrap and migration concerns.
