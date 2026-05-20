#!/bin/bash
# =============================================
#   Profile: url_launcher_ios (远程依赖，传递依赖)
#   版本: 6.x (Swift, SPM 结构)
#   iOS 源文件:
#     ios/url_launcher_ios/Sources/url_launcher_ios/
#       URLLauncherPlugin.swift
#       Launcher.swift
#       URLLaunchSession.swift
#       messages.g.swift            ← Pigeon 生成，不可修改
#
#   Status: draft
# =============================================

PROFILE_NAME="url_launcher_ios"
PROFILE_VERSION="6"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "URLLauncherPlugin"
    "Launcher"
    "URLLaunchSession"
    "register"
    "handle"
    "UrlLauncherApi"
)

PROFILE_SKIP_FILES=(
    "messages.g.swift"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "url_launcher_ios")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] || continue
            local fname; fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do [[ "$fname" == "$sf" ]] && skip=true && break; done
            [[ "$skip" == "true" ]] && continue
            bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] || continue
            local fname; fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do [[ "$fname" == "$sf" ]] && skip=true && break; done
            [[ "$skip" == "true" ]] && continue
            bt_reorder_swift_methods "$f"
        done
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.swift; do
            [[ -f "$f" ]] || continue
            local fname; fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do [[ "$fname" == "$sf" ]] && skip=true && break; done
            [[ "$skip" == "true" ]] && continue
            bt_inject_swift_dead_branches "$f"
        done
    fi
}
