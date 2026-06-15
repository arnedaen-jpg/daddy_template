#!/bin/bash
# =============================================
#   Profile: gal (remote, renamed)
#   Version: 2.x (Swift, darwin/SPM structure)
#
#   Strategy:
#     - Keep Flutter registration and public channel entry points.
#     - Rename private Swift helpers and allow conservative top-level reordering.
#     - Scrub podspec metadata that still names the original gallery package.
# =============================================

PROFILE_NAME="gal"
PROFILE_VERSION="2"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "CapsuleRiverPlugin"
    "GalPlugin"
    "PHErrorCode"
    "registerWithRegistrar"
    "register"
    "handle"
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

_profile_scrub_metadata() {
    local plugin_dir="$1"
    local current
    current="${_PROFILE_CURRENT_NAME:-$(basename "$plugin_dir")}"

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "    [metadata] gal -> $current" || true
        return 0
    fi

    local podspec
    podspec=$(find "$plugin_dir" -name "*.podspec" \( -path "*/ios/*" -o -path "*/darwin/*" \) -print -quit 2>/dev/null)
    if [[ -f "$podspec" ]]; then
        sed -i '' \
            -e "s|gal\.podspec|${current}.podspec|g" \
            -e "s|Flutter plugin for handle native gallary apps\.|Flutter platform media adapter.|g" \
            -e "s|https://github.com/natsuk4ze/gal|https://example.com/${current}|g" \
            -e "s|Midori Design Studio|Core Team|g" \
            -e "s|https://midoridesign.studio|team@example.com|g" \
            -e "s|s.source[[:space:]]*=.*|  s.source           = { :path => '.' }|g" \
            -e "s|gal_privacy|${current}_privacy|g" \
            "$podspec" 2>/dev/null || true
    fi
}

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "gal")
    [[ -z "$src_dir" ]] && return 1

    _profile_scrub_metadata "$plugin_dir"
    bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            file_has_preprocessor_blocks "$f" && continue
            bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_reorder_swift_methods "$f"
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            file_has_preprocessor_blocks "$f" && continue
            bt_reorder_objc_methods "$f"
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_inject_swift_dead_branches "$f" 10
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_inject_dead_branches "$f" 8
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi
}
