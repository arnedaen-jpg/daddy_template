#!/bin/bash

# ===========================================
#   Framework 混淆脚本 (Rename + Mutate)
#   Phase 1: 重命名 - 改 framework 名称 (对可重命名的B面插件)
#   Phase 2: 变异 - 注入/修改原生代码 (对 plugins/ 下所有含 iOS 原生代码的插件)
#   Phase 3: 构建 - flutter pub get + pod install
# ===========================================

set -e

# =============================================
# 路径与配置
# =============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGINS_DIR="$PROJECT_ROOT/plugins"
FLUTTER_BASE_DIR="$PROJECT_ROOT/flutter_base"
PODS_DIR="$PROJECT_ROOT/ios/Pods"
MAPPING_FILE="$SCRIPT_DIR/plugin_rename_mapping.conf"
SEMANTIC_WORDS_FILE="$SCRIPT_DIR/semantic_words.conf"

# 变异相关路径与配置
PROFILES_DIR="$SCRIPT_DIR/framework_profiles"
MANIFESTS_DIR="$SCRIPT_DIR/project_manifests"
INJECT_PREFIX="_zt_mutate_"

# 变异参数
SEED=""
VERIFY_AFTER=false
OVERRIDE_CLASSES=0    # 0 = auto
OVERRIDE_STRINGS=0    # 0 = auto
MANIFEST_FILE=""
MANIFEST_LOADED=false
MANIFEST_TMPFILE=""
SKIP_DEP_STRINGS=false

# 注入类名词表（大型，从 semantic_words.conf 加载后合并使用）
# 小型 fallback 仅在 semantic_words.conf 不存在时使用
CLASS_WORDS_FALLBACK=(
    Config Sync Cache Buffer Stream Pipe Task Worker Bridge Adapter
    Handler Manager Provider Factory Engine Module Component Wrapper
    Registry Resolver Dispatcher Scheduler Monitor Tracker Logger
    Serializer Validator Converter Formatter Parser Builder Router
    Session Context State Store Channel Socket Broker Proxy Relay
    Signal Token Queue Stack Pool Chain Filter Mapper Scanner
    Loader Fetcher Reader Writer Encoder Decoder Cipher Digest
    Allocator Analyzer Anchor Assembly Auditor Authority Balancer Beacon
    Binding Blueprint Boundary Bundler Calibrator Canvas Carrier Catalog
    Checkpoint Circuit Classifier Cluster Collector Commander Compiler
    Conductor Connector Console Container Coordinator Counter Courier
    Curator Daemon Delegate Deployer Descriptor Director Discovery
    Distributor Domain Driver Emitter Endpoint Evaluator Executor
    Exporter Explorer Extension Extractor Fabric Facilitator Federation
    Finalizer Firmware Flusher Foundation Fragment Gateway Generator
    Governor Guardian Harvester Hatcher Hierarchy Holder Horizon
    Importer Indexer Indicator Infra Initiator Inspector Instance
    Integrator Interface Interpreter Inventory Invoker Iterator Junction
    Keeper Kernel Launcher Ledger Liaison Lifecycle Limiter Linker
    Listener Locator Manifest Mediator Memory Merger Messenger
    Migrator Mirror Mixer Modulator Monitor Multiplexer Navigator
    Negotiator Notifier Observer Operator Optimizer Oracle Orchestrator
    Organizer Outlet Overseer Packer Partition Patcher Pathway
    Performer Pipeline Planner Platform Plugin Pointer Pooler
    Predictor Preprocessor Presenter Processor Producer Profiler
    Projector Promoter Propagator Protocol Provisioner Publisher
    Purger Qualifier Receptor Reconciler Recorder Reducer Reflector
    Regulator Renderer Replicator Reporter Repository Requester
    Responder Restorer Retriever Runtime Safeguard Sampler Sandbox
    Scaler Sentinel Sequencer Shelter Shifter Simulator Snapshot
    Sorter Spawner Specifier Stabilizer Stacker Stamper Stepper
    Streamer Subscriber Supplier Surveyor Suspender Switcher Synchronizer
    Synthesizer Terminal Throttler Timekeeper Tokenizer Transformer
    Translator Transmitter Traverser Trigger Truncator Tunnel Unifier
    Upgrader Uploader Utilizer Verifier Viewport Watcher Witness
)
declare -a CLASS_WORDS_POOL
declare -a CLASS_WORDS_POOL_LC
CLASS_WORDS_POOL_LOADED=false

# 词库缓存
declare -a WORD_PREFIXES
declare -a WORD_MIDDLES
declare -a WORD_SUFFIXES
WORDS_LOADED=false

# 运行配置
DRY_RUN=false
VERBOSE=false
PUB_CACHE_DIR=""
GENERATE_MAPPING=false
CURRENT_PROJECT=""
OBFUSCATE_RATIO=100
AUTO_DETECT_PLATFORM=true
CLEAN_ONLY=false
_IN_RUN_ALL=false

# 报告文件
REPORT_DIR="$SCRIPT_DIR/reports"
REPORT_FILE=""

# 运行时收集的报告数据（全局，跨 phase 累积）
declare -a _REPORT_RENAME_ENTRIES   # "old_name → new_name"
declare -a _REPORT_MUTATE_ENTRIES   # "plugin_name [level]: N files"
declare -a _REPORT_DETAIL_ENTRIES   # 详细变更：每个插件的具体操作
_REPORT_RENAME_COUNT=0
_REPORT_RENAME_SKIPPED=0
_REPORT_MUTATE_SEED=""
_REPORT_MUTATE_TOTAL=0
_REPORT_MUTATE_PROCESSED=0
declare -a _REPORT_POD_ENTRIES        # "PodName [level]: N .m + M .swift"
_REPORT_POD_TOTAL=0
_REPORT_POD_MUTATED=0
_REPORT_POD_SKIPPED=0

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $1" >&2; }

# =============================================
# 通用工具函数
# =============================================

# 从 ab_config.yaml 读取配置
read_ab_config() {
    local key="$1"
    local config_file="$PROJECT_ROOT/ab_config.yaml"
    
    if [[ -f "$config_file" ]]; then
        local value=$(grep "^${key}:" "$config_file" | head -1 | sed "s/^${key}: *//" | tr -d '\r\n"')
        echo "$value"
    fi
}

# 自动检测当前B面项目
detect_current_project() {
    local project=$(read_ab_config "project")
    if [[ -n "$project" ]]; then
        echo "$project"
        return 0
    fi
    return 1
}

# 检查项目是否使用 flutter_base
project_uses_flutter_base() {
    local project="$1"
    [[ "$project" == "md" || "$project" == "yms" ]]
}

# 执行结束后修复 flutter_base 的 image_loader.dart（如存在）
# 场景：某些流程会改写/覆盖 flutter_base/lib/image/image_loader.dart，导致 Base64 逻辑丢失。
patch_flutter_base_image_loader() {
    local target="$PROJECT_ROOT/flutter_base/lib/image/image_loader.dart"
    local template="$SCRIPT_DIR/templates/md_base64_image_loader.dart"

    if [[ ! -f "$target" ]]; then
        return 0
    fi
    if [[ ! -f "$template" ]]; then
        log_warning "未找到 image_loader 模板，跳过覆盖: $template"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将用模板覆盖: $target"
        return 0
    fi

    log_step "覆盖 flutter_base image_loader.dart（模板修复）..."
    cp -f "$template" "$target"
    log_success "已覆盖: $target"
}

# Hash 与随机值生成
hash_derive() {
    echo -n "$1" | md5 -q 2>/dev/null || echo -n "$1" | md5sum | cut -d' ' -f1
}

