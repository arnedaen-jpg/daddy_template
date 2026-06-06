#!/bin/bash
# =============================================
#   Profile: audio_session (remote, renamed)
#   Version: 0.x (ObjC)
#
#   Note: Do not rewrite AVAudioSession symbols. This profile only touches
#   file-local static functions, method order, dead branches, and injected files.
# =============================================

PROFILE_NAME="audio_session"
PROFILE_VERSION="0"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "AudioSessionPlugin"
    "DarwinAudioSession"
    "registerWithRegistrar"
    "handleMethodCall"
    "register"
    "handle"
    "initWithRegistrar"
    "channel"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local source_dirs=("${_PROFILE_SRC_DIRS[@]}")
    if [[ ${#source_dirs[@]} -eq 0 ]]; then
        local src_dir
        src_dir=$(bt_find_src_dir "$plugin_dir" "audio_session")
        [[ -n "$src_dir" ]] && source_dirs=("$src_dir")
    fi
    [[ ${#source_dirs[@]} -gt 0 ]] || return 1

    local src_dir
    for src_dir in "${source_dirs[@]}"; do
        [[ -d "$src_dir" ]] || continue
        bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

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
    done
}
