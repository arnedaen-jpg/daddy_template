#!/bin/bash
# =============================================
#   Profile: fijkplayer (local/path dependency, renamed)
#   Version: local (ObjC + binary BIJKPlayer dependency)
#
#   Strategy:
#     - Keep player/plugin public Objective-C symbols and all binary pod usage.
#     - At the current L1 manifest level, only inject classes and rename safe
#       file-local static functions.
#     - L2 is intentionally conservative and skips the two core player files.
# =============================================

PROFILE_NAME="fijkplayer"
PROFILE_VERSION="local"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "FijkPlugin"
    "FijkPlayer"
    "FijkHostOption"
    "FijkQueuingEventSink"
    "registerWithRegistrar"
    "handleMethodCall"
    "singleInstance"
    "initWithRegistrar"
    "initWithPlayer"
    "copyPixelBuffer"
    "onPlayingChange"
    "onPlayableChange"
    "setScreenOn"
)

PROFILE_L2_SKIP_FILES=(
    "FijkPlugin.m"
    "FijkPlayer.m"
)

_profile_should_skip_l2_file() {
    local file="$1"
    local fname
    fname=$(basename "$file")
    for sf in "${PROFILE_L2_SKIP_FILES[@]}"; do
        [[ "$fname" == "$sf" ]] && return 0
    done
    return 1
}

_profile_scrub_metadata() {
    local plugin_dir="$1"
    local current
    current="${_PROFILE_CURRENT_NAME:-$(basename "$plugin_dir")}"

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "    [metadata] fijkplayer -> $current" || true
        return 0
    fi

    local podspec
    podspec=$(find "$plugin_dir" -name "*.podspec" \( -path "*/ios/*" -o -path "*/darwin/*" \) -print -quit 2>/dev/null)
    if [[ -f "$podspec" ]]; then
        sed -i '' \
            -e "s|befovy@gmail.com|team@example.com|g" \
            -e "s|Flutter plugin for ijkplayer|Flutter media runtime adapter|g" \
            -e "s|http://github.com/befovy/fijkplayer|https://example.com/${current}|g" \
            -e "s|befovy|Core Team|g" \
            -e "s|Core Team@gmail.com|team@example.com|g" \
            "$podspec" 2>/dev/null || true
    fi
}

profile_apply() {
    local plugin_dir="$1"
    local level="$2"
    local source_dirs=("${_PROFILE_SRC_DIRS[@]}")
    [[ ${#source_dirs[@]} -gt 0 ]] || return 1

    _profile_scrub_metadata "$plugin_dir"

    local src_dir
    for src_dir in "${source_dirs[@]}"; do
        [[ -d "$src_dir" ]] || continue
        bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

        if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                file_has_preprocessor_blocks "$f" && continue
                bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
            done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi

        if [[ "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                _profile_should_skip_l2_file "$f" && continue
                file_has_preprocessor_blocks "$f" && continue
                bt_reorder_objc_methods "$f"
            done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi

        if [[ "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                _profile_should_skip_l2_file "$f" && continue
                file_has_preprocessor_blocks "$f" && continue
                bt_inject_dead_branches "$f" 8
            done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi
    done
}
