#!/bin/bash
# =============================================
#   Profile: rongcloud_im_wrapper_plugin (remote, renamed)
#   Version: 5.x (ObjC wrapper, ios/Classes/RCIMWrapper*.m + vendored xcframework)
#   结构: RCIMWrapperPlugin / RCIMWrapperEngine(单例) / RCIMWrapperArgumentAdapter /
#         RCIMWrapperMainThreadPoster，桥接到二进制 RongIMWrapper.xcframework 与
#         RongCloudIM Pod(IMLibCore/ChatRoom)。
#   说明: 仅对 4 个 wrapper 源文件做混淆。renamer 不改 ObjC 类名/selector，故
#         [RCIMWrapperEngine sharedInstance]、registerWithRegistrar、+load、getVersion
#         及对 RongIMLibCore 的外部 API 调用均不受影响。L3 死分支为恒假谓词，
#         注入到 +load/桥接方法也永不执行。vendored xcframework 与 RongCloudIM Pod
#         在 project_manifest 中保持 disabled，绝不混淆二进制。
# =============================================

PROFILE_NAME="rongcloud_im_wrapper_plugin"
PROFILE_VERSION="5"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "RCIMWrapperPlugin"
    "RCIMWrapperEngine"
    "RCIMWrapperArgumentAdapter"
    "RCIMWrapperMainThreadPoster"
    "registerWithRegistrar"
    "sharedInstance"
    "handleMethodCall"
    "load"
    "getVersion"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "rongcloud_im_wrapper_plugin")
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
