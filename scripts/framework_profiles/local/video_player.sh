#!/bin/bash
# =============================================
#   Profile: video_player (本地 fork 依赖)
#   子插件: video_player_avfoundation (ObjC)
#   iOS 源文件 (darwin/ 结构):
#     darwin/video_player_avfoundation/Sources/video_player_avfoundation/
#       FVPVideoPlayerPlugin.m
#       AVAssetTrackUtils.m
#       messages.g.m (Pigeon 生成，谨慎修改)
#     darwin/video_player_avfoundation/Sources/video_player_avfoundation_ios/
#       FVPDisplayLink.m
#
#   Status: draft
#   测试: 待验证
#   注意: messages.g.m 是 Pigeon 自动生成的，符号重命名可能破坏 Dart↔Native 通信
# =============================================

PROFILE_NAME="video_player"
PROFILE_VERSION="local"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "FVPVideoPlayerPlugin"
    "registerWithRegistrar"
    "handleMethodCall"
    "FVPDisplayLink"
    # messages.g.m 中的公开符号不要动
    "FVPVideoPlayerApi"
    "FVPTextureMessage"
    "FVPCreateMessage"
    "FVPLoopingMessage"
    "FVPMixWithOthersMessage"
    "FVPPlaybackSpeedMessage"
    "FVPPositionMessage"
    "FVPVolumeMessage"
)

# messages.g.m 完全跳过（Pigeon 生成文件）
PROFILE_SKIP_FILES=(
    "messages.g.m"
    "messages.g.h"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    # video_player 是 monorepo，找 avfoundation 子插件
    local src_dir
    src_dir=$(find "$plugin_dir" -path "*/Sources/video_player_avfoundation" -type d 2>/dev/null | head -1)
    local ios_src_dir
    ios_src_dir=$(find "$plugin_dir" -path "*/Sources/video_player_avfoundation_ios" -type d 2>/dev/null | head -1)

    # L0: 注入唯一类
    [[ -n "$src_dir" ]] && bt_inject_classes "$src_dir" "${PROFILE_NAME}_avfoundation" 6
    [[ -n "$ios_src_dir" ]] && bt_inject_classes "$ios_src_dir" "${PROFILE_NAME}_ios" 5

    # L1+: 只处理非 Pigeon 生成的文件
    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m "$ios_src_dir"/*.m; do
            [[ -f "$f" ]] || continue
            local fname
            fname=$(basename "$f")

            # 跳过 skip 列表中的文件
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do
                [[ "$fname" == "$sf" ]] && skip=true && break
            done
            [[ "$skip" == "true" ]] && continue

            bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m "$ios_src_dir"/*.m; do
            [[ -f "$f" ]] || continue
            local fname
            fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do
                [[ "$fname" == "$sf" ]] && skip=true && break
            done
            [[ "$skip" == "true" ]] && continue
            bt_reorder_objc_methods "$f"
        done
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m "$ios_src_dir"/*.m; do
            [[ -f "$f" ]] || continue
            local fname
            fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do
                [[ "$fname" == "$sf" ]] && skip=true && break
            done
            [[ "$skip" == "true" ]] && continue
            bt_inject_dead_branches "$f"
        done
    fi
}
