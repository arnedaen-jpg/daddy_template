#!/bin/bash
# =============================================
#   Profile: audioplayers_darwin (remote, renamed)
#   Version: 6.x (Swift, shared Darwin source)
# =============================================

PROFILE_NAME="audioplayers_darwin"
PROFILE_VERSION="6"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "AudioplayersDarwinPlugin"
    "CanvasGroupPlugin"
    "WrappedMediaPlayer"
    "AudioContext"
    "register"
    "handle"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "audioplayers_darwin")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f" 10
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi
}
