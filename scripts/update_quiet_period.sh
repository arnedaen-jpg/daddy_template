#!/bin/bash
# 兼容入口：已重命名为 update_silent_period.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update_silent_period.sh" "$@"
