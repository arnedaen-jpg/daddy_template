#!/bin/bash
# =============================================
#   Profile: video_player_avfoundation (remote, renamed)
#   Version: 2.x (ObjC, Pigeon generated API)
# =============================================

PROFILE_NAME="video_player_avfoundation"
PROFILE_VERSION="2"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "FVPVideoPlayerPlugin"
    "FVPVideoPlayerApi"
    "FVPVideoPlayer"
    "FVPTextureBasedVideoPlayer"
    "FVPNativeVideoView"
    "FVPAVFactory"
    "registerWithRegistrar"
    "handleMethodCall"
)

PROFILE_SKIP_FILES=(
    "messages.g.m"
    "messages.g.h"
)

_profile_patch_metadata() {
    local plugin_dir="$1"
    local current
    current="${_PROFILE_CURRENT_NAME:-$(basename "$plugin_dir")}"

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "    [metadata] video_player_avfoundation -> $current" || true
        return 0
    fi

    local podspec
    podspec=$(find "$plugin_dir" -name "*.podspec" \( -path "*/ios/*" -o -path "*/darwin/*" \) -print -quit 2>/dev/null)
    if [[ -f "$podspec" ]]; then
        sed -i '' -E \
            "s|^[[:space:]]*s\\.source_files[[:space:]]*=.*|  s.source_files = '${current}/Sources/{${current},video_player_avfoundation_objc}/**/*.{h,m,swift}'|" \
            "$podspec" 2>/dev/null || true
    fi

    local package_file
    package_file=$(find "$plugin_dir" -name "Package.swift" \( -path "*/ios/*" -o -path "*/darwin/*" \) -print -quit 2>/dev/null)
    if [[ -f "$package_file" ]]; then
        sed -i '' \
            -e "s|\\.headerSearchPath(\"include/${current}\")|.headerSearchPath(\"include/video_player_avfoundation\")|g" \
            -e "s|../${current}_objc/include/${current}_objc|../video_player_avfoundation_objc/include/video_player_avfoundation_objc|g" \
            "$package_file" 2>/dev/null || true
    fi
}

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

    _profile_patch_metadata "$plugin_dir"

    local source_dirs=("${_PROFILE_SRC_DIRS[@]}")
    if [[ ${#source_dirs[@]} -eq 0 ]]; then
        while IFS= read -r d; do
            [[ -n "$d" ]] && source_dirs+=("$d")
        done < <(find "$plugin_dir" -type f -name "*.m" \( -path "*/ios/*" -o -path "*/darwin/*" \) -print 2>/dev/null | while read -r f; do dirname "$f"; done | sort -u)
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
                bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
            done < <(find "$src_dir" -maxdepth 1 -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi

        if [[ "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                _profile_should_skip_file "$f" && continue
                file_has_preprocessor_blocks "$f" && continue
                bt_reorder_objc_methods "$f"
            done < <(find "$src_dir" -maxdepth 1 -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi

        if [[ "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                _profile_should_skip_file "$f" && continue
                bt_inject_dead_branches "$f" 10
            done < <(find "$src_dir" -maxdepth 1 -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi
    done
}
