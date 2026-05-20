#!/bin/bash
# =============================================
#   Profile: flutter_file_picker-master (本地 fork 依赖)
#   iOS 源文件 (SPM 结构):
#     ios/<pkg>/Sources/<pkg>/
#       <Plugin>Plugin.m          # 主插件类
#       <Plugin>Utils.m           # 工具类
#       ImageUtils.m              # 图片工具
#       FileInfo.m                # 文件信息
#
#   Status: draft
#   特点: 多个 ObjC 源文件，static 函数和辅助类较多
# =============================================

PROFILE_NAME="flutter_file_picker-master"
PROFILE_VERSION="local"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "registerWithRegistrar"
    "handleMethodCall"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "file_picker")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "file_picker" 6

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.m" -type f -not -name "_zt_*" 2>/dev/null)
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done < <(find "$src_dir" -name "*.m" -type f -not -name "_zt_*" 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done < <(find "$src_dir" -name "*.m" -type f -not -name "_zt_*" 2>/dev/null)
    fi
}
