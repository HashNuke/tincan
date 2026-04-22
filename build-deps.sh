#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_ROOT="$SCRIPT_DIR"
readonly INFERENCE_DIR="$PROJECT_ROOT/tincan-inference-macos"
readonly SERVER_DIR="$PROJECT_ROOT/tincan-server"
readonly APP_RUNTIME_DIR_DEFAULT="$PROJECT_ROOT/tincan-swift-app/BundledRuntime"

readonly STT_MODEL_REPO_DEFAULT="FluidInference/parakeet-tdt-0.6b-v3-coreml"
readonly STT_MODEL_REVISION_DEFAULT="775be920d492d20e9e522ee0a969414fd6e6e0f7"
readonly STT_MODEL_DIRNAME_DEFAULT="parakeet-tdt-0.6b-v3-coreml"

readonly TTS_MODEL_REPO_DEFAULT="mlx-community/kitten-tts-mini-0.8"
readonly TTS_MODEL_REVISION_DEFAULT="a22cce835c4af60bf9a50779124cf8cc34b0c36e"
readonly TTS_MODEL_DIRNAME_DEFAULT="kitten-tts-mini-0.8"

readonly KITTEN_G2P_REPO_DEFAULT="beshkenadze/kitten-tts-g2p"
readonly KITTEN_G2P_REVISION_DEFAULT="9c692b92682d959d9013a9cfe6a49541997add18"
readonly KITTEN_G2P_DIRNAME_DEFAULT="kitten-tts-g2p"
readonly KITTEN_G2P_DEPENDENCIES_DIRNAME_DEFAULT="_dependencies"
readonly -a KITTEN_G2P_REQUIRED_FILES_DEFAULT=(
  "us_gold.json"
  "us_silver.json"
  "us_bart_config.json"
  "us_bart.safetensors"
)

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--runtime-dir <path>] [--skip-model-downloads] [--force-model-downloads]

Builds and stages the bundled macOS runtime for tincan-swift-app.

Output layout:
  BundledRuntime/
    tincan-server
    tincan-inference-macos
    models/
      ${STT_MODEL_DIRNAME_DEFAULT}/
      ${TTS_MODEL_DIRNAME_DEFAULT}/
      _dependencies/kitten-tts-g2p/

Defaults:
  --runtime-dir  $APP_RUNTIME_DIR_DEFAULT
EOF
}

log() {
  printf '[build-deps.sh] %s\n' "$*"
}

