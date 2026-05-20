#!/bin/bash

# ============================================================
# 从模板初始化 pubspec.yaml
# 用于刚 clone 项目或需要重置 pubspec.yaml 时
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

TEMPLATE_FILE="$PROJECT_ROOT/pubspec.yaml.template"
TARGET_FILE="$PROJECT_ROOT/pubspec.yaml"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo -e "${RED}[ERROR]${NC} 模板文件不存在: $TEMPLATE_FILE"
    exit 1
fi

if [[ -f "$TARGET_FILE" ]]; then
    echo -e "${YELLOW}[WARNING]${NC} pubspec.yaml 已存在，是否覆盖? (y/N)"
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "已取消"
        exit 0
    fi
fi

cp "$TEMPLATE_FILE" "$TARGET_FILE"
echo -e "${GREEN}[SUCCESS]${NC} 已从模板初始化 pubspec.yaml"

# 运行 flutter pub get
echo ""
echo "正在运行 flutter pub get..."
cd "$PROJECT_ROOT"
if command -v fvm &> /dev/null; then
    fvm flutter pub get
else
    flutter pub get
fi

echo ""
echo -e "${GREEN}[SUCCESS]${NC} 初始化完成！"
