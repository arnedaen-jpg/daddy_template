#!/bin/bash
# =============================================
#   Profile: video_thumbnail (remote, renamed)
#   Version: 0.x (纯 ObjC, ios/Classes/VideoThumbnailPlugin.m)
#   说明: 单文件 ObjC 插件，内部含 libwebp 编码（#if __has_include 预处理块）。
#         本 profile 注入唯一类 + 重命名文件内 static C 函数；L3 死分支注入对
#         含预处理块的文件自动跳过（file_has_preprocessor_blocks 守卫），避免破坏
#         webp/libwebp 指针运算链路。保护 registerWithRegistrar/handleMethodCall/
#         generateThumbnail（ObjC 类方法，跨文件按类名引用，renamer 不会改类方法）。
#         oio/bili/yms 历史上保守取 L0；此处借预处理守卫安全提至 L3（实质为类注入）。
# =============================================

PROFILE_NAME="video_thumbnail"
PROFILE_VERSION="0"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "VideoThumbnailPlugin"
    "registerWithRegistrar"
    "handleMethodCall"
    "generateThumbnail"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "video_thumbnail")
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
