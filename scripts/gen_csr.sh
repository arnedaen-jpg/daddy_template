#!/bin/bash
# 一键生成 Apple 开发证书 CSR 并导入私钥到钥匙串
# 每次运行自动生成随机 EMAIL/CN/Country，可指定输出目录

# ================= 随机生成函数 =================
# 随机名字池
FIRST_NAMES=("james" "john" "robert" "michael" "david" "william" "richard" "joseph" "thomas" "charles" "emma" "olivia" "ava" "sophia" "isabella" "mia" "charlotte" "amelia" "harper" "evelyn" "daniel" "matthew" "anthony" "mark" "steven" "paul" "andrew" "joshua" "kevin" "brian")
LAST_NAMES=("smith" "johnson" "williams" "brown" "jones" "garcia" "miller" "davis" "rodriguez" "martinez" "wilson" "anderson" "taylor" "thomas" "moore" "jackson" "martin" "lee" "perez" "thompson" "white" "harris" "sanchez" "clark" "lewis")

# 邮箱域名池
EMAIL_DOMAINS=("gmail.com" "yahoo.com" "outlook.com" "hotmail.com" "icloud.com" "protonmail.com" "mail.com" "aol.com" "zoho.com" "fastmail.com")

# 国家代码池 (常见国家)
COUNTRIES=("US" "GB" "CA" "AU" "DE" "FR" "JP" "KR" "SG" "NL" "SE" "NO" "DK" "FI" "CH" "AT" "BE" "IE" "NZ" "IT")

# 随机数生成函数
rand_element() {
  local arr=("$@")
  echo "${arr[$((RANDOM % ${#arr[@]}))]}"
}

# 生成随机字符串 (用于邮箱用户名增加随机性)
rand_suffix() {
  echo $((RANDOM % 9000 + 1000))
}

# ================= 生成随机配置 =================
FIRST=$(rand_element "${FIRST_NAMES[@]}")
LAST=$(rand_element "${LAST_NAMES[@]}")
DOMAIN=$(rand_element "${EMAIL_DOMAINS[@]}")
SUFFIX=$(rand_suffix)

EMAIL="${FIRST}.${LAST}${SUFFIX}@${DOMAIN}"
CN="${FIRST} ${LAST}"
C=$(rand_element "${COUNTRIES[@]}")
KEY_NAME="mykey.key"
CSR_NAME="CertificateSigningRequest.certSigningRequest"
# ============================================

# 检查参数：指定输出目录
if [ -z "$1" ]; then
  echo "用法: $0 <输出目录>"
  exit 1
fi

OUT_DIR="$1"

# 确保输出目录存在
mkdir -p "${OUT_DIR}"

# 文件路径
KEY_PATH="${OUT_DIR}/${KEY_NAME}"
CSR_PATH="${OUT_DIR}/${CSR_NAME}"

echo ">>> 输出目录: ${OUT_DIR}"
echo ">>> 随机生成的配置:"
echo "    Email: ${EMAIL}"
echo "    CN: ${CN}"
echo "    Country: ${C}"

echo ">>> 生成 2048 位 RSA 私钥..."
openssl genrsa -out "${KEY_PATH}" 2048

echo ">>> 生成 CSR 请求文件..."
openssl req -new -key "${KEY_PATH}" \
    -out "${CSR_PATH}" \
    -subj "/emailAddress=${EMAIL}, CN=${CN}, C=${C}"

echo ">>> 导入私钥到钥匙串..."
security import "${KEY_PATH}" \
  -k ~/Library/Keychains/login.keychain-db \
  -P "" -T /usr/bin/codesign -T /usr/bin/security

echo ">>> 完成！"

