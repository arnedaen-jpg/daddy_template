#!/bin/bash
# =============================================
#   Profile: flutter_local_notifications (远程依赖)
#   版本: 18.x (ObjC, Classes/ 结构)
#   iOS 源文件:
#     ios/Classes/
#       <Plugin>Plugin.m           # 主插件类 (大量 static NSString)
#       Converters.m               # 数据转换工具
#       ActionEventSink.m          # Action 事件 sink
#       FlutterEngineManager.m     # 引擎管理器
#     darwin/Classes/
#       Converters.m               # 跨平台转换工具
#
#   Status: draft
#   特点: 大量 static NSString 常量和辅助类，L1 效果显著
# =============================================

PROFILE_NAME="flutter_local_notifications"
PROFILE_VERSION="18"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "registerWithRegistrar"
    "handleMethodCall"
    "registerPlugins"
    "actionEventSink"
    "FlutterEngineManager"
    "ActionEventSink"
    "Converters"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir="$plugin_dir/ios/Classes"
    [[ -d "$src_dir" ]] || return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

    # darwin/Classes 也注入
    local darwin_dir="$plugin_dir/darwin/Classes"
    [[ -d "$darwin_dir" ]] && bt_inject_classes "$darwin_dir" "${PROFILE_NAME}_darwin" 4

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.m" -type f 2>/dev/null)
        [[ -d "$darwin_dir" ]] && while IFS= read -r f; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$darwin_dir" -name "*.m" -type f 2>/dev/null)
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done < <(find "$src_dir" -name "*.m" -type f 2>/dev/null)
        [[ -d "$darwin_dir" ]] && while IFS= read -r f; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done < <(find "$darwin_dir" -name "*.m" -type f 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done < <(find "$src_dir" -name "*.m" -type f 2>/dev/null)
        [[ -d "$darwin_dir" ]] && while IFS= read -r f; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done < <(find "$darwin_dir" -name "*.m" -type f 2>/dev/null)
    fi
}
