# Stored Grok key could not be cleared from settings

## Status
DONE

## Problem
The Grok API key field shows a masked stored value until the user edits the
field, but the field binding is empty until editing begins. After the previous
clear action was removed, there was no direct UI path to mark an existing key
for deletion.

That left users unable to remove a stored key with the normal settings flow
unless they first typed temporary text into the field.

## Solution
Restored an explicit clear action in the Grok API key settings row.

- Added a `Clear` button next to the API key label when a stored key exists.
- The button marks the key for removal by setting the pending value to an empty
  string, which enables the page Save action.
- Added a regression test covering the save flow for removing an existing stored
  Grok key.

Users can now remove a stored Grok key directly and save that change without
typing a replacement value first.
