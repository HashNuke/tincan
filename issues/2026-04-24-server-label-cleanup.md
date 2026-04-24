# Server settings labels and phone-only current row

Status: DONE

## Problem

The server settings UI used inconsistent terminology across platforms.

- The settings destination was labeled `Connect Phone`, which does not match the screen's purpose.
- The server connection section used `Connect to remote server` instead of the preferred `Connect to server` wording.
- On iPhone, the connect screen showed a `Current` row with the currently connected server even though that extra status row is not needed there.

## Solution

Updated `tincan-swift-app/tincan/TincanRootView.swift` to align the copy and simplify the phone UI.

- Renamed the settings destination title from `Connect Phone` to `Connect to Server`.
- Renamed the server settings page title from `Connect phone` to `Connect to server`.
- Renamed the server connection section label from `Connect to remote server` to `Connect to server` on both Mac and iPhone.
- Removed the iPhone-only `Current` server row while keeping the Mac-specific current connection details intact.
