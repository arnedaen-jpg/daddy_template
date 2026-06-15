#!/bin/bash
# =============================================
#   Profile: image_gallery_saver_plus (remote, renamed)
#   Version: 4.x (Swift, Classes/ layout)
#
#   Strategy:
#     - Keep Flutter registration, channel entry points, Photos callbacks, and
#       result model names stable.
#     - Rename private Swift helpers and allow conservative method reordering.
# =============================================

PROFILE_NAME="image_gallery_saver_plus"
PROFILE_VERSION="4"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "ImageGallerySaverPlusPlugin"
    "SaveResultModel"
    "register"
    "handle"
    "didFinishSavingImage"
    "didFinishSavingVideo"
    "saveResult"
)

PROFILE_SKIP_FILES=(
    "Package.swift"
)

_profile_should_skip_file() {
    local file="$1"
    local fname
    fname=$(basename "$file")
    for sf in "${PROFILE_SKIP_FILES[@]}"; do
        [[ "$fname" == "$sf" ]] && return 0
    done
    return 1
}

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local source_dirs=("${_PROFILE_SRC_DIRS[@]}")
    if [[ ${#source_dirs[@]} -eq 0 ]]; then
        local src_dir
        src_dir=$(bt_find_src_dir "$plugin_dir" "image_gallery_saver_plus")
        [[ -n "$src_dir" ]] && source_dirs=("$src_dir")
    fi
    [[ ${#source_dirs[@]} -gt 0 ]] || return 1

    local src_dir
    for src_dir in "${source_dirs[@]}"; do
        [[ -d "$src_dir" ]] || continue
        bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

        if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                _profile_should_skip_file "$f" && continue
                bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi

        if [[ "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                _profile_should_skip_file "$f" && continue
                bt_reorder_swift_methods "$f"
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi

        if [[ "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                _profile_should_skip_file "$f" && continue
                bt_inject_swift_dead_branches "$f" 8
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi
    done
}
