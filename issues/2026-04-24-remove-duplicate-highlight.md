## Status

DONE

## Problem

The home screen had two separate live-update surfaces for the same conversation activity:

- a featured conversation card
- a separate amber highlighted update card

When live events arrived, both could appear on screen at the same time. That duplicated the same conversation state in two different UI treatments and made the home feed feel noisy and inconsistent.

## Solution

Removed the separate highlighted update card path from the SwiftUI app.

- deleted the `highlightedLiveUpdate` state from `TincanWorkspaceStore`
- stopped converting live `conversation_message_created` and `text_event` payloads into a separate highlighted card model
- removed `TincanHighlightedUpdateCard` from `TincanRootView`
- removed the home-screen rendering path that injected the amber card above the conversation feed

The home screen now relies on the existing conversation surfaces instead of showing a second live-update card.

## Notes

This change only removes the duplicate amber card. It does not change the existing featured-card selection logic or transcript scrolling behavior.
