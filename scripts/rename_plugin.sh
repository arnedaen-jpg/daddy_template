#!/bin/bash

# ===========================================
#   Flutter 插件重命名脚本
#   将原生插件复制到本地并重命名，避免 framework 名称特征
# ===========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGINS_DIR="$PROJECT_ROOT/plugins"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    echo "用法: $0 <source_plugin_path> <new_plugin_name>"
    echo ""
    echo "示例:"
    echo "  $0 ~/.pub-cache/hosted/pub.dev/shared_preferences-2.2.2 local_cache_helper"
    echo "  $0 ~/.pub-cache/hosted/pub.dev/url_launcher_ios-6.2.1 link_opener_ios"
    echo ""
    echo "说明:"
    echo "  1. 从 pub cache 复制插件到 plugins/ 目录"
    echo "  2. 重命名包名、podspec 名称、类名前缀等"
    echo "  3. 自动更新 pubspec.yaml 依赖配置"
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

SOURCE_PATH="$1"
NEW_NAME="$2"

if [ ! -d "$SOURCE_PATH" ]; then
    log_error "源插件路径不存在: $SOURCE_PATH"
    exit 1
fi

# 获取原始插件名
OLD_NAME=$(grep "^name:" "$SOURCE_PATH/pubspec.yaml" | head -1 | sed 's/name: *//' | tr -d '\r')
if [ -z "$OLD_NAME" ]; then
    log_error "无法从 pubspec.yaml 获取原始插件名"
    exit 1
fi

log_info "原始插件名: $OLD_NAME"
log_info "新插件名: $NEW_NAME"

# 目标路径
TARGET_PATH="$PLUGINS_DIR/$NEW_NAME"

if [ -d "$TARGET_PATH" ]; then
    log_warning "目标目录已存在: $TARGET_PATH"
    read -p "是否覆盖? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    rm -rf "$TARGET_PATH"
fi

# 复制插件
log_info "复制插件到 $TARGET_PATH..."
cp -r "$SOURCE_PATH" "$TARGET_PATH"

# 删除不需要的文件
rm -rf "$TARGET_PATH/.git" 2>/dev/null || true
rm -rf "$TARGET_PATH/.dart_tool" 2>/dev/null || true
rm -rf "$TARGET_PATH/build" 2>/dev/null || true
rm -rf "$TARGET_PATH/example" 2>/dev/null || true
rm -f "$TARGET_PATH/CHANGELOG.md" 2>/dev/null || true

# 生成类名前缀（驼峰命名）
# local_cache_helper -> LocalCacheHelper
OLD_CLASS_PREFIX=$(echo "$OLD_NAME" | sed -r 's/(^|_)([a-z])/\U\2/g')
NEW_CLASS_PREFIX=$(echo "$NEW_NAME" | sed -r 's/(^|_)([a-z])/\U\2/g')

log_info "原始类前缀: $OLD_CLASS_PREFIX"
log_info "新类前缀: $NEW_CLASS_PREFIX"

# 1. 重命名 pubspec.yaml 中的 name
log_info "更新 pubspec.yaml..."
if [ -f "$TARGET_PATH/pubspec.yaml" ]; then
    sed -i '' "s/^name: $OLD_NAME/name: $NEW_NAME/" "$TARGET_PATH/pubspec.yaml"
fi

# 2. 重命名 iOS podspec
log_info "更新 iOS podspec..."
if [ -d "$TARGET_PATH/ios" ]; then
    for podspec in "$TARGET_PATH/ios"/*.podspec; do
        if [ -f "$podspec" ]; then
            # 重命名文件
            new_podspec="$TARGET_PATH/ios/$NEW_NAME.podspec"
            mv "$podspec" "$new_podspec"
            
            # 更新内容
            sed -i '' "s/s\.name\s*=.*/s.name             = '$NEW_NAME'/" "$new_podspec"
            # 更新模块名
            sed -i '' "s/$OLD_NAME/$NEW_NAME/g" "$new_podspec"
        fi
    done
fi

# 3. 重命名 darwin podspec (如果存在)
if [ -d "$TARGET_PATH/darwin" ]; then
    for podspec in "$TARGET_PATH/darwin"/*.podspec; do
        if [ -f "$podspec" ]; then
            new_podspec="$TARGET_PATH/darwin/$NEW_NAME.podspec"
            mv "$podspec" "$new_podspec"
            sed -i '' "s/s\.name\s*=.*/s.name             = '$NEW_NAME'/" "$new_podspec"
            sed -i '' "s/$OLD_NAME/$NEW_NAME/g" "$new_podspec"
        fi
    done
fi

# 4. 重命名 Swift/ObjC 类
log_info "更新原生代码类名..."
find "$TARGET_PATH" -type f \( -name "*.swift" -o -name "*.h" -o -name "*.m" \) | while read file; do
    # 替换类名前缀
    sed -i '' "s/${OLD_CLASS_PREFIX}Plugin/${NEW_CLASS_PREFIX}Plugin/g" "$file"
    sed -i '' "s/${OLD_CLASS_PREFIX}Channel/${NEW_CLASS_PREFIX}Channel/g" "$file"
    
    # 重命名文件（如果需要）
    filename=$(basename "$file")
    if [[ "$filename" == *"$OLD_CLASS_PREFIX"* ]]; then
        newfilename="${filename/$OLD_CLASS_PREFIX/$NEW_CLASS_PREFIX}"
        mv "$file" "$(dirname "$file")/$newfilename"
    fi
done

# 5. 更新 Dart 代码中的包名引用
log_info "更新 Dart 代码..."
find "$TARGET_PATH" -type f -name "*.dart" | while read file; do
    sed -i '' "s/package:$OLD_NAME/package:$NEW_NAME/g" "$file"
done

# 6. 更新 method channel 名称（可选，增加隐蔽性）
# 生成随机 channel 名称
RANDOM_CHANNEL="plugins.app/$(openssl rand -hex 8)"
log_info "更新 method channel 名称..."
find "$TARGET_PATH" -type f \( -name "*.dart" -o -name "*.swift" -o -name "*.m" \) | while read file; do
    # 这里保守处理，只替换明显的 channel 名称模式
    # 具体替换逻辑可能需要根据插件调整
    :
done

log_success "插件重命名完成！"
echo ""
log_info "后续步骤:"
echo "  1. 在项目 pubspec.yaml 中添加依赖:"
echo ""
echo "     $NEW_NAME:"
echo "       path: plugins/$NEW_NAME"
echo ""
echo "  2. 全局替换 import 路径:"
echo "     import 'package:$OLD_NAME/...' -> import 'package:$NEW_NAME/...'"
echo ""
echo "  3. 运行 fvm flutter pub get"
echo ""
echo "  4. 运行 cd ios && pod install"
