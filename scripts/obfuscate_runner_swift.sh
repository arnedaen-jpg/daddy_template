#!/bin/bash

# ============================================================
# yms Runner Swift 原生轻量混淆
#
# 放在 Dart 代码混淆链路中调用：sync_secondary.sh 先同步原生文件，
# obfuscate_code.sh 再对 Runner Swift 做字符串解码、类名改写和轻量调用栈扰动。
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$SCRIPT_DIR/reports"

CURRENT_PROJECT=""
SEED=""
DRY_RUN=false
VERBOSE=false
REPORT_FILE=""

_RUNNER_NATIVE_FILES=0
_RUNNER_NATIVE_OPS=0
_RUNNER_SWIFT_TEXT_HELPER=""
_RUNNER_SWIFT_HELPER_NEEDED=false
declare -a _RUNNER_NATIVE_TOUCHED
declare -a _RUNNER_NATIVE_DETAILS

WORDS=(
    Anchor Bridge Buffer Cache Channel Cipher Config Core Device Event
    Feature Graph Helper Index Layer Manager Media Module Network Packet
    Policy Profile Queue Router Segment Signal Storage Token Vector Window
    Adapter Builder Collector Dispatcher Engine Kernel Monitor Provider
    Resolver Scanner Session Tracker Worker
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $1"; }

read_ab_config() {
    local key="$1"
    local config_file="$PROJECT_ROOT/ab_config.yaml"
    if [[ -f "$config_file" ]]; then
        grep "^${key}:" "$config_file" | head -1 | sed "s/^${key}: *//" | tr -d '\r\n"'
    fi
}

detect_current_project() {
    local project
    project=$(read_ab_config "project")
    [[ -n "$project" ]] && echo "$project" && return 0
    return 1
}

hash_derive() {
    echo -n "$1" | md5 -q 2>/dev/null || echo -n "$1" | md5sum | cut -d' ' -f1
}

derive_seed() {
    if [[ -n "$SEED" ]]; then
        return
    fi

    local pbxproj="$PROJECT_ROOT/ios/Runner.xcodeproj/project.pbxproj"
    if [[ -f "$pbxproj" ]]; then
        local bundle_id
        bundle_id=$(grep 'PRODUCT_BUNDLE_IDENTIFIER' "$pbxproj" 2>/dev/null | head -1 | sed 's/.*= *//;s/[";]//g;s/ //g')
        if [[ -n "$bundle_id" && "$bundle_id" != *'$'* ]]; then
            SEED="$bundle_id"
            if [[ "$VERBOSE" == "true" ]]; then
                log_info "Seed 来源: Bundle ID ($SEED)"
            fi
            return
        fi
    fi

    local project
    project=$(detect_current_project || true)
    if [[ -n "$project" ]]; then
        SEED="zt_${project}_$(date +%Y%m)"
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "Seed 来源: ab_config project ($SEED)"
        fi
        return
    fi

    SEED="zt_runner_swift"
}

pascal_from_hash() {
    local h="$1"
    local wc=${#WORDS[@]}
    local idx1=$((16#${h:0:4} % wc))
    local idx2=$((16#${h:4:4} % wc))
    local idx3=$((16#${h:8:4} % wc))
    echo "${WORDS[$idx1]}${WORDS[$idx2]}${WORDS[$idx3]}${h:12:2}"
}

identifier_from_hash() {
    local h="$1"
    local wc=${#WORDS[@]}
    local idx1=$((16#${h:0:4} % wc))
    local idx2=$((16#${h:4:4} % wc))
    local w1
    local w2
    w1=$(echo "${WORDS[$idx1]}" | tr '[:upper:]' '[:lower:]')
    w2=$(echo "${WORDS[$idx2]}" | tr '[:upper:]' '[:lower:]')
    echo "${w1}_${w2}_${h:8:4}"
}

runner_native_swift_available() {
    [[ "$CURRENT_PROJECT" == "yms" ]] || return 1
    [[ -f "$PROJECT_ROOT/ios/Runner/AppDelegate.swift" || -f "$PROJECT_ROOT/ios/Runner/BCSKeyChainTool.swift" ]]
}

runner_native_mark_file() {
    local file="$1"
    local existing
    for existing in "${_RUNNER_NATIVE_TOUCHED[@]}"; do
        [[ "$existing" == "$file" ]] && return 0
    done
    _RUNNER_NATIVE_TOUCHED+=("$file")
}

runner_swift_text_helper_name() {
    if [[ -n "$_RUNNER_SWIFT_TEXT_HELPER" ]]; then
        echo "$_RUNNER_SWIFT_TEXT_HELPER"
        return
    fi

    local helper_hash
    helper_hash=$(hash_derive "${SEED}:runner-swift:text-helper")
    _RUNNER_SWIFT_TEXT_HELPER="Native$(pascal_from_hash "$helper_hash")"
    echo "$_RUNNER_SWIFT_TEXT_HELPER"
}

runner_swift_xor_expr() {
    local text="$1"
    local salt="${2:-$1}"
    local helper_name
    helper_name=$(runner_swift_text_helper_name)

    local h
    h=$(hash_derive "${SEED}:runner-swift:string:${salt}:${text}")
    local key=$(( (16#${h:0:2} % 223) + 1 ))
    local bytes=()
    local n
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        bytes+=("$(( n ^ key ))")
    done < <(LC_CTYPE=C printf '%s' "$text" | od -An -tu1 -v | tr -s ' ' '\n' | grep -E '^[0-9]+$')

    local joined=""
    local b
    for b in "${bytes[@]}"; do
        [[ -n "$joined" ]] && joined+=", "
        joined+="$b"
    done

    printf '%s.s([%s], key: 0x%02X)' "$helper_name" "$joined" "$key"
}

runner_swift_replace_exact() {
    local file="$1"
    local from="$2"
    local to="$3"
    local label="${4:-Swift source rewrite}"

    [[ -f "$file" ]] || return 1
    grep -Fq "$from" "$file" 2>/dev/null || return 1

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "  [DRY-RUN] $(basename "$file"): $label"
        fi
    else
        FROM="$from" TO="$to" ruby -e '
          path = ARGV.fetch(0)
          text = File.read(path)
          text = text.gsub(ENV.fetch("FROM"), ENV.fetch("TO"))
          File.write(path, text)
        ' "$file"
    fi

    runner_native_mark_file "$file"
    _RUNNER_NATIVE_OPS=$((_RUNNER_NATIVE_OPS + 1))
    _RUNNER_NATIVE_DETAILS+=("      ~ $(basename "$file"): $label")
    return 0
}

runner_swift_obfuscate_literal() {
    local file="$1"
    local literal="$2"
    local salt="$3"
    local expr
    expr=$(runner_swift_xor_expr "$literal" "$salt")
    if runner_swift_replace_exact "$file" "\"$literal\"" "$expr" "字符串字面量运行时解码"; then
        _RUNNER_SWIFT_HELPER_NEEDED=true
    fi
}

runner_swift_remove_legacy_uuid_comments() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -q 'public var getDevuceUUID:String' "$file" 2>/dev/null || return 0

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "  [DRY-RUN] $(basename "$file"): 移除旧 UUID 注释块"
        fi
    else
        ruby -e '
          path = ARGV.fetch(0)
          text = File.read(path)
          text.gsub!(/\n[ \t]*\/\/[ \t]*public var getDevuceUUID:String\{.*?\n[ \t]*\/\/[ \t]*\}\n[ \t]*\/\/\/本地-UUID/m, "\n    ///本地-UUID")
          File.write(path, text)
        ' "$file"
    fi

    runner_native_mark_file "$file"
    _RUNNER_NATIVE_OPS=$((_RUNNER_NATIVE_OPS + 1))
    _RUNNER_NATIVE_DETAILS+=("      ~ $(basename "$file"): 移除旧 UUID 注释块")
}

runner_swift_insert_text_helper() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -q 'runner-native-text-helper:start' "$file" 2>/dev/null && return 0

    local helper_name
    helper_name=$(runner_swift_text_helper_name)

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "  [DRY-RUN] $(basename "$file"): 插入 Swift 字符串解码 helper ($helper_name)"
        fi
    else
        HELPER_NAME="$helper_name" ruby -e '
          path = ARGV.fetch(0)
          text = File.read(path)
          exit 0 if text.include?("runner-native-text-helper:start")

          helper = <<~SWIFT
          // runner-native-text-helper:start
          private enum #{ENV.fetch("HELPER_NAME")} {
              static func s(_ data: [UInt8], key: UInt8) -> String {
                  let bytes = data.map { $0 ^ key }
                  return String(bytes: bytes, encoding: .utf8) ?? ""
              }
          }
          // runner-native-text-helper:end
          SWIFT

          lines = text.lines
          insert_at = nil
          lines.each_with_index do |line, idx|
            if line.start_with?("import ")
              insert_at = idx + 1
            elsif line.strip.empty?
              next
            else
              break
            end
          end

          if insert_at
            lines.insert(insert_at, "\n#{helper}\n")
            text = lines.join
          else
            text = helper + "\n" + text
          end
          File.write(path, text)
        ' "$file"
    fi

    runner_native_mark_file "$file"
    _RUNNER_NATIVE_OPS=$((_RUNNER_NATIVE_OPS + 1))
    _RUNNER_NATIVE_DETAILS+=("      ~ $(basename "$file"): 插入 Swift 字符串解码 helper")
}

runner_swift_rename_keychain_class() {
    local app_delegate="$1"
    local keychain_file="$2"
    local class_hash
    class_hash=$(hash_derive "${SEED}:runner-swift:keychain-class")
    local new_class="Secure$(pascal_from_hash "$class_hash")"
    local file

    for file in "$app_delegate" "$keychain_file"; do
        [[ -f "$file" ]] || continue
        runner_swift_replace_exact "$file" "BCSKeyChainTool" "$new_class" "Keychain Swift 类名重命名" || true
    done
}

runner_swift_prune_keychain_header() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -q 'Butterfly\|BCSKeyChainTool.swift' "$file" 2>/dev/null || return 0

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "  [DRY-RUN] $(basename "$file"): 移除旧 Keychain 文件头注释"
        fi
    else
        ruby -e '
          path = ARGV.fetch(0)
          text = File.read(path)
          text.sub!(/\A(?:\/\/[^\n]*\n)+\n/, "")
          File.write(path, text)
        ' "$file"
    fi

    runner_native_mark_file "$file"
    _RUNNER_NATIVE_OPS=$((_RUNNER_NATIVE_OPS + 1))
    _RUNNER_NATIVE_DETAILS+=("      ~ $(basename "$file"): 移除旧 Keychain 文件头注释")
}

runner_swift_insert_stack_noise() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -q 'runner-native-mutation:start' "$file" 2>/dev/null && return 0

    local mix_hash warm_hash block_hash
    mix_hash=$(hash_derive "${SEED}:runner-swift:mix-name")
    warm_hash=$(hash_derive "${SEED}:runner-swift:warm-name")
    block_hash=$(hash_derive "${SEED}:runner-swift:block")

    local mix_name warm_name
    mix_name=$(identifier_from_hash "$mix_hash")
    warm_name=$(identifier_from_hash "$warm_hash")

    local c1=$((16#${block_hash:0:8}))
    local c2=$((16#${block_hash:8:8}))
    local c3=$((16#${block_hash:16:8}))
    local c4=$((16#${block_hash:24:8}))
    local defaults_key
    defaults_key=$(runner_swift_xor_expr "runner.native.${block_hash:0:8}" "runner-stack-key")

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "  [DRY-RUN] $(basename "$file"): 注入 Runner 调用栈扰动"
        fi
    else
        MIX_NAME="$mix_name" WARM_NAME="$warm_name" C1="$c1" C2="$c2" C3="$c3" C4="$c4" DEFAULTS_KEY="$defaults_key" ruby -e '
          path = ARGV.fetch(0)
          text = File.read(path)
          exit 0 if text.include?("runner-native-mutation:start")

          mix = ENV.fetch("MIX_NAME")
          warm = ENV.fetch("WARM_NAME")
          block = <<~SWIFT
              // runner-native-mutation:start
              private func #{mix}(_ value: UInt64) -> UInt64 {
                  var state = value ^ UInt64(#{ENV.fetch("C1")})
                  state = (state &* UInt64(#{ENV.fetch("C2")})) ^ (state >> 17)
                  state = (state &+ UInt64(#{ENV.fetch("C3")})) ^ (state << 11)
                  return state ^ UInt64(#{ENV.fetch("C4")})
              }

              private func #{warm}() {
                  if ProcessInfo.processInfo.processorCount > 2048 {
                      let sample = #{mix}(UInt64(ProcessInfo.processInfo.systemUptime))
                      if sample == UInt64(#{ENV.fetch("C4")}) {
                          UserDefaults.standard.set(sample, forKey: #{ENV.fetch("DEFAULTS_KEY")})
                      }
                  }
              }
              // runner-native-mutation:end
          SWIFT

          inserted = text.sub!(/(@objc\s+class\s+AppDelegate:\s+FlutterAppDelegate\s*\{\n)/, "\\1#{block}\n")
          if inserted
            text.sub!(/(\)\s*->\s*Bool\s*\{\n)/, "\\1        #{warm}() // runner-native-mutation-call\n")
          end
          File.write(path, text)
        ' "$file"
    fi

    runner_native_mark_file "$file"
    _RUNNER_SWIFT_HELPER_NEEDED=true
    _RUNNER_NATIVE_OPS=$((_RUNNER_NATIVE_OPS + 1))
    _RUNNER_NATIVE_DETAILS+=("      ~ $(basename "$file"): 注入 Runner 调用栈扰动")
}

obfuscate_runner_swift() {
    _RUNNER_NATIVE_FILES=0
    _RUNNER_NATIVE_OPS=0
    _RUNNER_SWIFT_TEXT_HELPER=""
    _RUNNER_SWIFT_HELPER_NEEDED=false
    _RUNNER_NATIVE_TOUCHED=()
    _RUNNER_NATIVE_DETAILS=()

    runner_native_swift_available || return 0

    local app_delegate="$PROJECT_ROOT/ios/Runner/AppDelegate.swift"
    local keychain_file="$PROJECT_ROOT/ios/Runner/BCSKeyChainTool.swift"

    log_info "ios/Runner [native-swift]: 处理 yms 原生 Swift..."

    if [[ -f "$app_delegate" ]]; then
        runner_swift_remove_legacy_uuid_comments "$app_delegate"

        local literals=(
            "loadinglogo"
            "com.yinse/device"
            "getDeviceId"
            "filePath"
            "getVideoDuration"
            "getVideoResolution"
            "getVideoRatio"
            "getVideoSize"
            "saveCoverInLocal"
            "getVideoBitrate"
            "com.smart.read.app"
            "00000000-0000-0000-0000-000000000000"
            "------------------------------"
            "/Documents/"
        )

        local idx=0
        local literal
        for literal in "${literals[@]}"; do
            idx=$((idx + 1))
            runner_swift_obfuscate_literal "$app_delegate" "$literal" "appdelegate-${idx}"
        done

        local cover_prefix cover_suffix cover_middle cover_from cover_to
        cover_prefix=$(runner_swift_xor_expr "upimg_" "cover-prefix")
        cover_suffix=$(runner_swift_xor_expr ".jpg" "cover-suffix")
        cover_middle='"\(Date().timeIntervalSince1970)"'
        cover_from='"upimg_\(Date().timeIntervalSince1970).jpg"'
        cover_to="${cover_prefix} + ${cover_middle} + ${cover_suffix}"
        if runner_swift_replace_exact "$app_delegate" "$cover_from" "$cover_to" "封面文件名运行时拼接"; then
            _RUNNER_SWIFT_HELPER_NEEDED=true
        fi

        runner_swift_insert_stack_noise "$app_delegate"

        if [[ "$_RUNNER_SWIFT_HELPER_NEEDED" == "true" ]]; then
            runner_swift_insert_text_helper "$app_delegate"
        fi
    fi

    runner_swift_rename_keychain_class "$app_delegate" "$keychain_file"
    runner_swift_prune_keychain_header "$keychain_file"

    _RUNNER_NATIVE_FILES=${#_RUNNER_NATIVE_TOUCHED[@]}
    if [[ $_RUNNER_NATIVE_FILES -gt 0 ]]; then
        local dry_prefix=""
        [[ "$DRY_RUN" == "true" ]] && dry_prefix="[DRY-RUN] "
        log_success "${dry_prefix}ios/Runner [native-swift]: 变换 $_RUNNER_NATIVE_FILES 个文件，$_RUNNER_NATIVE_OPS 项"
    else
        log_info "ios/Runner [native-swift]: 无需变换"
    fi
}

generate_report() {
    [[ "$DRY_RUN" == "true" ]] && return
    [[ $_RUNNER_NATIVE_FILES -gt 0 ]] || return

    mkdir -p "$REPORT_DIR"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local project_tag="${CURRENT_PROJECT:-unknown}"
    REPORT_FILE="$REPORT_DIR/native_swift_${project_tag}_${timestamp}.txt"

    {
        echo "========================================"
        echo "  Runner Swift 原生混淆报告"
        echo "========================================"
        echo ""
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "项目: $project_tag"
        echo "工程: $PROJECT_ROOT"
        echo "Seed: $SEED"
        echo ""
        echo "--- 变更 ---"
        echo "文件: $_RUNNER_NATIVE_FILES"
        echo "操作: $_RUNNER_NATIVE_OPS"
        echo ""
        for entry in "${_RUNNER_NATIVE_DETAILS[@]}"; do
            echo "$entry"
        done
    } > "$REPORT_FILE"

    log_info "Runner Swift 报告已保存: $REPORT_FILE"
}

usage() {
    cat << EOF
Runner Swift 原生混淆

用法: $0 [选项]

选项:
  -p, --project NAME     项目代码；当前仅 yms 生效，默认从 ab_config.yaml 读取
  --seed SEED            指定混淆种子，默认使用 iOS Bundle ID
  -d, --dry-run          模拟运行
  -v, --verbose          详细输出
  -h, --help             显示帮助
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                CURRENT_PROJECT="$2"
                shift 2
                ;;
            --seed)
                SEED="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$CURRENT_PROJECT" ]]; then
        CURRENT_PROJECT=$(detect_current_project || true)
    fi

    if [[ "$CURRENT_PROJECT" != "yms" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "当前项目不是 yms，跳过 Runner Swift 原生混淆"
        fi
        exit 0
    fi

    derive_seed
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Seed: $SEED"
    fi

    log_step "Runner Swift 原生混淆..."
    obfuscate_runner_swift
    generate_report
}

main "$@"
