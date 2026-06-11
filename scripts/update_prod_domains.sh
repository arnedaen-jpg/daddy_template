#!/bin/bash
# 兼容入口：仅更新正式环境域名快照（内部转调 update_domain_snapshots.sh）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/update_domain_snapshots.sh" "$@"
