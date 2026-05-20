#!/bin/bash
#
# 域名列表加密脚本
# 将明文 domain_fallback.json 加密为 domain_fallback.enc
# 加密后的文件需手动上传到 CDN，供存量 app 动态更新域名列表
#
# 使用方法：
#   ./scripts/encrypt_domains.sh                    # 加密并输出到 config/output/
#   ./scripts/encrypt_domains.sh --check            # 验证加密/解密是否正确
#   ./scripts/encrypt_domains.sh --gen-key          # 生成随机密钥
#   ./scripts/encrypt_domains.sh --gen-bytes FILE   # 输出文件中域名的 Dart 字节数组
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

INPUT_FILE="$PROJECT_DIR/config/domain_fallback.json"
OUTPUT_DIR="$PROJECT_DIR/config/output"
OUTPUT_FILE="$OUTPUT_DIR/domain_fallback.enc"

# ============================================================
# AES-256-CBC 密钥和 IV（十六进制）
# 必须与 lib/services/domain_manager.dart 中的 _aesKeyBytes / _aesIvBytes 保持一致
# 每个项目应使用不同的密钥，通过 create_ab_project.sh 生成时替换
# ============================================================
AES_KEY_HEX="5a65757354656d706c61746544656661756c744145534b657932303235212121"
AES_IV_HEX="5a65757344656661756c744956212121"

print_usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  (无参数)            加密域名列表文件，输出到 config/output/"
    echo "  --check             验证加密/解密是否正确"
    echo "  --gen-key           生成随机密钥和 IV"
    echo "  --gen-bytes [FILE]  输出域名的 Dart 字节数组（用于硬编码到 s.dart）"
    echo "  -h, --help          显示帮助信息"
    echo ""
    echo "加密后的文件需手动上传到 CDN 对应的 URL"
}

gen_random_key() {
    echo "=== 生成随机 AES-256-CBC 密钥 ==="
    echo ""
    local new_key=$(openssl rand -hex 32)
    local new_iv=$(openssl rand -hex 16)
    echo "AES_KEY_HEX=\"$new_key\""
    echo "AES_IV_HEX=\"$new_iv\""
    echo ""
    echo "Dart 字节数组:"
    echo ""

    echo -n "Key bytes: ["
    for ((i=0; i<${#new_key}; i+=2)); do
        local byte_hex="${new_key:$i:2}"
        local byte_dec=$((16#$byte_hex))
        if [ $i -gt 0 ]; then echo -n ", "; fi
        echo -n "$byte_dec"
    done
    echo "]"

    echo -n "IV bytes:  ["
    for ((i=0; i<${#new_iv}; i+=2)); do
        local byte_hex="${new_iv:$i:2}"
        local byte_dec=$((16#$byte_hex))
        if [ $i -gt 0 ]; then echo -n ", "; fi
        echo -n "$byte_dec"
    done
    echo "]"
    echo ""
    echo "请将以上值替换到 encrypt_domains.sh 和 domain_manager.dart 中"
}

gen_dart_bytes() {
    local file="${1:-$INPUT_FILE}"
    if [ ! -f "$file" ]; then
        echo "错误: 找不到输入文件: $file"
        exit 1
    fi

    echo "=== 生成 Dart 字节数组（用于 s.dart fallbackDomainBytes） ==="
    echo ""
    echo "static const List<List<int>> fallbackDomainBytes = <List<int>>["

    # 从 JSON 中提取 domains 数组
    python3 -c "
import json, sys
with open('$file') as f:
    data = json.load(f)
for domain in data.get('domains', []):
    bs = list(domain.encode('utf-8'))
    print(f'    <int>[{\",\".join(str(b) for b in bs)}],')
"
    echo "];"
}

do_encrypt() {
    if [ ! -f "$INPUT_FILE" ]; then
        echo "错误: 找不到输入文件: $INPUT_FILE"
        exit 1
    fi

    # 验证 JSON 格式
    if ! python3 -m json.tool "$INPUT_FILE" > /dev/null 2>&1; then
        echo "错误: 输入文件不是有效的 JSON 格式"
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR"

    # AES-256-CBC 加密，无盐值，Base64 编码
    openssl enc -aes-256-cbc \
        -in "$INPUT_FILE" \
        -K "$AES_KEY_HEX" \
        -iv "$AES_IV_HEX" \
        -base64 \
        -nosalt \
        > "$OUTPUT_FILE"

    echo "✓ 加密成功: $OUTPUT_FILE"
    echo ""
    echo "文件大小: $(wc -c < "$OUTPUT_FILE" | tr -d ' ') bytes"
    echo ""
    echo "后续操作:"
    echo "  请将 $OUTPUT_FILE 上传到 CDN 对应的 URL"
}

do_check() {
    if [ ! -f "$OUTPUT_FILE" ]; then
        echo "错误: 加密文件不存在，请先运行加密: $0"
        exit 1
    fi

    echo "=== 验证加密/解密 ==="
    echo ""
    echo "原始内容:"
    cat "$INPUT_FILE"
    echo ""

    echo "解密结果:"
    openssl enc -aes-256-cbc -d \
        -in "$OUTPUT_FILE" \
        -K "$AES_KEY_HEX" \
        -iv "$AES_IV_HEX" \
        -base64 \
        -nosalt
    echo ""

    # 比较
    local original=$(cat "$INPUT_FILE")
    local decrypted=$(openssl enc -aes-256-cbc -d \
        -in "$OUTPUT_FILE" \
        -K "$AES_KEY_HEX" \
        -iv "$AES_IV_HEX" \
        -base64 \
        -nosalt 2>/dev/null)

    if [ "$original" = "$decrypted" ]; then
        echo "✓ 验证通过: 解密内容与原始内容一致"
    else
        echo "✗ 验证失败: 解密内容与原始内容不一致"
        exit 1
    fi
}

case "${1:-}" in
    --check)
        do_check
        ;;
    --gen-key)
        gen_random_key
        ;;
    --gen-bytes)
        gen_dart_bytes "${2:-}"
        ;;
    -h|--help)
        print_usage
        ;;
    "")
        do_encrypt
        ;;
    *)
        echo "未知选项: $1"
        print_usage
        exit 1
        ;;
esac
