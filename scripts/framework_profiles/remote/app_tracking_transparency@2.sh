#!/bin/bash
# =============================================
#   Profile: app_tracking_transparency (remote, renamed)
#   Version: 2.x (Swift 主类 + ObjC 桥, ios/Classes 结构)
#   结构: AppTrackingTransparencyPlugin.m/.h(ObjC 桥) +
#         SwiftAppTrackingTransparencyPlugin.swift(主实现，内部 private 方法)
#   说明: 与 flutter_statusbarcolor_ns@0 同构（Swift+ObjC 桥）。仅重命名 Swift
#         文件内 private 方法（文件内一致替换，安全），注入唯一类与死分支；
#         保护注册符号 register/registerWithRegistrar/handle，channel 名为字符串字面量不受影响。
#   ⚠️ 关键：bt_rename_swift_privates 按全文件词边界替换，若 private 方法名与
#         Apple 系统 selector 同名（requestTrackingAuthorization / addObserver /
#         removeObserver 等），系统调用会被一并误改导致编译失败。故这些 selector
#         名必须列入 PROFILE_PROTECTED，使其跳过重命名。
# =============================================

PROFILE_NAME="app_tracking_transparency"
PROFILE_VERSION="2"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "AppTrackingTransparencyPlugin"
    "SwiftAppTrackingTransparencyPlugin"
    "registerWithRegistrar"
    "register"
    "handle"
    "detachFromEngine"
    # --- Apple 系统 selector：与插件 private 方法同名，禁止重命名 ---
    "requestTrackingAuthorization"
    "addObserver"
    "removeObserver"
    "trackingAuthorizationStatus"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "app_tracking_transparency")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_inject_swift_dead_branches "$f" 10
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "Package.swift" ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            file_has_preprocessor_blocks "$f" && continue
            bt_inject_dead_branches "$f" 8
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi
}
