#!/bin/bash
# =============================================
#   Profile: audio_session (远程依赖)
#   版本: 0.2.x  (纯 ObjC, SPM 结构)
#   iOS 源文件:
#     ios/audio_session/Sources/audio_session/
#       AudioSessionPlugin.m
#       DarwinAudioSession.m
#       include/audio_session/AudioSessionPlugin.h
#       include/audio_session/DarwinAudioSession.h
#
#   Status: draft
#   说明: 主类暴露 Flutter MethodChannel handler，所有 -(void)getXXX:result:
#         /-(void)setXXX:args:result: 是动态调用入口，绝不可重命名。
#         L1 只动 static 函数；L2 仅打乱方法顺序（仍保留方法签名）；
#         L3 注入死分支不改签名。
# =============================================

PROFILE_NAME="audio_session"
PROFILE_VERSION="0.2"
PROFILE_STATUS="draft"

# 公开 API / 类名 / Flutter 注册入口 — 不允许重命名
PROFILE_PROTECTED=(
    "AudioSessionPlugin"
    "DarwinAudioSession"
    "register"
    "registerWithRegistrar"
    "handle"
    "handleMethodCall"
    "initWithRegistrar"
    "channel"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "audio_session")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 5

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done
    fi
}
