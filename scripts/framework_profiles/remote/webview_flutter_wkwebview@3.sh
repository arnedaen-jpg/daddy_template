#!/bin/bash
# =============================================
#   Profile: webview_flutter_wkwebview (远程依赖，传递依赖)
#   版本: 3.x (Swift, darwin/SPM 结构, 43 个源文件)
#   iOS 源文件:
#     darwin/webview_flutter_wkwebview/Sources/webview_flutter_wkwebview/
#       WebViewFlutterPlugin.swift       # 主插件
#       ProxyAPIRegistrar.swift          # API 注册
#       WebKitLibrary.g.swift            ← Pigeon 生成，不可修改
#       *ProxyAPIDelegate.swift          # 各种代理 (20+ 文件)
#       FlutterViewFactory.swift
#       FlutterAssetManager.swift
#       ...
#
#   Status: draft
#   特点: 大型 Swift 插件，43 个源文件，L1 效果显著
# =============================================

PROFILE_NAME="webview_flutter_wkwebview"
PROFILE_VERSION="3"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "WebViewFlutterPlugin"
    "WebViewFlutterWKWebViewExternalAPI"
    "ProxyAPIRegistrar"
    "FlutterViewFactory"
    "register"
    "handle"
    "create"
    "pigeonRegistrar"
)

PROFILE_SKIP_FILES=(
    "WebKitLibrary.g.swift"
)

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "webview_flutter_wkwebview")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            local fname; fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do [[ "$fname" == "$sf" ]] && skip=true && break; done
            [[ "$skip" == "true" ]] && continue
            bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -maxdepth 1 -name "*.swift" -type f 2>/dev/null)
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            local fname; fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do [[ "$fname" == "$sf" ]] && skip=true && break; done
            [[ "$skip" == "true" ]] && continue
            bt_reorder_swift_methods "$f"
        done < <(find "$src_dir" -maxdepth 1 -name "*.swift" -type f 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            local fname; fname=$(basename "$f")
            local skip=false
            for sf in "${PROFILE_SKIP_FILES[@]}"; do [[ "$fname" == "$sf" ]] && skip=true && break; done
            [[ "$skip" == "true" ]] && continue
            bt_inject_swift_dead_branches "$f"
        done < <(find "$src_dir" -maxdepth 1 -name "*.swift" -type f 2>/dev/null)
    fi
}
