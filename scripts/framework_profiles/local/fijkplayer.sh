#!/bin/bash
# =============================================
#   Profile: fijkplayer (本地 path 依赖)
#   版本: 0.11.x  (纯 ObjC，B 站魔改 IjkPlayer)
#   iOS 源文件:
#     ios/Classes/
#       FijkPlugin.h       (Plugin 注册类)
#       FijkPlugin.m
#       FijkPlayer.h       (主播放器，依赖 IJKFFMediaPlayer C 内核)
#       FijkPlayer.m
#       FijkHostOption.h   (配置项)
#       FijkHostOption.m
#       FijkQueuingEventSink.h  (Flutter EventChannel 队列)
#       FijkQueuingEventSink.m
#
#   Status: draft
#   说明: IJKFFMediaPlayer 等 C 内核类来自 IJKMediaFramework.framework（预编译），
#         本 profile 不触碰 framework 内部，仅对 ios/Classes/ 下 ObjC 桥接代码做 L1-L3 变异。
#         所有 Flutter MethodChannel/EventChannel 入口、Texture 协议方法、单例都受保护。
#         L1 只动 static 内部函数；L2 打乱方法顺序；L3 注入死分支不改签名。
# =============================================

PROFILE_NAME="fijkplayer"
PROFILE_VERSION="local"
PROFILE_STATUS="draft"

# 公开 API / 类名 / Flutter 注册入口 — 不允许重命名
PROFILE_PROTECTED=(
    # 类名
    "FijkPlugin"
    "FijkPlayer"
    "FijkHostOption"
    "FijkQueuingEventSink"
    # Flutter Plugin 入口
    "registerWithRegistrar"
    "singleInstance"
    "handleMethodCall"
    # EventChannel 协议
    "onListenWithArguments"
    "onCancelWithArguments"
    # 实例化入口
    "initWithRegistrar"
    "initJustTexture"
    # Flutter Texture 协议（绝对不可改，运行时反射调用）
    "copyPixelBuffer"
    "setupSurface"
    # IjkPlayer 公开 API（Dart 端通过 MethodChannel 调用）
    "setup"
    "shutdown"
    "setOptions"
    "setDataSource"
    "prepareAsync"
    "start"
    "pause"
    "stop"
    "reset"
    "release"
    "seekTo"
    "setVolume"
    "setSpeed"
    "setLoop"
    "setNetworkType"
    "takeSnapshot"
    # 状态/事件回调（Player → Plugin/Native 内部约定）
    "onStateChangedWithNew"
    "onPlayingChange"
    "onPlayableChange"
    "handleEvent"
    "onEvent4Player"
    "display_pixelbuffer"
    "isPlayable"
    "setScreenOn"
    # FijkPlugin 系统音量 API（Native 通知监听）
    "initVolumeView"
    "getSystemVolume"
    "setSystemVolume"
    "updateVolumeVisiablity"
    "volumeChange"
    "sendVolumeChange"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir="$plugin_dir/ios/Classes"
    [[ -d "$src_dir" ]] || return 1

    # L0: 注入唯一类
    bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

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
