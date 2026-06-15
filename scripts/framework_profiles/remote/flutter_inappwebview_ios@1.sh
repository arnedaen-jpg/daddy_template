#!/bin/bash
# =============================================
#   Profile: flutter_inappwebview_ios (remote, renamed)
#   Version: 1.x (large Swift plugin, ios/Classes layout)
#
#   Strategy:
#     - Keep Flutter registration, public bridge classes, and channel-facing APIs.
#     - Avoid Swift member reordering for this plugin; the source has many nested
#       delegates/extensions and generated JS wrappers.
#     - Apply private symbol rename + dead branches + ObjC class injection.
# =============================================

PROFILE_NAME="flutter_inappwebview_ios"
PROFILE_VERSION="1"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "InAppWebViewFlutterPlugin"
    "SwiftFlutterPlugin"
    "registerWithRegistrar"
    "register"
    "handle"
    "ChannelDelegate"
    "FlutterMethodCallDelegate"
    "FlutterMethodChannel"
    "InAppWebView"
    "WebViewChannelDelegate"
    "JavaScriptBridgeJS"
)

PROFILE_SKIP_FILES=(
    "Package.swift"
)

_profile_should_skip_file() {
    local file="$1"
    local fname
    fname=$(basename "$file")
    for sf in "${PROFILE_SKIP_FILES[@]}"; do
        [[ "$fname" == "$sf" ]] && return 0
    done
    return 1
}

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "flutter_inappwebview_ios")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 10

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            file_has_preprocessor_blocks "$f" && continue
            bt_reorder_objc_methods "$f"
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_inject_swift_dead_branches "$f" 12
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_inject_dead_branches "$f" 8
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi
}
