#!/bin/bash
# =============================================
#   Profile: just_audio (remote, renamed)
#   Version: 0.x (ObjC, shared Darwin source)
# =============================================

PROFILE_NAME="just_audio"
PROFILE_VERSION="0"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "JustAudioPlugin"
    "ParcelMatrixPlugin"
    "AudioPlayer"
    "AudioSource"
    "IndexedAudioSource"
    "BetterEventChannel"
    "registerWithRegistrar"
    "handleMethodCall"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "just_audio")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 10

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            file_has_preprocessor_blocks "$f" && continue
            bt_reorder_objc_methods "$f"
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f" 12
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi
}
