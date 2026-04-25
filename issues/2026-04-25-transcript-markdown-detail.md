## Status

DONE

## Problem

Transcript message cards exposed three levels of server output:

- `notificationText` for the tiny immediate update
- `summaryText` for the short summary update
- `detailText` for the full detailed message

The transcript screen was still rendering `detailText` with plain `Text`, so markdown formatting in the detailed message was lost even though the app already had the `MarkdownView` dependency added.

## Solution

Updated the transcript card UI in `TincanRootView.swift`.

- imported the `MarkdownView` module into the SwiftUI root view file
- kept the immediate update and summary update rendered as plain text
- replaced the plain `Text(detailText)` rendering with `MarkdownView(detailText)`
- kept the detailed markdown block as the last section inside each transcript message card

## Notes

Verified the change with a macOS build and then built, installed, and launched the iOS app on the connected phone using `bin/build-and-run ios`.
