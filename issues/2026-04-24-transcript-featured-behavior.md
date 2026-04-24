## Status

DONE

## Problem

There were two home/transcript behavior issues:

1. The transcript screen auto-scrolled to the newest message every time a new message arrived, even if the user had scrolled upward to read earlier messages.
2. When a conversation was shown in the large featured card, that same conversation was removed from the conversations list below.

The transcript should behave like chat UI with newest messages at the bottom, but only auto-scroll when the user is already near the bottom. The featured card should be a highlight, not a replacement for the normal list row.

## Solution

Updated the SwiftUI home and transcript screens.

- kept transcript ordering oldest-to-newest so the newest messages stay at the bottom
- changed transcript auto-scroll to trigger only when a new message arrives and the scroll position is already near the bottom
- kept the initial transcript open behavior that scrolls to the latest message
- removed the filter that excluded the featured conversation from the conversations list

## Notes

This change does not alter how the featured conversation is selected. It only changes how that featured conversation is presented alongside the existing list.
