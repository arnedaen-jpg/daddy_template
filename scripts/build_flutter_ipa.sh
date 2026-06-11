#!/bin/bash
# build_flutter_ipa.sh - Flutter iOS 打包脚本
# 参考原生 iOS 打包脚本，适配 Flutter 工程

# ========== 日志到终端与文件 ==========
: "${LOG_FILE:=./build_flutter_ipa.log}"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  exec 3>&1 4>&2
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

echo ">>> build_flutter_ipa.sh starting at $(date '+%F %T')"
echo "bash version: $BASH_VERSION"
echo "pwd: $(pwd)"
echo "argv: $*"

# ========== 严格模式 ==========
set -e
set -u
set -o pipefail
IFS=$'\n\t'
echo ">>> passed strict-mode setup"

# DEBUG=1 时开启命令追踪
if [[ "${DEBUG:-0}" == "1" ]]; then
  set -x
  echo ">>> DEBUG mode enabled"
fi

# ========== 参数 ==========
# 解析可选参数
# SILENT_PERIOD_DAYS: 控制 app_config.dart 中的 silentPeriodDays
#   buildTimestamp 始终更新为当前时间，silentPeriodDays 设为 SILENT_PERIOD_DAYS
#   = 0  → 禁用静默期，AB 接口可直接请求
#   = 1  → 静默期 1 天（从打包时间起 1 天内不请求 AB 接口）
#   = 3  → 默认，静默期 3 天
#   = N  → 自定义 N 天静默期
# 与 --cooldown= 为同一含义（历史兼容参数名）
SILENT_PERIOD_DAYS=3  # 默认 3 天静默期

# 先扫描所有参数，提取可选 flag
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --cooldown=*|--silent=*)
      if [[ "$arg" == --cooldown=* ]]; then
        SILENT_PERIOD_DAYS="${arg#--cooldown=}"
      else
        SILENT_PERIOD_DAYS="${arg#--silent=}"
      fi
      # 校验必须是非负整数
      if ! [[ "$SILENT_PERIOD_DAYS" =~ ^[0-9]+$ ]]; then
        echo "❌ --silent 或 --cooldown 须为非负整数，例如: --silent=0 / --cooldown=3"
        exit 1
      fi
      echo ">>> 静默期 silentPeriodDays 将设为 ${SILENT_PERIOD_DAYS} 天"
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

