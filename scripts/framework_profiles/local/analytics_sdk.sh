#!/bin/bash
# =============================================
#   Profile: analytics_sdk (local/path dependency, renamed)
#   Version: local (small Swift Flutter plugin)
#
#   Strategy:
#     - Keep Flutter registration and channel-facing APIs stable.
#     - Apply Swift private rename/dead-branch noise and injected ObjC classes.
# =============================================

PROFILE_NAME="analytics_sdk"
PROFILE_VERSION="local"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "AnalyticsSdkPlugin"
    "DataPlusSdkPlugin"
    "MaskSidePlugin"
    "register"
    "handle"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"
    local source_dirs=("${_PROFILE_SRC_DIRS[@]}")
    if [[ ${#source_dirs[@]} -eq 0 ]]; then
        local src_dir
        src_dir=$(bt_find_src_dir "$plugin_dir" "analytics_sdk")
        [[ -n "$src_dir" ]] && source_dirs=("$src_dir")
    fi
    [[ ${#source_dirs[@]} -gt 0 ]] || return 1

    local src_dir
    for src_dir in "${source_dirs[@]}"; do
        [[ -d "$src_dir" ]] || continue
        bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

        if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi

        if [[ "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] && bt_reorder_swift_methods "$f"
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi

        if [[ "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f" 8
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi
    done
}
