#!/bin/bash
# build_and_resign.sh - 使用重签技术从源码构建 IPA
# 结合 build_flutter_ipa.sh 和 resign_ipa.sh 的功能

set -e
set -u
set -o pipefail

# ========== 颜色输出 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========== 帮助信息 ==========
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <flutter_project_path>

从源码构建 Flutter IPA 并使用 cert/ 目录的证书重签名。

OPTIONS:
    -p, --profile <path>    指定 mobileprovision 文件路径 (默认: cert/adhoc.mobileprovision)
    -c, --cert <path>       指定 p12 证书文件路径 (默认: cert/adhoc.p12)
    -i, --identity <name>   签名身份名称 (默认: 从证书自动检测)
    -o, --output <path>     输出 IPA 路径 (默认: <project_name>_resigned.ipa)
    -b, --bundle-id <id>    覆盖 Bundle ID (可选)
    --password <pwd>        p12 证书密码 (默认: 空)
    --no-clean              跳过 flutter clean
    --debug                 构建 debug 版本 (默认: release)
    -h, --help              显示帮助

EXAMPLES:
    # 基本用法 - 使用默认 cert/adhoc 证书
    $0 /Users/yuanli/git/md-android-client

    # 指定输出路径
    $0 -o ~/Desktop/myapp.ipa /Users/yuanli/git/md-android-client

    # 指定其他证书和 profile
    $0 -p cert/development.mobileprovision -c cert/development.p12 /path/to/project

    # 覆盖 Bundle ID
    $0 -b com.example.newbundleid /path/to/project

EOF
    exit 0
}

# ========== 参数解析 ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERT_DIR="$PROJECT_ROOT/cert"

# 默认值
PROFILE_PATH="$CERT_DIR/adhoc.mobileprovision"
CERT_PATH="$CERT_DIR/adhoc.p12"
CERT_PASSWORD=""
IDENTITY=""
OUTPUT_IPA=""
BUNDLE_ID_OVERRIDE=""
FLUTTER_PROJECT=""
NO_CLEAN=false
BUILD_MODE="release"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profile)
            PROFILE_PATH="$2"
            shift 2
            ;;
        -c|--cert)
            CERT_PATH="$2"
            shift 2
            ;;
        -i|--identity)
            IDENTITY="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_IPA="$2"
            shift 2
            ;;
        -b|--bundle-id)
            BUNDLE_ID_OVERRIDE="$2"
            shift 2
            ;;
        --password)
            CERT_PASSWORD="$2"
            shift 2
            ;;
        --no-clean)
            NO_CLEAN=true
            shift
            ;;
        --debug)
            BUILD_MODE="debug"
            shift
            ;;
        -h|--help)
            show_help
            ;;
        -*)
            log_error "未知选项: $1"
            show_help
            ;;
        *)
            FLUTTER_PROJECT="$1"
            shift
            ;;
    esac
done

# ========== 验证参数 ==========
if [[ -z "$FLUTTER_PROJECT" ]]; then
    log_error "请指定 Flutter 工程路径"
    show_help
fi

