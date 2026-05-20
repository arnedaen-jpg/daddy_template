#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DRY_RUN=false
[[ "${1:-}" == "-d" || "${1:-}" == "--dry-run" ]] && DRY_RUN=true

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
step()  { echo -e "${GREEN}[→]${NC} $*"; }

if $DRY_RUN; then
  warn "Dry-run mode — no changes will be made"
  echo
fi

# 1. 删除 assets/secondary
if [ -d "assets/secondary" ]; then
  step "删除 assets/secondary/"
  $DRY_RUN || rm -rf assets/secondary
else
  info "assets/secondary/ 不存在，跳过"
fi

# 2. 删除 backups
if [ -d "backups" ]; then
  step "删除 backups/"
  $DRY_RUN || rm -rf backups
else
  info "backups/ 不存在，跳过"
fi

# 3. 删除 build
if [ -d "build" ]; then
  step "删除 build/"
  $DRY_RUN || rm -rf build
else
  info "build/ 不存在，跳过"
fi

# 4. 删除 plugins
if [ -d "plugins" ]; then
  step "删除 plugins/"
  $DRY_RUN || rm -rf plugins
else
  info "plugins/ 不存在，跳过"
fi

# 5. 删除 lib/modules/secondary
if [ -d "lib/modules/secondary" ]; then
  step "删除 lib/modules/secondary/"
  $DRY_RUN || rm -rf lib/modules/secondary
else
  info "lib/modules/secondary/ 不存在，跳过"
fi

# 6. 删除 flutter_base（仅 md 项目）
if [ -d "flutter_base" ]; then
  step "删除 flutter_base/"
  $DRY_RUN || rm -rf flutter_base
else
  info "flutter_base/ 不存在，跳过"
fi

# 7. 删除 lib/utils 下 Base64 支持文件（若存在）
for f in "lib/utils/base_hh_image.dart" "lib/utils/secondary_image_base64_ext.dart"; do
  if [ -f "$f" ]; then
    step "删除 $f"
    $DRY_RUN || rm -f "$f"
  else
    info "$f 不存在，跳过"
  fi
done

# 8. 撤销所有 unstaged 修改（含未跟踪文件不处理，仅 restore 已跟踪文件的修改）
UNSTAGED=$(git diff --name-only 2>/dev/null || true)
if [ -n "$UNSTAGED" ]; then
  step "撤销 unstaged 修改："
  echo "$UNSTAGED" | sed 's/^/       /'
  $DRY_RUN || git checkout -- .
else
  info "没有 unstaged 修改"
fi

echo
info "清理完成"
