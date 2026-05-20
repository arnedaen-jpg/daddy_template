#!/bin/bash
set -euo pipefail

APP_DIR="${1:-}"

if [ -z "$APP_DIR" ]; then
    echo "[ERROR] 请指定工作目录，例如: $0 /Users/User/Documents/apps_info/myapp_aiagent"
    exit 1
fi

CONFIG_FILE="$APP_DIR/build_config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 未找到配置文件: $CONFIG_FILE"
    exit 1
fi

EXPORT_DIR=$(jq -r '.export_dir' "$CONFIG_FILE")
IPA_PATH=$(find "$APP_DIR/$EXPORT_DIR" -name "*.ipa" -type f | head -1)

if [ -z "$IPA_PATH" ]; then
    echo "[ERROR] 未找到 IPA 文件: $APP_DIR/$EXPORT_DIR/*.ipa"
    exit 1
fi

KEY_ID=$(jq -r '.apple_api_key.key_id' "$CONFIG_FILE" | tr -d '[:space:]')
ISSUER_ID=$(jq -r '.apple_api_key.issuer_id' "$CONFIG_FILE" | tr -d '[:space:]')
P8_FILE_REL=$(jq -r '.apple_api_key.p8_file' "$CONFIG_FILE")
P8_FILE="$APP_DIR/$P8_FILE_REL"

PROXY_STR=$(jq -r '.proxy.socks5' "$CONFIG_FILE")

# Handle different proxy formats
# Remove scheme for parsing
CLEAN_PROXY="${PROXY_STR#*://}"

if [[ "$CLEAN_PROXY" == *"@"* ]]; then
    # Format: user:pass@host:port
    PROXY_STR="socks5://$CLEAN_PROXY"
    echo "[INFO] 识别为标准认证格式: $PROXY_STR"
elif [[ "$CLEAN_PROXY" =~ ^[^:]+:[0-9]+:[^:]+:.*$ ]]; then
    # Format: host:port:user:pass (Old format)
    host=$(echo "$CLEAN_PROXY" | cut -d: -f1)
    port=$(echo "$CLEAN_PROXY" | cut -d: -f2)
    user=$(echo "$CLEAN_PROXY" | cut -d: -f3)
    pass=$(echo "$CLEAN_PROXY" | cut -d: -f4-)
    PROXY_STR="socks5://${user}:${pass}@${host}:${port}"
    echo "[INFO] 代理已转换为标准格式: $PROXY_STR"
fi

echo "[INFO] 测试代理..."
curl --max-time 10 --silent --socks5-hostname ${PROXY_STR#*://} https://api.ipify.org?format=json || {
    echo "[ERROR] 代理不可用"
    exit 1
}

# 拷贝 p8 到 altool 可识别目录
ALTOOL_KEY_DIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$ALTOOL_KEY_DIR"
cp -f "$P8_FILE" "$ALTOOL_KEY_DIR/AuthKey_${KEY_ID}.p8"
chmod 600 "$ALTOOL_KEY_DIR/AuthKey_${KEY_ID}.p8"

# 退出时确保清理
cleanup() {
    rm -f "$ALTOOL_KEY_DIR/AuthKey_${KEY_ID}.p8"
    export ALL_PROXY=""
    export http_proxy=""
    export https_proxy=""
    export HTTP_PROXY=""
    export HTTPS_PROXY=""
}
trap cleanup EXIT

# 设置代理
export ALL_PROXY="$PROXY_STR"
export http_proxy="$PROXY_STR"
export https_proxy="$PROXY_STR"
export HTTP_PROXY="$PROXY_STR"
export HTTPS_PROXY="$PROXY_STR"

# ---------- 上传逻辑 with 实时输出 & 重试 ----------
LOG_FILE="$APP_DIR/upload_$(date +%Y%m%d_%H%M%S).log"
MAX_RETRIES=3
RETRY_DELAY=5

for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
    echo "[INFO] 上传尝试次数: $attempt/$MAX_RETRIES ..."
    echo "[INFO] 日志文件路径: $LOG_FILE"
    
    # 临时关闭 set -e 以便手动处理错误
    set +e
    # 使用 tee 实时显示和保存 altool 输出
    xcrun altool --upload-app \
        --type ios \
        --apiKey "$KEY_ID" \
        --apiIssuer "$ISSUER_ID" \
        -f "$IPA_PATH" \
        --output-format xml 2>&1 | tee -a "$LOG_FILE"
    
    PIPE_STATUS=("${PIPESTATUS[@]}")
    ALTOOL_EXIT_CODE=${PIPE_STATUS[0]}
    set -e

    # 检查是否成功：
    # 1. exit code 为 0
    # 2. 日志中没有 "product-errors" (XML 错误标记)
    # 3. 日志中没有 "UPLOAD FAILED" (文本错误标记)
    if [[ $ALTOOL_EXIT_CODE -eq 0 ]] && ! grep -q "product-errors" "$LOG_FILE" && ! grep -q "UPLOAD FAILED" "$LOG_FILE"; then
        echo "[SUCCESS] 上传成功: $IPA_PATH"
        exit 0
    fi

    echo "[ERROR] 上传失败 (Exit Code: $ALTOOL_EXIT_CODE)"

    # 检查是否为网络/SSL错误
    if grep -q "An SSL error has occurred" "$LOG_FILE" || grep -q "secure connection" "$LOG_FILE"; then
        echo "[WARN] 检测到 SSL/网络错误，等待 ${RETRY_DELAY}s 后重试..."
        sleep "$RETRY_DELAY"
        continue
    else
        # 如果是校验错误（Validation failed），重试通常没用，直接退出
        if grep -q "Validation failed" "$LOG_FILE"; then
             echo "[FATAL] 校验失败 (Validation failed)。请检查错误信息并重新打包，无需重试。"
             exit 1
        fi
        
        echo "[WARN] 未知错误，尝试重试..."
        sleep "$RETRY_DELAY"
    fi
done

echo "[FAIL] 已重试 $MAX_RETRIES 次，依然失败。请检查 $LOG_FILE 查看详细日志。"
exit 1

