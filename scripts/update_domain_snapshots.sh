#!/bin/bash
# update_domain_snapshots.sh - 编译时拉取测试 / 预发 / 正式三套环境域名快照
#
# 参考 XMSport Formal.xcconfig UpdateDomain / CONF_OBS_URL：
#   - 正式：https://bfw-pic-new0111.obs.cn-south-1.myhuaweicloud.com/cdn/app_prod.json
#   - 测试：unpkg @hd-team/app-dnpkg-test（base64 JSON）
#   - 预发：unpkg @hd-team/app-dnpkg-beta（base64 JSON）
#
# 写入 Flutter 随包资源（原样 base64）：
#   assets/config/test_domains.b64
#   assets/config/staging_domains.b64
#   assets/config/prod_domains.b64
#
# 用法:
#   scripts/update_domain_snapshots.sh [--project-dir <dir>] [-d|--dry-run]
#
# 环境变量可覆盖默认源：
#   AB_TEST_OBS_URL / AB_STAGING_OBS_URL / AB_PROD_OBS_URL
#
# 设计原则：永不让打包失败。单项拉取失败保留旧快照，以 0 退出。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY_RUN=0

# 默认域名源：正式对齐 XMSport Formal CONF_OBS_URL；测/预发仍用 unpkg
DEFAULT_TEST_URL="https://unpkg.com/@hd-team/app-dnpkg-test@latest"
DEFAULT_STAGING_URL="https://unpkg.com/@hd-team/app-dnpkg-beta@latest"
DEFAULT_PROD_URL="https://bfw-pic-new0111.obs.cn-south-1.myhuaweicloud.com/cdn/app_prod.json"

