#!/bin/bash
# =============================================
#   Profile: screen_brightness_ios (remote, renamed)
#   Version: 2.x (Swift, ios/SPM structure)
#
#   Strategy:
#     - Keep Flutter registration, lifecycle hooks, and stream handlers public.
#     - Rename private Swift helpers and allow top-level Swift block reordering.
#     - Scrub high-signal podspec/SPM metadata that still names the original package.
# =============================================

PROFILE_NAME="screen_brightness_ios"
PROFILE_VERSION="2"
PROFILE_STATUS="draft"

PROFILE_PROTECTED=(
    "TreatyColumnPlugin"
    "ScreenBrightnessIosPlugin"
    "SwiftScreenBrightnessIosPlugin"
    "BaseStreamHandler"
    "ScreenBrightnessChangedStreamHandler"
    "registerWithRegistrar"
    "register"
    "handle"
    "onListen"
    "onCancel"
    "addScreenBrightnessToEventSink"
    "applicationWillResignActive"
    "applicationDidBecomeActive"
    "applicationWillTerminate"
    "detachFromEngine"
)

PROFILE_SKIP_FILES=(
    "Package.swift"
)

_profile_should_skip_file() {
    local file="$1"
    if command -v bt_is_non_runtime_path >/dev/null 2>&1 && bt_is_non_runtime_path "$file"; then
        return 0
    fi
    case "$file" in
        */Tests/*|*/RunnerTests/*|*/test/*|*/tests/*|*/example/*|*/examples/*|*/integration_test/*|*/test_driver/*)
            return 0
            ;;
    esac
    local fname
    fname=$(basename "$file")
    for sf in "${PROFILE_SKIP_FILES[@]}"; do
        [[ "$fname" == "$sf" ]] && return 0
    done
    return 1
}

_profile_scrub_metadata() {
    local plugin_dir="$1"
    local current
    current="${_PROFILE_CURRENT_NAME:-$(basename "$plugin_dir")}"

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "    [metadata] screen_brightness_ios -> $current" || true
        return 0
    fi

    local podspec
    podspec=$(find "$plugin_dir" -name "*.podspec" \( -path "*/ios/*" -o -path "*/darwin/*" \) -print -quit 2>/dev/null)
    if [[ -f "$podspec" ]]; then
        sed -i '' \
            -e "s|screen_brightness_ios\.podspec|${current}.podspec|g" \
            -e "s|The iOS federated plugin implementation of the screen_brightness\.|A Flutter platform adapter.|g" \
            -e "s|https://github.com/aaassseee/screen_brightness|https://example.com/${current}|g" \
            -e "s|Jack Liu|Core Team|g" \
            -e "s|ywp033319@gmail.com|team@example.com|g" \
            -e "s|screen_brightness_ios_privacy|${current}_privacy|g" \
            "$podspec" 2>/dev/null || true
    fi

    local package_file
    package_file=$(find "$plugin_dir" -name "Package.swift" \( -path "*/ios/*" -o -path "*/darwin/*" \) -print -quit 2>/dev/null)
    if [[ -f "$package_file" ]]; then
        sed -i '' \
            -e "s|screen-brightness-ios|${current}|g" \
            "$package_file" 2>/dev/null || true
    fi

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        _profile_should_skip_file "$f" && continue
        sed -i '' \
            -e "s|//  screen_brightness|//  ${current}|g" \
            "$f" 2>/dev/null || true
    done < <(find "$plugin_dir" -name "*.swift" -type f 2>/dev/null)
}

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "screen_brightness_ios")
    [[ -z "$src_dir" ]] && return 1

    _profile_scrub_metadata "$plugin_dir"
    bt_inject_classes "$src_dir" "$PROFILE_NAME" 8

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_rename_swift_privates "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            file_has_preprocessor_blocks "$f" && continue
            bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_reorder_swift_methods "$f"
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)

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
            bt_inject_swift_dead_branches "$f" 10
        done < <(find "$src_dir" -name "*.swift" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _profile_should_skip_file "$f" && continue
            bt_inject_dead_branches "$f" 8
        done < <(find "$src_dir" -name "*.m" -type f ! -name "${INJECT_PREFIX}*" 2>/dev/null)
    fi
}
