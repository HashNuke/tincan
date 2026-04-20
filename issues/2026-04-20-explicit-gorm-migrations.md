## Status

DONE

## Problem

While moving conversation persistence to GORM, the first implementation used `AutoMigrate`.

That was not the right fit for this project because schema changes should be intentional and versioned rather than inferred automatically.

## Solution

Replaced `AutoMigrate` with an explicit migration runner in `conversations/service.go`:

- added a `schema_migrations` table
- added named migrations for:
  - `conversations`
  - `conversation_updates`
- migrations are applied transactionally and only once

## Notes

The `conversations` package still uses GORM for data access, but the schema is now created through explicit SQL migrations rather than automatic schema inference.
