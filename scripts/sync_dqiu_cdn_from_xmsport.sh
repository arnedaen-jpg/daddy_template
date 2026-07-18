#!/bin/bash
# sync_dqiu_cdn_from_xmsport.sh
# 将 dqiu（B 面）CDN 拉源对齐 XMSport CONF_HUAWEI_URL / CONF_OBS_URL：
#
#   正式: https://bfw-pic-new0111.obs.cn-south-1.myhuaweicloud.com/cdn/app_prod.json
#   测试: https://bfw-btd-pic-new0111.obs.ap-southeast-1.myhuaweicloud.com:443/cdn/app_test.json
#   预发: https://bfw-btd-pic-new0111.obs.ap-southeast-1.myhuaweicloud.com:443/cdn/app_beta.json
#
# 会改：
#   - **/xx_domain_manager.dart 的 pullDomainFromCDN URL 选择
#   - **/encrypt_strings.dart 的 string_obs 注释与明文模板（若仍被引用）
#
# 用法:
#   ./scripts/sync_dqiu_cdn_from_xmsport.sh -p /Users/t-yh/dqiu
#   ./scripts/sync_dqiu_cdn_from_xmsport.sh -p /Users/t-yh/watchsport -d
#
set -euo pipefail

TARGET_DIR=""
DRY_RUN=0

PROD_URL="https://bfw-pic-new0111.obs.cn-south-1.myhuaweicloud.com/cdn/app_prod.json"
TEST_URL="https://bfw-btd-pic-new0111.obs.ap-southeast-1.myhuaweicloud.com:443/cdn/app_test.json"
BETA_URL="https://bfw-btd-pic-new0111.obs.ap-southeast-1.myhuaweicloud.com:443/cdn/app_beta.json"
# string_obs 单模板无法表达「测/预发不同主机」，保留正式主机 + app_#.json 作兜底注释
OBS_TEMPLATE="https://bfw-pic-new0111.obs.cn-south-1.myhuaweicloud.com/cdn/app_#.json"

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--path) TARGET_DIR="$(cd "$2" && pwd)"; shift 2;;
    -p=*|--path=*) TARGET_DIR="$(cd "${1#*=}" && pwd)"; shift;;
    -d|--dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数: $1"; usage; exit 1;;
  esac
done

if [[ -z "$TARGET_DIR" ]]; then
  for cand in \
    "/Users/t-yh/dqiu" \
    "/Users/t-yh/dqiu/xty" \
    "/Users/t-yh/watchsport" \
    "$HOME/dqiu" \
    "$(pwd)/dqiu"
  do
    if [[ -d "$cand" ]] && find "$cand" -name 'xx_domain_manager.dart' -print -quit 2>/dev/null | grep -q .; then
      TARGET_DIR="$cand"
      break
    fi
  done
fi

if [[ -z "$TARGET_DIR" || ! -d "$TARGET_DIR" ]]; then
  echo "错误: 未找到 dqiu/B 面工程。请传 -p /path/to/dqiu（或 watchsport）"
  exit 1
fi

echo "目标目录: $TARGET_DIR"
[[ "$DRY_RUN" == "1" ]] && echo "(dry-run)"

# ---- patch xx_domain_manager.dart pullDomainFromCDN ----
while IFS= read -r -d '' mgr; do
  python3 - "$mgr" "$PROD_URL" "$TEST_URL" "$BETA_URL" "$DRY_RUN" <<'PY'
import re, sys
path, prod, test, beta, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
text = open(path, encoding="utf-8").read()
orig = text

# Replace the URL assignment block inside pullDomainFromCDN
pat = re.compile(
    r"(void\s+pullDomainFromCDN\s*\(\s*\)\s*async\s*\{.*?)"
    r"(String\s+urlStr\s*;\s*)"
    r"(if\s*\(\s*isTestModel\s*\(\s*\)\s*\)\s*\{.*?)"
    r"(else\s*if\s*\(\s*isBetaModel\s*\(\s*\)\s*\)\s*\{.*?)"
    r"(else\s*\{.*?)"
    r"(String\?\s+result\s*=\s*await\s+HttpManager\.requestCDNData\(urlStr\);)",
    re.S,
)

def repl(m):
    head, _decl = m.group(1), m.group(2)
    return (
        f"{head}"
        f"String urlStr;\n"
        f"    if (isTestModel()) {{\n"
        f"      urlStr = \"{test}\";\n"
        f"    }} else if (isBetaModel()) {{\n"
        f"      urlStr = \"{beta}\";\n"
        f"    }} else {{\n"
        f"      urlStr = \"{prod}\";\n"
        f"    }}\n"
        f"    {m.group(6)}"
    )

new, n = pat.subn(repl, text, count=1)
if n == 0:
    print(f"  ! 未匹配 pullDomainFromCDN 块: {path}")
else:
    print(f"{'dry-run 将更新' if dry else '已更新'} pullDomainFromCDN: {path}")
    print(f"  test → {test}")
    print(f"  beta → {beta}")
    print(f"  prod → {prod}")
    if not dry and new != orig:
        open(path, "w", encoding="utf-8").write(new)
PY
done < <(find "$TARGET_DIR" -name 'xx_domain_manager.dart' -print0 2>/dev/null)

# ---- patch encrypt_strings.dart string_obs comment / plaintext fallback ----
while IFS= read -r -d '' enc; do
  python3 - "$enc" "$OBS_TEMPLATE" "$DRY_RUN" <<'PY'
import re, sys
path, tmpl, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
text = open(path, encoding="utf-8").read()
orig = text

# Prefer replacing whole string_obs line with plaintext (avoid re-encrypting)
pat = re.compile(
    r"^(\s*static\s+String\s+string_obs\s*=\s*)([^;]+)(;\s*//\s*)(https?://\S+)?\s*$",
    re.M,
)

def repl(m):
    return f'{m.group(1)}"{tmpl}"{m.group(3)}{tmpl}'

new, n = pat.subn(repl, text, count=1)
if n == 0:
    # try comment-only update next to string_obs
    pat2 = re.compile(
        r"(static\s+String\s+string_obs\s*=\s*EncryptionUtils\.decrypt\([^;]+;\s*//\s*)(https?://\S+)"
    )
    new, n = pat2.subn(rf"\g<1>{tmpl}", text, count=1)
    if n == 0:
        print(f"  ! 未匹配 string_obs: {path}")
    else:
        print(f"{'dry-run 将更新' if dry else '已更新'} string_obs 注释: {path}")
        print(f"  → {tmpl}")
        if not dry:
            open(path, "w", encoding="utf-8").write(new)
else:
    print(f"{'dry-run 将更新' if dry else '已更新'} string_obs 为明文模板: {path}")
    print(f"  → {tmpl}")
    if not dry and new != orig:
        open(path, "w", encoding="utf-8").write(new)
PY
done < <(find "$TARGET_DIR" -name 'encrypt_strings.dart' -print0 2>/dev/null)

echo "完成"
echo "提示: XMSport 测/预发 btd OBS 若仍返回 PWNED，需运维修复对应 json；正式 app_prod.json 当前可用。"
