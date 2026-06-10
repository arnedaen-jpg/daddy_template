#!/bin/bash
# update_prod_domains.sh - 编译时拉取「正式环境」域名快照
#
# 参考 XMSport 的 Xcode 构建期脚本（UpdateDomain build phase）：
#     curl <OBS_URL> -> base64 -> ScriptGetObsData.json（随包资源）
# 本脚本把「正式环境」最新域名从 OBS 拉下来，原样（base64）写入 Flutter 资源
#     assets/config/prod_domains.b64
# 每次打包前调用，用最新域名覆盖本地旧快照。
#
# 运行时仅「正式环境」读取该快照（见 lib/config/env_config.dart）；
# 解析失败 / 为空时回退到 env_config.dart 中硬编码的 _productionDomainBytes。
#
# 用法:
#   scripts/update_prod_domains.sh [--url <obs_url>] [--out <path>] \
#                                  [--project-dir <dir>] [-d|--dry-run]
#
# 默认 OBS 源可用环境变量覆盖: AB_PROD_OBS_URL
#
# 设计原则：永不让打包失败。拉取/校验失败时保留本地旧快照并以 0 退出。

set -uo pipefail

# 默认 OBS 源（dq 正式环境域名下发，与 XMSport UpdateDomain 同源）
DEFAULT_OBS_URL="https://pic001-prod-new.obs.ap-southeast-1.myhuaweicloud.com/cdn/app_eight.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OBS_URL="${AB_PROD_OBS_URL:-$DEFAULT_OBS_URL}"
OUT_PATH=""
DRY_RUN=0

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) OBS_URL="$2"; shift 2;;
    --url=*) OBS_URL="${1#--url=}"; shift;;
    --out) OUT_PATH="$2"; shift 2;;
    --out=*) OUT_PATH="${1#--out=}"; shift;;
    --project-dir) PROJECT_DIR="$(cd "$2" && pwd)"; shift 2;;
    --project-dir=*) PROJECT_DIR="$(cd "${1#--project-dir=}" && pwd)"; shift;;
    -d|--dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数: $1"; usage; exit 1;;
  esac
done

[[ -z "$OUT_PATH" ]] && OUT_PATH="$PROJECT_DIR/assets/config/prod_domains.b64"

log() { echo "[update_prod_domains] $*"; }

log "OBS URL : $OBS_URL"
log "输出     : $OUT_PATH"
[[ "$DRY_RUN" == "1" ]] && log "(dry-run，不写文件)"

# ===== 拉取（最多重试 3 次）=====
RESPONSE=""
for attempt in 1 2 3; do
  RESPONSE="$(curl -fsSL -m 25 "$OBS_URL" 2>/dev/null || true)"
  [[ -n "$RESPONSE" ]] && break
  log "第 ${attempt}/3 次拉取失败，重试..."
  sleep 2
done

if [[ -z "$RESPONSE" ]]; then
  log "⚠️  拉取失败/响应为空，保留本地旧快照，不覆盖"
  exit 0
fi

# 去除所有空白（curl 输出可能含换行），得到纯 base64
B64="$(printf '%s' "$RESPONSE" | tr -d '[:space:]')"

# ===== 校验：base64 解码后应为含 "domain" 的 JSON =====
DECODED="$(printf '%s' "$B64" | base64 -d 2>/dev/null || true)"
if [[ -z "$DECODED" ]] || ! printf '%s' "$DECODED" | grep -q '"domain"'; then
  log "⚠️  响应不是预期的 base64(JSON)（缺少 domain 字段），保留旧快照，不覆盖"
  log "    响应前 80 字符: ${RESPONSE:0:80}"
  exit 0
fi

# 提取域名仅用于可读日志（不影响写入内容）
DOMAINS_PREVIEW="$(printf '%s' "$DECODED" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); arr=d.get("data") or []
    print(", ".join([x.get("domain","") for x in arr if x.get("domain")]))
except Exception:
    print("")' 2>/dev/null || true)"
log "解析到正式域名: ${DOMAINS_PREVIEW:-<none>}"

if [[ "$DRY_RUN" == "1" ]]; then
  log "dry-run：将写入 ${#B64} 字节 base64 到 $OUT_PATH（已跳过实际写入）"
  exit 0
fi

mkdir -p "$(dirname "$OUT_PATH")"
printf '%s' "$B64" > "$OUT_PATH"
log "✅ 已更新正式环境域名快照（$(wc -c < "$OUT_PATH" | tr -d ' ') 字节）"
