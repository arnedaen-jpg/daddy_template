#!/bin/bash
# =============================================
#   Profile: qrcode_flutter (remote, renamed)
#   Version: 3.x (纯 ObjC, ios/Classes 多文件 PlatformView)
#   结构: QrcodeFlutterPlugin(注册 method channel + view factory) →
#         QRCaptureViewFactory → QRCapturePlatformView → QRCaptureView(AVFoundation 相机)
#   说明: renamer 仅改 static C 函数（此处无），不改 ObjC 类名/selector，故
#         Plugin/Factory/PlatformView/CaptureView 间的跨文件类引用、registerViewFactory
#         withId 字符串、method channel 名均不受影响。L3 死分支为恒假不透明谓词，
#         编译期存在、运行期永不进入，故即使注入到相机捕获代码也不改变扫码行为。
# =============================================

PROFILE_NAME="qrcode_flutter"
PROFILE_VERSION="3"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "QrcodeFlutterPlugin"
    "QRCaptureViewFactory"
    "QRCapturePlatformView"
    "QRCaptureView"
    "registerWithRegistrar"
    "handleMethodCall"
    "readQRCodeFromImage"
    "initWithRegistrar"
    "createWithFrame"
    "initWithFrame"
    "view"
    "pause"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "qrcode_flutter")
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
