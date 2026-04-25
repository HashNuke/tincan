# Duplicate Server Listeners

Status: DONE

## Problem

The Mac app normally launches a single bundled `tincan-server` process, but an extra child process with the same executable and command line was observed holding the inherited `4490` listener. This made `lsof` show two `tincan-server` processes listening on the same port, and stopping the tracked parent did not necessarily clear the child listener.

## Root Cause

Killed the running duplicate server processes. A launcher-side cleanup was considered and then reverted because it would mask the root cause.

The duplicate was consistent with a macOS Go fork/exec failure mode: a child process gets stuck before `exec`, so `ps` still shows the parent `tincan-server run ...` command line and `lsof` shows the child's copy of the parent's open listener. The environment contained `__CF_USER_TEXT_ENCODING=0x1F5:0x0:0x0`, which matches known reports of this macOS Go failure mode.

## Solution

Updated `tincan-server` to unset `__CF_USER_TEXT_ENCODING` at process startup before it spawns any children. Also updated `tincan-exec` to unset the same variable before it spawns agent commands, preventing the problematic environment from propagating through the command wrapper.
