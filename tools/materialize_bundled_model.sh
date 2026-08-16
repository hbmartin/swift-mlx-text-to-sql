#!/bin/zsh
set -euo pipefail

UV_BIN="$(command -v uv || true)"
if [[ -z "$UV_BIN" && -x "$HOME/.local/bin/uv" ]]; then
  UV_BIN="$HOME/.local/bin/uv"
fi
if [[ -z "$UV_BIN" ]]; then
  echo "error: uv is required to materialize the SQL model. Install uv and rebuild."
  exit 1
fi

RESOURCE_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
MODEL_DIR="$RESOURCE_DIR/SQLModel"
MANIFEST_DESTINATION="$RESOURCE_DIR/model-manifest.json"
RECEIPT_DESTINATION="$RESOURCE_DIR/production-model-receipt.json"
PROCESSED_INFO_PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
MODELS_CACHE="${CREG_MODELS_DIR:-$SRCROOT/models}"
DEBUG_FUSED_CACHE="${CREG_DEBUG_FUSED_MODELS_DIR:-$MODELS_CACHE/debug-fused}"
CANDIDATE_SELECTOR="${CREG_CANDIDATE_TRAINING_RUN:-}"
CONTRACT_PATH="$SRCROOT/model-runtime-contract.json"

SOURCE_REVISION="$(git -C "$SRCROOT" rev-parse HEAD)"
if [[ ${#SOURCE_REVISION} -ne 40 || "$SOURCE_REVISION" == *[^0-9a-f]* ]]; then
  echo "error: unable to resolve a full Git source revision for the app bundle."
  exit 1
fi
if [[ -n "$(git -C "$SRCROOT" status --porcelain=v1 --untracked-files=all --ignore-submodules=none)" ]]; then
  SOURCE_DIRTY=true
else
  SOURCE_DIRTY=false
fi
cd "$SRCROOT/fine-tuning"
CONTRACT_VERSION="$(
  "$UV_BIN" run --frozen python -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["current_version"])' \
    "$CONTRACT_PATH"
)"

if [[ ! -f "$PROCESSED_INFO_PLIST" ]]; then
  echo "error: processed Info.plist is missing at $PROCESSED_INFO_PLIST"
  exit 1
fi
set_plist_value() {
  local key="$1"
  local type="$2"
  local value="$3"
  if ! /usr/libexec/PlistBuddy -c "Set :$key $value" "$PROCESSED_INFO_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$PROCESSED_INFO_PLIST"
  fi
}
set_plist_value CREGModelRuntimeContractVersion integer "$CONTRACT_VERSION"
set_plist_value CREGSourceRevision string "$SOURCE_REVISION"
set_plist_value CREGSourceDirty bool "$SOURCE_DIRTY"

mkdir -p "$RESOURCE_DIR"
"$UV_BIN" run --frozen python tools/stamp_bundle_manifest.py \
  --source "$SRCROOT/model-manifest.json" \
  --destination "$MANIFEST_DESTINATION" \
  --contract "$CONTRACT_PATH" \
  --source-revision "$SOURCE_REVISION" \
  --source-dirty "$SOURCE_DIRTY"

if [[ "$CONFIGURATION" == "Debug" || "$CONFIGURATION" == "Beta" ]]; then
  if [[ -n "$CANDIDATE_SELECTOR" ]]; then
    CANDIDATE_ARGS=(
      --training-runs-dir "$SRCROOT/eval/training-runs"
      --model-manifest "$MANIFEST_DESTINATION"
      --models-dir "$MODELS_CACHE"
      --fused-cache "$DEBUG_FUSED_CACHE"
      --destination "$MODEL_DIR"
      --manifest-destination "$MANIFEST_DESTINATION"
      --receipt-destination "$RECEIPT_DESTINATION"
    )
    if [[ "$CANDIDATE_SELECTOR" == "latest-local-v3" ]]; then
      CANDIDATE_ARGS+=(--latest-local-v3)
    else
      CANDIDATE_ARGS+=(--training-run "$CANDIDATE_SELECTOR")
    fi
    echo "warning: $CONFIGURATION is bundling a local candidate without requiring a W&B receipt."
    "$UV_BIN" run --frozen python tools/materialize_debug_model.py "${CANDIDATE_ARGS[@]}"
    exit 0
  fi
else
  if [[ -n "$CANDIDATE_SELECTOR" ]]; then
    echo "error: CREG_CANDIDATE_TRAINING_RUN is forbidden in Release builds."
    exit 1
  fi
fi

FETCH_ARGS=(
  --manifest "$MANIFEST_DESTINATION"
  --production
  --models-dir "$MODELS_CACHE"
  --destination "$MODEL_DIR"
)
if [[ "$CONFIGURATION" == "Debug" || "$CONFIGURATION" == "Beta" ]]; then
  FETCH_ARGS+=(--allow-historical-policy)
fi
"$UV_BIN" run --frozen python tools/fetch_model.py "${FETCH_ARGS[@]}"
