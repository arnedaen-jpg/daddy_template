#!/bin/bash
# =============================================
#   Profile: permission_handler_apple (远程依赖，传递依赖)
#   版本: 9.x (ObjC, Classes/ 结构)
#   iOS 源文件:
#     ios/Classes/ 或 ios/<module>/Sources/<module>/
#       PermissionHandlerPlugin.m       # 主插件类
#       PermissionManager.m             # 权限管理器
#       util/Codec.m                    # 编解码工具
#       strategies/*.m                  # 各权限策略（20+ 文件）
#
#   Status: draft
#   测试: 待验证
#   特点: 大量 strategy 文件，static 函数较多，L1 效果显著
# =============================================

PROFILE_NAME="permission_handler_apple"
PROFILE_VERSION="9.1"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "PermissionHandlerPlugin"
    "registerWithRegistrar"
    "handleMethodCall"
    "PermissionManager"
    "checkPermissionStatus"
    "requestPermission"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local source_dirs=("${_PROFILE_SRC_DIRS[@]}")
    if [[ ${#source_dirs[@]} -eq 0 ]]; then
        local src_dir
        src_dir=$(bt_find_src_dir "$plugin_dir" "permission_handler_apple")
        [[ -n "$src_dir" ]] && source_dirs=("$src_dir")
    fi
    [[ ${#source_dirs[@]} -gt 0 ]] || return 1

    local src_dir
    for src_dir in "${source_dirs[@]}"; do
        [[ -d "$src_dir" ]] || continue

        # L0: 注入唯一类
        bt_inject_classes "$src_dir" "$PROFILE_NAME" 7

        if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
            # strategies/ 下大量 static 函数可安全重命名
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

        if [[ "$level" == "L3" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                file_has_preprocessor_blocks "$f" && continue
                bt_inject_dead_branches "$f" 8
            done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
        fi
    done
}