# 解析绝对路径
if [[ ! "$FLUTTER_PROJECT" = /* ]]; then
    FLUTTER_PROJECT="$(cd "$FLUTTER_PROJECT" 2>/dev/null && pwd)" || {
        log_error "Flutter 工程路径不存在: $FLUTTER_PROJECT"
        exit 1
    }
fi

if [[ ! -f "$FLUTTER_PROJECT/pubspec.yaml" ]]; then
    log_error "未找到 Flutter 工程: $FLUTTER_PROJECT/pubspec.yaml"
    exit 1
fi

if [[ ! -f "$PROFILE_PATH" ]]; then
    log_error "Provisioning profile 不存在: $PROFILE_PATH"
    exit 1
fi

# ========== 获取项目名称 ==========
PROJECT_NAME=$(basename "$FLUTTER_PROJECT")
if [[ -z "$OUTPUT_IPA" ]]; then
    OUTPUT_IPA="$FLUTTER_PROJECT/${PROJECT_NAME}_resigned.ipa"
fi

# ========== 解析 Provisioning Profile ==========
log_info "解析 Provisioning Profile..."

# 提取 profile 信息
PROFILE_PLIST=$(mktemp)
security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST" 2>/dev/null || {
    log_error "无法解析 provisioning profile: $PROFILE_PATH"
    rm -f "$PROFILE_PLIST"
    exit 1
}

# 提取 entitlements
ENTITLEMENTS_PLIST=$(mktemp)
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$PROFILE_PLIST" > "$ENTITLEMENTS_PLIST"

# 提取 Bundle ID 和 Team ID
FULL_APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST")
TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST")
PROFILE_BUNDLE_ID=${FULL_APP_ID#$TEAM_ID.}
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST" 2>/dev/null || echo "Unknown")

log_info "Profile Name: $PROFILE_NAME"
log_info "Team ID: $TEAM_ID"
log_info "Profile Bundle ID: $PROFILE_BUNDLE_ID"

# 确定最终使用的 Bundle ID
if [[ -n "$BUNDLE_ID_OVERRIDE" ]]; then
    TARGET_BUNDLE_ID="$BUNDLE_ID_OVERRIDE"
    log_info "使用覆盖的 Bundle ID: $TARGET_BUNDLE_ID"
else
    TARGET_BUNDLE_ID="$PROFILE_BUNDLE_ID"
fi

# ========== 导入证书 (如果提供) ==========
if [[ -f "$CERT_PATH" ]]; then
    log_info "导入证书: $CERT_PATH"
    if [[ -n "$CERT_PASSWORD" ]]; then
        security import "$CERT_PATH" -k login.keychain -P "$CERT_PASSWORD" -A 2>/dev/null || true
    else
        security import "$CERT_PATH" -k login.keychain -A 2>/dev/null || true
    fi
fi

# ========== 检测签名身份 ==========
if [[ -z "$IDENTITY" ]]; then
    log_info "自动检测签名身份..."
    # 尝试找到与 Team ID 匹配的 Apple Distribution 证书
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Distribution" | grep "$TEAM_ID" | head -1 | sed 's/.*"\(.*\)"/\1/' || echo "")
    
    if [[ -z "$IDENTITY" ]]; then
        # 回退: 尝试找任意 Apple Distribution 证书
        IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Distribution" | head -1 | sed 's/.*"\(.*\)"/\1/' || echo "")
    fi
    
    if [[ -z "$IDENTITY" ]]; then
        # 再回退: 尝试找 iPhone Distribution 证书
        IDENTITY=$(security find-identity -v -p codesigning | grep "iPhone Distribution" | head -1 | sed 's/.*"\(.*\)"/\1/' || echo "")
    fi
    
    if [[ -z "$IDENTITY" ]]; then
        log_error "无法找到有效的签名身份，请使用 -i 参数指定"
        log_info "可用的签名身份:"
        security find-identity -v -p codesigning
        rm -f "$PROFILE_PLIST" "$ENTITLEMENTS_PLIST"
        exit 1
    fi
fi

log_info "签名身份: $IDENTITY"

# ========== 配置回显 ==========
echo ""
echo "========================================"
echo "构建配置"
echo "========================================"
echo "Flutter 工程: $FLUTTER_PROJECT"
echo "构建模式:     $BUILD_MODE"
echo "Profile:      $PROFILE_PATH"
echo "证书:         $CERT_PATH"
echo "签名身份:     $IDENTITY"
echo "Bundle ID:    $TARGET_BUNDLE_ID"
echo "Team ID:      $TEAM_ID"
echo "输出路径:     $OUTPUT_IPA"
echo "========================================"
echo ""

# ========== 构建 Flutter iOS ==========
cd "$FLUTTER_PROJECT"
IOS_DIR="$FLUTTER_PROJECT/ios"

if [[ ! -d "$IOS_DIR" ]]; then
    log_error "未找到 ios 目录: $IOS_DIR"
    rm -f "$PROFILE_PLIST" "$ENTITLEMENTS_PLIST"
    exit 1
fi

# Clean (如果需要)
if [[ "$NO_CLEAN" != true ]]; then
    log_info "清理 Flutter 工程..."
    fvm flutter clean || flutter clean
fi

# 获取依赖
log_info "获取 Flutter 依赖..."
fvm flutter pub get || flutter pub get

# Pod install
log_info "安装 CocoaPods 依赖..."
cd "$IOS_DIR"
pod install --repo-update || pod install || true

# 构建 iOS (不签名)
log_info "构建 Flutter iOS ($BUILD_MODE, 无签名)..."
cd "$FLUTTER_PROJECT"

# 使用 --no-codesign 构建
fvm flutter build ios --$BUILD_MODE --no-codesign || flutter build ios --$BUILD_MODE --no-codesign

# ========== 查找 .app 文件 ==========
log_info "查找构建产物..."

# Flutter 构建产物路径
if [[ "$BUILD_MODE" == "debug" ]]; then
    APP_BUILD_DIR="$FLUTTER_PROJECT/build/ios/iphonesimulator"
else
    APP_BUILD_DIR="$FLUTTER_PROJECT/build/ios/iphoneos"
fi

# 查找 .app
APP_PATH=""
if [[ -d "$APP_BUILD_DIR" ]]; then
    APP_PATH=$(find "$APP_BUILD_DIR" -maxdepth 1 -name "*.app" -type d | head -1)
fi

# 如果没找到，尝试其他路径
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    APP_PATH=$(find "$FLUTTER_PROJECT/build/ios" -name "*.app" -type d 2>/dev/null | head -1)
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    log_error "未找到构建的 .app 文件"
    log_info "请检查 $FLUTTER_PROJECT/build/ios 目录"
    rm -f "$PROFILE_PLIST" "$ENTITLEMENTS_PLIST"
    exit 1
fi

log_info "找到 App: $APP_PATH"
APP_NAME=$(basename "$APP_PATH")

# ========== 重签名流程 ==========
log_info "开始重签名..."

# 创建临时目录
TEMP_DIR=$(mktemp -d)
log_info "工作目录: $TEMP_DIR"

# 复制 .app 到临时目录
PAYLOAD_DIR="$TEMP_DIR/Payload"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"

WORKING_APP="$PAYLOAD_DIR/$APP_NAME"

# 1. 更新 Info.plist 中的 Bundle ID
CURRENT_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$WORKING_APP/Info.plist" 2>/dev/null || echo "")
log_info "当前 Bundle ID: $CURRENT_BUNDLE_ID"

if [[ "$CURRENT_BUNDLE_ID" != "$TARGET_BUNDLE_ID" ]]; then
    log_info "更新 Bundle ID 为: $TARGET_BUNDLE_ID"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TARGET_BUNDLE_ID" "$WORKING_APP/Info.plist"
fi

# 1.5 (可选) 成品包混淆：资源指纹差异化 / Mach-O 符号混淆（改写后本脚本重签名）
#   ZT_IPA_OBFUSCATE=1 启用；ZT_IPA_MACHO=1 额外开 Mach-O；ZT_IPA_SEED 指定 seed
if [[ "${ZT_IPA_OBFUSCATE:-0}" == "1" ]]; then
    OBF_SCRIPT="$SCRIPT_DIR/obfuscate_ipa.sh"
    if [[ -f "$OBF_SCRIPT" ]]; then
        OBF_SEED="${ZT_IPA_SEED:-$TARGET_BUNDLE_ID}"
        OBF_ARGS=(--app "$WORKING_APP" --seed "$OBF_SEED" --resources)
        [[ "${ZT_IPA_MACHO:-0}" == "1" ]] && OBF_ARGS+=(--macho)
        log_info "成品包混淆 (seed=$OBF_SEED, macho=${ZT_IPA_MACHO:-0})..."
        bash "$OBF_SCRIPT" "${OBF_ARGS[@]}" || log_warning "成品包混淆失败，继续重签名"
    else
        log_warning "未找到 $OBF_SCRIPT，跳过成品包混淆"
    fi
fi

# 2. 删除旧签名
log_info "删除旧签名..."
rm -rf "$WORKING_APP/_CodeSignature"

# 3. 复制 provisioning profile
log_info "嵌入 Provisioning Profile..."
cp "$PROFILE_PATH" "$WORKING_APP/embedded.mobileprovision"

# 4. 签名 Frameworks
if [[ -d "$WORKING_APP/Frameworks" ]]; then
    log_info "签名 Frameworks..."
    find "$WORKING_APP/Frameworks" -depth \( -name "*.framework" -o -name "*.dylib" \) | while read -r FRAMEWORK; do
        log_info "  签名: $(basename "$FRAMEWORK")"
        /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$FRAMEWORK"
    done
fi

# 5. 签名 PlugIns (如果存在)
if [[ -d "$WORKING_APP/PlugIns" ]]; then
    log_info "签名 PlugIns..."
    find "$WORKING_APP/PlugIns" -depth -name "*.appex" | while read -r PLUGIN; do
        log_info "  签名: $(basename "$PLUGIN")"
        /usr/bin/codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS_PLIST" --timestamp=none "$PLUGIN"
    done
fi

# 6. 签名主 App
log_info "签名主 App..."
/usr/bin/codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS_PLIST" --timestamp=none "$WORKING_APP"

# 7. 打包 IPA
log_info "打包 IPA..."
cd "$TEMP_DIR"
zip -qr "app.ipa" Payload

# 移动到输出路径
mkdir -p "$(dirname "$OUTPUT_IPA")"
mv "app.ipa" "$OUTPUT_IPA"

# ========== 清理 ==========
rm -rf "$TEMP_DIR"
rm -f "$PROFILE_PLIST" "$ENTITLEMENTS_PLIST"

# ========== 完成 ==========
echo ""
echo "========================================"
log_success "构建完成!"
echo "========================================"
echo "输出文件: $OUTPUT_IPA"
echo "文件大小: $(ls -lh "$OUTPUT_IPA" | awk '{print $5}')"
echo "========================================"

# 验证签名
log_info "验证签名..."
codesign -vv "$OUTPUT_IPA" 2>&1 || true
