#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v chuck >/dev/null 2>&1; then
  echo "chuck is not installed or not on PATH" >&2
  exit 1
fi

for script in "$ROOT"/*.ck; do
  [ -e "$script" ] || continue
  echo "rendering $(basename "$script")"
  chuck --silent "$script"
done
