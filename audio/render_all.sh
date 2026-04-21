#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$ROOT/output"

if ! command -v chuck >/dev/null 2>&1; then
  echo "chuck is not installed or not on PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

for script in "$ROOT"/*.ck; do
  [ -e "$script" ] || continue
  output="$OUTPUT_DIR/$(basename "${script%.ck}.wav")"
  input_name="$(basename "$script")"
  chuck --silent "$script"
  echo "Rendered $input_name as $output"
done
