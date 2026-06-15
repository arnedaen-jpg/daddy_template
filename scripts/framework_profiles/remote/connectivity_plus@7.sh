#!/bin/bash

PROFILE_NAME="connectivity_plus"
PROFILE_VERSION="7.1"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "ConnectivityPlusPlugin"
    "register"
    "handle"
    "ConnectivityProvider"
    "connectivityUpdateHandler"
    "pathUpdateHandler"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local source_dirs=("${_PROFILE_SRC_DIRS[@]}")
    if [[ ${#source_dirs[@]} -eq 0 ]]; then
        local src_dir
        src_dir=$(bt_find_src_dir "$plugin_dir" "connectivity_plus")
        [[ -n "$src_dir" ]] && source_dirs=("$src_dir")
    fi
    [[ ${#source_dirs[@]} -gt 0 ]] || return 1

    local src_dir
    for src_dir in "${source_dirs[@]}"; do
        [[ -d "$src_dir" ]] || continue
        bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

        if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" 2>/dev/null)
        fi

        if [[ "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] && bt_reorder_swift_methods "$f"
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" 2>/dev/null)
        fi

        if [[ "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f"
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" 2>/dev/null)
        fi
    done
}