fail() {
  printf '[build-deps.sh] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

resolve_path() {
  local path="$1"

  if [[ "$path" == "~" ]]; then
    path="$HOME"
  elif [[ "$path" == "~/"* ]]; then
    path="$HOME/${path#"~/"}"
  elif [[ "$path" != /* ]]; then
    path="$PROJECT_ROOT/$path"
  fi

  mkdir -p "$path"
  (
    cd "$path"
    pwd -P
  )
}

is_parakeet_model_ready() {
  local model_dir="$1"
  [[ -d "$model_dir" ]] || return 1
  [[ -d "$model_dir/Preprocessor.mlmodelc" ]] || return 1
  [[ -d "$model_dir/Encoder.mlmodelc" ]] || return 1
  [[ -d "$model_dir/Decoder.mlmodelc" ]] || return 1
  [[ -d "$model_dir/JointDecision.mlmodelc" ]] || return 1
  [[ -f "$model_dir/parakeet_vocab.json" ]] || return 1
}

is_kitten_model_ready() {
  local model_dir="$1"
  [[ -d "$model_dir" ]] || return 1
  [[ -f "$model_dir/config.json" ]] || return 1
  [[ -f "$model_dir/voices.safetensors" ]] || return 1

  find "$model_dir" -maxdepth 1 -type f -name '*.safetensors' ! -name 'voices.safetensors' | grep -q .
}

download_hf_snapshot() {
  local repo_id="$1"
  local revision="$2"
  local destination_dir="$3"

  require_command uvx

  uvx --from huggingface_hub hf download \
    "$repo_id" \
    --revision "$revision" \
    --local-dir "$destination_dir" \
    --type model \
    --max-workers 8 \
    --format human

  rm -rf "$destination_dir/.cache"
}

download_hf_files() {
  local repo_id="$1"
  local revision="$2"
  local destination_dir="$3"
  shift 3

  require_command uvx

  uvx --from huggingface_hub hf download \
    "$repo_id" \
    "$@" \
    --revision "$revision" \
    --local-dir "$destination_dir" \
    --type model \
    --max-workers 8 \
    --format human

  rm -rf "$destination_dir/.cache"
}

ensure_parakeet_model() {
  local models_dir="$1"
  local destination_dir="$models_dir/${STT_MODEL_DIRNAME:-$STT_MODEL_DIRNAME_DEFAULT}"

  if [[ "${FORCE_MODEL_DOWNLOADS}" == "1" ]]; then
    rm -rf "$destination_dir"
  fi

  if is_parakeet_model_ready "$destination_dir"; then
    log "Parakeet model already staged at $destination_dir"
    return
  fi

  log "Downloading Parakeet model to $destination_dir"
  rm -rf "$destination_dir"
  mkdir -p "$destination_dir"
  download_hf_snapshot \
    "${STT_MODEL_REPO:-$STT_MODEL_REPO_DEFAULT}" \
    "${STT_MODEL_REVISION:-$STT_MODEL_REVISION_DEFAULT}" \
    "$destination_dir"

  is_parakeet_model_ready "$destination_dir" || fail "Parakeet model download incomplete: $destination_dir"
}

ensure_kitten_model() {
  local models_dir="$1"
  local destination_dir="$models_dir/${TTS_MODEL_DIRNAME:-$TTS_MODEL_DIRNAME_DEFAULT}"

  if [[ "${FORCE_MODEL_DOWNLOADS}" == "1" ]]; then
    rm -rf "$destination_dir"
  fi

  if is_kitten_model_ready "$destination_dir"; then
    log "Kitten TTS model already staged at $destination_dir"
    return
  fi

  log "Downloading Kitten TTS model to $destination_dir"
  rm -rf "$destination_dir"
  mkdir -p "$destination_dir"
  download_hf_snapshot \
    "${TTS_MODEL_REPO:-$TTS_MODEL_REPO_DEFAULT}" \
    "${TTS_MODEL_REVISION:-$TTS_MODEL_REVISION_DEFAULT}" \
    "$destination_dir"

  is_kitten_model_ready "$destination_dir" || fail "Kitten TTS model download incomplete: $destination_dir"
}

is_kitten_g2p_ready() {
  local resource_dir="$1"
  local filename

  [[ -d "$resource_dir" ]] || return 1

  for filename in "${KITTEN_G2P_REQUIRED_FILES_DEFAULT[@]}"; do
    [[ -f "$resource_dir/$filename" ]] || return 1
  done
}

ensure_kitten_g2p_resources() {
  local models_dir="$1"
  local dependencies_dir="$models_dir/${KITTEN_G2P_DEPENDENCIES_DIRNAME_DEFAULT}"
  local destination_dir="$dependencies_dir/${KITTEN_G2P_DIRNAME_DEFAULT}"

  if [[ "${FORCE_MODEL_DOWNLOADS}" == "1" ]]; then
    rm -rf "$destination_dir"
  fi

  if is_kitten_g2p_ready "$destination_dir"; then
    log "Kitten G2P resources already staged at $destination_dir"
    return
  fi

  log "Downloading Kitten G2P resources to $destination_dir"
  rm -rf "$destination_dir"
  mkdir -p "$destination_dir"
  download_hf_files \
    "${KITTEN_G2P_REPO:-$KITTEN_G2P_REPO_DEFAULT}" \
    "${KITTEN_G2P_REVISION:-$KITTEN_G2P_REVISION_DEFAULT}" \
    "$destination_dir" \
    "${KITTEN_G2P_REQUIRED_FILES_DEFAULT[@]}"

  is_kitten_g2p_ready "$destination_dir" || fail "Kitten G2P download incomplete: $destination_dir"
}

stage_manifest() {
  local runtime_dir="$1"
  local manifest_path="$runtime_dir/manifest.json"
  local stt_model_dirname="${STT_MODEL_DIRNAME:-$STT_MODEL_DIRNAME_DEFAULT}"
  local tts_model_dirname="${TTS_MODEL_DIRNAME:-$TTS_MODEL_DIRNAME_DEFAULT}"

  cat > "$manifest_path" <<EOF
{
  "models_dir": "models",
  "inference_executable": "tincan-inference-macos",
  "server_executable": "tincan-server",
  "stt_model": "$stt_model_dirname",
  "tts_model": "$tts_model_dirname"
}
EOF
}

build_inference() {
  local destination_bin="$1"

  require_command swift

  log "Building tincan-inference-macos"
  swift build --package-path "$INFERENCE_DIR" -c release --product tincan-inference-macos
  install -m 0755 "$INFERENCE_DIR/.build/release/tincan-inference-macos" "$destination_bin"
}

build_server() {
  local destination_bin="$1"

  require_command go

  log "Building tincan-server"
  (
    cd "$SERVER_DIR"
    go build -trimpath -o "$destination_bin" .
  )
}

main() {
  local runtime_dir="$APP_RUNTIME_DIR_DEFAULT"
  local skip_model_downloads=0

  FORCE_MODEL_DOWNLOADS=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runtime-dir)
        [[ $# -ge 2 ]] || fail "missing value for --runtime-dir"
        runtime_dir="$2"
        shift 2
        ;;
      --skip-model-downloads)
        skip_model_downloads=1
        shift
        ;;
      --force-model-downloads)
        FORCE_MODEL_DOWNLOADS=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done

  runtime_dir="$(resolve_path "$runtime_dir")"

  local models_dir="$runtime_dir/models"

  mkdir -p "$models_dir"

  if [[ "$skip_model_downloads" == "0" ]]; then
    ensure_parakeet_model "$models_dir"
    ensure_kitten_model "$models_dir"
    ensure_kitten_g2p_resources "$models_dir"
  else
    log "Skipping model downloads"
  fi

  build_inference "$runtime_dir/tincan-inference-macos"
  build_server "$runtime_dir/tincan-server"
  stage_manifest "$runtime_dir"

  log "Bundled runtime staged at $runtime_dir"
}

main "$@"
