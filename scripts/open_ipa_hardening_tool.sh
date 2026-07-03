#!/bin/bash
# 打开 IPA 成品包混淆独立工具（本地浏览器 UI）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
chmod +x harden_ipa_standalone.sh 2>/dev/null || true
PORT="${1:-8765}"
echo "启动 IPA 加固工具（端口 $PORT）…"
exec python3 "$SCRIPT_DIR/ipa_hardening_server.py" "$PORT"
