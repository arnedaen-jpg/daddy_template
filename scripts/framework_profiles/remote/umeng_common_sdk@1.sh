#!/bin/bash
# =============================================
#   Profile: umeng_common_sdk (remote, renamed)
#   Version: 1.x (纯 ObjC 包装层, ios/Classes/UmengCommonSdkPlugin.m)
#   结构: UmengCommonSdkPlugin + 内部辅助类 UMengflutterpluginForUMCommon /
#         UMengflutterpluginForAnalytics，转发到二进制 Pod UMCommon(UMConfigure/MobClick)。
#   说明: renamer 仅改 static C 函数（此处无），不改 ObjC 类名/selector，故三个类
#         的跨类调用与对 UMConfigure/MobClick 的外部 API 调用均不受影响。
#         L3 注入唯一类 + 死分支（恒假谓词，永不执行）。
#         二进制 Pod UMCommon/UMDevice 在 project_manifest 中保持 disabled。
# =============================================

PROFILE_NAME="umeng_common_sdk"
PROFILE_VERSION="1"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "UmengCommonSdkPlugin"
    "UMengflutterpluginForUMCommon"
    "UMengflutterpluginForAnalytics"
    "registerWithRegistrar"
    "handleMethodCall"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "umeng_common_sdk")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            file_has_preprocessor_blocks "$f" && continue
            bt_inject_dead_branches "$f" 8
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi
}
