#!/bin/bash

# ============================================================
# 生成 secondary 图片 Base64 映射文件
# 输出: lib/modules/secondary/generate/secondary_image_base64_map.dart
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="${1:-$PROJECT_ROOT/assets/secondary}"
OUTPUT_FILE="${2:-$PROJECT_ROOT/lib/modules/secondary/generate/secondary_image_base64_map.dart}"

log_info()    { echo -e "\033[0;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

if [[ ! -d "$TARGET_DIR" ]]; then
  log_error "图片目录不存在: $TARGET_DIR"
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

tmp_data_file="$(mktemp)"
tmp_name_seen_file="$(mktemp)"
tmp_path_seen_file="$(mktemp)"
trap 'rm -f "$tmp_data_file" "$tmp_name_seen_file" "$tmp_path_seen_file"' EXIT

total_count=0
duplicate_count=0
duplicate_path_count=0

# FNV-1a（63 位掩码，保证正数）哈希，供 map key 脱敏使用。
# 必须与 write_base64_support_darts.sh 中的 Dart 实现保持完全一致。
fnv1a() {
  python3 - "$1" << 'PY'
import sys
MASK = 0x7FFFFFFFFFFFFFFF
PRIME = 0x100000001b3
h = 0xcbf29ce484222325 & MASK
for b in sys.argv[1].encode('utf-8'):
    h ^= b
    h = (h * PRIME) & MASK
sys.stdout.write('k%x' % h)
PY
}

log_info "扫描图片目录: $TARGET_DIR"
# 策略：除 SVG / SVGA 外，所有栅格图一律编入 Base64 map（与 sync_secondary.sh
# delete_secondary_image_files 删除范围对齐）。SVG/SVGA 仍以文件形式保留在 bundle。
# lottie/ 下图片也会进 map；是否从磁盘删除由 sync 的 delete 步骤决定（默认保留 lottie 文件，
# 避免 Lottie JSON 按相对路径加载失败）。

while IFS= read -r -d '' file; do
  rel_path="${file#$PROJECT_ROOT/}"
  file_name="$(basename "$file")"

  # 防重：极端情况下（大小写匹配/软链/重复输入）同一路径可能被重复扫描。
  if grep -Fxq -- "$rel_path" "$tmp_path_seen_file" 2>/dev/null; then
    duplicate_path_count=$((duplicate_path_count + 1))
    continue
  fi
  echo "$rel_path" >> "$tmp_path_seen_file"

  # 读取并转换成单行 base64
  b64="$(base64 < "$file" | tr -d '\n')"

  # 文件名可能重复，重复时自动加序号，避免 map key 冲突
  key_name="$file_name"
  if grep -Fxq -- "$file_name" "$tmp_name_seen_file" 2>/dev/null; then
    duplicate_count=$((duplicate_count + 1))
    idx=1
    while grep -Fxq -- "${file_name}__${idx}" "$tmp_name_seen_file" 2>/dev/null; do
      idx=$((idx + 1))
    done
    key_name="${file_name}__${idx}"
  fi
  echo "$key_name" >> "$tmp_name_seen_file"

  # 使用分隔符保存中间数据，避免直接拼接巨量字符串
  printf '%s|%s|%s\n' "$rel_path" "$key_name" "$b64" >> "$tmp_data_file"
  total_count=$((total_count + 1))
done < <(find "$TARGET_DIR" -type f \( \
  -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \
  -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.bmp" \
  -o -iname "*.ico" -o -iname "*.heic" \
  -o -iname "*.tif" -o -iname "*.tiff" \
\) -print0)

if [[ "$total_count" -eq 0 ]]; then
  log_warning "未发现图片，跳过生成"
  exit 0
fi

{
  echo "// GENERATED CODE - DO NOT MODIFY BY HAND."
  echo "// 由 scripts/generate_secondary_base64_map.sh 自动生成"
  echo ""
  echo "class SecondaryImageBase64Map {"
  echo "  /// key: FNV-1a 哈希后的 assets 相对路径（脱敏，避免明文业务资源名进入二进制）"
  echo "  static const Map<String, String> byPath = {"
  while IFS='|' read -r rel_path key_name b64; do
    printf "    '%s': '%s',\n" "$(fnv1a "$rel_path")" "$b64"
  done < "$tmp_data_file"
  echo "  };"
  echo ""
  echo "  /// key: FNV-1a 哈希后的图片文件名"
  echo "  static const Map<String, String> byName = {"
  while IFS='|' read -r rel_path key_name b64; do
    printf "    '%s': '%s',\n" "$(fnv1a "$key_name")" "$b64"
  done < "$tmp_data_file"
  echo "  };"
  echo ""
  echo "  /// 与 write_base64_support_darts.sh 中的 _fnv1a 保持一致。"
  echo "  static String _h(String s) {"
  echo "    var hash = 0xcbf29ce484222325 & 0x7FFFFFFFFFFFFFFF;"
  echo "    for (final unit in s.codeUnits) {"
  echo "      hash ^= unit;"
  echo "      hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;"
  echo "    }"
  echo "    return 'k\${hash.toRadixString(16)}';"
  echo "  }"
  echo ""
  echo "  static String? getByPath(String path) => byPath[_h(path)];"
  echo "  static String? getByName(String name) => byName[_h(name)];"
  echo "}"
} > "$OUTPUT_FILE"

log_success "Base64 映射文件已生成: $OUTPUT_FILE"
log_info "图片总数: $total_count"
if [[ "$duplicate_count" -gt 0 ]]; then
  log_warning "检测到重名文件: $duplicate_count 个（byName 已自动追加 __序号）"
fi
if [[ "$duplicate_path_count" -gt 0 ]]; then
  log_warning "检测到重复路径输入: $duplicate_path_count 个（已去重处理）"
fi

# 写入 secondary_image_base64_ext.dart（与映射配套；BaseHHImage 由 sync --replace-image-entry 写入）
if [[ -f "$SCRIPT_DIR/write_base64_support_darts.sh" ]]; then
  bash "$SCRIPT_DIR/write_base64_support_darts.sh" "$PROJECT_ROOT" ext-only
fi
