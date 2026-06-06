#!/bin/bash
# =============================================
#   Profile: sqflite_darwin (remote, transitive)
#   Version: 2.x (ObjC, shared Darwin source)
#
#   Keep this at L2 by default. Database code has many category/helper symbols,
#   so we avoid broad dead-branch injection until runtime DB smoke tests exist.
# =============================================

PROFILE_NAME="sqflite_darwin"
PROFILE_VERSION="2"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "SqflitePlugin"
    "SqfliteDatabase"
    "SqfliteOperation"
    "SqfliteCursor"
    "SqfliteDarwinDatabase"
    "SqfliteDarwinDatabaseQueue"
    "registerWithRegistrar"
    "handleMethodCall"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local source_dirs=("${_PROFILE_SRC_DIRS[@]}")
    if [[ ${#source_dirs[@]} -eq 0 ]]; then
        local src_dir
        src_dir=$(bt_find_src_dir "$plugin_dir" "sqflite_darwin")
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
    done
}
