#!/bin/bash
# sync_xmsport_obs_to_formal.sh（文件名历史兼容）
# 将 XMSport 各环境 CONF_OBS_URL / CONF_HUAWEI_URL 对齐 Formal 华为 OBS 体系
# （与 Configs/Formal|Test|Preview|Dev.xcconfig 原始分工一致）：
#
#   Formal OBS/HUAWEI → .../cdn/app_prod.json  (bfw-pic-new0111.cn-south-1)
#   Test    HUAWEI    → .../cdn/app_test.json  (bfw-btd-pic-new0111)
#   Preview HUAWEI    → .../cdn/app_beta.json
#   Dev     HUAWEI    → .../cdn/app_dev.json
#   非正式 CONF_OBS_URL 仍指向正式 app_prod.json（与 XMSport 历史注释一致）
#
# 用法:
#   ./scripts/sync_xmsport_cdn_from_dqiu.sh -p /path/to/XMSport
#   ./scripts/sync_xmsport_cdn_from_dqiu.sh -p /path/to/XMSport -d
#
set -euo pipefail

XMSPORT_DIR=""
DRY_RUN=0

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--path) XMSPORT_DIR="$(cd "$2" && pwd)"; shift 2;;
    -p=*|--path=*) XMSPORT_DIR="$(cd "${1#*=}" && pwd)"; shift;;
    -d|--dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数: $1"; usage; exit 1;;
  esac
done

if [[ -z "$XMSPORT_DIR" ]]; then
  for cand in \
    "/Users/t-yh/XMSport" \
    "$HOME/XMSport" \
    "$(pwd)/XMSport"
  do
    if [[ -d "$cand/Configs" ]]; then
      XMSPORT_DIR="$cand"
      break
    fi
  done
fi

if [[ -z "$XMSPORT_DIR" || ! -d "$XMSPORT_DIR/Configs" ]]; then
  echo "错误: 未找到 XMSport（需含 Configs/）。请传 -p /path/to/XMSport"
  exit 1
fi

CONFIG_DIR="$XMSPORT_DIR/Configs"
esc() { printf 'https:/$()/%s' "${1#https://}"; }

PROD_OBS="$(esc "https://bfw-pic-new0111.obs.cn-south-1.myhuaweicloud.com/cdn/app_prod.json")"
TEST_HW="$(esc "https://bfw-btd-pic-new0111.obs.ap-southeast-1.myhuaweicloud.com:443/cdn/app_test.json")"
BETA_HW="$(esc "https://bfw-btd-pic-new0111.obs.ap-southeast-1.myhuaweicloud.com:443/cdn/app_beta.json")"
DEV_HW="$(esc "https://bfw-btd-pic-new0111.obs.ap-southeast-1.myhuaweicloud.com:443/cdn/app_dev.json")"

patch_file() {
  local file="$1"
  local obs_url="$2"
  local huawei_url="$3"

  if [[ ! -f "$file" ]]; then
    echo "跳过（不存在）: $file"
    return 0
  fi

  python3 - "$file" "$obs_url" "$huawei_url" "$DRY_RUN" <<'PY'
import re, sys
path, obs, huawei, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
text = open(path, encoding="utf-8").read()
orig = text

def repl_key(key, url, s):
    pat = re.compile(rf'^({re.escape(key)}\s*=\s*")[^"]*(")\s*$', re.M)
    if not pat.search(s):
        print(f"  ! 未找到 {key} in {path}")
        return s
    return pat.sub(rf'\1{url}\2', s)

text = repl_key("CONF_OBS_URL", obs, text)
text = repl_key("CONF_HUAWEI_URL", huawei, text)
if text == orig:
    print(f"无变化: {path}")
else:
    print(f"{'dry-run 将更新' if dry else '已更新'}: {path}")
    print(f"  CONF_OBS_URL    = \"{obs}\"")
    print(f"  CONF_HUAWEI_URL = \"{huawei}\"")
    if not dry:
        open(path, "w", encoding="utf-8").write(text)
PY
}

echo "XMSport: $XMSPORT_DIR"
[[ "$DRY_RUN" == "1" ]] && echo "(dry-run)"

patch_file "$CONFIG_DIR/Formal.xcconfig"  "$PROD_OBS" "$PROD_OBS"
patch_file "$CONFIG_DIR/Test.xcconfig"    "$PROD_OBS" "$TEST_HW"
patch_file "$CONFIG_DIR/Preview.xcconfig" "$PROD_OBS" "$BETA_HW"
patch_file "$CONFIG_DIR/Dev.xcconfig"     "$PROD_OBS" "$DEV_HW"

echo "完成"