# 构建用于注入类名的大词池（首字母大写，从 semantic words 合并去重）
# 必须在主 shell 中调用一次（不能在 $() 子 shell 中首次执行，否则结果丢失）
_build_class_words_pool() {
    [[ "$CLASS_WORDS_POOL_LOADED" == "true" ]] && return
    load_semantic_words

    CLASS_WORDS_POOL=()

    local all_raw=("${WORD_PREFIXES[@]}" "${WORD_MIDDLES[@]}" "${WORD_SUFFIXES[@]}" "${CLASS_WORDS_FALLBACK[@]}")
    # 一次性用 awk 完成过滤+去重+首字母大写，避免逐行 bash 循环
    local result
    result=$(printf '%s\n' "${all_raw[@]}" | awk '
        length >= 3 && !/-/ {
            w = tolower($0)
            if (seen[w]++) next
            print toupper(substr($0,1,1)) substr($0,2)
        }')

    local IFS=$'\n'
    CLASS_WORDS_POOL=($result)
    unset IFS

    # 预计算小写版本，避免运行时 tr 调用
    local lc_result
    lc_result=$(printf '%s\n' "${CLASS_WORDS_POOL[@]}" | tr '[:upper:]' '[:lower:]')
    IFS=$'\n'
    CLASS_WORDS_POOL_LC=($lc_result)
    unset IFS

    CLASS_WORDS_POOL_LOADED=true
}

hex_to_classname() {
    local hex="$1"
    _build_class_words_pool
    local wc=${#CLASS_WORDS_POOL[@]}
    local idx1=$(( 16#${hex:0:4} % wc ))
    local idx2=$(( 16#${hex:4:4} % wc ))
    local idx3=$(( 16#${hex:8:4} % wc ))
    local idx4=$(( 16#${hex:16:4} % wc ))
    local mode=$(( 16#${hex:12:1} % 6 ))
    case $mode in
        0) echo "${CLASS_WORDS_POOL[$idx1]}${CLASS_WORDS_POOL[$idx2]}${hex:16:3}" ;;
        1) echo "${CLASS_WORDS_POOL[$idx1]}${CLASS_WORDS_POOL[$idx2]}${CLASS_WORDS_POOL[$idx3]}" ;;
        2) echo "${CLASS_WORDS_POOL[$idx1]}${CLASS_WORDS_POOL[$idx2]}$(( 16#${hex:16:2} ))" ;;
        3) echo "${CLASS_WORDS_POOL[$idx1]}${CLASS_WORDS_POOL[$idx3]}${CLASS_WORDS_POOL[$idx4]}${hex:20:2}" ;;
        4) echo "${CLASS_WORDS_POOL[$idx2]}${CLASS_WORDS_POOL[$idx1]}$(( 16#${hex:20:3} ))" ;;
        5) echo "${CLASS_WORDS_POOL[$idx3]}${CLASS_WORDS_POOL[$idx4]}${CLASS_WORDS_POOL[$idx1]}" ;;
    esac
}

hex_to_identifier() {
    local hex="$1"
    _build_class_words_pool
    local wc=${#CLASS_WORDS_POOL_LC[@]}
    local idx1=$(( 16#${hex:0:4} % wc ))
    local idx2=$(( 16#${hex:4:4} % wc ))
    echo "${CLASS_WORDS_POOL_LC[$idx1]}_${CLASS_WORDS_POOL_LC[$idx2]}_${hex:8:4}"
}

hex_to_string_value() {
    local hex="$1"
    local mode=$(( 16#${hex:0:1} % 8 ))
    case $mode in
        0) echo "${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}" ;;
        1) echo "com.app.${hex:0:6}.${hex:6:4}.${hex:10:6}" ;;
        2) echo "${hex:0:12}.${hex:12:8}.internal" ;;
        3) echo "x_${hex:0:4}_${hex:4:4}_${hex:8:4}_${hex:12:4}_v${hex:28:2}" ;;
        4) echo "cfg.${hex:0:3}.${hex:3:5}-${hex:8:4}.${hex:12:6}_rev${hex:18:2}" ;;
        5) echo "io.sdk.${hex:0:4}.mod_${hex:4:6}.${hex:10:3}.${hex:13:3}" ;;
        6) echo "ns_${hex:0:5}_${hex:5:5}_${hex:10:5}_${hex:15:5}_t${hex:20:2}" ;;
        7) echo "lib.${hex:0:4}.${hex:4:4}.opt-${hex:8:6}.build_${hex:14:4}" ;;
    esac
}

hex_to_int() {
    local hex="$1"
    local offset="${2:-0}"
    echo $(( 16#${hex:$offset:8} ))
}

# =============================================
# Pubspec 与依赖工具
# =============================================

# 检测 pub cache 目录
detect_pub_cache() {
    if [[ -n "$PUB_CACHE_DIR" ]]; then
        return
    fi
    
    if [[ -d "$HOME/.pub-cache/hosted/pub.dev" ]]; then
        PUB_CACHE_DIR="$HOME/.pub-cache/hosted/pub.dev"
    elif [[ -d "$HOME/.pub-cache/hosted/pub.dartlang.org" ]]; then
        PUB_CACHE_DIR="$HOME/.pub-cache/hosted/pub.dartlang.org"
    else
        log_error "无法检测 pub cache 目录，请使用 --pub-cache 指定"
        exit 1
    fi
    
    log_info "Pub cache 目录: $PUB_CACHE_DIR"
}

# 从配置文件加载词库
load_semantic_words() {
    if [[ "$WORDS_LOADED" == "true" ]]; then
        return
    fi
    
    local default_prefixes=("app" "local" "native" "custom" "core" "base" "main" "data" "file" "net" "io" "util" "service" "helper" "handler" "manager" "controller" "provider" "adapter" "module" "component" "engine" "system" "cache" "buffer" "stream" "pipe" "task" "worker" "client" "widget")
    local default_middles=("home" "main" "content" "user" "profile" "setting" "config" "detail" "info" "data" "file" "media" "audio" "video" "image" "photo" "storage" "cache" "network" "sync" "update" "load" "save" "get" "set" "create" "read" "edit" "process" "render" "display" "view" "control" "handle" "manage" "common" "shared" "global" "default" "standard" "basic" "simple" "custom" "primary" "internal" "external")
    local default_suffixes=("normal" "default" "active" "enabled" "valid" "small" "medium" "large" "full" "auto" "primary" "secondary" "base" "core" "main" "util" "helper" "handler" "manager" "service" "provider" "adapter" "wrapper" "module" "component" "engine" "system" "tool" "factory")
    
    WORD_PREFIXES=("${default_prefixes[@]}")
    WORD_MIDDLES=("${default_middles[@]}")
    WORD_SUFFIXES=("${default_suffixes[@]}")
    
    if [[ ! -f "$SEMANTIC_WORDS_FILE" ]]; then
        log_warning "词库文件不存在: $SEMANTIC_WORDS_FILE，使用默认词库"
        WORDS_LOADED=true
        return
    fi
    
    local current_section=""
    local file_prefixes=()
    local file_middles=()
    local file_suffixes=()
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        if [[ "$line" =~ ^\[PREFIXES\] ]]; then
            current_section="prefixes"
            continue
        elif [[ "$line" =~ ^\[MIDDLES\] ]]; then
            current_section="middles"
            continue
        elif [[ "$line" =~ ^\[SUFFIXES\] ]]; then
            current_section="suffixes"
            continue
        fi
        
        local word=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$word" ]] && continue
        
        case "$current_section" in
            prefixes) file_prefixes+=("$word") ;;
            middles) file_middles+=("$word") ;;
            suffixes) file_suffixes+=("$word") ;;
        esac
    done < "$SEMANTIC_WORDS_FILE"
    
    [[ ${#file_prefixes[@]} -gt 0 ]] && WORD_PREFIXES=("${file_prefixes[@]}")
    [[ ${#file_middles[@]} -gt 0 ]] && WORD_MIDDLES=("${file_middles[@]}")
    [[ ${#file_suffixes[@]} -gt 0 ]] && WORD_SUFFIXES=("${file_suffixes[@]}")
    
    WORDS_LOADED=true
    [[ "$VERBOSE" == "true" ]] && log_info "词库加载完成: ${#WORD_PREFIXES[@]} 前缀, ${#WORD_MIDDLES[@]} 中缀, ${#WORD_SUFFIXES[@]} 后缀" || true
}

# 生成随机名称（使用词库组合）
generate_random_name() {
    local original_name="$1"
    
    load_semantic_words
    
    local mode=$((RANDOM % 6))
    local name=""
    
    case $mode in
        0)
            local p="${WORD_PREFIXES[$((RANDOM % ${#WORD_PREFIXES[@]}))]}"
            local m="${WORD_MIDDLES[$((RANDOM % ${#WORD_MIDDLES[@]}))]}"
            name="${p}_${m}"
            ;;
        1)
            local p="${WORD_PREFIXES[$((RANDOM % ${#WORD_PREFIXES[@]}))]}"
            local s="${WORD_SUFFIXES[$((RANDOM % ${#WORD_SUFFIXES[@]}))]}"
            name="${p}_${s}"
            ;;
        2)
            local m="${WORD_MIDDLES[$((RANDOM % ${#WORD_MIDDLES[@]}))]}"
            local s="${WORD_SUFFIXES[$((RANDOM % ${#WORD_SUFFIXES[@]}))]}"
            name="${m}_${s}"
            ;;
        3)
            local p="${WORD_PREFIXES[$((RANDOM % ${#WORD_PREFIXES[@]}))]}"
            local m="${WORD_MIDDLES[$((RANDOM % ${#WORD_MIDDLES[@]}))]}"
            local s="${WORD_SUFFIXES[$((RANDOM % ${#WORD_SUFFIXES[@]}))]}"
            name="${p}_${m}_${s}"
            ;;
        4)
            local m1="${WORD_MIDDLES[$((RANDOM % ${#WORD_MIDDLES[@]}))]}"
            local m2="${WORD_MIDDLES[$((RANDOM % ${#WORD_MIDDLES[@]}))]}"
            while [[ "$m1" == "$m2" ]]; do
                m2="${WORD_MIDDLES[$((RANDOM % ${#WORD_MIDDLES[@]}))]}"
            done
            name="${m1}_${m2}"
            ;;
        5)
            local p="${WORD_PREFIXES[$((RANDOM % ${#WORD_PREFIXES[@]}))]}"
            local m="${WORD_MIDDLES[$((RANDOM % ${#WORD_MIDDLES[@]}))]}"
            local num=$((RANDOM % 100))
            name="${p}_${m}${num}"
            ;;
    esac
    
    echo "$name" | tr '[:upper:]' '[:lower:]' | tr '-' '_'
}

# 解析 pubspec.yaml 获取依赖
get_pubspec_dependencies() {
    local pubspec="$PROJECT_ROOT/pubspec.yaml"
    if [[ ! -f "$pubspec" ]]; then
        log_error "pubspec.yaml 不存在"
        exit 1
    fi
    
    grep -E "^\s+[a-z_]+:" "$pubspec" | \
        grep -v "sdk:" | \
        grep -v "path:" | \
        sed 's/^\s*//' | \
        cut -d: -f1 | \
        sort -u
}

# 获取已有的 path 依赖
get_path_dependencies() {
    local pubspec="$PROJECT_ROOT/pubspec.yaml"
    grep -B1 "path:" "$pubspec" 2>/dev/null | \
        grep -E "^\s+[a-z_]+:" | \
        sed 's/^\s*//' | \
        cut -d: -f1
}

# 从 pubspec.lock 中读取 hosted 包的锁定版本
get_locked_package_version() {
    local package_name="$1"
    local lock_file="$PROJECT_ROOT/pubspec.lock"
    [[ -f "$lock_file" ]] || return 1

    awk -v pkg="$package_name" '
        BEGIN { in_pkg=0; source=""; version="" }
        $0 ~ "^  " pkg ":" {
            in_pkg=1
            source=""
            version=""
            next
        }
        in_pkg && $0 ~ "^  [^[:space:]].*:$" {
            in_pkg=0
        }
        in_pkg && $0 ~ "^    source: " {
            line=$0
            sub("^    source: ", "", line)
            source=line
        }
        in_pkg && $0 ~ "^    version: " {
            line=$0
            sub("^    version: \"?", "", line)
            sub("\"$", "", line)
            version=line
        }
        in_pkg && source=="hosted" && version!="" {
            print version
            exit
        }
    ' "$lock_file"
}

# 查找 pub cache 中插件目录（优先使用 pubspec.lock 锁定版本）
find_pub_cache_plugin_path() {
    local package_name="$1"
    local locked_version
    local locked_path
    local latest_path

    locked_version=$(get_locked_package_version "$package_name")
    if [[ -n "$locked_version" ]]; then
        locked_path="$PUB_CACHE_DIR/${package_name}-${locked_version}"
        if [[ -d "$locked_path" ]]; then
            [[ "$VERBOSE" == "true" ]] && log_info "  使用 lock 版本: $package_name ($locked_version)" || true
            echo "$locked_path"
            return 0
        fi
        [[ "$VERBOSE" == "true" ]] && log_warning "  lock 版本目录不存在，回退最新版本: $package_name ($locked_version)" || true
    fi

    latest_path=$(find "$PUB_CACHE_DIR" -maxdepth 1 -type d -name "${package_name}-*" 2>/dev/null | sort -V | tail -1)
    [[ -n "$latest_path" ]] && echo "$latest_path"
    return 0
}

# 判断包的 pubspec 是否声明了 Apple 平台插件
# 返回:
#   apple    -> 明确声明 ios/macos
#   nonapple -> 声明了 plugin，但未声明 Apple 平台
#   unknown  -> 未发现 plugin 声明，回退到源码布局判断
get_package_apple_plugin_mode() {
    local plugin_dir="$1"
    local pubspec="$plugin_dir/pubspec.yaml"
    [[ -f "$pubspec" ]] || { echo "unknown"; return 0; }

    awk '
        BEGIN {
            in_flutter = 0
            in_plugin = 0
            in_platforms = 0
            has_plugin = 0
            has_apple = 0
        }

        /^flutter:[[:space:]]*$/ {
            in_flutter = 1
            in_plugin = 0
            in_platforms = 0
            next
        }

        in_flutter && /^[^[:space:]]/ {
            in_flutter = 0
            in_plugin = 0
            in_platforms = 0
        }

        in_flutter && /^  plugin:[[:space:]]*$/ {
            in_plugin = 1
            in_platforms = 0
            has_plugin = 1
            next
        }

        in_plugin && /^  [^[:space:]]/ {
            in_plugin = 0
            in_platforms = 0
        }

        in_plugin && /^    platforms:[[:space:]]*$/ {
            in_platforms = 1
            next
        }

        in_platforms && /^      (ios|macos):([[:space:]]*|$)/ {
            has_apple = 1
        }

        in_platforms && /^    [^[:space:]]/ {
            in_platforms = 0
        }

        END {
            if (!has_plugin) {
                print "unknown"
            } else if (has_apple) {
                print "apple"
            } else {
                print "nonapple"
            }
        }
    ' "$pubspec"
}

# 判断目录是否具备 Apple 原生插件源码布局
package_has_apple_source_layout() {
    local plugin_dir="$1"
    [[ -d "$plugin_dir" ]] || return 1

    if find "$plugin_dir" -maxdepth 2 -type f \
        \( -path "*/ios/*.podspec" -o -path "*/darwin/*.podspec" -o -path "*/macos/*.podspec" \) \
        -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi

    local known_dirs=(
        "$plugin_dir/ios/Classes"
        "$plugin_dir/ios/Sources"
        "$plugin_dir/darwin"
        "$plugin_dir/macos/Classes"
        "$plugin_dir/macos/Sources"
    )
    local dir=""
    for dir in "${known_dirs[@]}"; do
        [[ -d "$dir" ]] && return 0
    done

    if [[ -d "$plugin_dir/ios" ]] && find "$plugin_dir/ios" -maxdepth 4 -type f \
        \( -name "*.m" -o -name "*.mm" -o -name "*.swift" -o -name "*.h" \) \
        -not -path "*/example/*" \
        -not -path "*/Runner/*" \
        -not -path "*/Flutter/*" \
        -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi

    if [[ -d "$plugin_dir/darwin" ]] && find "$plugin_dir/darwin" -maxdepth 5 -type f \
        \( -name "*.m" -o -name "*.mm" -o -name "*.swift" -o -name "*.h" \) \
        -not -path "*/example/*" \
        -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi

    if [[ -d "$plugin_dir/macos" ]] && find "$plugin_dir/macos" -maxdepth 4 -type f \
        \( -name "*.m" -o -name "*.mm" -o -name "*.swift" -o -name "*.h" \) \
        -not -path "*/example/*" \
        -not -path "*/Runner/*" \
        -not -path "*/Flutter/*" \
        -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi

    return 1
}

# 是否应视为 Apple 原生插件
is_apple_native_plugin_dir() {
    local plugin_dir="$1"
    [[ -d "$plugin_dir" ]] || return 1

    local mode
    mode=$(get_package_apple_plugin_mode "$plugin_dir")

    if [[ "$mode" == "nonapple" ]]; then
        return 1
    fi

    package_has_apple_source_layout "$plugin_dir"
}

# 从 pubspec.yaml 中提取B面（次要模块）依赖
get_secondary_dependencies() {
    local pubspec="$PROJECT_ROOT/pubspec.yaml"
    if [[ ! -f "$pubspec" ]]; then
        log_error "pubspec.yaml 不存在"
        exit 1
    fi
    
    local in_secondary=false
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        if echo "$line" | grep -q "# === 次要模块依赖"; then
            in_secondary=true
            continue
        fi
        
        if [[ "$in_secondary" == "true" ]] && echo "$line" | grep -qE "^(dev_dependencies|flutter):"; then
            break
        fi
        
        [[ "$in_secondary" != "true" ]] && continue
        
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        if echo "$line" | grep -qE '^  [a-z_][a-z_0-9]*:'; then
            echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1
        fi
    done < "$pubspec" | sort -u
}

# 从 YAML 行中提取 path: 的值（兼容 macOS BSD sed）
extract_path_value() {
    echo "$1" | sed 's/.*path://' | tr -d "'" | tr -d '"' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# 从 pubspec.yaml 获取本地 path 依赖的绝对路径
find_local_plugin_path() {
    local package_name="$1"
    local pubspec="$PROJECT_ROOT/pubspec.yaml"
    [[ -f "$pubspec" ]] || return 1

    local current_dep=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if echo "$line" | grep -qE '^  [a-z_][a-z_0-9]*:'; then
            local key=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1)
            if echo "$line" | grep -qE '^  [a-z_][a-z_0-9]*:[[:space:]]*$'; then
                current_dep="$key"
            else
                current_dep=""
            fi
        elif echo "$line" | grep -qE '^[[:space:]]+path:' && [[ -n "$current_dep" ]] && [[ "$current_dep" == "$package_name" ]]; then
            local dep_path=$(extract_path_value "$line")
            local abs_path="$PROJECT_ROOT/$dep_path"
            if [[ -d "$abs_path" ]]; then
                echo "$abs_path"
                return 0
            fi
            current_dep=""
        fi
    done < "$pubspec"
    return 0
}

# 收集本地 path 插件内部通过 path 引用的所有子包名
get_path_provided_packages() {
    local pubspec="$PROJECT_ROOT/pubspec.yaml"
    local path_provided=()

    local current_dep=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^[[:space:]]+[a-z_]+:[[:space:]]*$'; then
            current_dep=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1)
        elif echo "$line" | grep -qE '^[[:space:]]+path:' && [[ -n "$current_dep" ]]; then
            local dep_path=$(extract_path_value "$line")
            local abs_path="$PROJECT_ROOT/$dep_path"
            path_provided+=("$current_dep")
            if [[ -f "$abs_path/pubspec.yaml" ]]; then
                local sub_dep=""
                while IFS= read -r sub_line; do
                    if echo "$sub_line" | grep -qE '^[[:space:]]+[a-z_]+:[[:space:]]*(#.*)?$'; then
                        sub_dep=$(echo "$sub_line" | sed 's/^[[:space:]]*//' | cut -d: -f1)
                    elif echo "$sub_line" | grep -qE '^[[:space:]]+path:' && [[ -n "$sub_dep" ]]; then
                        path_provided+=("$sub_dep")
                        sub_dep=""
                    else
                        sub_dep=""
                    fi
                done < "$abs_path/pubspec.yaml"
            fi
            current_dep=""
        else
            current_dep=""
        fi
    done < "$pubspec"

    printf '%s\n' "${path_provided[@]}" | sort -u
}

# 检测传递依赖中的 iOS 平台包
detect_ios_platform_packages() {
    [[ "$AUTO_DETECT_PLATFORM" != "true" ]] && return

    local path_pkgs=$(get_path_provided_packages)

    local all_platform=$(fvm flutter pub deps 2>/dev/null | \
        grep -E "├── |└── " | \
        sed 's/.*[├└]── //' | \
        sed 's/\.\.\.$//' | \
        grep -v "^$" | \
        sort -u)

    while IFS= read -r pkg_line; do
        [[ -z "$pkg_line" ]] && continue
        local pkg_name=$(echo "$pkg_line" | awk '{print $1}')
        local pkg_version=$(echo "$pkg_line" | awk '{print $2}')
        if echo "$path_pkgs" | grep -qx "$pkg_name" 2>/dev/null; then
            [[ "$VERBOSE" == "true" ]] && log_info "  跳过 $pkg_name (已由本地 path 插件提供)" || true
            continue
        fi

        local plugin_path=""
        plugin_path=$(find_local_plugin_path "$pkg_name")
        [[ -z "$plugin_path" ]] && plugin_path=$(find_pub_cache_plugin_path "$pkg_name")
        [[ -z "$plugin_path" ]] && continue

        is_apple_native_plugin_dir "$plugin_path" || continue

        if [[ -z "$pkg_version" || "$pkg_version" == "..." ]]; then
            pkg_version=$(get_plugin_version "$plugin_path")
        fi
        echo "$pkg_name $pkg_version"
    done <<< "$all_platform"
}

# 获取传递依赖的版本
get_transitive_package_version() {
    local package_name="$1"
    
    local version=$(fvm flutter pub deps 2>/dev/null | \
        grep -E "[├└]── ${package_name} [0-9]" | \
        head -1 | \
        sed "s/.*${package_name} //" | \
        awk '{print $1}')
    
    echo "$version"
}

# 将 iOS 平台包添加到 pubspec.yaml
add_platform_package_to_pubspec() {
    local package_name="$1"
    local version="$2"
    local pubspec="$PROJECT_ROOT/pubspec.yaml"
    
    if grep -q "^  ${package_name}:" "$pubspec" 2>/dev/null; then
        [[ "$VERBOSE" == "true" ]] && log_info "  $package_name 已存在于 pubspec.yaml" || true
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 添加到 pubspec.yaml: $package_name: ^$version"
        return 0
    fi
    
    local marker_line=$(grep -n "^  # === 自动检测的 iOS 平台包 ===" "$pubspec" | head -1 | cut -d: -f1)
    
    if [[ -n "$marker_line" ]]; then
        sed -i '' "${marker_line}a\\
  ${package_name}: ^${version}
" "$pubspec"
    else
        local dev_deps_line=$(grep -n "^dev_dependencies:" "$pubspec" | head -1 | cut -d: -f1)
        
        if [[ -z "$dev_deps_line" ]]; then
            log_warning "未找到 dev_dependencies 部分，跳过添加 $package_name"
            return 1
        fi
        
        local insert_line=$((dev_deps_line - 1))
        sed -i '' "${insert_line}a\\
\\
  # === 自动检测的 iOS 平台包 ===\\
  ${package_name}: ^${version}
" "$pubspec"
    fi
    
    log_info "  添加到 pubspec.yaml: $package_name: ^$version"
}

# 按比例随机选择插件
select_by_ratio() {
    local plugins="$1"
    local ratio="$OBFUSCATE_RATIO"
    
    if [[ "$ratio" -ge 100 ]]; then
        echo "$plugins"
        return
    fi
    
    local filtered=$(echo "$plugins" | grep -v "^$")
    local total=$(echo "$filtered" | wc -l | tr -d ' ')
    
    [[ "$total" -eq 0 ]] && return
    
    local select_count=$(( total * ratio / 100 ))
    
    [[ "$select_count" -lt 1 ]] && select_count=1
    
    echo "$filtered" | awk 'BEGIN{srand()} {print rand()"\t"$0}' | sort -n | cut -f2- | head -n "$select_count"
}

# =============================================
# Phase 1: 重命名函数
# =============================================

# 列出可重命名的B面 iOS 插件
list_plugins() {
    log_step "分析B面依赖..."
    log_info "当前项目: ${CURRENT_PROJECT:-未知}"
    
    detect_pub_cache
    
    echo ""
    echo "=== B面 iOS 原生插件 (可重命名) ==="
    echo "    注意: 仅显示B面依赖（'# === 次要模块依赖' 标记之后）"
    echo ""
    
    local deps=$(get_secondary_dependencies)
    local plugin_count=0
    
    if [[ -z "$deps" ]]; then
        echo "  (未找到B面依赖，请确保 pubspec.yaml 中有 '# === 次要模块依赖' 标记)"
    fi
    
    for dep in $deps; do
        local plugin_path=$(find_local_plugin_path "$dep")
        local source_type=""
        if [[ -n "$plugin_path" ]]; then
            source_type="local-path"
        else
            plugin_path=$(find_pub_cache_plugin_path "$dep")
            source_type="pub-cache"
        fi
        
        if [[ -n "$plugin_path" ]] && is_apple_native_plugin_dir "$plugin_path"; then
            if [[ "$source_type" == "pub-cache" ]]; then
                local version=$(basename "$plugin_path" | sed "s/${dep}-//")
                echo "  $dep ($version) [pub-cache]"
            else
                echo "  $dep [local-path]"
            fi
            plugin_count=$((plugin_count + 1))
        fi
    done
    
    if [[ $plugin_count -eq 0 ]]; then
        echo "  (无可重命名的 iOS 原生插件)"
    fi
    
    echo ""
    echo "=== 本地 plugins/ 已存在 ==="
    echo ""
    
    if [[ -d "$PLUGINS_DIR" ]]; then
        for plugin in "$PLUGINS_DIR"/*/; do
            if [[ -d "$plugin" ]]; then
                local name=$(basename "$plugin")
                echo "  $name"
            fi
        done
    else
        echo "  (plugins 目录不存在)"
    fi
    
    if project_uses_flutter_base "$CURRENT_PROJECT"; then
        echo ""
        echo "=== flutter_base/ 模块 ==="
        echo ""
        
        if [[ -d "$FLUTTER_BASE_DIR" ]]; then
            for module in "$FLUTTER_BASE_DIR"/*/; do
                if [[ -d "$module" ]] && [[ -f "$module/pubspec.yaml" ]]; then
                    local name=$(basename "$module")
                    if is_apple_native_plugin_dir "$module"; then
                        echo "  $name [flutter-base]"
                        plugin_count=$((plugin_count + 1))
                    fi
                fi
            done
        else
            echo "  (flutter_base 目录不存在)"
        fi
    else
        echo ""
        echo -e "${YELLOW}提示: flutter_base 仅已注册项目使用，当前项目 ($CURRENT_PROJECT) 跳过${NC}"
    fi
    
    echo ""
    echo "统计: $plugin_count 个可混淆的 iOS 原生插件"
    echo ""
}

# 生成映射配置
generate_mapping() {
    log_step "生成随机映射配置..."
    log_info "当前项目: ${CURRENT_PROJECT:-未知}"
    log_info "混淆比例: ${OBFUSCATE_RATIO}%"
    
    detect_pub_cache
    _build_class_words_pool
    
    local output_file="$SCRIPT_DIR/plugin_rename_mapping.conf"
    
    if [[ -f "$output_file" ]]; then
        mv "$output_file" "${output_file}.bak"
        log_info "已备份原配置到 ${output_file}.bak"
    fi
    
    local uses_flutter_base="否"
    project_uses_flutter_base "$CURRENT_PROJECT" && uses_flutter_base="是"
    
    # Step 1: 检测 iOS 平台包并添加到 pubspec.yaml
    if [[ "$AUTO_DETECT_PLATFORM" == "true" ]]; then
        log_step "检测传递依赖中的 iOS 平台包..."
        local platform_packages=$(detect_ios_platform_packages)
        local platform_added=0
        
        while IFS= read -r pkg_line; do
            [[ -z "$pkg_line" ]] && continue
            local pkg_name=$(echo "$pkg_line" | awk '{print $1}')
            local pkg_version=$(echo "$pkg_line" | awk '{print $2}')
            
            if ! grep -q "^  ${pkg_name}:" "$PROJECT_ROOT/pubspec.yaml" 2>/dev/null; then
                add_platform_package_to_pubspec "$pkg_name" "$pkg_version"
                platform_added=$((platform_added + 1))
            fi
        done <<< "$platform_packages"
        
        if [[ $platform_added -gt 0 ]]; then
            log_success "已添加 $platform_added 个 iOS 平台包到 pubspec.yaml"
            log_info "运行 fvm flutter pub get 更新依赖..."
            fvm flutter pub get 2>/dev/null || true
        fi
    fi
    
    cat > "$output_file" << HEADER
# Flutter 插件/Framework 重命名映射配置
# 格式: 原始包名 -> 新包名
# 
# 本配置由 obfuscate_frameworks.sh -g 自动生成
# 项目: ${CURRENT_PROJECT:-未知}
# 生成模式: 所有 B面 iOS 原生插件
# 混淆比例: ${OBFUSCATE_RATIO}%
# flutter_base: ${uses_flutter_base}
#
# 特性：
# 1. 每个插件名称完全随机，无统一前缀
# 2. 自动检测并处理 iOS 平台包
# 3. 按比例随机选择插件进行混淆

HEADER

    local pub_count=0
    local base_count=0
    local eligible_plugins=""
    local skipped_transitive=0
    local skipped_plugins_info=""
    
    local cached_deps_file=$(mktemp)
    fvm flutter pub deps > "$cached_deps_file" 2>/dev/null
    
    # Step 2: 收集B面可混淆的插件（排除有传递依赖冲突的）
    log_step "分析B面可混淆的插件..."
    
    local deps=$(get_secondary_dependencies)
    if [[ -z "$deps" ]]; then
        log_warning "未在 pubspec.yaml 中找到B面依赖（缺少 '# === 次要模块依赖' 标记）"
        log_info "请确保 pubspec.yaml 中有 '# === 次要模块依赖' 标记来区分A/B面依赖"
    fi
    for dep in $deps; do
        # 查找插件路径：优先本地 path 依赖，否则 pub cache
        local plugin_path=$(find_local_plugin_path "$dep")
        [[ -z "$plugin_path" ]] && plugin_path=$(find_pub_cache_plugin_path "$dep")
        
        if [[ -n "$plugin_path" ]] && is_apple_native_plugin_dir "$plugin_path"; then
            # 检查传递依赖冲突（在生成阶段就过滤）
            if check_transitive_dependency "$dep"; then
                local dep_paths=$(grep -B100 "${dep}\.\.\." "$cached_deps_file" 2>/dev/null | \
                    grep -E "^├── |^└── " | \
                    tail -1 | \
                    awk '{print $2}' | \
                    grep -v "^${dep}$")
                
                skipped_plugins_info+="# $dep"$'\n'
                if [[ -n "$dep_paths" ]]; then
                    skipped_plugins_info+="#   被依赖于: $dep_paths"$'\n'
                else
                    skipped_plugins_info+="#   被依赖于: (多个包或直接依赖)"$'\n'
                fi
                [[ "$VERBOSE" == "true" ]] && log_info "  跳过 $dep (被 ${dep_paths:-未知} 传递依赖)" || true
                skipped_transitive=$((skipped_transitive + 1))
                continue
            fi
            eligible_plugins+="$dep"$'\n'
        fi
    done
    
    # Step 3: 按比例随机选择
    local selected_plugins=$(select_by_ratio "$eligible_plugins")
    local total_eligible=$(echo "$eligible_plugins" | grep -v "^$" | wc -l | tr -d ' ')
    local total_selected=$(echo "$selected_plugins" | grep -v "^$" | wc -l | tr -d ' ')
    
    if [[ $skipped_transitive -gt 0 ]]; then
        log_info "跳过 $skipped_transitive 个有传递依赖冲突的插件"
    fi
    log_info "可混淆插件: $total_eligible 个，选择: $total_selected 个 (${OBFUSCATE_RATIO}%)"
    
    echo "# === Pub Cache 插件 ===" >> "$output_file"
    
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        local new_name=$(generate_random_name "$dep")
        echo "$dep -> $new_name" >> "$output_file"
        pub_count=$((pub_count + 1))
        [[ "$VERBOSE" == "true" ]] && log_info "  $dep -> $new_name" || true
    done <<< "$selected_plugins"
    
    # Step 4: 处理 flutter_base（仅已注册项目）
    if project_uses_flutter_base "$CURRENT_PROJECT"; then
        echo "" >> "$output_file"
        echo "# === flutter_base 模块 (已注册项目专用) ===" >> "$output_file"
        
        if [[ -d "$FLUTTER_BASE_DIR" ]]; then
            local base_plugins=""
            for module in "$FLUTTER_BASE_DIR"/*/; do
                if [[ -d "$module" ]] && [[ -f "$module/pubspec.yaml" ]]; then
                    local name=$(basename "$module")
                    if is_apple_native_plugin_dir "$module"; then
                        base_plugins+="$name"$'\n'
                    fi
                fi
            done
            
            local selected_base=$(select_by_ratio "$base_plugins")
            while IFS= read -r name; do
                [[ -z "$name" ]] && continue
                local new_name=$(generate_random_name "$name")
                echo "$name -> $new_name" >> "$output_file"
                base_count=$((base_count + 1))
                [[ "$VERBOSE" == "true" ]] && log_info "  $name -> $new_name" || true
            done <<< "$selected_base"
        fi
    else
        echo "" >> "$output_file"
        echo "# flutter_base 仅已注册项目使用，当前项目 ($CURRENT_PROJECT) 跳过" >> "$output_file"
    fi
    
    # Step 5: 添加跳过的插件信息
    if [[ -n "$skipped_plugins_info" ]]; then
        echo "" >> "$output_file"
        echo "# =============================================" >> "$output_file"
        echo "# 跳过的插件 (有传递依赖冲突，重命名会导致构建失败)" >> "$output_file"
        echo "# =============================================" >> "$output_file"
        echo "# " >> "$output_file"
        echo "# 这些插件被其他包作为传递依赖引入，如果重命名会导致:" >> "$output_file"
        echo "# 1. 同一个类有两个不同版本 (原版本 + 重命名版本)" >> "$output_file"
        echo "# 2. 类型冲突导致编译失败" >> "$output_file"
        echo "# " >> "$output_file"
        echo "# 优化建议:" >> "$output_file"
        echo "# - 如果父包可以被替换，考虑移除父包依赖" >> "$output_file"
        echo "# - 如果父包是必须的，此插件无法混淆" >> "$output_file"
        echo "# " >> "$output_file"
        echo "$skipped_plugins_info" >> "$output_file"
    fi
    
    rm -f "$cached_deps_file" 2>/dev/null || true
    
    log_success "映射配置已生成: $output_file"
    echo ""
    echo "统计:"
    echo "  Pub Cache: $pub_count 个"
    if project_uses_flutter_base "$CURRENT_PROJECT"; then
        echo "  flutter_base: $base_count 个"
    fi
    if [[ $skipped_transitive -gt 0 ]]; then
        echo "  跳过 (传递依赖冲突): $skipped_transitive 个"
    fi
    echo "  总计可混淆: $((pub_count + base_count)) 个"
    if [[ "$_IN_RUN_ALL" != "true" ]]; then
        echo ""
        echo "后续步骤:"
        echo "  1. 检查并编辑配置文件: vim $output_file"
        echo "  2. 应用配置: $0 apply"
        echo "  3. 运行: fvm flutter pub get && cd ios && pod install"
    fi
}

# 解析映射配置
parse_mapping() {
    if [[ ! -f "$MAPPING_FILE" ]]; then
        return 1
    fi
    
    grep -v "^#" "$MAPPING_FILE" | grep -v "^$" | grep -- "->" || true
}

# 转换为驼峰命名
to_camel_case() {
    local input="$1"
    local result=""
    local capitalize_next=true
    
    for (( i=0; i<${#input}; i++ )); do
        local char="${input:$i:1}"
        if [[ "$char" == "_" ]]; then
            capitalize_next=true
        elif [[ "$capitalize_next" == true ]]; then
            result+=$(echo "$char" | tr '[:lower:]' '[:upper:]')
            capitalize_next=false
        else
            result+="$char"
        fi
    done
    
    echo "$result"
}

# 恢复 Pigeon HostApi 名称，避免 channel 名跟随插件类名一起被改坏
restore_pigeon_host_api_names() {
    local target_path="$1"
    local old_class="$2"
    local new_class="$3"

    [[ -d "$target_path" ]] || return 0
    [[ "$old_class" == "$new_class" ]] && return 0

    local should_restore=false
    while IFS= read -r file; do
        if grep -q "dev\\.flutter\\.pigeon\\..*\\.${new_class}Api\\." "$file" 2>/dev/null; then
            should_restore=true
            break
        fi
    done < <(find "$target_path" -type f \( -name "*.swift" -o -name "*.h" -o -name "*.m" -o -name "*.kt" -o -name "*.java" \) 2>/dev/null)

    [[ "$should_restore" == "true" ]] || return 0

    while IFS= read -r file; do
        sed -i '' "s|${new_class}FlutterApi|${old_class}FlutterApi|g" "$file" 2>/dev/null || true
        sed -i '' "s|${new_class}HostApi|${old_class}HostApi|g" "$file" 2>/dev/null || true
        sed -i '' "s|${new_class}Api|${old_class}Api|g" "$file" 2>/dev/null || true
    done < <(find "$target_path" -type f \( -name "*.swift" -o -name "*.h" -o -name "*.m" -o -name "*.kt" -o -name "*.java" \) 2>/dev/null)

    [[ "$VERBOSE" == "true" ]] && log_info "  恢复 Pigeon HostApi 名称: ${new_class}*Api -> ${old_class}*Api" || true
}

# 重命名单个插件
rename_plugin() {
    local source_path="$1"
    local old_name="$2"
    local new_name="$3"
    local target_path="$PLUGINS_DIR/$new_name"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 重命名: $old_name -> $new_name"
        [[ "$source_path" == "$PLUGINS_DIR/"* ]] && [[ "$source_path" != "$target_path" ]] && log_info "[DRY-RUN] 将删除旧版本（替换）: $(basename "$source_path")" || true
        return
    fi
    
    log_step "重命名: $old_name -> $new_name"
    
    mkdir -p "$PLUGINS_DIR"
    
    if [[ -d "$target_path" ]]; then
        log_warning "目标已存在，覆盖: $target_path"
        rm -rf "$target_path"
    fi
    
    cp -r "$source_path" "$target_path"
    
    rm -rf "$target_path/.git" 2>/dev/null || true
    rm -rf "$target_path/.dart_tool" 2>/dev/null || true
    rm -rf "$target_path/build" 2>/dev/null || true
    rm -rf "$target_path/example" 2>/dev/null || true
    
    local old_class=$(to_camel_case "$old_name")
    local new_class=$(to_camel_case "$new_name")
    
    # 更新 pubspec.yaml
    if [[ -f "$target_path/pubspec.yaml" ]]; then
        sed -i '' "s/^name: $old_name/name: $new_name/" "$target_path/pubspec.yaml"
        
        local temp_pubspec=$(mktemp)
        local in_native_platform=false
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            if echo "$line" | grep -qE '^\s+(ios|macos):\s*$'; then
                in_native_platform=true
            elif echo "$line" | grep -qE '^\s+[a-z_]+:\s*$'; then
                in_native_platform=false
            fi
            
            if [[ "$in_native_platform" == "true" ]] && echo "$line" | grep -q "pluginClass:"; then
                line=$(echo "$line" | sed -E "s/${old_class}([A-Z])/${new_class}\1/g")
                line=$(echo "$line" | sed -E "s/${old_class}([^A-Za-z0-9]|$)/${new_class}\1/g")
            fi
            
            echo "$line"
        done < "$target_path/pubspec.yaml" > "$temp_pubspec"
        
        mv "$temp_pubspec" "$target_path/pubspec.yaml"
    fi
    
    # 更新 iOS podspec
    if [[ -d "$target_path/ios" ]]; then
        for podspec in "$target_path/ios"/*.podspec; do
            if [[ -f "$podspec" ]]; then
                local new_podspec="$target_path/ios/$new_name.podspec"
                mv "$podspec" "$new_podspec" 2>/dev/null || true
                sed -i '' "s/s\.name\s*=.*/s.name             = '$new_name'/" "$new_podspec"
                sed -i '' "s/s\.module_name\s*=.*/s.module_name      = '$new_name'/" "$new_podspec"
                sed -i '' "s|${old_name}/|${new_name}/|g" "$new_podspec"
                sed -i '' "s/'$old_name'/'$new_name'/g" "$new_podspec"
            fi
        done
    fi
    
    # 更新 darwin podspec
    if [[ -d "$target_path/darwin" ]]; then
        for podspec in "$target_path/darwin"/*.podspec; do
            if [[ -f "$podspec" ]]; then
                local new_podspec="$target_path/darwin/$new_name.podspec"
                mv "$podspec" "$new_podspec" 2>/dev/null || true
                sed -i '' "s/s\.name\s*=.*/s.name             = '$new_name'/" "$new_podspec"
                sed -i '' "s/s\.module_name\s*=.*/s.module_name      = '$new_name'/" "$new_podspec"
                sed -i '' "s|${old_name}/|${new_name}/|g" "$new_podspec"
                sed -i '' "s/'$old_name'/'$new_name'/g" "$new_podspec"
            fi
        done
    fi
    
    # 更新 Package.swift
    find "$target_path" -name "Package.swift" -type f 2>/dev/null | while read pkg_swift; do
        sed -i '' "s|\"${old_name}\"|\"${new_name}\"|g" "$pkg_swift" 2>/dev/null || true
        sed -i '' "s|/${old_name}|/${new_name}|g" "$pkg_swift" 2>/dev/null || true
    done
    
    # 更新原生代码
    find "$target_path" -type f \( -name "*.swift" -o -name "*.h" -o -name "*.m" \) 2>/dev/null | while read file; do
        sed -i '' -E "s/${old_class}([A-Z])/${new_class}\1/g" "$file" 2>/dev/null || true
        sed -i '' -E "s/${old_class}([^A-Za-z0-9])/${new_class}\1/g" "$file" 2>/dev/null || true
        sed -i '' -E "s/${old_class}\$/${new_class}/g" "$file" 2>/dev/null || true
        
        sed -i '' "s|${old_name}-Swift\.h|${new_name}-Swift.h|g" "$file" 2>/dev/null || true
        sed -i '' "s|@import ${old_name};|@import ${new_name};|g" "$file" 2>/dev/null || true
        sed -i '' "s|${old_name}/|${new_name}/|g" "$file" 2>/dev/null || true
        
        local filename=$(basename "$file")
        if [[ "$filename" == *"$old_class"* ]]; then
            local newfilename="${filename/$old_class/$new_class}"
            mv "$file" "$(dirname "$file")/$newfilename" 2>/dev/null || true
        fi
    done
    
    # 恢复 Firebase SDK 模块导入
    if [[ "$old_name" == firebase_* ]]; then
        find "$target_path" -type f \( -name "*.h" -o -name "*.m" -o -name "*.mm" -o -name "*.swift" \) 2>/dev/null | while read file; do
            sed -i '' "s|@import ${new_class};|@import ${old_class};|g" "$file" 2>/dev/null || true
            sed -i '' "s|import ${new_class}|import ${old_class}|g" "$file" 2>/dev/null || true
            sed -i '' "s|#import <${new_class}/|#import <${old_class}/|g" "$file" 2>/dev/null || true
            sed -i '' "s|#import <${new_class}>|#import <${old_class}>|g" "$file" 2>/dev/null || true
            sed -i '' "s|${old_class}/${new_class}\.h|${old_class}/${old_class}.h|g" "$file" 2>/dev/null || true
        done
        [[ "$VERBOSE" == "true" ]] && log_info "  恢复 Firebase SDK 导入: @import ${old_class}" || true
    fi
    
    # 重命名 iOS/darwin 内以旧包名命名的目录
    for platform_dir in "$target_path/ios" "$target_path/darwin"; do
        [[ -d "$platform_dir" ]] || continue
        find "$platform_dir" -type d -name "$old_name" 2>/dev/null | \
            awk '{print length, $0}' | sort -rn | cut -d' ' -f2- | \
            while read dir_to_rename; do
                local parent_dir=$(dirname "$dir_to_rename")
                if [[ -d "$dir_to_rename" ]] && [[ ! -d "$parent_dir/$new_name" ]]; then
                    mv "$dir_to_rename" "$parent_dir/$new_name"
                    [[ "$VERBOSE" == "true" ]] && log_info "  重命名目录: $(basename "$parent_dir")/$old_name -> $new_name" || true
                fi
            done
    done

    restore_pigeon_host_api_names "$target_path" "$old_class" "$new_class"
    
    # 更新 Dart 代码
    find "$target_path" -type f -name "*.dart" 2>/dev/null | while read file; do
        sed -i '' "s|package:${old_name}/|package:${new_name}/|g" "$file" 2>/dev/null || true
        sed -i '' "/^[[:space:]]*import /!{/^[[:space:]]*export /!{s|/${old_name}/|/${new_name}/|g;}}" "$file" 2>/dev/null || true
    done
    
    # 创建新的主入口文件
    local old_main="$target_path/lib/${old_name}.dart"
    local new_main="$target_path/lib/${new_name}.dart"
    if [[ -f "$old_main" && ! -f "$new_main" ]]; then
        echo "// Auto-generated entry point for renamed plugin" > "$new_main"
        echo "// Original package: $old_name" >> "$new_main"
        echo "export '${old_name}.dart';" >> "$new_main"
        [[ "$VERBOSE" == "true" ]] && log_info "  创建主入口: $new_main" || true
    fi
    
    # 若源为 plugins/ 内本地 path 插件，删除旧目录
    if [[ "$source_path" == "$PLUGINS_DIR/"* ]] && [[ "$source_path" != "$target_path" ]] && [[ -d "$source_path" ]]; then
        log_info "  删除旧版本（替换）: $(basename "$source_path")"
        rm -rf "$source_path"
    fi
    
    [[ "$VERBOSE" == "true" ]] && log_info "  完成: $target_path" || true
}

# 更新项目 pubspec.yaml
update_project_pubspec() {
    local old_name="$1"
    local new_name="$2"
    local pubspec="$PROJECT_ROOT/pubspec.yaml"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 更新 pubspec.yaml: $old_name -> $new_name"
        return
    fi
    
    if grep -q "^  ${new_name}:" "$pubspec"; then
        [[ "$VERBOSE" == "true" ]] && log_info "  $new_name 已存在于 pubspec.yaml" || true
        return
    fi
    
    if grep -q "^  ${old_name}:" "$pubspec"; then
        cp "$pubspec" "${pubspec}.bak"
        
        local temp_file=$(mktemp)
        local in_old_dep=false
        local indent=""
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^([[:space:]]*)${old_name}: ]]; then
                indent="${BASH_REMATCH[1]}"
                in_old_dep=true
                
                if [[ "$line" =~ ^[[:space:]]*${old_name}:[[:space:]]+[^\{] ]]; then
                    echo "${indent}${new_name}:" >> "$temp_file"
                    echo "${indent}  path: plugins/$new_name" >> "$temp_file"
                    in_old_dep=false
                else
                    echo "${indent}${new_name}:" >> "$temp_file"
                    echo "${indent}  path: plugins/$new_name" >> "$temp_file"
                fi
            elif [[ "$in_old_dep" == "true" ]]; then
                if [[ "$line" =~ ^[[:space:]]{0,${#indent}}[^[:space:]] ]] && [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
                    in_old_dep=false
                    echo "$line" >> "$temp_file"
                fi
            else
                echo "$line" >> "$temp_file"
            fi
        done < "$pubspec"
        
        mv "$temp_file" "$pubspec"
        [[ "$VERBOSE" == "true" ]] && log_info "  更新 pubspec.yaml: $old_name -> $new_name" || true
    else
        local dev_deps_line=$(grep -n "^dev_dependencies:" "$pubspec" | head -1 | cut -d: -f1)
        
        if [[ -n "$dev_deps_line" ]]; then
            sed -i '' "${dev_deps_line}i\\
  ${new_name}:\\
    path: plugins/${new_name}\\

" "$pubspec"
            [[ "$VERBOSE" == "true" ]] && log_info "  添加新依赖到 pubspec.yaml: $new_name" || true
        else
            log_warning "未找到 dev_dependencies 部分，无法添加 $new_name"
        fi
    fi
}

# 更新 flutter_base/pubspec.yaml
update_flutter_base_pubspec() {
    local old_name="$1"
    local new_name="$2"
    local flutter_base_pubspec="$FLUTTER_BASE_DIR/pubspec.yaml"
    
    if [[ ! -f "$flutter_base_pubspec" ]]; then
        return
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 更新 flutter_base/pubspec.yaml: $old_name -> $new_name"
        return
    fi
    
    if grep -q "^  ${old_name}:" "$flutter_base_pubspec"; then
        local temp_file=$(mktemp)
        local in_old_dep=false
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^([[:space:]]*)${old_name}: ]]; then
                in_old_dep=true
                echo "  ${new_name}:" >> "$temp_file"
                echo "    path: ../plugins/${new_name}" >> "$temp_file"
            elif [[ "$in_old_dep" == "true" ]]; then
                if [[ "$line" =~ ^[[:space:]]+path: ]]; then
                    in_old_dep=false
                elif [[ "$line" =~ ^[[:space:]]*[a-z_]+: ]] || [[ -z "$line" ]] || [[ "$line" =~ ^[^[:space:]] ]]; then
                    in_old_dep=false
                    echo "$line" >> "$temp_file"
                fi
            else
                echo "$line" >> "$temp_file"
            fi
        done < "$flutter_base_pubspec"
        
        mv "$temp_file" "$flutter_base_pubspec"
        [[ "$VERBOSE" == "true" ]] && log_info "  更新 flutter_base/pubspec.yaml: $old_name -> $new_name" || true
    fi
}

# 更新项目中的 Dart import
update_dart_imports() {
    local old_name="$1"
    local new_name="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 更新 Dart imports: $old_name -> $new_name"
        return
    fi
    
    local search_dirs=("$PROJECT_ROOT/lib")
    if [[ -d "$FLUTTER_BASE_DIR/lib" ]]; then
        search_dirs+=("$FLUTTER_BASE_DIR/lib")
    fi
    # flutter_base 子模块的 lib/ 目录（md 项目子包可能互相引用）
    if project_uses_flutter_base "$CURRENT_PROJECT" && [[ -d "$FLUTTER_BASE_DIR" ]]; then
        for _submod_lib in "$FLUTTER_BASE_DIR"/*/lib; do
            [[ -d "$_submod_lib" ]] && search_dirs+=("$_submod_lib")
        done
    fi
    # plugins/ 中已重命名的插件（跨插件 import 更新）
    if [[ -d "$PLUGINS_DIR" ]]; then
        for _plugin_lib in "$PLUGINS_DIR"/*/lib; do
            [[ -d "$_plugin_lib" ]] && search_dirs+=("$_plugin_lib")
        done
    fi
    
    for search_dir in "${search_dirs[@]}"; do
        find "$search_dir" -type f -name "*.dart" 2>/dev/null | while read file; do
            if grep -q "package:${old_name}/" "$file"; then
                sed -i '' "s|package:${old_name}/|package:${new_name}/|g" "$file"
                [[ "$VERBOSE" == "true" ]] && log_info "  更新: $file" || true
            fi
        done
    done
}

# 检查插件是否被其他包传递依赖
check_transitive_dependency() {
    local plugin_name="$1"
    
    local transitive_count=$(fvm flutter pub deps 2>/dev/null | grep -c "${plugin_name}\.\.\.$" 2>/dev/null || echo "0")
    transitive_count=$(echo "$transitive_count" | head -1 | tr -d '[:space:]')
    
    if [[ "$transitive_count" -gt 0 ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "  $plugin_name 被 $transitive_count 个其他包传递依赖" || true
        return 0
    else
        return 1
    fi
}

# 获取插件的传递依赖路径
get_transitive_dependency_paths() {
    local plugin_name="$1"
    
    fvm flutter pub deps 2>/dev/null | \
        grep -B50 "${plugin_name}\.\.\." 2>/dev/null | \
        grep -E "^[├└]── [a-z]" | \
        tail -1 | \
        sed 's/^[├└]── //' | \
        awk '{print $1}' | \
        grep -v "^${plugin_name}$" | \
        sort -u
}

# 应用映射配置
apply_mapping() {
    log_step "应用 Framework 重命名映射..."
    
    if [[ ! -f "$MAPPING_FILE" ]]; then
        log_error "映射配置不存在: $MAPPING_FILE"
        log_info "请先运行 $0 -g 生成配置"
        exit 1
    fi
    
    detect_pub_cache
    
    local mappings=$(parse_mapping)
    if [[ -z "$mappings" ]]; then
        log_error "映射配置为空或格式错误"
        log_info "配置文件格式: 原始包名 -> 新包名"
        exit 1
    fi
    
    # 选择性清理：仅删除映射中会重新生成的插件
    if [[ -d "$PLUGINS_DIR" ]] && [[ "$(ls -A "$PLUGINS_DIR" 2>/dev/null)" ]]; then
        local to_remove=()
        while IFS= read -r line; do
            local new_name=$(echo "$line" | sed 's/\s*->\s*/|/' | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$new_name" ]] && [[ -d "$PLUGINS_DIR/$new_name" ]] && to_remove+=("$new_name")
        done <<< "$mappings"
        if [[ ${#to_remove[@]} -gt 0 ]]; then
            log_info "清理映射中的旧插件: ${to_remove[*]}"
            for name in "${to_remove[@]}"; do
                rm -rf "$PLUGINS_DIR/$name"
            done
        fi
    fi
    mkdir -p "$PLUGINS_DIR"
    
    # 恢复 flutter_base（如果是 git 仓库）
    if [[ -d "$FLUTTER_BASE_DIR/.git" ]]; then
        log_info "恢复 flutter_base 到原始状态..."
        git -C "$FLUTTER_BASE_DIR" checkout -- pubspec.yaml lib/ 2>/dev/null || true
    fi
    
    local count=0
    local skipped=0
    
    echo ""
    echo "=== 开始重命名 ==="
    echo ""
    
    while IFS= read -r line; do
        local old_name=$(echo "$line" | sed 's/\s*->\s*/|/' | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local new_name=$(echo "$line" | sed 's/\s*->\s*/|/' | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [[ -z "$old_name" ]] || [[ -z "$new_name" ]]; then
            continue
        fi
        
        local source_path=""
        
        # 1. 检查是否为本地 path 依赖
        source_path=$(find_local_plugin_path "$old_name")
        [[ -n "$source_path" ]] && [[ "$VERBOSE" == "true" ]] && log_info "  使用本地路径: $old_name -> $source_path" || true
        
        # 2. 检查 pub cache
        if [[ -z "$source_path" ]]; then
            source_path=$(find_pub_cache_plugin_path "$old_name")
        fi
        
        # 3. 检查 flutter_base
        if [[ -z "$source_path" ]] && [[ -d "$FLUTTER_BASE_DIR/$old_name" ]]; then
            source_path="$FLUTTER_BASE_DIR/$old_name"
        fi
        
        # 4. 检查已有 plugins
        if [[ -z "$source_path" ]] && [[ -d "$PLUGINS_DIR/$old_name" ]]; then
            source_path="$PLUGINS_DIR/$old_name"
        fi
        
        if [[ -z "$source_path" ]]; then
            log_warning "跳过: $old_name (未找到源)"
            skipped=$((skipped + 1))
            continue
        fi
        
        if ! is_apple_native_plugin_dir "$source_path"; then
            [[ "$VERBOSE" == "true" ]] && log_info "跳过: $old_name (无 iOS 原生代码)" || true
            skipped=$((skipped + 1))
            continue
        fi
        
        # flutter_base 子模块跳过传递依赖检查（其 pubspec 会同步更新）
        local _is_flutter_base_module=false
        if [[ "$source_path" == "$FLUTTER_BASE_DIR/"* ]]; then
            _is_flutter_base_module=true
        fi
        if [[ "$_is_flutter_base_module" == "false" ]] && check_transitive_dependency "$old_name"; then
            log_warning "跳过: $old_name (被其他包传递依赖，重命名会导致冲突)"
            skipped=$((skipped + 1))
            continue
        fi
        
        rename_plugin "$source_path" "$old_name" "$new_name"
        update_project_pubspec "$old_name" "$new_name"
        update_flutter_base_pubspec "$old_name" "$new_name"
        update_dart_imports "$old_name" "$new_name"
        
        _REPORT_RENAME_ENTRIES+=("$old_name → $new_name")
        count=$((count + 1))
        
    done <<< "$mappings"

    _REPORT_RENAME_COUNT=$count
    _REPORT_RENAME_SKIPPED=$skipped
    
    echo ""
    log_success "完成! 重命名 $count 个插件, 跳过 $skipped 个"
    
    if [[ "$DRY_RUN" == "false" && "$_IN_RUN_ALL" != "true" ]]; then
        echo ""
        log_info "后续步骤:"
        if project_uses_flutter_base "$CURRENT_PROJECT" && [[ -d "$FLUTTER_BASE_DIR" ]]; then
            echo "  1. 运行 cd flutter_base && fvm flutter pub get  # flutter_base 优先"
            echo "  2. 运行 fvm flutter pub get                    # 主工程"
            echo "  3. 运行 cd ios && pod install"
        else
            echo "  1. 运行 fvm flutter pub get"
            echo "  2. 运行 cd ios && pod install"
        fi
        echo "  或使用 $0 run 一键完成全部流程"
    fi
}

# =============================================
# Phase 1.5: 传递依赖本地化（仅复制，不重命名）
# =============================================

# 将因传递依赖冲突而跳过重命名的插件复制到 plugins/ 以便 L0 变异
# 这些插件不能重命名（父包按原名引入），但可以注入唯一代码
localize_skipped_plugins() {
    if [[ ! -f "$MAPPING_FILE" ]]; then
        return
    fi

    detect_pub_cache

    # 从映射文件中提取被跳过的插件名
    # 格式: "# image_picker_ios" 在跳过区域内
    local in_skip_section=false
    local skipped_names=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "# 跳过的插件 (有传递依赖冲突"* ]]; then
            in_skip_section=true
            continue
        fi
        if [[ "$in_skip_section" == "true" ]]; then
            if [[ "$line" =~ ^#\ ([a-z_][a-z_0-9]*)$ ]]; then
                skipped_names+=("${BASH_REMATCH[1]}")
            fi
        fi
    done < "$MAPPING_FILE"

    if [[ ${#skipped_names[@]} -eq 0 ]]; then
        log_info "无需本地化的传递依赖插件"
        return
    fi

    local localized=0

    for plugin_name in "${skipped_names[@]}"; do
        # 已存在于 plugins/ 且有文件则跳过；空目录（复制失败残留）则清除重来
        if [[ -d "$PLUGINS_DIR/$plugin_name" ]]; then
            local has_any_file
            has_any_file=$(find "$PLUGINS_DIR/$plugin_name" -type f -print -quit 2>/dev/null)
            if [[ -n "$has_any_file" ]]; then
                [[ "$VERBOSE" == "true" ]] && log_info "  $plugin_name 已在 plugins/，跳过" || true
                continue
            fi
            log_info "  $plugin_name 目录存在但无文件，重新复制..."
            rm -rf "$PLUGINS_DIR/$plugin_name"
        fi

        local source_path
        # 优先本地 path 依赖，再检查 flutter_base，最后 pub cache
        source_path=$(find_local_plugin_path "$plugin_name")
        if [[ -z "$source_path" ]] && [[ -d "$FLUTTER_BASE_DIR/$plugin_name" ]]; then
            source_path="$FLUTTER_BASE_DIR/$plugin_name"
        fi
        if [[ -z "$source_path" ]]; then
            source_path=$(find_pub_cache_plugin_path "$plugin_name")
        fi

        if [[ -z "$source_path" ]]; then
            log_warning "  $plugin_name: 未在本地路径/flutter_base/pub cache 中找到，跳过"
            continue
        fi

        if ! is_apple_native_plugin_dir "$source_path"; then
            [[ "$VERBOSE" == "true" ]] && log_info "  $plugin_name: 无 iOS 原生代码，跳过" || true
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "  [DRY-RUN] 本地化: $plugin_name (仅复制，不重命名)"
            localized=$((localized + 1))
            continue
        fi

        log_step "本地化: $plugin_name (仅复制，用于 L0 变异)"
        mkdir -p "$PLUGINS_DIR"
        cp -R "$source_path" "$PLUGINS_DIR/$plugin_name"

        rm -rf "$PLUGINS_DIR/$plugin_name/.git" 2>/dev/null || true
        rm -rf "$PLUGINS_DIR/$plugin_name/.dart_tool" 2>/dev/null || true
        rm -rf "$PLUGINS_DIR/$plugin_name/build" 2>/dev/null || true
        rm -rf "$PLUGINS_DIR/$plugin_name/example" 2>/dev/null || true

        # 验证复制是否成功
        local copied_files
        copied_files=$(find "$PLUGINS_DIR/$plugin_name" -type f -print -quit 2>/dev/null)
        if [[ -z "$copied_files" ]]; then
            log_warning "  $plugin_name: cp 复制后无文件，尝试 rsync..."
            rm -rf "$PLUGINS_DIR/$plugin_name"
            rsync -a "$source_path/" "$PLUGINS_DIR/$plugin_name/"
            rm -rf "$PLUGINS_DIR/$plugin_name/.git" "$PLUGINS_DIR/$plugin_name/.dart_tool" \
                   "$PLUGINS_DIR/$plugin_name/build" "$PLUGINS_DIR/$plugin_name/example" 2>/dev/null || true
        fi

        # 通过 dependency_overrides 强制使用本地路径
        # 不能改 dependencies（父包要求 hosted 源，path 源会冲突）
        local pubspec="$PROJECT_ROOT/pubspec.yaml"

        if ! grep -q "^dependency_overrides:" "$pubspec" 2>/dev/null; then
            echo "" >> "$pubspec"
            echo "dependency_overrides:" >> "$pubspec"
        fi

        # 检查是否已在 dependency_overrides 中
        local already_overridden=false
        local in_overrides=false
        while IFS= read -r pline; do
            if [[ "$pline" == "dependency_overrides:" ]]; then in_overrides=true; continue; fi
            if [[ "$in_overrides" == "true" ]]; then
                [[ "$pline" =~ ^[a-z] ]] && break
                [[ "$pline" =~ ^[[:space:]]+${plugin_name}: ]] && already_overridden=true && break
            fi
        done < "$pubspec"

        if [[ "$already_overridden" == "false" ]]; then
            local override_line
            override_line=$(grep -n "^dependency_overrides:" "$pubspec" | head -1 | cut -d: -f1)
            if [[ -n "$override_line" ]]; then
                sed -i '' "${override_line}a\\
  ${plugin_name}:\\
    path: plugins/${plugin_name}
" "$pubspec"
            fi
        fi

        localized=$((localized + 1))
    done

    if [[ $localized -gt 0 ]]; then
        local dry_prefix=""
        [[ "$DRY_RUN" == "true" ]] && dry_prefix="[DRY-RUN] "
        log_success "${dry_prefix}本地化 $localized 个传递依赖插件（不重命名，仅用于 L0 变异注入）"
    fi
}

# =============================================
# Phase 2: 变异函数
# =============================================

# 推导 seed
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
            log_info "Seed 来源: Bundle ID ($SEED)"
            return
        fi
    fi

    local config_file="$PROJECT_ROOT/ab_config.yaml"
    if [[ -f "$config_file" ]]; then
        local project
        project=$(grep "^project:" "$config_file" | head -1 | sed 's/^project: *//' | tr -d '\r\n"')
        if [[ -n "$project" ]]; then
            SEED="zt_${project}_$(date +%Y%m)"
            log_info "Seed 来源: ab_config project ($SEED)"
            return
        fi
    fi

    SEED="zt_$(openssl rand -hex 8)"
    log_warning "无法自动推导 seed，已随机生成: $SEED"
    log_info "建议将 seed 记录到 ab_config.yaml 或通过 --seed 参数传入"
}

# 加载项目清单
load_manifest() {
    if [[ "$MANIFEST_LOADED" == "true" ]]; then
        return
    fi

    if [[ -z "$MANIFEST_FILE" ]]; then
        local project=""
        local config_file="$PROJECT_ROOT/ab_config.yaml"
        if [[ -f "$config_file" ]]; then
            project=$(grep "^project:" "$config_file" | head -1 | sed 's/^project: *//' | tr -d '\r\n"')
        fi
        if [[ -n "$project" && -f "$MANIFESTS_DIR/${project}.conf" ]]; then
            MANIFEST_FILE="$MANIFESTS_DIR/${project}.conf"
        fi
    fi

    if [[ -z "$MANIFEST_FILE" || ! -f "$MANIFEST_FILE" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "无项目清单，所有插件使用 L0 (仅注入)" || true
        return
    fi

    log_info "加载项目清单: $(basename "$MANIFEST_FILE")"

    MANIFEST_TMPFILE=$(mktemp)
    local entry_count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        local type name version level
        IFS=':' read -r type name version level <<< "$line"
        [[ -z "$name" || -z "$level" ]] && continue

        echo "${name}:${level}" >> "$MANIFEST_TMPFILE"
        entry_count=$((entry_count + 1))
        [[ "$VERBOSE" == "true" ]] && log_info "  $name → $level" || true
    done < "$MANIFEST_FILE"

    MANIFEST_LOADED=true
    log_info "  清单条目: $entry_count 个"

    # 构建反向映射（new_name → original_name）用于清单/profile 查找
    _REVERSE_MAP_FILE=$(mktemp)
    if [[ -f "$MAPPING_FILE" ]]; then
        grep -v "^#" "$MAPPING_FILE" | grep -- "->" | while IFS= read -r mline; do
            local orig new
            orig=$(echo "$mline" | sed 's/\s*->\s*/|/' | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            new=$(echo "$mline" | sed 's/\s*->\s*/|/' | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$orig" && -n "$new" ]] && echo "${new}:${orig}" >> "$_REVERSE_MAP_FILE"
        done
    fi
}

# 获取重命名前的原始插件名（如果有映射的话）
get_original_plugin_name() {
    local plugin_name="$1"
    if [[ -n "$_REVERSE_MAP_FILE" && -f "$_REVERSE_MAP_FILE" ]]; then
        local orig
        orig=$(grep "^${plugin_name}:" "$_REVERSE_MAP_FILE" 2>/dev/null | head -1 | cut -d: -f2)
        [[ -n "$orig" ]] && echo "$orig" && return
    fi
    echo "$plugin_name"
}

# 获取插件的混淆级别
get_plugin_level() {
    local plugin_name="$1"

    if [[ "$MANIFEST_LOADED" == "true" && -f "$MANIFEST_TMPFILE" ]]; then
        # 先查当前名（适用于未重命名的传递依赖/本地插件）
        local level
        level=$(grep "^${plugin_name}:" "$MANIFEST_TMPFILE" 2>/dev/null | head -1 | cut -d: -f2)
        if [[ -n "$level" ]]; then
            echo "$level"
            return
        fi

        # 再查原始名（适用于重命名后的插件）
        local orig_name
        orig_name=$(get_original_plugin_name "$plugin_name")
        if [[ "$orig_name" != "$plugin_name" ]]; then
            level=$(grep "^${orig_name}:" "$MANIFEST_TMPFILE" 2>/dev/null | head -1 | cut -d: -f2)
            if [[ -n "$level" ]]; then
                echo "$level"
                return
            fi
        fi
    fi

    echo "L0"
}

# 从插件目录的 pubspec.yaml 读取版本号
# 返回: 版本号 (如 "11.2.0")，未找到则返回空
get_plugin_version() {
    local plugin_dir="$1"
    local pubspec="$plugin_dir/pubspec.yaml"
    [[ -f "$pubspec" ]] || return 0
    grep "^version:" "$pubspec" 2>/dev/null | head -1 | sed 's/^version:[[:space:]]*//' | tr -d '\r\n"' | sed "s/[[:space:]]*#.*//"
}

# 从版本号提取主版本号
# "11.2.0" → "11", "6.1.3" → "6"
get_major_version() {
    echo "$1" | cut -d. -f1
}

# 查找并加载 profile 文件（版本感知）
#
# 查找优先级（以 remote 依赖 device_info_plus 11.2.0 为例）:
#   1. remote/device_info_plus@11.sh    — 主版本精确匹配
#   2. remote/device_info_plus.sh       — 通用（版本无关）
#   3. local/device_info_plus@11.sh     — 本地同名
#   4. local/device_info_plus.sh        — 本地通用
#
# 加载后校验: PROFILE_VERSION 与实际主版本号是否兼容
load_profile() {
    local plugin_name="$1"
    local orig_name
    orig_name=$(get_original_plugin_name "$plugin_name")

    # 从 plugins/ 中的实际源码读取版本
    local actual_version=""
    local actual_major=""
    if [[ -d "$PLUGINS_DIR/$plugin_name" ]]; then
        actual_version=$(get_plugin_version "$PLUGINS_DIR/$plugin_name")
        [[ -n "$actual_version" ]] && actual_major=$(get_major_version "$actual_version")
    fi

    # 按优先级查找 profile 文件（先查原始名，再查当前名）
    local profile_file=""
    local search_dirs=("remote" "local")
    local search_names=("$orig_name")
    [[ "$orig_name" != "$plugin_name" ]] && search_names+=("$plugin_name")

    for sname in "${search_names[@]}"; do
        for dir in "${search_dirs[@]}"; do
            # 1. 带主版本号的 profile（精确匹配）
            if [[ -n "$actual_major" && -f "$PROFILES_DIR/$dir/${sname}@${actual_major}.sh" ]]; then
                profile_file="$PROFILES_DIR/$dir/${sname}@${actual_major}.sh"
                break 2
            fi
            # 2. 通用 profile（无版本号）
            if [[ -f "$PROFILES_DIR/$dir/${sname}.sh" ]]; then
                profile_file="$PROFILES_DIR/$dir/${sname}.sh"
                break 2
            fi
        done
    done

    if [[ -z "$profile_file" ]]; then
        return 1
    fi

    # 重置并加载
    PROFILE_NAME=""
    PROFILE_VERSION=""
    PROFILE_STATUS=""
    PROFILE_PROTECTED=()

    source "$profile_file"

    if [[ "$PROFILE_STATUS" == "disabled" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "  profile $plugin_name: disabled，跳过" || true
        return 1
    fi

    # 版本兼容性校验：PROFILE_VERSION 为数字版本时，与实际主版本比较
    # "local" 等非数字版本跳过校验
    if [[ -n "$PROFILE_VERSION" && -n "$actual_major" && "$PROFILE_VERSION" =~ ^[0-9] ]]; then
        local profile_major
        profile_major=$(get_major_version "$PROFILE_VERSION")
        if [[ "$profile_major" != "$actual_major" ]]; then
            log_warning "  $plugin_name: profile 版本 ($PROFILE_VERSION) 与实际版本 ($actual_version) 主版本不匹配，降级 L0"
            return 1
        fi
    fi

    [[ "$VERBOSE" == "true" ]] && log_info "  加载 profile: $(basename "$profile_file") (v${actual_version:-?}, status: $PROFILE_STATUS)" || true
    return 0
}

# 加载基础变换函数库
load_base_transforms() {
    local bt_file="$PROFILES_DIR/base_transforms.sh"
    if [[ -f "$bt_file" ]]; then
        source "$bt_file"
        [[ "$VERBOSE" == "true" ]] && log_info "基础变换函数库已加载" || true
    fi
}

# 生成单个 ObjC 变异文件
generate_mutation_file() {
    local plugin_name="$1"
    local file_index="$2"
    local target_dir="$3"

    local base_hash
    base_hash=$(hash_derive "${SEED}:${plugin_name}:${file_index}")
    local class_name
    class_name=$(hex_to_classname "$base_hash")
    local full_class="_ZTM${class_name}"
    local filename="${INJECT_PREFIX}${plugin_name}_${file_index}.m"
    local filepath="${target_dir}/${filename}"

    local num_strings=$OVERRIDE_STRINGS
    if [[ $num_strings -eq 0 ]]; then
        num_strings=$(( (16#${base_hash:24:2} % 30) + 25 ))
    fi

    local num_ops=$(( (16#${base_hash:26:2} % 14) + 10 ))

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "  [DRY-RUN] 生成 $filename (class: $full_class, ${num_strings} strings, ${num_ops} ops)" || true
        return
    fi

    local string_entries=""
    for (( s=0; s<num_strings; s++ )); do
        local str_hash
        str_hash=$(hash_derive "${SEED}:${plugin_name}:${file_index}:s:${s}")
        local str_val
        str_val=$(hex_to_string_value "$str_hash")
        string_entries="${string_entries}        @\"${str_val}\",
"
    done

    local info_entries=""
    local info_count=$(( (16#${base_hash:20:2} % 12) + 10 ))
    for (( k=0; k<info_count; k++ )); do
        local k_hash
        k_hash=$(hash_derive "${SEED}:${plugin_name}:${file_index}:k:${k}")
        local key_name
        key_name=$(hex_to_identifier "$k_hash")
        local val_mode=$(( 16#${k_hash:16:1} % 3 ))
        case $val_mode in
            0)
                local int_val
                int_val=$(hex_to_int "$k_hash" 8)
                info_entries="${info_entries}        info[@\"_zt_${key_name}\"] = @(${int_val});
"
                ;;
            1)
                local str_val
                str_val=$(hex_to_string_value "$k_hash")
                info_entries="${info_entries}        info[@\"_zt_${key_name}\"] = @\"${str_val}\";
"
                ;;
            2)
                local float_val="$(( 16#${k_hash:8:4} )).$(( 16#${k_hash:12:4} ))"
                info_entries="${info_entries}        info[@\"_zt_${key_name}\"] = @(${float_val});
"
                ;;
        esac
    done

    local compute_body=""
    local ops=("^" "+" "-" "*" "|" "&")
    local shifts=("1" "3" "5" "7" "11" "13" "17" "19")
    for (( o=0; o<num_ops; o++ )); do
        local op_hash
        op_hash=$(hash_derive "${SEED}:${plugin_name}:${file_index}:op:${o}")
        local op_type=$(( 16#${op_hash:0:2} % 8 ))
        local op_val=$(( 16#${op_hash:2:8} ))
        local shift_idx=$(( 16#${op_hash:10:2} % ${#shifts[@]} ))
        local op_val2=$(( 16#${op_hash:12:8} ))
        case $op_type in
            0)
                compute_body="${compute_body}    result = result ^ ${op_val}UL;
"
                ;;
            1)
                compute_body="${compute_body}    result = result + ${op_val}UL;
"
                ;;
            2)
                compute_body="${compute_body}    result = (result << ${shifts[$shift_idx]}) | (result >> (64 - ${shifts[$shift_idx]}));
"
                ;;
            3)
                compute_body="${compute_body}    result = result ^ (result >> ${shifts[$shift_idx]});
    result = result * ${op_val}UL;
"
                ;;
            4)
                compute_body="${compute_body}    result = ~result + ${op_val}UL;
"
                ;;
            5)
                compute_body="${compute_body}    result = (result ^ ${op_val}UL) + (result >> ${shifts[$shift_idx]});
    result = result ^ (result << ${shifts[$(( (shift_idx + 1) % ${#shifts[@]} ))]});
"
                ;;
            6)
                compute_body="${compute_body}    { NSUInteger t = result; result = (t >> ${shifts[$shift_idx]}) ^ (t * ${op_val2}UL) ^ ${op_val}UL; }
"
                ;;
            7)
                compute_body="${compute_body}    result = ((result & 0xFFFFFFFF00000000UL) >> 32) | ((result & 0x00000000FFFFFFFFUL) << 32);
    result = result ^ ${op_val}UL;
"
                ;;
        esac
    done

    local sel_hash
    sel_hash=$(hash_derive "${SEED}:${plugin_name}:${file_index}:sel")
    local sel_name
    sel_name=$(hex_to_identifier "$sel_hash")

    local extra_methods=""
    local num_extra=$(( (16#${base_hash:28:2} % 8) + 6 ))
    for (( e=0; e<num_extra; e++ )); do
        local em_hash
        em_hash=$(hash_derive "${SEED}:${plugin_name}:${file_index}:em:${e}")
        local em_name
        em_name=$(hex_to_identifier "$em_hash")
        local em_int1=$(hex_to_int "$em_hash" 0)
        local em_int2=$(hex_to_int "$em_hash" 8)
        local em_type=$(( 16#${em_hash:16:2} % 5 ))
        local shift_v=$(( (16#${em_hash:18:2} % 19) + 1 ))

        case $em_type in
            0)
                extra_methods="${extra_methods}
+ (NSUInteger)_zt_${em_name}:(NSUInteger)x {
    NSUInteger r = x ^ ${em_int1}UL;
    r = (r << ${shift_v}) | (r >> (64 - ${shift_v}));
    r = r + ${em_int2}UL;
    return r;
}
" ;;
            1)
                local em_hash2
                em_hash2=$(hash_derive "${SEED}:${plugin_name}:${file_index}:emx:${e}")
                local em_int3=$(hex_to_int "$em_hash2" 0)
                local em_int4=$(hex_to_int "$em_hash2" 8)
                extra_methods="${extra_methods}
+ (NSData *)_zt_${em_name}:(NSUInteger)x {
    uint8_t buf[32];
    NSUInteger v = x ^ ${em_int1}UL;
    for (int i = 0; i < 32; i++) {
        v = v * ${em_int3}UL + ${em_int4}UL;
        buf[i] = (uint8_t)(v >> ${shift_v});
    }
    return [NSData dataWithBytes:buf length:sizeof(buf)];
}
" ;;
            2)
                local num_cases=$(( (16#${em_hash:20:2} % 4) + 3 ))
                local switch_body=""
                for (( sc=0; sc<num_cases; sc++ )); do
                    local sc_hash
                    sc_hash=$(hash_derive "${SEED}:${plugin_name}:${file_index}:sc:${e}:${sc}")
                    local sc_val=$(hex_to_int "$sc_hash" 0)
                    switch_body="${switch_body}        case ${sc}: r = r ^ ${sc_val}UL; break;
"
                done
                extra_methods="${extra_methods}
+ (NSUInteger)_zt_${em_name}:(NSUInteger)x mode:(NSUInteger)m {
    NSUInteger r = x + ${em_int1}UL;
    switch (m % $(( num_cases ))) {
${switch_body}        default: r = r ^ ${em_int2}UL; break;
    }
    return r;
}
" ;;
            3)
                extra_methods="${extra_methods}
+ (NSString *)_zt_${em_name}:(NSUInteger)x {
    NSUInteger h = x;
    h = (h ^ (h >> 16)) * ${em_int1}UL;
    h = (h ^ (h >> 13)) * ${em_int2}UL;
    h = h ^ (h >> 16);
    return [NSString stringWithFormat:@\"%016lx\", (unsigned long)h];
}
" ;;
            4)
                local arr_count=$(( (16#${em_hash:22:2} % 6) + 4 ))
                local arr_items=""
                for (( ai=0; ai<arr_count; ai++ )); do
                    local ai_hash
                    ai_hash=$(hash_derive "${SEED}:${plugin_name}:${file_index}:ai:${e}:${ai}")
                    local ai_val=$(hex_to_int "$ai_hash" 0)
                    arr_items="${arr_items} @(${ai_val}UL),"
                done
                extra_methods="${extra_methods}
+ (NSArray *)_zt_${em_name}:(NSUInteger)count {
    static NSArray *_table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _table = @[${arr_items} ];
    });
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count && i < _table.count; i++) {
        NSUInteger v = [_table[i] unsignedIntegerValue] ^ (i * ${em_int1}UL);
        [result addObject:@(v)];
    }
    return result;
}
" ;;
        esac
    done

    # 生成 property 声明
    local prop_hash
    prop_hash=$(hash_derive "${SEED}:${plugin_name}:${file_index}:props")
    local num_props=$(( (16#${prop_hash:0:2} % 6) + 4 ))
    local prop_decls=""
    local prop_synths=""
    local prop_inits=""
    for (( p=0; p<num_props; p++ )); do
        local ph
        ph=$(hash_derive "${SEED}:${plugin_name}:${file_index}:prop:${p}")
        local pname
        pname=$(hex_to_identifier "$ph")
        local ptype=$(( 16#${ph:16:1} % 3 ))
        case $ptype in
            0)
                prop_decls="${prop_decls}@property (nonatomic, assign) NSUInteger _zt_${pname};
"
                prop_inits="${prop_inits}        self._zt_${pname} = $(hex_to_int "$ph" 0)UL;
"
                ;;
            1)
                prop_decls="${prop_decls}@property (nonatomic, copy) NSString *_zt_${pname};
"
                local pval
                pval=$(hex_to_string_value "$ph")
                prop_inits="${prop_inits}        self._zt_${pname} = @\"${pval}\";
"
                ;;
            2)
                prop_decls="${prop_decls}@property (nonatomic, strong) NSData *_zt_${pname};
"
                prop_inits="${prop_inits}        self._zt_${pname} = [NSData data];
"
                ;;
        esac
    done

    cat > "$filepath" << OBJC_EOF
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface ${full_class} : NSObject
${prop_decls}@end

@implementation ${full_class}

+ (void)load {
    @autoreleasepool {
        NSMutableDictionary *info = [NSMutableDictionary new];
${info_entries}
        info[@"_zt_os"] = [[NSProcessInfo processInfo] operatingSystemVersionString];
        info[@"_zt_id"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        info[@"_zt_ts"] = @([[NSDate date] timeIntervalSince1970]);

        objc_setAssociatedObject(
            [${full_class} class],
            @selector(_zt_info_${sel_name}),
            info,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
${prop_inits}    }
    return self;
}

+ (NSDictionary *)_zt_info_${sel_name} {
    return objc_getAssociatedObject([self class], @selector(_zt_info_${sel_name}));
}

+ (NSString *)_zt_variant_${sel_name}:(NSUInteger)idx {
    static NSArray *_items;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _items = @[
${string_entries}        ];
    });
    return _items[idx % _items.count];
}

+ (NSUInteger)_zt_compute_${sel_name}:(NSUInteger)input {
    NSUInteger result = input;
${compute_body}    return result;
}

+ (NSDictionary *)_zt_describe_${sel_name} {
    return @{
        @"class": NSStringFromClass(self),
        @"info": [self _zt_info_${sel_name}] ?: @{},
        @"sample": [self _zt_variant_${sel_name}:0] ?: @"",
    };
}
${extra_methods}
@end
OBJC_EOF

    [[ "$VERBOSE" == "true" ]] && log_info "  生成 $filename (class: $full_class, ${num_strings} strings)" || true
}

# 查找插件的 iOS 原生源码目录
find_ios_source_dir() {
    local plugin_path="$1"
    local plugin_name
    plugin_name=$(basename "$plugin_path")

    local candidates=(
        "$plugin_path/ios/Classes"
        "$plugin_path/darwin/Classes"
        "$plugin_path/ios/${plugin_name}/Sources/${plugin_name}"
        "$plugin_path/ios/${plugin_name}/Sources"
        "$plugin_path/darwin/${plugin_name}/Sources/${plugin_name}"
        "$plugin_path/darwin/${plugin_name}/Sources"
    )

    for dir in "${candidates[@]}"; do
        if [[ -d "$dir" ]]; then
            local native_count
            native_count=$(find "$dir" -maxdepth 3 \( -name "*.m" -o -name "*.swift" -o -name "*.h" \) 2>/dev/null | wc -l | tr -d ' ')
            if [[ $native_count -gt 0 ]]; then
                echo "$dir"
                return 0
            fi
        fi
    done

    for platform in "ios" "darwin"; do
        if [[ -d "$plugin_path/$platform" ]]; then
            local found_dir
            found_dir=$(find "$plugin_path/$platform" -type f \( -name "*.m" -o -name "*.swift" \) -print -quit 2>/dev/null)
            if [[ -n "$found_dir" ]]; then
                echo "$(dirname "$found_dir")"
                return 0
            fi
        fi
    done

    return 1
}

# 查找插件下所有 iOS 源码目录
find_all_ios_source_dirs() {
    local plugin_path="$1"
    local dirs=()

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local dominated=false
        for existing in "${dirs[@]}"; do
            if [[ "$dir" == "$existing"* ]]; then
                dominated=true
                break
            fi
        done
        if [[ "$dominated" == "false" ]]; then
            dirs+=("$dir")
        fi
    done < <(find "$plugin_path" -type f \( -name "*.m" -o -name "*.swift" \) -not -name "${INJECT_PREFIX}*" \
             \( -path "*/ios/*" -o -path "*/darwin/*" \) 2>/dev/null | \
             while read -r f; do dirname "$f"; done | sort -u)

    for dir in "${dirs[@]}"; do
        echo "$dir"
    done
}

# 清理插件中之前注入的文件，结果存入 _CLEAN_COUNT
clean_plugin_mutations() {
    local plugin_path="$1"
    _CLEAN_COUNT=0
    while IFS= read -r file; do
        if [[ "$DRY_RUN" == "true" ]]; then
            [[ "$VERBOSE" == "true" ]] && log_info "  [DRY-RUN] 删除 $(basename "$file")" || true
        else
            rm -f "$file"
        fi
        _CLEAN_COUNT=$((_CLEAN_COUNT + 1))
    done < <(find "$plugin_path" -name "${INJECT_PREFIX}*.m" -type f 2>/dev/null)
}

# 处理单个插件的变异，结果存入 _PLUGIN_FILES, _PLUGIN_LEVEL
mutate_plugin() {
    local plugin_path="$1"
    local plugin_name
    plugin_name=$(basename "$plugin_path")
    _PLUGIN_FILES=0
    _PLUGIN_LEVEL=""

    clean_plugin_mutations "$plugin_path"
    [[ $_CLEAN_COUNT -gt 0 ]] && [[ "$VERBOSE" == "true" ]] && log_info "  清理旧注入: $_CLEAN_COUNT 个文件" || true

    if [[ "$CLEAN_ONLY" == "true" ]]; then
        [[ $_CLEAN_COUNT -gt 0 ]] && log_info "  $plugin_name: 清理 $_CLEAN_COUNT 个变异文件" || true
        _PLUGIN_FILES=$_CLEAN_COUNT
        return
    fi

    local level
    level=$(get_plugin_level "$plugin_name")
    _PLUGIN_LEVEL="$level"

    if [[ "$level" == "disabled" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "  $plugin_name: disabled，跳过" || true
        return
    fi

    local source_dirs=()
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && source_dirs+=("$dir")
    done < <(find_all_ios_source_dirs "$plugin_path")

    if [[ ${#source_dirs[@]} -eq 0 ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "  $plugin_name: 无 iOS 原生代码，跳过" || true
        return
    fi

    local has_profile=false
    if [[ "$level" != "L0" ]]; then
        local profile_result=0
        load_profile "$plugin_name" || profile_result=$?
        if [[ $profile_result -eq 0 ]]; then
            has_profile=true
        else
            log_warning "  $plugin_name: 级别 $level 但无 profile，降级为 L0"
            level="L0"
            _PLUGIN_LEVEL="L0"
        fi
    fi

    if [[ "$has_profile" == "true" && "$level" != "L0" ]]; then
        log_info "  $plugin_name [$level] 使用 profile 变换..."
        # 为 profile 提供已发现的源码目录，避免 profile 内部重复查找（且重命名后路径不同）
        _PROFILE_SRC_DIRS=("${source_dirs[@]}")
        _PROFILE_CURRENT_NAME="$plugin_name"
        if [[ "$DRY_RUN" != "true" ]]; then
            profile_apply "$plugin_path" "$level" || log_warning "  $plugin_name: profile 应用出错"
        else
            log_info "    [DRY-RUN] 将应用 profile: $PROFILE_NAME ($level)"
        fi
        _PLUGIN_FILES=1
    else
        local plugin_hash
        plugin_hash=$(hash_derive "${SEED}:${plugin_name}")
        local num_classes=$OVERRIDE_CLASSES
        if [[ $num_classes -eq 0 ]]; then
            num_classes=$(( (16#${plugin_hash:0:2} % 8) + 10 ))
        fi

        local target_dir="${source_dirs[0]}"

        for (( i=0; i<num_classes; i++ )); do
            generate_mutation_file "$plugin_name" "$i" "$target_dir"
            _PLUGIN_FILES=$((_PLUGIN_FILES + 1))
        done

        if [[ ${#source_dirs[@]} -gt 1 ]]; then
            for (( d=1; d<${#source_dirs[@]}; d++ )); do
                local sub_dir="${source_dirs[$d]}"
                local sub_name
                sub_name=$(echo "$sub_dir" | sed "s|.*$plugin_name/||" | tr '/' '_')
                local sub_hash
                sub_hash=$(hash_derive "${SEED}:${plugin_name}:sub:${sub_name}")
                local sub_classes=$(( (16#${sub_hash:0:2} % 6) + 6 ))

                for (( i=0; i<sub_classes; i++ )); do
                    generate_mutation_file "${plugin_name}_${sub_name}" "$i" "$sub_dir"
                    _PLUGIN_FILES=$((_PLUGIN_FILES + 1))
                done
            done
        fi

        local dry_prefix=""
        [[ "$DRY_RUN" == "true" ]] && dry_prefix="[DRY-RUN] "
        log_info "  ${dry_prefix}$plugin_name [L0]: 注入 $_PLUGIN_FILES 个变异文件"
    fi

    if [[ "$VERIFY_AFTER" == "true" && "$DRY_RUN" != "true" ]]; then
        bt_verify_plugin "$plugin_path" 2>/dev/null || true
    fi

    # 如果注入了 .m 文件，确保 podspec 能编译它们
    if [[ "$DRY_RUN" != "true" && $_PLUGIN_FILES -gt 0 ]]; then
        _patch_podspec_for_objc "$plugin_path"
    fi
}

# 修补 Swift-only podspec，使其也能编译注入的 .m/.h 文件
# 策略：用 Ruby 语法直接追加 .m/.h 到 source_files 数组，避免 sed 正则问题
_patch_podspec_for_objc() {
    local plugin_path="$1"

    local has_m_files
    has_m_files=$(find "$plugin_path" -name "${INJECT_PREFIX}*.m" -type f -print -quit 2>/dev/null)
    [[ -z "$has_m_files" ]] && return 0

    local podspec
    podspec=$(find "$plugin_path" -name "*.podspec" \( -path "*/ios/*" -o -path "*/darwin/*" \) -print -quit 2>/dev/null)
    [[ -z "$podspec" ]] && return 0

    # 已修补则跳过
    grep -q 'zt_objc_injection' "$podspec" 2>/dev/null && return 0

    # 检查是否 Swift-only
    local src_line
    src_line=$(grep -E "s\.(ios\.)?source_files\s*=" "$podspec" 2>/dev/null | head -1)
    [[ -z "$src_line" ]] && return 0

    # 已包含 .m 或 通配的不需要修补
    echo "$src_line" | grep -qE '\.m|Classes/\*\*/\*' 2>/dev/null && return 0
    # 必须是 Swift-only
    echo "$src_line" | grep -q '\.swift' 2>/dev/null || return 0

    # 提取引号内的完整 glob 模式
    local swift_glob
    swift_glob=$(echo "$src_line" | sed -E "s/.*'([^']+\.swift)'.*/\1/")
    [[ -z "$swift_glob" || "$swift_glob" == "$src_line" ]] && return 0

    # 从 swift glob 派生 objc glob: 把 *.swift 替换为 *.{m,h}
    local objc_glob
    objc_glob=$(echo "$swift_glob" | sed 's/\*\.swift$/*.{m,h}/')

    # 用 Ruby 安全替换（避免 sed 正则对 ** 的问题）
    ruby -e "
      f = File.read('$podspec')
      pat = \"'${swift_glob}'\"
      rep = \"['${swift_glob}', '${objc_glob}'] # zt_objc_injection\"
      f.gsub!(pat, rep)
      File.write('$podspec', f)
    " 2>/dev/null || true

    # 添加 public_header_files（避免 Swift 混编模块警告）
    if ! grep -q 'public_header_files' "$podspec" 2>/dev/null; then
        local h_glob
        h_glob=$(echo "$swift_glob" | sed 's/\*\.swift$/*.h/')
        ruby -e "
          f = File.read('$podspec')
          f.sub!(/^(.*source_files.*)$/, \"\\\\1\n  s.public_header_files = '${h_glob}' # zt_objc_injection\")
          File.write('$podspec', f)
        " 2>/dev/null || true
    fi

    [[ "$VERBOSE" == "true" ]] && log_info "    [podspec] 已修补: $(basename "$podspec") 添加 ObjC 编译支持" || true
}

# 收集单个插件的详细变更信息，存入 _REPORT_DETAIL_ENTRIES
_collect_plugin_detail() {
    local plugin_dir="$1"
    local pname="$2"
    local level="$3"

    _REPORT_DETAIL_ENTRIES+=("") # 空行分隔
    _REPORT_DETAIL_ENTRIES+=("  [$pname] level=$level")

    # 新增注入文件
    local inject_files
    inject_files=$(find "$plugin_dir" -name "${INJECT_PREFIX}*.m" -type f 2>/dev/null | sort)
    if [[ -n "$inject_files" ]]; then
        _REPORT_DETAIL_ENTRIES+=("    新增文件:")
        while IFS= read -r f; do
            local fname
            fname=$(basename "$f")
            local lines
            lines=$(wc -l < "$f" | tr -d ' ')
            local classes
            classes=$(grep -c '@implementation' "$f" 2>/dev/null || true)
            local methods
            methods=$(grep -cE '^[[:space:]]*[-+][[:space:]]*\(' "$f" 2>/dev/null || true)
            _REPORT_DETAIL_ENTRIES+=("      + $fname  (${lines} 行, ${classes} 类, ${methods} 方法)")
        done <<< "$inject_files"
    fi

    # 被修改的原有文件（检测 _zt 前缀符号 / 死分支注入）
    if [[ "$level" != "L0" ]]; then
        local modified_files=()
        local all_src_files
        all_src_files=$(find "$plugin_dir" -type f \( -name "*.m" -o -name "*.swift" -o -name "*.h" \) \
                        -not -name "${INJECT_PREFIX}*" \
                        \( -path "*/ios/*" -o -path "*/darwin/*" \) 2>/dev/null)

        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local fname
            fname=$(basename "$f")
            local changes=()

            # 检查符号重命名
            local renamed
            renamed=$(grep -c '_zt[0-9a-f]\{4\}_' "$f" 2>/dev/null || true)
            [[ $renamed -gt 0 ]] && changes+=("重命名符号×${renamed}")

            # 检查死分支注入
            local deadbranch
            deadbranch=$(grep -c '_zt_' "$f" 2>/dev/null || true)
            local zt_mutate
            zt_mutate=$(grep -c "${INJECT_PREFIX}" "$f" 2>/dev/null || true)
            deadbranch=$((deadbranch - zt_mutate))
            [[ $deadbranch -lt 0 ]] && deadbranch=0
            [[ $deadbranch -gt 0 ]] && changes+=("死分支×${deadbranch}")

            if [[ ${#changes[@]} -gt 0 ]]; then
                local change_str
                change_str=$(printf '%s, ' "${changes[@]}")
                change_str="${change_str%, }"
                _REPORT_DETAIL_ENTRIES+=("    修改文件:")
                _REPORT_DETAIL_ENTRIES+=("      ~ $fname  ($change_str)")
            fi
        done <<< "$all_src_files"
    fi

    # podspec 修补
    if grep -rq 'zt_objc_injection' "$plugin_dir" 2>/dev/null; then
        _REPORT_DETAIL_ENTRIES+=("    podspec: 已修补 (添加 ObjC 编译支持)")
    fi
}

# 执行变异阶段（独立入口，也被 run_all 调用）
run_mutate() {
    echo ""
    echo "=========================================="
    echo "      原生代码变异 (Native Mutation)"
    echo "=========================================="
    echo ""

    derive_seed
    local seed_hash
    seed_hash=$(hash_derive "$SEED")
    log_info "Seed: $SEED"
    log_info "Seed Hash: ${seed_hash:0:16}..."

    load_base_transforms
    load_manifest
    _build_class_words_pool

    local _has_flutter_base=false
    project_uses_flutter_base "$CURRENT_PROJECT" && [[ -d "$FLUTTER_BASE_DIR" ]] && _has_flutter_base=true

    if [[ ! -d "$PLUGINS_DIR" ]] && [[ "$_has_flutter_base" == "false" ]]; then
        log_warning "plugins 目录不存在，跳过变异"
        return
    fi

    local total_plugins=0
    local total_files=0
    local processed_plugins=0
    local level_counts_L0=0
    local level_counts_L1=0
    local level_counts_L2=0
    local level_counts_L3=0
    local level_counts_disabled=0

    echo ""
    if [[ "$CLEAN_ONLY" == "true" ]]; then
        log_step "清理所有注入的变异文件..."
    else
        log_step "开始原生代码变异..."
    fi
    echo ""

    for plugin_dir in "$PLUGINS_DIR"/*/; do
        [[ -d "$plugin_dir" ]] || continue
        total_plugins=$((total_plugins + 1))

        mutate_plugin "$plugin_dir"
        local pname
        pname=$(basename "$plugin_dir")
        if [[ $_PLUGIN_FILES -gt 0 ]]; then
            total_files=$((total_files + _PLUGIN_FILES))
            processed_plugins=$((processed_plugins + 1))
            _REPORT_MUTATE_ENTRIES+=("$pname [${_PLUGIN_LEVEL:-L0}]: $_PLUGIN_FILES files")
            # 收集详细变更
            _collect_plugin_detail "$plugin_dir" "$pname" "${_PLUGIN_LEVEL:-L0}"
        elif [[ -n "$_PLUGIN_LEVEL" && "$_PLUGIN_LEVEL" != "disabled" ]]; then
            _REPORT_MUTATE_ENTRIES+=("$pname [${_PLUGIN_LEVEL}]: 0 files (no iOS source)")
        fi

        case "$_PLUGIN_LEVEL" in
            L0) level_counts_L0=$((level_counts_L0 + 1)) ;;
            L1) level_counts_L1=$((level_counts_L1 + 1)) ;;
            L2) level_counts_L2=$((level_counts_L2 + 1)) ;;
            L3) level_counts_L3=$((level_counts_L3 + 1)) ;;
            disabled) level_counts_disabled=$((level_counts_disabled + 1)) ;;
        esac
    done

    # flutter_base 子模块中未被重命名到 plugins/ 的 iOS 原生模块也需要变异
    if project_uses_flutter_base "$CURRENT_PROJECT" && [[ -d "$FLUTTER_BASE_DIR" ]]; then
        # 收集已重命名且 plugins/新名 实际存在的原始名列表
        local _fb_renamed_list=""
        if [[ -f "$MAPPING_FILE" ]] && [[ -d "$PLUGINS_DIR" ]]; then
            while IFS= read -r _mline; do
                local _orig _new
                _orig=$(echo "$_mline" | sed 's/\s*->\s*/|/' | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                _new=$(echo "$_mline" | sed 's/\s*->\s*/|/' | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -n "$_orig" && -n "$_new" && -d "$PLUGINS_DIR/$_new" ]] && _fb_renamed_list+="${_orig}"$'\n'
            done < <(grep -v "^#" "$MAPPING_FILE" 2>/dev/null | grep -- "->")
        fi

        for module in "$FLUTTER_BASE_DIR"/*/; do
            [[ -d "$module" ]] || continue
            local mod_name
            mod_name=$(basename "$module")
            [[ -f "$module/pubspec.yaml" ]] || continue
            is_apple_native_plugin_dir "$module" || continue

            if echo "$_fb_renamed_list" | grep -qx "$mod_name" 2>/dev/null; then
                [[ "$VERBOSE" == "true" ]] && log_info "  flutter_base/$mod_name: 已重命名到 plugins/，跳过" || true
                continue
            fi

            total_plugins=$((total_plugins + 1))
            [[ "$VERBOSE" == "true" ]] && log_info "  flutter_base/$mod_name: 原地变异 (未重命名)" || true

            mutate_plugin "$module"
            if [[ $_PLUGIN_FILES -gt 0 ]]; then
                total_files=$((total_files + _PLUGIN_FILES))
                processed_plugins=$((processed_plugins + 1))
                _REPORT_MUTATE_ENTRIES+=("$mod_name [flutter_base, ${_PLUGIN_LEVEL:-L0}]: $_PLUGIN_FILES files")
                _collect_plugin_detail "$module" "$mod_name" "${_PLUGIN_LEVEL:-L0}"
            fi
            case "$_PLUGIN_LEVEL" in
                L0) level_counts_L0=$((level_counts_L0 + 1)) ;;
                L1) level_counts_L1=$((level_counts_L1 + 1)) ;;
                L2) level_counts_L2=$((level_counts_L2 + 1)) ;;
                L3) level_counts_L3=$((level_counts_L3 + 1)) ;;
                disabled) level_counts_disabled=$((level_counts_disabled + 1)) ;;
            esac
        done
    fi

    echo ""
    echo "=========================================="
    if [[ "$CLEAN_ONLY" == "true" ]]; then
        log_success "清理完成"
        echo "  清理文件: $total_files 个"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_success "[DRY-RUN] 模拟完成"
        else
            log_success "变异注入完成"
        fi
        echo "  Seed: $SEED"
        echo "  扫描插件: $total_plugins 个"
        echo "  处理插件: $processed_plugins 个"
        echo "  注入文件: $total_files 个"
        echo ""
        echo "  级别分布:"
        [[ $level_counts_L0 -gt 0 ]] && echo "    L0 (注入):     $level_counts_L0 个"
        [[ $level_counts_L1 -gt 0 ]] && echo "    L1 (+ 重命名): $level_counts_L1 个"
        [[ $level_counts_L2 -gt 0 ]] && echo "    L2 (+ 打乱):   $level_counts_L2 个"
        [[ $level_counts_L3 -gt 0 ]] && echo "    L3 (+ 死分支): $level_counts_L3 个"
        [[ $level_counts_disabled -gt 0 ]] && echo "    disabled:      $level_counts_disabled 个"
    fi
    echo "=========================================="
    echo ""

    _REPORT_MUTATE_SEED="$SEED"
    _REPORT_MUTATE_TOTAL=$total_plugins
    _REPORT_MUTATE_PROCESSED=$processed_plugins

    [[ -n "$MANIFEST_TMPFILE" ]] && rm -f "$MANIFEST_TMPFILE"
    [[ -n "$_REVERSE_MAP_FILE" ]] && rm -f "$_REVERSE_MAP_FILE"
    MANIFEST_LOADED=false
    MANIFEST_TMPFILE=""
    _REVERSE_MAP_FILE=""
}

# =============================================
# Phase 2.5: 第三方 Pod 原地变异
# =============================================

# 对单个 CocoaPod 执行原地变异（L1-L3）
# Pod 源码在 pod install 后位于 ios/Pods/<PodName>/
# 与 Flutter 插件不同：不注入新文件（无法自动加入 Pods.xcodeproj），仅修改已有源码
mutate_pod() {
    local pod_name="$1"
    local pod_dir="$PODS_DIR/$pod_name"

    if [[ ! -d "$pod_dir" ]]; then
        log_warning "  $pod_name: 目录不存在 ($pod_dir)，跳过"
        _REPORT_POD_ENTRIES+=("$pod_name [missing]: Pod 目录不存在")
        return
    fi

    local level
    level=$(get_plugin_level "$pod_name")

    if [[ "$level" == "disabled" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "  $pod_name: disabled，跳过" >&2 || true
        _REPORT_POD_ENTRIES+=("$pod_name [disabled]: 二进制或不可修改")
        _REPORT_POD_SKIPPED=$((_REPORT_POD_SKIPPED + 1))
        return
    fi

    if [[ "$level" == "L0" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "  $pod_name: L0 (Pod 不支持文件注入)，跳过" >&2 || true
        _REPORT_POD_ENTRIES+=("$pod_name [L0]: Pod 不支持 L0 文件注入，跳过")
        _REPORT_POD_SKIPPED=$((_REPORT_POD_SKIPPED + 1))
        return
    fi

    local m_count swift_count
    m_count=$(find "$pod_dir" -type f -name "*.m" 2>/dev/null | wc -l | tr -d ' ')
    swift_count=$(find "$pod_dir" -type f -name "*.swift" ! -name "Package.swift" 2>/dev/null | wc -l | tr -d ' ')

    if [[ $m_count -eq 0 && $swift_count -eq 0 ]]; then
        log_info "  $pod_name: 无源码（二进制 Pod），跳过"
        _REPORT_POD_ENTRIES+=("$pod_name [$level]: 无源码（二进制），跳过")
        _REPORT_POD_SKIPPED=$((_REPORT_POD_SKIPPED + 1))
        return
    fi

    log_info "  $pod_name [$level]: .m=$m_count .swift=$swift_count"

    local renamed_count=0
    local reordered_count=0
    local injected_count=0

    # 尝试加载 pods/ 目录下的自定义 profile
    local _pod_profile=""
    local _pod_version=""
    _pod_version=$(echo "$pod_name" | tr -d '\n')
    # 从 Podfile.lock 提取版本
    local _pod_actual_ver=""
    if [[ -f "$PROJECT_ROOT/ios/Podfile.lock" ]]; then
        _pod_actual_ver=$(awk -v name="$pod_name" '
            /^PODS:/ { in_pods=1; next }
            /^[A-Z]/ && !/^PODS:/ { in_pods=0 }
            in_pods && /^  - / && !/^    - / {
                line=$0
                gsub(/^  - "?/, "", line)
                gsub(/"? \(.*/, "", line)
                split(line, a, "/")
                if (a[1] == name) {
                    v=$0
                    i=index(v, " (")
                    if (i > 0) {
                        rest=substr(v, i+2)
                        j=index(rest, ")")
                        if (j > 0) { print substr(rest, 1, j-1); exit }
                    }
                }
            }
        ' "$PROJECT_ROOT/ios/Podfile.lock")
    fi
    local _pod_major=""
    [[ -n "$_pod_actual_ver" ]] && _pod_major=$(echo "$_pod_actual_ver" | cut -d. -f1)

    # 查找 profile: pods/<name>@<major>.sh → pods/<name>.sh
    if [[ -n "$_pod_major" && -f "$PROFILES_DIR/pods/${pod_name}@${_pod_major}.sh" ]]; then
        _pod_profile="$PROFILES_DIR/pods/${pod_name}@${_pod_major}.sh"
    elif [[ -f "$PROFILES_DIR/pods/${pod_name}.sh" ]]; then
        _pod_profile="$PROFILES_DIR/pods/${pod_name}.sh"
    fi

    if [[ -n "$_pod_profile" ]]; then
        PROFILE_NAME=""
        PROFILE_VERSION=""
        PROFILE_STATUS=""
        PROFILE_PROTECTED=()
        PROFILE_SKIP_FILES=()
        source "$_pod_profile"
        [[ "$VERBOSE" == "true" ]] && log_info "    使用 Pod profile: $(basename "$_pod_profile")" || true

        _PROFILE_SRC_DIRS=()
        _PROFILE_CURRENT_NAME="$pod_name"
        if [[ "$DRY_RUN" != "true" ]]; then
            profile_apply "$pod_dir" "$level" || log_warning "  $pod_name: profile 应用出错"
        else
            log_info "    [DRY-RUN] 将应用 Pod profile: $PROFILE_NAME ($level)"
        fi
        _REPORT_POD_ENTRIES+=("$pod_name [$level]: profile=${PROFILE_NAME}, .m=$m_count, .swift=$swift_count")
        _REPORT_POD_MUTATED=$((_REPORT_POD_MUTATED + 1))
        return
    fi

    # 通用变异（无自定义 profile）
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "  [DRY-RUN] $pod_name [$level]: 将变异 .m=$m_count .swift=$swift_count"
        _REPORT_POD_ENTRIES+=("$pod_name [$level]: .m=$m_count, .swift=$swift_count")
        _REPORT_POD_MUTATED=$((_REPORT_POD_MUTATED + 1))
        return
    fi

    # L1+: 重命名 static 函数（仅 ObjC）
    # 注意: Swift private func 重命名对 Pods 不安全——同名方法跨类调用时
    #       sed 全局替换会误改其他类的方法调用（如 SomeManager.fetchVideo → SomeManager._zt_fetchVideo）
    #       ObjC static 函数是文件作用域，重命名完全安全
    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            bt_rename_static_functions "$f"
            renamed_count=$((renamed_count + 1))
        done < <(find "$pod_dir" -type f -name "*.m" ! -name "${INJECT_PREFIX}*" ! -name "*.g.m" 2>/dev/null)
    fi

    # L2+: 方法顺序打乱
    # 注意: 含 #if 预处理指令的 ObjC 文件必须跳过——方法重排会拆散 #if/#endif 配对
    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            if grep -q '^[[:space:]]*#if' "$f" 2>/dev/null; then
                [[ "$VERBOSE" == "true" ]] && log_info "    [L2] $(basename "$f"): 含 #if 预处理指令，跳过重排" || true
                continue
            fi
            bt_reorder_objc_methods "$f"
            reordered_count=$((reordered_count + 1))
        done < <(find "$pod_dir" -type f -name "*.m" ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            if grep -q '^[[:space:]]*#if' "$f" 2>/dev/null; then
                [[ "$VERBOSE" == "true" ]] && log_info "    [L2] $(basename "$f"): 含 #if 预处理指令，跳过重排" || true
                continue
            fi
            bt_reorder_swift_methods "$f"
            reordered_count=$((reordered_count + 1))
        done < <(find "$pod_dir" -type f -name "*.swift" ! -name "Package.swift" 2>/dev/null)
    fi

    # L3: 死分支注入
    # 同样跳过含 #if 预处理指令的文件，避免在条件编译块内注入导致编译错误
    if [[ "$level" == "L3" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            if grep -q '^[[:space:]]*#if' "$f" 2>/dev/null; then
                continue
            fi
            bt_inject_dead_branches "$f"
            injected_count=$((injected_count + 1))
        done < <(find "$pod_dir" -type f -name "*.m" ! -name "${INJECT_PREFIX}*" 2>/dev/null)

        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            bt_inject_swift_dead_branches "$f"
            injected_count=$((injected_count + 1))
        done < <(find "$pod_dir" -type f -name "*.swift" ! -name "Package.swift" 2>/dev/null)
    fi

    local detail="$pod_name [$level]: .m=$m_count, .swift=$swift_count"
    [[ $renamed_count -gt 0 ]] && detail+=", renamed=$renamed_count"
    [[ $reordered_count -gt 0 ]] && detail+=", reordered=$reordered_count"
    [[ $injected_count -gt 0 ]] && detail+=", dead_branch=$injected_count"
    log_success "  $detail"
    _REPORT_POD_ENTRIES+=("$detail")
    _REPORT_POD_MUTATED=$((_REPORT_POD_MUTATED + 1))
}

# 执行第三方 Pod 变异阶段
# 从清单文件中读取 pod: 类型条目，对每个有源码的 Pod 进行原地变异
run_mutate_pods() {
    echo ""
    echo "=========================================="
    echo "      第三方 Pod 变异 (CocoaPods Mutation)"
    echo "=========================================="
    echo ""

    if [[ ! -d "$PODS_DIR" ]]; then
        log_warning "ios/Pods 目录不存在，跳过 Pod 变异"
        return
    fi

    # 确保基础设施已加载
    [[ -z "$SEED" ]] && derive_seed
    load_base_transforms
    load_manifest

    if [[ "$MANIFEST_LOADED" != "true" || -z "$MANIFEST_FILE" || ! -f "$MANIFEST_FILE" ]]; then
        log_info "无项目清单或清单中无 pod 条目，跳过 Pod 变异"
        return
    fi

    local pod_count=0
    local has_pod_entries=false

    # 检查是否有 pod: 条目
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        local type name version plevel
        IFS=':' read -r type name version plevel <<< "$line"
        if [[ "$type" == "pod" && -n "$name" ]]; then
            has_pod_entries=true
            break
        fi
    done < "$MANIFEST_FILE"

    if [[ "$has_pod_entries" != "true" ]]; then
        log_info "清单中无 pod: 条目，跳过 Pod 变异"
        return
    fi

    log_step "开始第三方 Pod 原地变异..."
    echo ""

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        local type name version plevel
        IFS=':' read -r type name version plevel <<< "$line"
        [[ "$type" == "pod" ]] || continue
        [[ -z "$name" ]] && continue

        pod_count=$((pod_count + 1))
        mutate_pod "$name"
    done < "$MANIFEST_FILE"

    _REPORT_POD_TOTAL=$pod_count

    echo ""
    log_success "Pod 变异完成: 处理=$_REPORT_POD_MUTATED, 跳过=$_REPORT_POD_SKIPPED, 总计=$pod_count"
}

# =============================================
# 报告生成
# =============================================

# 检测第三方原生 CocoaPods（非 Flutter 插件），输出报告段落到 stdout
_report_third_party_pods() {
    local podfile_lock="$PROJECT_ROOT/ios/Podfile.lock"
    [[ -f "$podfile_lock" ]] || return

    # 用 awk 一次扫描: 提取 PODS 里的顶级 Pod 基名 + DEPENDENCIES 里的 Flutter 插件名
    local result
    result=$(awk '
        /^PODS:/ { section="pods"; next }
        /^DEPENDENCIES:/ { section="deps"; next }
        /^[A-Z]/ { section="" }

        section=="pods" && /^  - / && !/^    - / {
            line=$0
            gsub(/^  - "?/, "", line)
            # 提取版本: "Name (x.y.z):" → x.y.z
            v=""
            i=index(line, " (")
            if (i > 0) {
                rest=substr(line, i+2)
                j=index(rest, ")")
                if (j > 0) v=substr(rest, 1, j-1)
            }
            gsub(/"? \(.*/, "", line)
            split(line, a, "/")
            pods[a[1]]=1
            if (v != "") ver[a[1]]=v
        }

        section=="deps" && /^  - / {
            line=$0
            gsub(/^  - /, "", line)
            gsub(/ \(.*/, "", line)
            flutter[line]=1
        }

        END {
            for (p in pods) {
                if (p == "Flutter" || p == "FlutterMacOS") continue
                if (!(p in flutter)) {
                    printf "%s|%s\n", p, ver[p]
                }
            }
        }
    ' "$podfile_lock" | sort -t'|' -k1,1)

    [[ -z "$result" ]] && return

    echo "--- 第三方原生 Pods (非 Flutter 插件) ---"
    echo "以下 CocoaPods 由 Flutter 插件的 podspec 引入，当前未被混淆工具处理。"
    echo "如需进一步混淆，可在 framework_profiles/ 中为对应的 Flutter 插件创建 profile。"
    echo ""
    while IFS='|' read -r pod_name pod_ver; do
        echo "  ${pod_name}${pod_ver:+ ($pod_ver)}"
    done <<< "$result"
    echo ""
}

generate_report() {
    [[ "$DRY_RUN" == "true" ]] && return

    mkdir -p "$REPORT_DIR"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local project_tag="${CURRENT_PROJECT:-unknown}"
    REPORT_FILE="$REPORT_DIR/${project_tag}_${timestamp}.txt"

    {
        echo "========================================"
        echo "  Framework 混淆报告"
        echo "========================================"
        echo ""
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "项目: $project_tag"
        echo "工程: $PROJECT_ROOT"
        echo "Seed: ${_REPORT_MUTATE_SEED:-N/A}"
        echo "Manifest: ${MANIFEST_FILE:-未使用}"
        echo ""

        # ---- 重命名映射 ----
        echo "--- 重命名映射 (Rename Mapping) ---"
        echo "成功: $_REPORT_RENAME_COUNT 个"
        echo "跳过: $_REPORT_RENAME_SKIPPED 个"
        echo ""
        if [[ ${#_REPORT_RENAME_ENTRIES[@]} -gt 0 ]]; then
            for entry in "${_REPORT_RENAME_ENTRIES[@]}"; do
                echo "  $entry"
            done
        else
            echo "  (无)"
        fi
        echo ""
        # 跳过的插件（从映射文件读取）
        if [[ -f "$MAPPING_FILE" ]]; then
            local _skip_section=""
            local _in_skip=false
            while IFS= read -r _line; do
                if [[ "$_line" == "# 跳过的插件"* ]]; then _in_skip=true; fi
                if [[ "$_in_skip" == "true" ]]; then _skip_section+="$_line"$'\n'; fi
            done < "$MAPPING_FILE"
            if [[ -n "$_skip_section" ]]; then
                echo "跳过的插件 (传递依赖冲突):"
                echo "$_skip_section" | grep "^# [a-z]" | sed 's/^# /  /' || true
                echo "$_skip_section" | grep "^#   被依赖于" | sed 's/^# /  /' || true
                echo ""
            fi
        fi

        # ---- 变异 ----
        echo "--- 变异 (Mutation) ---"
        echo "扫描: $_REPORT_MUTATE_TOTAL 个插件"
        echo "处理: $_REPORT_MUTATE_PROCESSED 个插件"
        echo ""
        if [[ ${#_REPORT_MUTATE_ENTRIES[@]} -gt 0 ]]; then
            for entry in "${_REPORT_MUTATE_ENTRIES[@]}"; do
                echo "  $entry"
            done
        else
            echo "  (无)"
        fi
        echo ""

        # ---- 第三方 Pod 变异 ----
        if [[ $_REPORT_POD_TOTAL -gt 0 ]]; then
            echo "--- 第三方 Pod 变异 (CocoaPods Mutation) ---"
            echo "总计: $_REPORT_POD_TOTAL 个 Pod"
            echo "变异: $_REPORT_POD_MUTATED 个"
            echo "跳过: $_REPORT_POD_SKIPPED 个 (二进制/disabled/L0)"
            echo ""
            if [[ ${#_REPORT_POD_ENTRIES[@]} -gt 0 ]]; then
                for entry in "${_REPORT_POD_ENTRIES[@]}"; do
                    echo "  $entry"
                done
            fi
            echo ""
        else
            _report_third_party_pods
        fi

        # ---- 详细变更 ----
        if [[ ${#_REPORT_DETAIL_ENTRIES[@]} -gt 0 ]]; then
            echo "--- 详细变更 (Detail) ---"
            for entry in "${_REPORT_DETAIL_ENTRIES[@]}"; do
                echo "$entry"
            done
            echo ""
        fi

        # ---- plugins/ 最终状态 ----
        echo "--- 最终 plugins/ 目录 ---"
        if [[ -d "$PLUGINS_DIR" ]]; then
            for d in "$PLUGINS_DIR"/*/; do
                [[ -d "$d" ]] || continue
                local pname
                pname=$(basename "$d")
                local ver
                ver=$(get_plugin_version "$d")
                local m_count
                m_count=$(find "$d" -name "${INJECT_PREFIX}*.m" -type f 2>/dev/null | wc -l | tr -d ' ')
                local src_count
                src_count=$(find "$d" -type f \( -name "*.m" -o -name "*.swift" \) \
                           -not -name "${INJECT_PREFIX}*" \
                           \( -path "*/ios/*" -o -path "*/darwin/*" \) 2>/dev/null | wc -l | tr -d ' ')
                local podspec_patched=""
                if grep -rq 'zt_objc_injection' "$d" 2>/dev/null; then
                    podspec_patched=" [podspec patched]"
                fi
                echo "  $pname${ver:+ (v$ver)}  src: ${src_count}, injected: ${m_count}${podspec_patched}"
            done
        fi
        echo ""
        echo "========================================"
    } > "$REPORT_FILE"

    # 映射信息已合并到报告中，删除独立映射文件
    if [[ "$_IN_RUN_ALL" == "true" && -f "$MAPPING_FILE" ]]; then
        rm -f "$MAPPING_FILE"
        [[ "$VERBOSE" == "true" ]] && log_info "映射文件已合并到报告，已删除: $MAPPING_FILE" || true
    fi

    log_info "报告已保存: $REPORT_FILE"
}

# =============================================
# Phase 3: 构建 + 编排
# =============================================

# 依赖字符串混淆（调用独立脚本）
run_dep_strings() {
    local args=()
    [[ -n "$CURRENT_PROJECT" ]] && args+=("-p" "$CURRENT_PROJECT")
    [[ "$DRY_RUN" == "true" ]] && args+=("-d")
    [[ "$VERBOSE" == "true" ]] && args+=("-v")

    local dep_strings_script="$SCRIPT_DIR/obfuscate_dep_strings.sh"
    if [[ ! -f "$dep_strings_script" ]]; then
        log_warning "依赖字符串混淆脚本不存在: $dep_strings_script"
        return 1
    fi

    bash "$dep_strings_script" "${args[@]}"
}

# 一键完成全部流程
run_all() {
    local start_time=$(date +%s)
    _IN_RUN_ALL=true
    
    local total_steps=7
    [[ "$SKIP_DEP_STRINGS" == "true" ]] && total_steps=6

    echo ""
    echo "============================================"
    echo "  Framework 混淆 (generate → apply → localize → mutate → build → pod mutate$(
        [[ "$SKIP_DEP_STRINGS" != "true" ]] && echo " → dep-strings"
    ))"
    echo "============================================"
    echo ""
    
    # Step 1: 生成映射配置
    log_step "[1/$total_steps] 生成映射配置..."
    echo ""
    generate_mapping
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        log_info "[DRY-RUN] 模拟运行完成，未实际修改任何文件"
        return
    fi
    
    # Step 2: 应用映射
    echo ""
    echo "--------------------------------------------"
    log_step "[2/$total_steps] 应用映射配置..."
    echo ""
    apply_mapping
    
    # Step 2.5: 传递依赖本地化
    echo ""
    echo "--------------------------------------------"
    log_step "[2.5/$total_steps] 传递依赖本地化（不重命名，仅用于变异注入）..."
    echo ""
    localize_skipped_plugins
    
    # Step 3: 原生代码变异
    echo ""
    echo "--------------------------------------------"
    log_step "[3/$total_steps] 原生代码变异 (Native Mutation)..."
    echo ""
    run_mutate
    
    # Step 4: flutter pub get
    echo ""
    echo "--------------------------------------------"
    log_step "[4/$total_steps] 运行 fvm flutter pub get..."
    echo ""
    
    if project_uses_flutter_base "$CURRENT_PROJECT" && [[ -d "$FLUTTER_BASE_DIR" ]] && [[ -f "$FLUTTER_BASE_DIR/pubspec.yaml" ]]; then
        log_info "flutter_base 优先: cd flutter_base && fvm flutter pub get"
        if ! (cd "$FLUTTER_BASE_DIR" && fvm flutter pub get 2>&1); then
            log_error "flutter_base 的 fvm flutter pub get 失败"
            exit 1
        fi
        log_success "flutter_base pub get 完成"
        echo ""
    fi
    
    if ! fvm flutter pub get 2>&1; then
        log_error "主工程 fvm flutter pub get 失败"
        log_info "请手动排查依赖问题后重试"
        exit 1
    fi
    log_success "主工程 pub get 完成"
    
    # Step 5: pod install
    echo ""
    echo "--------------------------------------------"
    log_step "[5/$total_steps] 运行 pod install..."
    echo ""
    
    cd "$PROJECT_ROOT/ios" || { log_error "无法进入 ios 目录"; exit 1; }

    # 自动检测 plugins/ 中所有 podspec 要求的最低 iOS 版本，确保 Podfile 满足
    local _podfile="$PROJECT_ROOT/ios/Podfile"
    if [[ -f "$_podfile" ]]; then
        local _max_target=""
        while IFS= read -r _ver; do
            if [[ -z "$_max_target" ]] || \
               [[ "$(printf '%s\n%s' "$_max_target" "$_ver" | sort -V | tail -1)" == "$_ver" ]]; then
                _max_target="$_ver"
            fi
        done < <(find "$PROJECT_ROOT/plugins" -name "*.podspec" -exec \
            grep -oE "ios\.deployment_target\s*=\s*'[0-9]+\.[0-9]+'" {} \; 2>/dev/null | \
            grep -oE "[0-9]+\.[0-9]+" | sort -u)

        if [[ -n "$_max_target" ]]; then
            local _cur_target
            _cur_target=$(grep -oE "platform\s*:ios,\s*'[0-9]+\.[0-9]+'" "$_podfile" | grep -oE "[0-9]+\.[0-9]+" | head -1)
            if [[ -n "$_cur_target" ]] && \
               [[ "$(printf '%s\n%s' "$_cur_target" "$_max_target" | sort -V | tail -1)" != "$_cur_target" ]]; then
                sed -i '' "s/platform :ios, '$_cur_target'/platform :ios, '$_max_target'/" "$_podfile"
                log_info "Podfile platform :ios 自动提升: '$_cur_target' → '$_max_target'（满足插件要求）"
            fi
        fi
    fi

    rm -rf Pods Podfile.lock 2>/dev/null || true
    
    local _pod_log
    _pod_log=$(mktemp)
    local _pod_rc=0
    pod install > "$_pod_log" 2>&1 || _pod_rc=$?
    grep -v '^Ignoring ' "$_pod_log" || true
    rm -f "$_pod_log"
    if [[ $_pod_rc -ne 0 ]]; then
        log_error "pod install 失败"
        log_info "常见原因: 网络问题（GitHub 下载超时）、CocoaPods 缓存过期"
        log_info "可尝试: pod install --repo-update 或检查代理设置"
        cd "$PROJECT_ROOT"
        exit 1
    fi
    
    cd "$PROJECT_ROOT"
    log_success "pod install 完成"
    
    # Step 6: 第三方 Pod 原地变异（必须在 pod install 之后）
    echo ""
    echo "--------------------------------------------"
    log_step "[6/$total_steps] 第三方 Pod 原地变异 (CocoaPods Mutation)..."
    echo ""
    run_mutate_pods
    
    # Step 7: 依赖字符串混淆（可选）
    if [[ "$SKIP_DEP_STRINGS" != "true" ]]; then
        echo ""
        echo "--------------------------------------------"
        log_step "[7/$total_steps] 依赖字符串混淆 (Dep String Obfuscation)..."
        echo ""
        run_dep_strings || log_warning "依赖字符串混淆失败，但不影响其他流程"
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    
    # 生成报告
    generate_report

    echo ""
    echo "============================================"
    log_success "全部完成! 耗时 ${elapsed} 秒"
    echo "============================================"
    echo ""
    echo "统计:"
    echo "  插件目录: $PLUGINS_DIR"
    [[ -n "$REPORT_FILE" ]] && echo "  混淆报告: $REPORT_FILE"
    echo ""
    echo "下一步: fvm flutter run"
    echo ""
}

# =============================================
# 帮助与主入口
# =============================================

usage() {
    cat << EOF
Framework 混淆脚本 — 统一的 framework 混淆方案

用法: $0 [选项] [子命令]

选项:
  -p, --project NAME     项目代码
                         如不指定，自动从 ab_config.yaml 读取
  -m, --mapping FILE     指定映射配置文件 (默认: scripts/plugin_rename_mapping.conf)
  -g, --generate         仅生成映射配置
  -r, --ratio PERCENT    重命名混淆比例 1-100 (默认: 100，即全部混淆)
                         例如: -r 80 表示随机混淆 80% 的插件
  --seed SEED            变异种子 (默认从 bundle ID 推导)
  --manifest FILE        变异项目清单
  --verify               变异后验证编译
  --no-platform-detect   禁用自动检测 iOS 平台包
  --no-dep-strings       run 时跳过依赖字符串混淆
  --pub-cache DIR        指定 pub cache 目录 (默认自动检测)
  -d, --dry-run          模拟运行，不实际修改
  -v, --verbose          详细输出
  -c, --clean            仅清理注入的变异文件
  -h, --help             显示帮助

子命令:
  run          一键全流程 (generate → apply → mutate → build → pod mutate → dep-strings)
               默认包含依赖字符串混淆，可用 --no-dep-strings 跳过
  list         列出可混淆的B面 iOS 原生插件
  apply        仅应用重命名映射
  mutate       仅执行原生代码变异（对 plugins/ 下所有插件）
  mutate-pods  仅执行第三方 Pod 原地变异（需先完成 pod install）
  dep-strings  独立运行依赖字符串混淆（Dart + Swift + ObjC，需配置 dep_strings_manifests/）
  clean        仅清理注入的变异文件（等同于 -c）

  注意: 只混淆B面（次要模块）依赖，从 pubspec.yaml 的 "# === 次要模块依赖" 标记识别。
        A面依赖不会被混淆。

特性:
  - 只混淆B面依赖（从 pubspec.yaml 的 "# === 次要模块依赖" 标记识别）
  - A面依赖（标记之前）不会被混淆
  - 本地 path 依赖优先作为源，避免覆盖 fork 的插件
  - plugins/ 中与映射无关的本地插件会被保留（仅清理会重新生成的插件）
  - 自动检测传递依赖中的 iOS 平台包
  - 变异注入为所有 plugins/ 下含 iOS 原生代码的插件生成唯一类
  - 支持 profile + manifest 分层混淆 (L0-L3)

示例:
  $0 run                               # 一键完成（含字符串混淆，推荐）
  $0 run --no-dep-strings              # 一键完成，跳过字符串混淆
  $0 run -r 80                         # 一键完成，只混淆 80% 的插件
  $0 run -d                            # 模拟运行全流程（不实际修改）
  $0 list                              # 列出所有可混淆的 iOS 原生插件
  $0 -g                                # 仅生成映射配置
  $0 apply                             # 仅应用映射配置
  $0 mutate                            # 仅执行原生代码变异
  $0 mutate --seed com.my.app          # 指定 seed 变异
  $0 mutate --verify -v                # 变异后验证编译
  $0 mutate-pods                       # 仅对第三方 Pod 原地变异
  $0 mutate-pods -d -v                 # 模拟 Pod 变异（详细输出）
  $0 dep-strings                       # 独立运行字符串混淆（Dart/Swift/ObjC）
  $0 dep-strings -d -v                 # 模拟字符串混淆（详细输出）
  $0 clean                             # 清理所有注入的变异文件
EOF
    exit 0
}

main() {
    echo ""
    echo "=========================================="
    echo "      Framework 混淆工具 (Rename + Mutate)"
    echo "=========================================="
    echo ""
    
    local command=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            run|list|apply|mutate|mutate-pods|dep-strings|clean)
                command="$1"
                [[ "$command" == "clean" ]] && CLEAN_ONLY=true
                shift
                ;;
            -p|--project)
                CURRENT_PROJECT="$2"
                shift 2
                ;;
            -m|--mapping)
                MAPPING_FILE="$2"
                shift 2
                ;;
            -g|--generate)
                GENERATE_MAPPING=true
                shift
                ;;
            -r|--ratio)
                OBFUSCATE_RATIO="$2"
                if [[ "$OBFUSCATE_RATIO" -lt 1 || "$OBFUSCATE_RATIO" -gt 100 ]]; then
                    log_error "混淆比例必须在 1-100 之间"
                    exit 1
                fi
                shift 2
                ;;
            --seed)
                SEED="$2"
                shift 2
                ;;
            --manifest)
                MANIFEST_FILE="$2"
                shift 2
                ;;
            --classes)
                OVERRIDE_CLASSES="$2"
                shift 2
                ;;
            --strings)
                OVERRIDE_STRINGS="$2"
                shift 2
                ;;
            --verify)
                VERIFY_AFTER=true
                shift
                ;;
            --no-platform-detect)
                AUTO_DETECT_PLATFORM=false
                shift
                ;;
            --pub-cache)
                PUB_CACHE_DIR="$2"
                shift 2
                ;;
            --no-dep-strings)
                SKIP_DEP_STRINGS=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -c|--clean)
                CLEAN_ONLY=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "未知参数: $1"
                usage
                ;;
        esac
    done
    
    # 如果未指定项目，自动检测
    if [[ -z "$CURRENT_PROJECT" ]]; then
        CURRENT_PROJECT=$(detect_current_project)
        if [[ -n "$CURRENT_PROJECT" ]]; then
            log_info "自动检测到项目: $CURRENT_PROJECT"
        else
            log_warning "未检测到项目"
            log_info "提示: 使用 -p 参数指定项目"
        fi
    fi
    
    # 执行命令
    if [[ "$command" == "run" ]]; then
        run_all
    elif [[ "$GENERATE_MAPPING" == "true" ]]; then
        generate_mapping
    elif [[ "$command" == "list" ]]; then
        list_plugins
    elif [[ "$command" == "apply" ]]; then
        apply_mapping
    elif [[ "$command" == "mutate" ]]; then
        run_mutate
        generate_report
    elif [[ "$command" == "mutate-pods" ]]; then
        run_mutate_pods
        generate_report
    elif [[ "$command" == "dep-strings" ]]; then
        run_dep_strings
    elif [[ "$command" == "clean" ]] || [[ "$CLEAN_ONLY" == "true" ]]; then
        CLEAN_ONLY=true
        run_mutate
    else
        usage
    fi

    # 最后兜底：若 flutter_base/lib/image/image_loader.dart 存在，则用模板覆盖
    patch_flutter_base_image_loader
}

main "$@"
