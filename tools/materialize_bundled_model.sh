#!/bin/zsh
set -euo pipefail

HARNESS_BUILD_VALUE="${CREG_ACCESSIBILITY_HARNESS_BUILD:-NO}"
HARNESS_BUILD_NORMALIZED="$(
  printf '%s' "$HARNESS_BUILD_VALUE" | tr '[:upper:]' '[:lower:]'
)"
case "$HARNESS_BUILD_NORMALIZED" in
  1 | yes | true | on) HARNESS_BUILD=true ;;
  "" | 0 | no | false | off) HARNESS_BUILD=false ;;
  *)
    echo "error: CREG_ACCESSIBILITY_HARNESS_BUILD must be a Boolean; found '$HARNESS_BUILD_VALUE'."
    exit 1
    ;;
esac

CONFIGURATION_VALUE="${CONFIGURATION:-}"
PLATFORM_NAME_VALUE="${PLATFORM_NAME:-}"
if [[ "$HARNESS_BUILD" == true ]]; then
  if [[ "$CONFIGURATION_VALUE" != "Debug" || "$PLATFORM_NAME_VALUE" != "iphonesimulator" ]]; then
    echo "error: CREG_ACCESSIBILITY_HARNESS_BUILD is restricted to Debug iOS Simulator builds."
    exit 1
  fi
fi

if [[ -z "${SRCROOT:-}" || -z "${TARGET_BUILD_DIR:-}" \
  || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" || -z "${INFOPLIST_PATH:-}" \
  || -z "$CONFIGURATION_VALUE" ]]
then
  echo "error: model materialization requires the Xcode build environment."
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

if [[ ! -f "$CONTRACT_PATH" ]]; then
  echo "error: model runtime contract is missing at $CONTRACT_PATH"
  exit 1
fi
CONTRACT_VERSION="$(
  /usr/bin/plutil -extract current_version raw -o - "$CONTRACT_PATH" 2>/dev/null \
    || true
)"
if [[ -z "$CONTRACT_VERSION" || "$CONTRACT_VERSION" == *[^0-9]* ]]; then
  echo "error: model runtime contract current_version must be an integer."
  exit 1
fi

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

if [[ "$HARNESS_BUILD" == true ]]; then
  /bin/rm -rf -- "$MODEL_DIR"
  /bin/rm -f -- "$MANIFEST_DESTINATION" "$RECEIPT_DESTINATION"
  echo "warning: Debug UI-test harness build omits SQL model materialization; stale model artifacts were cleared and source provenance was stamped."
  exit 0
fi

UV_BIN="$(command -v uv || true)"
if [[ -z "$UV_BIN" && -n "${HOME:-}" && -x "$HOME/.local/bin/uv" ]]; then
  UV_BIN="$HOME/.local/bin/uv"
fi
if [[ -z "$UV_BIN" ]]; then
  echo "error: uv is required to materialize the SQL model. Install uv and rebuild."
  exit 1
fi

mkdir -p "$RESOURCE_DIR"
cd "$SRCROOT/fine-tuning"
"$UV_BIN" run --frozen python tools/stamp_bundle_manifest.py \
  --source "$SRCROOT/model-manifest.json" \
  --destination "$MANIFEST_DESTINATION" \
  --contract "$CONTRACT_PATH" \
  --source-revision "$SOURCE_REVISION" \
  --source-dirty "$SOURCE_DIRTY"

if [[ "$CONFIGURATION_VALUE" == "Debug" || "$CONFIGURATION_VALUE" == "Beta" ]]; then
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
    echo "warning: $CONFIGURATION_VALUE is bundling a local candidate without requiring a W&B receipt."
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
if [[ "$CONFIGURATION_VALUE" == "Debug" || "$CONFIGURATION_VALUE" == "Beta" ]]; then
  FETCH_ARGS+=(--allow-historical-policy)
fi
"$UV_BIN" run --frozen python tools/fetch_model.py "${FETCH_ARGS[@]}"