if [ ${#ARGS[@]} -lt 1 ]; then
  echo "用法: $0 <工作目录，包含 build_config.json> [--silent=N] [--cooldown=N]"
  echo "示例: $0 /Users/dagou/Desktop/appstore/MyFlutterApp"
  echo "  --silent=3 或 --cooldown=3   默认，静默期 3 天（打包后 3 天内不请求 AB 接口）"
  echo "  --silent=1   静默期 1 天"
  echo "  --silent=0   禁用静默期（AB 接口可直接请求）"
  exit 1
fi
WORK_DIR="${ARGS[0]%/}"

# 早期校验
echo ">>> Checking if WORK_DIR exists: $WORK_DIR"
if [[ ! -d "$WORK_DIR" ]]; then
  echo "❌ 提供的 WORK_DIR 不存在: $WORK_DIR"
  exit 1
fi

CONFIG_FILE="$WORK_DIR/build_config.json"
echo ">>> Checking if config file exists: $CONFIG_FILE"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ 未找到配置文件: $CONFIG_FILE"
  exit 1
fi

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ========== JSON 读取 ==========
jget() {
  local key="$1"
  local default="${2:-}"
  echo ">>> Trying to get value for key: $key from config" >&2
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CONFIG_FILE" "$key" "$default" <<'PY'
import json,sys
path=sys.argv[1]; key=sys.argv[2]; default=sys.argv[3] if len(sys.argv)>3 else ""
with open(path,'r',encoding='utf-8') as f:
    data=json.load(f)
cur=data
for part in key.split('.'):
    if isinstance(cur,dict) and part in cur:
        cur=cur[part]
    else:
        cur=None; break
if cur is None:
    print(default)
else:
    if isinstance(cur,(dict,list)):
        print(json.dumps(cur,ensure_ascii=False))
    else:
        print(cur)
PY
    return 0
  elif command -v plutil >/dev/null 2>&1; then
    local val
    if val="$(plutil -extract "$key" raw -o - "$CONFIG_FILE" 2>/dev/null)"; then
      printf '%s\n' "$val"
    else
      printf '%s\n' "$default"
    fi
    return 0
  else
    echo "需要 python3 或 plutil 以解析 JSON" >&2
    exit 1
  fi
}

# 获取配置文件名称（从 mobileprovision 文件提取）
get_profile_name() {
    local profile_path="$1"
    if [[ -f "$profile_path" ]]; then
        local profile_name=$(security cms -D -i "$profile_path" 2>/dev/null | grep -A1 "<key>Name</key>" | grep "<string>" | sed 's/.*<string>//' | sed 's/<\/string>.*//' || echo "")
        if [[ -n "$profile_name" ]]; then
            echo "$profile_name"
        else
            basename "$profile_path" .mobileprovision
        fi
    else
        echo ""
    fi
}

# 更新 iOS 项目签名配置
update_ios_signing() {
    local project_file="$1"
    local new_bundle_id="$2"
    local team_id="$3"
    local signing_style="$4"
    local profile_specifier="$5"
    local code_sign_identity="$6"
    
    if [[ ! -f "$project_file" ]]; then
        echo "❌ project.pbxproj 不存在: $project_file"
        return 1
    fi
    
    echo ">>> 更新 iOS 签名配置..."
    
    # 1. 更新 Bundle Identifier (仅更新主 Target，保留 RunnerTests 后缀)
    if [[ -n "$new_bundle_id" ]]; then
        echo "  - Bundle ID: $new_bundle_id"
        # 先更新主 app bundle id (不包含 .RunnerTests 的行)
        sed -i '' "/RunnerTests/!s/PRODUCT_BUNDLE_IDENTIFIER = [^;]*;/PRODUCT_BUNDLE_IDENTIFIER = $new_bundle_id;/g" "$project_file"
        # 更新 RunnerTests 的 bundle id
        sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER = [^;]*\.RunnerTests;/PRODUCT_BUNDLE_IDENTIFIER = ${new_bundle_id}.RunnerTests;/g" "$project_file"
    fi
    
    # 2. 更新 Team ID
    if [[ -n "$team_id" ]]; then
        echo "  - Team ID: $team_id"
        sed -i '' "s/DEVELOPMENT_TEAM = [^;]*;/DEVELOPMENT_TEAM = $team_id;/g" "$project_file"
    fi
    
    # 3. 更新签名方式 (Manual/Automatic)
    if [[ -n "$signing_style" ]]; then
        local style_value
        if [[ "$signing_style" == "manual" ]]; then
            style_value="Manual"
        else
            style_value="Automatic"
        fi
        echo "  - Signing Style: $style_value"
        # 替换已存在的 CODE_SIGN_STYLE
        sed -i '' "s/CODE_SIGN_STYLE = [^;]*;/CODE_SIGN_STYLE = $style_value;/g" "$project_file"
        # 在没有 CODE_SIGN_STYLE 的 DEVELOPMENT_TEAM 后添加
        # 使用 Python 更可靠地处理
        python3 - "$project_file" "$style_value" <<'PYEOF'
import sys
import re
filepath = sys.argv[1]
style = sys.argv[2]
with open(filepath, 'r') as f:
    content = f.read()
lines = content.split('\n')
result = []
i = 0
while i < len(lines):
    result.append(lines[i])
    # 如果是 DEVELOPMENT_TEAM 行
    if 'DEVELOPMENT_TEAM = ' in lines[i] and i + 1 < len(lines):
        # 检查下一行是否已有 CODE_SIGN_STYLE
        if 'CODE_SIGN_STYLE' not in lines[i + 1]:
            # 获取当前行的缩进
            indent = len(lines[i]) - len(lines[i].lstrip())
            result.append(' ' * indent + f'CODE_SIGN_STYLE = {style};')
    i += 1
with open(filepath, 'w') as f:
    f.write('\n'.join(result))
PYEOF
    fi
    
    # 4. 更新 Code Sign Identity (发布时使用 Apple Distribution)
    if [[ -n "$code_sign_identity" ]]; then
        echo "  - Code Sign Identity: $code_sign_identity"
        python3 - "$project_file" "$code_sign_identity" <<'PYEOF'
import sys
import re
filepath = sys.argv[1]
identity = sys.argv[2]
with open(filepath, 'r') as f:
    content = f.read()
# 替换所有 CODE_SIGN_IDENTITY[sdk=iphoneos*] 的值
pattern = r'"CODE_SIGN_IDENTITY\[sdk=iphoneos\*\]" = "[^"]*"'
replacement = f'"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "{identity}"'
content = re.sub(pattern, replacement, content)
with open(filepath, 'w') as f:
    f.write(content)
PYEOF
    fi
    
    # 5. 更新 Provisioning Profile Specifier (仅手动签名时)
    if [[ "$signing_style" == "manual" && -n "$profile_specifier" ]]; then
        echo "  - Profile Specifier: $profile_specifier"
        # 如果存在则替换，否则添加
        if grep -q "PROVISIONING_PROFILE_SPECIFIER" "$project_file"; then
            sed -i '' "s/PROVISIONING_PROFILE_SPECIFIER = [^;]*;/PROVISIONING_PROFILE_SPECIFIER = \"$profile_specifier\";/g" "$project_file"
        else
            # 在每个 DEVELOPMENT_TEAM 后添加 PROVISIONING_PROFILE_SPECIFIER
            sed -i '' "s/DEVELOPMENT_TEAM = $team_id;/DEVELOPMENT_TEAM = $team_id;\\
				PROVISIONING_PROFILE_SPECIFIER = \"$profile_specifier\";/g" "$project_file"
        fi
    fi
    
    echo "  ✅ 签名配置已更新"
}

# ========== 配置读取 ==========
BUNDLE_ID="$(jget bundle_id "")"
TEAM_ID="$(jget team_id "")"
PROFILE_REL="$(jget profile "appstore.mobileprovision")"
PROFILE_SPECIFIER_OVERRIDE="$(jget profile_specifier "")"
CERT_REL="$(jget certificate "")"
PKEY_REL="$(jget private_key "")"
EXPORT_DIR_REL="$(jget export_dir "ipa")"
EXPORT_METHOD="$(jget export_method "app-store")"
EXPORT_PLIST_REL="$(jget export_options_plist "")"
CODE_SIGN_IDENTITY="$(jget code_sign_identity 'Apple Distribution')"
SIGNING_STYLE="$(jget signing_style manual)"
FLUTTER_BUILD_MODE="$(jget flutter_build_mode "release")"
FLUTTER_PROJECT_REL="$(jget flutter_project "")"

# ========== 路径解析 ==========
is_abs() { [[ "${1:-}" = /* ]]; }
resolve_path() {
  local rel="${1:-}"
  if [[ -z "$rel" ]]; then
    echo ""
  elif is_abs "$rel"; then
    echo "$rel"
  else
    echo "$WORK_DIR/$rel"
  fi
}

PROFILE_PATH="$(resolve_path "$PROFILE_REL")"
CERT_PATH="$(resolve_path "$CERT_REL")"
PKEY_PATH="$(resolve_path "$PKEY_REL")"
EXPORT_DIR="$(resolve_path "$EXPORT_DIR_REL")"
CUSTOM_EXPORT_PLIST="$(resolve_path "$EXPORT_PLIST_REL")"

# Flutter 工程目录
# 如果配置文件指定了 flutter_project，则使用它；否则使用脚本所在目录的父目录
if [[ -n "${FLUTTER_PROJECT_REL:-}" ]]; then
  FLUTTER_PROJECT_DIR="$(resolve_path "$FLUTTER_PROJECT_REL")"
  echo ">>> 使用配置文件指定的 Flutter 工程目录: $FLUTTER_PROJECT_DIR"
else
  FLUTTER_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  echo ">>> 使用默认 Flutter 工程目录: $FLUTTER_PROJECT_DIR"
fi

if [[ ! -f "$FLUTTER_PROJECT_DIR/pubspec.yaml" ]]; then
  echo "❌ 未找到 Flutter 工程: $FLUTTER_PROJECT_DIR/pubspec.yaml"
  exit 1
fi

# Flutter 相关路径
IOS_DIR="$FLUTTER_PROJECT_DIR/ios"
WORKSPACE_PATH="$IOS_DIR/Runner.xcworkspace"
ARCHIVE_PATH="$FLUTTER_PROJECT_DIR/build/ios/archive/Runner.xcarchive"

# ========== 配置回显 ==========
echo ""
echo "---- 配置回显 ----"
echo "WORK_DIR         = $WORK_DIR"
echo "FLUTTER_PROJECT  = $FLUTTER_PROJECT_DIR"
echo "BUNDLE_ID        = $BUNDLE_ID"
echo "TEAM_ID          = $TEAM_ID"
echo "PROFILE          = ${PROFILE_PATH:-<empty>}"
echo "EXPORT_DIR       = $EXPORT_DIR"
echo "EXPORT_METHOD    = $EXPORT_METHOD"
echo "SIGNING_STYLE    = $SIGNING_STYLE"
echo "FLUTTER_MODE     = $FLUTTER_BUILD_MODE"
echo "------------------"
echo ""

# 验证必要参数
if [[ -z "$BUNDLE_ID" ]]; then
  echo "❌ 缺少 bundle_id 配置"
  exit 1
fi
if [[ -z "$TEAM_ID" ]]; then
  echo "❌ 缺少 team_id 配置"
  exit 1
fi

# profile_specifier 优先级
if [[ -n "$PROFILE_SPECIFIER_OVERRIDE" ]]; then
  PROFILE_SPECIFIER="$PROFILE_SPECIFIER_OVERRIDE"
  echo ">>> 使用配置文件中的 profile_specifier: $PROFILE_SPECIFIER"
elif [[ -n "${PROFILE_PATH:-}" && -f "$PROFILE_PATH" ]]; then
  security cms -D -i "$PROFILE_PATH" > /dev/null 2>&1 || { echo "❌ $PROFILE_PATH 不是有效的 mobileprovision 文件"; exit 1; }
  PROFILE_SPECIFIER="$(get_profile_name "$PROFILE_PATH")"
  echo ">>> 从 .mobileprovision 获取 profile_specifier: $PROFILE_SPECIFIER"
else
  PROFILE_SPECIFIER=""
  echo ">>> 未找到 profile，将使用自动签名"
fi

# ========== 证书/描述文件安装 ==========
if [[ -n "${PROFILE_PATH:-}" && -f "$PROFILE_PATH" ]]; then
  echo ">>> 安装描述文件: $PROFILE_PATH"
  PROFILE_UUID="$(security cms -D -i "$PROFILE_PATH" | grep -A1 '<key>UUID</key>' | grep '<string>' | sed 's/.*<string>//' | sed 's/<\/string>.*//' | head -1)"
  PROFILE_NAME="$(security cms -D -i "$PROFILE_PATH" | grep -A1 '<key>Name</key>' | grep '<string>' | sed 's/.*<string>//' | sed 's/<\/string>.*//' | head -1 || echo "")"
  PROF_INSTALL_PATH="$HOME/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.mobileprovision"
  mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
  cp "$PROFILE_PATH" "$PROF_INSTALL_PATH"
  echo "Profile Name: $PROFILE_NAME"
  echo "Profile UUID: $PROFILE_UUID"
fi

if [[ -n "${CERT_PATH:-}" && -f "$CERT_PATH" ]]; then
  echo ">>> 导入分发证书（如已存在可忽略错误）"
  security import "$CERT_PATH" -k login.keychain -A || true
fi

if [[ -n "${PKEY_PATH:-}" && -f "$PKEY_PATH" ]]; then
  echo ">>> 导入私钥（如已存在可忽略错误）"
  security import "$PKEY_PATH" -k login.keychain -A || true
fi

# ========== 生成 ExportOptions.plist ==========
mkdir -p "$EXPORT_DIR"
EXPORT_PLIST="$EXPORT_DIR/ExportOptions.plist"

if [[ -n "${CUSTOM_EXPORT_PLIST:-}" && -f "$CUSTOM_EXPORT_PLIST" ]]; then
  echo ">>> 使用自定义 ExportOptions.plist: $CUSTOM_EXPORT_PLIST"
  cp -f "$CUSTOM_EXPORT_PLIST" "$EXPORT_PLIST"
else
  echo ">>> 生成 ExportOptions.plist"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo '  <key>method</key><string>app-store-connect</string>'
    echo '  <key>signingStyle</key><string>'"$SIGNING_STYLE"'</string>'
    echo '  <key>teamID</key><string>'"$TEAM_ID"'</string>'
    if [[ "$SIGNING_STYLE" == "manual" && -n "${BUNDLE_ID:-}" && -n "${PROFILE_SPECIFIER:-}" ]]; then
      echo '  <key>provisioningProfiles</key><dict>'
      echo '    <key>'"$BUNDLE_ID"'</key><string>'"$PROFILE_SPECIFIER"'</string>'
      echo '  </dict>'
    fi
    echo '  <key>compileBitcode</key><false/>'
    echo '  <key>stripSwiftSymbols</key><true/>'
    echo '  <key>destination</key><string>export</string>'
    echo '</dict></plist>'
  } > "$EXPORT_PLIST"
fi

echo ">>> ExportOptions.plist 内容:"
cat "$EXPORT_PLIST"
echo ""

# ========== Flutter Clean ==========
echo ""
echo "🧹 清理 Flutter 工程..."
echo "========================"
cd "$FLUTTER_PROJECT_DIR"
fvm flutter clean

# ========== Flutter Pub Get ==========
echo ""
echo "📦 获取依赖..."
echo "=============="
fvm flutter pub get

# ========== Pod Install ==========
echo ""
echo "🍫 安装 CocoaPods 依赖..."
echo "========================="
cd "$IOS_DIR"
pod install --repo-update || pod install

# ========== 清理 CocoaPods xcconfig 签名设置 ==========
clean_pods_signing() {
    local pods_dir="$1"
    
    echo ">>> 检查 CocoaPods 签名冲突"
    
    if [[ -d "$pods_dir/Target Support Files" ]]; then
        local cleaned_count=0
        
        while IFS= read -r -d '' file; do
            if grep -q "CODE_SIGN_STYLE = " "$file" 2>/dev/null; then
                echo "  - 清理文件: $(basename "$(dirname "$file")")/$(basename "$file")"
                sed -i '' '/^CODE_SIGN_STYLE = /d' "$file" 2>/dev/null || true
                sed -i '' '/^PROVISIONING_PROFILE_SPECIFIER = /d' "$file" 2>/dev/null || true
                ((cleaned_count++))
            fi
        done < <(find "$pods_dir/Target Support Files" -name "*.release.xcconfig" -print0 2>/dev/null)
        
        if [[ $cleaned_count -gt 0 ]]; then
            echo "  ✅ 已清理 $cleaned_count 个 CocoaPods 配置文件"
        else
            echo "  ✅ CocoaPods 签名设置正常"
        fi
    fi
}

PODS_DIR="$IOS_DIR/Pods"
if [[ -d "$PODS_DIR" ]]; then
    clean_pods_signing "$PODS_DIR"
fi

# ========== 更新 iOS 签名配置 ==========
echo ""
echo "🔧 更新 iOS 签名配置..."
echo "======================="
PROJECT_PBXPROJ="$IOS_DIR/Runner.xcodeproj/project.pbxproj"
update_ios_signing "$PROJECT_PBXPROJ" "$BUNDLE_ID" "$TEAM_ID" "$SIGNING_STYLE" "${PROFILE_SPECIFIER:-}" "$CODE_SIGN_IDENTITY"

# ========== 更新打包时间戳与静默期 ==========
echo ""
echo "🕐 更新打包时间戳与静默期..."
echo "=============================="
APP_CONFIG_FILE="$FLUTTER_PROJECT_DIR/lib/config/app_config.dart"
if [[ -f "$APP_CONFIG_FILE" ]]; then
  # 1. buildTimestamp 始终更新为当前时间（毫秒）
  BUILD_TIMESTAMP=$(python3 -c "import time; print(int(time.time() * 1000))")
  BUILD_DATE=$(date -r $((BUILD_TIMESTAMP / 1000)) '+%Y-%m-%d %H:%M:%S')
  # 兼容有无行尾注释两种格式：
  #   static const int buildTimestamp = 1234567890000;
  #   static const int buildTimestamp = 1234567890000; // 2025-01-17 12:00:00 UTC
  if sed -i '' "s/static const int buildTimestamp = [0-9][0-9]*;[^$]*/static const int buildTimestamp = ${BUILD_TIMESTAMP}; \/\/ ${BUILD_DATE} CST/" "$APP_CONFIG_FILE" 2>/dev/null; then
    echo "  ✅ buildTimestamp 已更新为: ${BUILD_TIMESTAMP}  (${BUILD_DATE} CST)"
  else
    echo "  ⚠️  未能更新 buildTimestamp，请手动检查"
  fi

  # 2. silentPeriodDays：支持新字段；兼容旧项目 quietPeriodDays
  if sed -i '' "s/static const int silentPeriodDays = [0-9][0-9]*;/static const int silentPeriodDays = ${SILENT_PERIOD_DAYS};/" "$APP_CONFIG_FILE" 2>/dev/null; then
    echo "  ✅ silentPeriodDays 已更新为: ${SILENT_PERIOD_DAYS} 天"
  elif sed -i '' "s/static const int quietPeriodDays = [0-9][0-9]*;/static const int silentPeriodDays = ${SILENT_PERIOD_DAYS};/" "$APP_CONFIG_FILE" 2>/dev/null; then
    echo "  ✅ 已从 quietPeriodDays 迁移为 silentPeriodDays: ${SILENT_PERIOD_DAYS} 天"
  else
    echo "  ⚠️  未能更新 silentPeriodDays（可能变量名不符，请手动检查）"
  fi
else
  echo "  ⚠️  未找到 app_config.dart: $APP_CONFIG_FILE"
fi

# ========== 拉取测试/预发/正式环境最新域名快照 ==========
# 参考 XMSport：正式 OBS app_eight.json；测试/预发 unpkg app-dnpkg-test/beta
echo ""
echo "🌐 拉取域名快照（测试/预发/正式，覆盖本地旧域名）..."
echo "====================================================="
if [[ -x "$SCRIPT_DIR/update_domain_snapshots.sh" ]]; then
  "$SCRIPT_DIR/update_domain_snapshots.sh" --project-dir "$FLUTTER_PROJECT_DIR" \
    || echo "  ⚠️  域名快照更新失败（保留旧快照，不影响打包）"
elif [[ -x "$SCRIPT_DIR/update_prod_domains.sh" ]]; then
  "$SCRIPT_DIR/update_prod_domains.sh" --project-dir "$FLUTTER_PROJECT_DIR" \
    || echo "  ⚠️  域名快照更新失败（保留旧快照，不影响打包）"
else
  echo "  ⚠️  未找到 update_domain_snapshots.sh，跳过域名快照更新"
fi

# ========== Flutter Build IPA ==========
echo ""
echo "🔨 构建 Flutter iOS Archive..."
echo "==============================="
cd "$FLUTTER_PROJECT_DIR"

# Flutter build ipa 会生成 archive，然后导出
# 使用 --export-options-plist 指定导出选项
# --obfuscate 启用代码混淆，--split-debug-info 保存符号表用于崩溃日志解析
SYMBOLS_DIR="$FLUTTER_PROJECT_DIR/build/symbols"
mkdir -p "$SYMBOLS_DIR"

# AB 包工厂 / 上架：B 面 String.fromEnvironment('ENVIRONMENT') 固定为 release（与 dq 等模板一致）
# 可选：AB_BUILD_APP_CHANNEL 传入后同时设置 APP_CHANNEL（与 xxChannel 一致）
EXTRA_DEFS=(--dart-define=ENVIRONMENT=release)
if [[ -n "${AB_BUILD_APP_CHANNEL:-}" ]]; then
  EXTRA_DEFS+=(--dart-define=APP_CHANNEL="${AB_BUILD_APP_CHANNEL}")
  echo ">>> dart-define: ENVIRONMENT=release APP_CHANNEL=${AB_BUILD_APP_CHANNEL}"
else
  echo ">>> dart-define: ENVIRONMENT=release（未设置 AB_BUILD_APP_CHANNEL 则沿用源码 defaultValue）"
fi

fvm flutter build ipa \
  --$FLUTTER_BUILD_MODE \
  --obfuscate \
  --split-debug-info="$SYMBOLS_DIR" \
  --export-options-plist="$EXPORT_PLIST" \
  "${EXTRA_DEFS[@]}"

echo ">>> 调试符号已保存到: $SYMBOLS_DIR"

# ========== 检查生成的文件 ==========
echo ""
echo "🎉 构建完成！"
echo "==========="

# Flutter 默认导出目录
FLUTTER_IPA_DIR="$FLUTTER_PROJECT_DIR/build/ios/ipa"

if [[ -d "$FLUTTER_IPA_DIR" ]]; then
  echo "📁 Flutter IPA 目录: $FLUTTER_IPA_DIR"
  if ls "$FLUTTER_IPA_DIR"/*.ipa >/dev/null 2>&1; then
    echo "📱 IPA 文件:"
    ls -lh "$FLUTTER_IPA_DIR"/*.ipa
    
    # 复制到指定的导出目录
    if [[ "$FLUTTER_IPA_DIR" != "$EXPORT_DIR" ]]; then
      echo ""
      echo ">>> 复制 IPA 到指定导出目录: $EXPORT_DIR"
      cp "$FLUTTER_IPA_DIR"/*.ipa "$EXPORT_DIR/"
      ls -lh "$EXPORT_DIR"/*.ipa
    fi
    
    echo ""
    echo "✅ IPA 文件已成功生成到: $EXPORT_DIR"
  else
    echo "⚠️  未找到 IPA 文件"
  fi
else
  echo "❌ Flutter IPA 目录不存在: $FLUTTER_IPA_DIR"
fi

echo ""
echo ">>> build_flutter_ipa.sh finished at $(date '+%F %T')"

