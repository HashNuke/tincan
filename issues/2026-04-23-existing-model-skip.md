Status: DONE

# Existing model directories should skip downloads

## Problem

`build-deps.sh` only skipped model and G2P downloads when each destination directory passed a full readiness check.
If a model directory already existed but was incomplete or intentionally pre-staged by another process, the script deleted that directory and downloaded it again.

That made the default behavior too aggressive for local development, where the preferred behavior is to compile the binaries we need and leave any existing staged model content alone unless a forced refresh is explicitly requested.

## Solution

Updated `build-deps.sh` so the default behavior now treats any existing staged model or G2P destination directory as sufficient to skip downloading.

The script now:

- skips Parakeet download when its destination directory already exists
- skips Kitten TTS download when its destination directory already exists
- skips Kitten G2P resource download when its destination directory already exists
- still supports `--force-model-downloads` to delete and re-download those directories when needed

## Result

Running `build-deps.sh` now defaults to preserving existing model directories and only building the runtime binaries and manifest unless model directories are missing or forced to refresh.
