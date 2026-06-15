#!/bin/bash

PROFILE_NAME="flutter_secure_storage"
PROFILE_VERSION="9"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "FlutterSecureStoragePlugin"
    "SwiftFlutterSecureStoragePlugin"
    "registerWithRegistrar"
    "register"
    "handle"
    "deleteAll"
    "containsKey"
    "readAll"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"
    local source_dirs=("${_PROFILE_SRC_DIRS[@]}")
    [[ ${#source_dirs[@]} -gt 0 ]] || return 1

    local src_dir
    for src_dir in "${source_dirs[@]}"; do
        [[ -d "$src_dir" ]] || continue
        bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

        if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
            done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
            while IFS= read -r f; do
                [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" 2>/dev/null)
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
                [[ -f "$f" ]] || continue
                file_has_preprocessor_blocks "$f" && continue
                bt_inject_dead_branches "$f" 8
            done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
            while IFS= read -r f; do
                [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f" 10
            done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" 2>/dev/null)
        fi
    done
}
