#!/bin/bash
# update_silent_period.sh - 更新静默期时间戳（与旧脚本 update_quiet_period.sh 功能相同，仅命名更新）
# 用于手动重置静默期开始时间，无需重新打包

set -e
set -u
set -o pipefail

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_CONFIG_FILE="$PROJECT_DIR/lib/config/app_config.dart"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo ""
echo "🕐 更新静默期时间戳"
echo "===================="

# 检查文件是否存在
if [[ ! -f "$APP_CONFIG_FILE" ]]; then
  echo -e "${RED}❌ 未找到 app_config.dart: $APP_CONFIG_FILE${NC}"
  exit 1
fi

# 读取当前时间戳
CURRENT_TIMESTAMP=$(grep -o 'static const int buildTimestamp = [0-9]*;' "$APP_CONFIG_FILE" | grep -o '[0-9]*')
if [[ -n "$CURRENT_TIMESTAMP" ]]; then
  CURRENT_DATE=$(date -r $((CURRENT_TIMESTAMP / 1000)) '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "无效时间")
  echo "📅 当前时间戳: $CURRENT_TIMESTAMP"
  echo "   对应时间: $CURRENT_DATE"
fi

# 支持自定义时间戳参数
if [[ $# -gt 0 ]]; then
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo ""
    echo "用法: $0 [时间戳(毫秒)]"
    echo ""
    echo "示例:"
    echo "  $0              # 使用当前时间"
    echo "  $0 1737100800000  # 使用指定时间戳"
    echo ""
    echo "说明:"
    echo "  静默期从 buildTimestamp 开始计算，持续 silentPeriodDays 天。"
    echo "  在此期间，应用强制显示主要模式。"
    exit 0
  fi
  NEW_TIMESTAMP="$1"
  echo ""
  echo ">>> 使用指定时间戳: $NEW_TIMESTAMP"
else
  NEW_TIMESTAMP=$(python3 -c "import time; print(int(time.time() * 1000))")
  echo ""
  echo ">>> 使用当前时间"
fi

# 验证时间戳格式
if ! [[ "$NEW_TIMESTAMP" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}❌ 无效的时间戳格式: $NEW_TIMESTAMP${NC}"
  exit 1
fi

# 更新时间戳
if sed -i '' "s/static const int buildTimestamp = [0-9]*;/static const int buildTimestamp = $NEW_TIMESTAMP;/" "$APP_CONFIG_FILE" 2>/dev/null; then
  NEW_DATE=$(date -r $((NEW_TIMESTAMP / 1000)) '+%Y-%m-%d %H:%M:%S')
  echo ""
  echo -e "${GREEN}✅ buildTimestamp 已更新${NC}"
  echo "   新时间戳: $NEW_TIMESTAMP"
  echo "   对应时间: $NEW_DATE"

  # 读取静默期天数
  SP_DAYS=$(grep -o 'static const int silentPeriodDays = [0-9]*;' "$APP_CONFIG_FILE" | grep -o '[0-9]*')
  if [[ -n "$SP_DAYS" && "$SP_DAYS" -gt 0 ]]; then
    END_TIMESTAMP=$((NEW_TIMESTAMP + SP_DAYS * 86400000))
    END_DATE=$(date -r $((END_TIMESTAMP / 1000)) '+%Y-%m-%d %H:%M:%S')
    echo ""
    echo -e "${YELLOW}📌 静默期信息${NC}"
    echo "   静默期天数: $SP_DAYS 天"
    echo "   静默期结束: $END_DATE"
  fi
else
  echo -e "${RED}❌ 未能更新 buildTimestamp，请手动检查${NC}"
  exit 1
fi

echo ""