TEST_URL="${AB_TEST_OBS_URL:-$DEFAULT_TEST_URL}"
STAGING_URL="${AB_STAGING_OBS_URL:-$DEFAULT_STAGING_URL}"
PROD_URL="${AB_PROD_OBS_URL:-$DEFAULT_PROD_URL}"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR="$(cd "$2" && pwd)"; shift 2;;
    --project-dir=*) PROJECT_DIR="$(cd "${1#--project-dir=}" && pwd)"; shift;;
    -d|--dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数: $1"; usage; exit 1;;
  esac
done

CONFIG_DIR="$PROJECT_DIR/assets/config"
mkdir -p "$CONFIG_DIR"

log() { echo "[update_domain_snapshots] $*"; }

# 校验候选 base64：解码后必须是含 "domain" 的 JSON。成功打印解码后的 JSON，失败返回 1。
_decode_if_valid() {
  local candidate="$1"
  local decoded
  decoded="$(printf '%s' "$candidate" | base64 -d 2>/dev/null || true)"
  if [[ -n "$decoded" ]] && printf '%s' "$decoded" | grep -q '"domain"'; then
    printf '%s' "$decoded"
    return 0
  fi
  return 1
}

# 从响应中提取有效的 base64(JSON) 负载，应对 unpkg / npm 多种返回形态：
#   1) 纯 base64 文本（unpkg 直接返回包主文件内容，当前线上形态）
#   2) JS 包装，如 module.exports="<base64>" / export default "<base64>"
#   3) 其它噪声（重定向提示、HTML 等）
# 思路：先整体当 base64；失败则抽取响应里最长的 base64 子串再校验。
# 成功时通过全局变量 EXTRACTED_B64 / EXTRACTED_JSON 返回。
EXTRACTED_B64=""
EXTRACTED_JSON=""
extract_b64_payload() {
  local raw="$1"
  EXTRACTED_B64=""
  EXTRACTED_JSON=""

  # 候选 1：整体去空白后当作 base64
  local whole
  whole="$(printf '%s' "$raw" | tr -d '[:space:]')"
  local decoded
  if decoded="$(_decode_if_valid "$whole")"; then
    EXTRACTED_B64="$whole"
    EXTRACTED_JSON="$decoded"
    return 0
  fi

  # 候选 2：在「去空白后的整串」上抽取最长 base64 子串（JS 包装 / 引号包裹场景，
  # 先去空白可把跨行 base64 拼回单行，再正则提取）
  local longest
  longest="$(printf '%s' "$whole" \
    | grep -oE '[A-Za-z0-9+/]{40,}={0,2}' \
    | awk '{ if (length($0) > maxlen) { maxlen = length($0); val = $0 } } END { if (maxlen > 0) print val }')"
  if [[ -n "$longest" ]]; then
    if decoded="$(_decode_if_valid "$longest")"; then
      EXTRACTED_B64="$longest"
      EXTRACTED_JSON="$decoded"
      return 0
    fi
  fi

  return 1
}

# 拉取一项快照：url → out_path
# 响应可能是纯 base64 或被 JS 包装；统一交给 extract_b64_payload 提取并校验
fetch_one() {
  local label="$1"
  local url="$2"
  local out="$3"

  log "[$label] URL: $url"
  log "[$label] OUT: $out"

  local response=""
  local attempt
  for attempt in 1 2 3; do
    response="$(curl -fsSL -m 25 "$url" 2>/dev/null || true)"
    [[ -n "$response" ]] && break
    log "[$label] 第 ${attempt}/3 次拉取失败，重试..."
    sleep 2
  done

  if [[ -z "$response" ]]; then
    log "[$label] ⚠️  拉取失败/响应为空，保留旧快照"
    return 0
  fi

  if ! extract_b64_payload "$response"; then
    log "[$label] ⚠️  响应中未提取到有效 base64(JSON)（缺少 domain），保留旧快照"
    log "[$label]     响应前 80 字符: ${response:0:80}"
    return 0
  fi

  local preview
  preview="$(printf '%s' "$EXTRACTED_JSON" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); arr=d.get("data") or []
    print(", ".join([x.get("domain","") for x in arr if x.get("domain")]))
except Exception:
    print("")' 2>/dev/null || true)"
  log "[$label] 解析到域名: ${preview:-<none>}"

  # 拒绝明显被篡改的快照（如 OBS 被写成 PWNED / 内网 POC）
  if printf '%s' "$EXTRACTED_JSON" | python3 -c 'import sys,json,re
try:
  d=json.load(sys.stdin)
except Exception:
  sys.exit(1)
msg=str(d.get("msg") or "")
if "PWNED" in msg.upper():
  sys.exit(2)
arr=d.get("data") or []
if not arr:
  sys.exit(3)
bad=0
for x in arr:
  dom=str((x or {}).get("domain") or "")
  if re.search(r"https?://(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)", dom):
    bad += 1
if bad and bad >= len(arr):
  sys.exit(4)
sys.exit(0)' 2>/dev/null; then
    :
  else
    local rc=$?
    log "[$label] ⚠️  快照疑似被篡改/无效 (check=$rc)，保留旧快照"
    return 0
  fi

  # domain 字段单独 base64 映射（与硬编码域名同级；外层仍是 base64(JSON)）
  local mapped_json mapped_b64
  mapped_json="$(printf '%s' "$EXTRACTED_JSON" | python3 -c '
import sys, json, base64
d = json.load(sys.stdin)
for x in d.get("data") or []:
    if not isinstance(x, dict):
        continue
    dom = str(x.get("domain") or "").strip()
    if not dom:
        continue
    if dom.startswith("http://") or dom.startswith("https://"):
        x["domain"] = base64.b64encode(dom.encode()).decode()
    else:
        # 已是映射则校验能解出 http
        try:
            plain = base64.b64decode(dom).decode()
            if plain.startswith("http://") or plain.startswith("https://"):
                x["domain"] = dom
        except Exception:
            pass
json.dump(d, sys.stdout, ensure_ascii=False, separators=(",", ":"))
' 2>/dev/null || true)"

  if [[ -z "$mapped_json" ]]; then
    log "[$label] ⚠️  domain 字段映射失败，保留旧快照"
    return 0
  fi

  mapped_b64="$(printf '%s' "$mapped_json" | python3 -c 'import sys,base64; print(base64.b64encode(sys.stdin.buffer.read()).decode(), end="")')"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "[$label] dry-run：将写入 ${#mapped_b64} 字节（已跳过，domain 已字段级 base64）"
    return 0
  fi

  printf '%s' "$mapped_b64" > "$out"
  log "[$label] ✅ 已更新（$(wc -c < "$out" | tr -d ' ') 字节，domain 字段已 base64 映射）"
}

log "项目目录: $PROJECT_DIR"
[[ "$DRY_RUN" == "1" ]] && log "(dry-run 模式)"

fetch_one "测试" "$TEST_URL" "$CONFIG_DIR/test_domains.b64"
fetch_one "预发" "$STAGING_URL" "$CONFIG_DIR/staging_domains.b64"
fetch_one "正式" "$PROD_URL" "$CONFIG_DIR/prod_domains.b64"

log "全部完成"
