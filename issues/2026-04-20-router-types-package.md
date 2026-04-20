## Status

DONE

## Problem

The router request and response types were still living beside the root router implementation.

That made later package cleanup harder, especially because adapter code also needed those same router types.

## Solution

Moved the shared router request and response types into a dedicated `router` package:

- added `tincan-server/router/types.go`
- moved `UserRouterInput`
- moved `UserRouterResult`
- updated root router code and agent adapters to import the shared types from `tincan-server/router`

## Notes

This is the cleanup step that makes it easier to move more router-related code behind a real package boundary and later split adapter implementations into their own package without depending on root-package router types.
