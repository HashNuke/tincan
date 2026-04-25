# CallKit Init Deprecation

Status: DONE

## Problem

`CallKitController` initialized `CXProviderConfiguration` with `init(localizedName:)`, which was deprecated in iOS 14.0. This produced a compiler warning in the iOS target.

## Solution

Updated `CallKitController` to use `CXProviderConfiguration()` instead. The current CallKit API uses the app metadata for provider display naming rather than the deprecated localized-name initializer.
