#!/bin/bash

# ============================================================
# 依赖字符串混淆脚本
# 混淆依赖目录下的字符串：Dart + Swift + Objective-C/Objective-C++
#
# 设计原则：
#   - 每个 plugin 单独配置，通过 dep_strings_manifests/<project>.conf 管理
#   - 支持 dry-run 预览
#   - 生成详细文本报告
#   - 按 plugin/package 自动并行处理（无需额外参数）
#   - Dart 复用 dart_obfuscator 工具；Swift/ObjC(++) 用 shell+perl 替换
#
# 字符串混淆方法：
#   Dart:   String.fromCharCodes([...])
#   Swift:  String(bytes: [...] as [UInt8], encoding: .utf8)!
#   ObjC:   @"\ooo\ooo..."  (八进制字节转义，保持 NSString 字面量语义)
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGINS_DIR="$PROJECT_ROOT/plugins"
FLUTTER_BASE_DIR="$PROJECT_ROOT/flutter_base"
DART_OBFUSCATOR_DIR="$SCRIPT_DIR/dart_obfuscator"
MANIFESTS_DIR="$SCRIPT_DIR/dep_strings_manifests"
SKIP_RULES_DIR="$SCRIPT_DIR/dep_strings_skip"
MAPPING_FILE="$SCRIPT_DIR/plugin_rename_mapping.conf"

DRY_RUN=false
VERBOSE=false
CURRENT_PROJECT=""
SINGLE_PLUGIN=""
REPORT_FILE=""
REPORT_STARTED_AT=""
REPORT_STARTED_EPOCH=""
REPORT_COMMAND_LINE=""
REPORT_TRAP_ENABLED=false
DART_CMD=""

# Manifest: parallel arrays (bash 3.x compatible)
_MF_NAMES=()
_MF_LANGS=()

# Skip rules: loaded from config files
_SKIP_EXACT_COMMON=()
_SKIP_REGEX_COMMON=()
_SKIP_EXACT_DART=()
_SKIP_REGEX_DART=()
_SKIP_EXACT_SWIFT=()
_SKIP_REGEX_SWIFT=()
_SKIP_EXACT_OBJC=()
_SKIP_REGEX_OBJC=()

# Report counters
_REPORT_DART_FILES=0
_REPORT_DART_STRINGS=0
_REPORT_SWIFT_FILES=0
_REPORT_SWIFT_STRINGS=0
_REPORT_OBJC_FILES=0
_REPORT_OBJC_STRINGS=0
_REPORT_PLUGINS_PROCESSED=0
_REPORT_PLUGINS_SKIPPED=0
declare -a _REPORT_ENTRIES
declare -a _REPORT_WARNINGS

# Plugin/package task queue (bash 3.x compatible)
_PLUGIN_TASK_DIRS=()
_PLUGIN_TASK_NAMES=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    _REPORT_WARNINGS+=("$1")
}
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $1"; }
log_debug()   { [[ "$VERBOSE" == "true" ]] && echo -e "  ${NC}$1" || true; }

reset_plugin_report_state() {
    _REPORT_DART_FILES=0
    _REPORT_DART_STRINGS=0
    _REPORT_SWIFT_FILES=0
    _REPORT_SWIFT_STRINGS=0
    _REPORT_OBJC_FILES=0
    _REPORT_OBJC_STRINGS=0
    _REPORT_PLUGINS_PROCESSED=0
    _REPORT_PLUGINS_SKIPPED=0
    _REPORT_ENTRIES=()
    _REPORT_WARNINGS=()
}

enqueue_plugin_task() {
    local plugin_dir="${1%/}"
    local plugin_name="$2"
    plugin_dir=$(normalize_dir_path "$plugin_dir")
    [[ -z "$plugin_name" ]] && plugin_name=$(basename "$plugin_dir")

    local existing
    for existing in "${_PLUGIN_TASK_DIRS[@]}"; do
        [[ "$existing" == "$plugin_dir" ]] && return 0
    done

    _PLUGIN_TASK_DIRS+=("$plugin_dir")
    _PLUGIN_TASK_NAMES+=("$plugin_name")
}

is_queued_plugin_task_dir() {
    local plugin_dir="${1%/}"
    plugin_dir=$(normalize_dir_path "$plugin_dir")

    local existing
    for existing in "${_PLUGIN_TASK_DIRS[@]}"; do
        [[ "$existing" == "$plugin_dir" ]] && return 0
    done
    return 1
}

is_under_other_queued_task_dir() {
    local path="$1"
    local current_dir="${2%/}"
    current_dir=$(normalize_dir_path "$current_dir")

    local existing
    for existing in "${_PLUGIN_TASK_DIRS[@]}"; do
        [[ "$existing" == "$current_dir" ]] && continue
        case "$path" in
            "$existing"/*) return 0 ;;
        esac
    done
    return 1
}

dep_strings_worker_jobs() {
    if [[ -n "$SINGLE_PLUGIN" ]]; then
        echo 1
        return 0
    fi

    local cpu_count=4
    if command -v sysctl >/dev/null 2>&1; then
        cpu_count=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    elif command -v getconf >/dev/null 2>&1; then
        cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    fi
    [[ "$cpu_count" =~ ^[0-9]+$ ]] || cpu_count=4

    local jobs=$((cpu_count - 2))
    [[ $jobs -lt 2 ]] && jobs=2
    [[ $jobs -gt 8 ]] && jobs=8
    echo "$jobs"
}

write_worker_result() {
    local base="$1"
    local rc="${2:-0}"

    {
        echo "DS_DART_FILES=$_REPORT_DART_FILES"
        echo "DS_DART_STRINGS=$_REPORT_DART_STRINGS"
        echo "DS_SWIFT_FILES=$_REPORT_SWIFT_FILES"
        echo "DS_SWIFT_STRINGS=$_REPORT_SWIFT_STRINGS"
        echo "DS_OBJC_FILES=$_REPORT_OBJC_FILES"
        echo "DS_OBJC_STRINGS=$_REPORT_OBJC_STRINGS"
        echo "DS_PLUGINS_PROCESSED=$_REPORT_PLUGINS_PROCESSED"
        echo "DS_PLUGINS_SKIPPED=$_REPORT_PLUGINS_SKIPPED"
        echo "DS_RC=$rc"
    } > "$base.stats"

    printf '%s\n' "${_REPORT_ENTRIES[@]}" > "$base.entries"
    printf '%s\n' "${_REPORT_WARNINGS[@]}" > "$base.warnings"
}

merge_worker_result() {
    local base="$1"

    [[ -f "$base.log" ]] && cat "$base.log"

    if [[ -f "$base.stats" ]]; then
        local DS_DART_FILES=0
        local DS_DART_STRINGS=0
        local DS_SWIFT_FILES=0
        local DS_SWIFT_STRINGS=0
        local DS_OBJC_FILES=0
        local DS_OBJC_STRINGS=0
        local DS_PLUGINS_PROCESSED=0
        local DS_PLUGINS_SKIPPED=0
        local DS_RC=0

        # shellcheck disable=SC1090
        source "$base.stats"

        _REPORT_DART_FILES=$((_REPORT_DART_FILES + DS_DART_FILES))
        _REPORT_DART_STRINGS=$((_REPORT_DART_STRINGS + DS_DART_STRINGS))
        _REPORT_SWIFT_FILES=$((_REPORT_SWIFT_FILES + DS_SWIFT_FILES))
        _REPORT_SWIFT_STRINGS=$((_REPORT_SWIFT_STRINGS + DS_SWIFT_STRINGS))
        _REPORT_OBJC_FILES=$((_REPORT_OBJC_FILES + DS_OBJC_FILES))
        _REPORT_OBJC_STRINGS=$((_REPORT_OBJC_STRINGS + DS_OBJC_STRINGS))
        _REPORT_PLUGINS_PROCESSED=$((_REPORT_PLUGINS_PROCESSED + DS_PLUGINS_PROCESSED))
        _REPORT_PLUGINS_SKIPPED=$((_REPORT_PLUGINS_SKIPPED + DS_PLUGINS_SKIPPED))
    else
        log_warning "并行任务缺少统计文件: $(basename "$base")"
    fi

    if [[ -f "$base.entries" ]]; then
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            _REPORT_ENTRIES+=("$line")
        done < "$base.entries"
    fi

    if [[ -f "$base.warnings" ]]; then
        local warning
        while IFS= read -r warning || [[ -n "$warning" ]]; do
            [[ -n "$warning" ]] && _REPORT_WARNINGS+=("$warning")
        done < "$base.warnings"
    fi
}

run_plugin_worker() {
    local plugin_dir="$1"
    local plugin_name="$2"
    local worker_dir="$3"
    local task_index="$4"
    local base="$worker_dir/task_$task_index"

    (
        reset_plugin_report_state
        export DART_STRING_OBFUSCATION_REPORT="$base.dart_string_report.txt"

        local rc=0
        set +e
        process_plugin "$plugin_dir" "$plugin_name"
        rc=$?
        set -e

        write_worker_result "$base" "$rc"
        exit "$rc"
    ) > "$base.log" 2>&1
}

run_plugin_tasks_parallel() {
    local task_count=${#_PLUGIN_TASK_DIRS[@]}
    if [[ $task_count -eq 0 ]]; then
        log_warning "没有匹配到需要扫描的 plugin/package"
        return 0
    fi

    local jobs
    jobs=$(dep_strings_worker_jobs)
    [[ $jobs -gt $task_count ]] && jobs=$task_count
    [[ $jobs -lt 1 ]] && jobs=1

    if [[ $jobs -gt 1 ]]; then
        log_info "插件级并行: $task_count 个任务, 并发 $jobs"
    else
        log_info "插件级处理: $task_count 个任务"
    fi

    local worker_dir
    worker_dir=$(mktemp -d "${TMPDIR:-/tmp}/dep_strings_workers.XXXXXX")

    local overall_rc=0
    local idx=0
    while [[ $idx -lt $task_count ]]; do
        local pids=()
        local bases=()
        local names=()
        local batch=0

        while [[ $batch -lt $jobs && $idx -lt $task_count ]]; do
            local base="$worker_dir/task_$idx"
            run_plugin_worker "${_PLUGIN_TASK_DIRS[$idx]}" "${_PLUGIN_TASK_NAMES[$idx]}" "$worker_dir" "$idx" &
            pids+=("$!")
            bases+=("$base")
            names+=("${_PLUGIN_TASK_NAMES[$idx]}")
            idx=$((idx + 1))
            batch=$((batch + 1))
        done

        local i=0
        while [[ $i -lt ${#pids[@]} ]]; do
            local task_rc=0
            wait "${pids[$i]}" || task_rc=$?
            merge_worker_result "${bases[$i]}"
            if [[ $task_rc -ne 0 ]]; then
                overall_rc=$task_rc
                log_warning "${names[$i]}: 并行任务失败 (rc=$task_rc)"
            fi
            i=$((i + 1))
        done
    done

    rm -rf "$worker_dir" 2>/dev/null || true
    return "$overall_rc"
}

is_non_runtime_path() {
    local path="$1"
    case "$path" in
        */Tests/*|*/RunnerTests/*|*/test/*|*/tests/*|*/example/*|*/examples/*|*/integration_test/*|*/test_driver/*|*/__tests__/*)
            return 0
            ;;
    esac
    return 1
}

is_non_ios_native_path() {
    local path="$1"
    is_non_runtime_path "$path" && return 0
    case "$path" in
        */macos/*)
            return 0
            ;;
    esac
    return 1
}

# =============================================
# 项目检测
# =============================================
read_ab_config() {
    local key="$1"
    local config_file="$PROJECT_ROOT/ab_config.yaml"
    if [[ -f "$config_file" ]]; then
        grep "^${key}:" "$config_file" 2>/dev/null | head -1 | sed "s/^${key}: *//" | tr -d '\r\n"'
    fi
}

detect_current_project() {
    local project
    project=$(read_ab_config "project")
    [[ -n "$project" ]] && echo "$project" && return 0

    local project_file="$PROJECT_ROOT/.current_secondary_project"
    if [[ -f "$project_file" ]]; then
        project=$(tr -d '\n\r ' < "$project_file")
        [[ -n "$project" ]] && echo "$project" && return 0
    fi
    return 1
}

project_uses_flutter_base() {
    local project="$1"
    [[ "$project" == "yms" || "$project" == "oio" || "$project" == "bili" || "$project" == "txpjb" || "$project" == "xjpjb" ]]
}

reject_retired_project() {
    local project="$1"
    if [[ "$project" == "md" ]]; then
        log_error "md 项目已下线，不再支持依赖字符串混淆"
        exit 1
    fi
}

project_uses_root_flutter_base_path_dep() {
    local project="$1"
    [[ "$project" == "xjpjb" ]]
}

find_latest_framework_report() {
    local project="$1"
    local report_dir="$SCRIPT_DIR/reports"
    local candidates=()
    local file=""
    while IFS= read -r file; do
        [[ -n "$file" ]] && candidates+=("$file")
    done < <(find "$report_dir" -maxdepth 1 -type f \( \
        -name "obf_${project}_frameworks_*.txt" -o \
        -name "${project}_*.txt" \
    \) ! -name "*_dep_strings_*" -print 2>/dev/null)

    [[ ${#candidates[@]} -eq 0 ]] && return 0
    ls -1t "${candidates[@]}" 2>/dev/null | head -1
}

extract_path_value() {
    echo "$1" | sed 's/.*path://' | sed 's/[[:space:]]*#.*$//' | tr -d "'" | tr -d '"' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

normalize_dir_path() {
    local dir="${1%/}"
    if [[ -d "$dir" ]]; then
        (cd "$dir" 2>/dev/null && pwd -P) || printf '%s\n' "$dir"
    else
        printf '%s\n' "$dir"
    fi
}

read_package_name_from_pubspec() {
    local pubspec="$1"
    [[ -f "$pubspec" ]] || return 1
    grep '^name:' "$pubspec" 2>/dev/null | head -1 | sed 's/^name:[[:space:]]*//' | tr -d '\r\n"' | sed 's/[[:space:]]*#.*//'
}

get_original_plugin_name() {
    local current_name="$1"
    [[ -n "$current_name" ]] || return 1

    local original_name

    if [[ -f "$MAPPING_FILE" ]]; then
        original_name=$(grep -v '^#' "$MAPPING_FILE" 2>/dev/null | grep -- '->' | \
            awk -F'->' -v current="$current_name" '
                {
                    orig=$1
                    renamed=$2
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", orig)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", renamed)
                    if (renamed == current) {
                        print orig
                        exit
                    }
                }')
    fi

    if [[ -z "$original_name" && -n "$CURRENT_PROJECT" ]]; then
        local latest_report
        latest_report=$(find_latest_framework_report "$CURRENT_PROJECT")
        if [[ -f "$latest_report" ]]; then
            original_name=$(awk -F'→' -v current="$current_name" '
                /^[[:space:]]*[[:alnum:]_.+-]+[[:space:]]+→[[:space:]]+[[:alnum:]_.+-]+[[:space:]]*$/ {
                    orig=$1
                    renamed=$2
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", orig)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", renamed)
                    if (renamed == current) {
                        print orig
                        exit
                    }
                }' "$latest_report")
        fi
    fi

    if [[ -n "$original_name" ]]; then
        echo "$original_name"
    else
        echo "$current_name"
    fi
}

collect_extra_path_packages() {
    local pubspec="$PROJECT_ROOT/pubspec.yaml"
    [[ -f "$pubspec" ]] || return 0

    local current_dep=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if echo "$line" | grep -qE '^  [a-z_][a-z_0-9]*:[[:space:]]*$'; then
            current_dep=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1)
            continue
        fi

        if echo "$line" | grep -qE '^[[:space:]]+path:' && [[ -n "$current_dep" ]]; then
            local rel_path
            rel_path=$(extract_path_value "$line")
            local abs_path="$PROJECT_ROOT/$rel_path"
            current_dep=""

            [[ -d "$abs_path" ]] || continue
            abs_path=$(normalize_dir_path "$abs_path")
            [[ -f "$abs_path/pubspec.yaml" ]] || continue

            if [[ "$abs_path" == "$FLUTTER_BASE_DIR" ]] && \
                ! project_uses_flutter_base "$CURRENT_PROJECT" && \
                ! project_uses_root_flutter_base_path_dep "$CURRENT_PROJECT"; then
                continue
            fi

            case "$abs_path" in
                "$PLUGINS_DIR"/*|"$FLUTTER_BASE_DIR"/*)
                    continue
                    ;;
            esac

            local package_name
            package_name=$(read_package_name_from_pubspec "$abs_path/pubspec.yaml")
            [[ -z "$package_name" ]] && package_name=$(basename "$abs_path")

            local tag="[path-dep]"
            [[ "$abs_path" == "$PROJECT_ROOT/third_party/"* ]] && tag="[third_party]"
            printf '%s|%s|%s\n' "$package_name" "$abs_path" "$tag"
        fi
    done < "$pubspec" | sort -u
}

# =============================================
# Manifest 加载 (bash 3.x: parallel arrays)
# 加载顺序: _shared.conf → <project>.conf（后者覆盖前者）
# =============================================

# 从文件解析配置行追加到 _MF 数组
_parse_manifest_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" ]] && continue

        local plugin_name langs
        plugin_name=$(echo "$line" | cut -d: -f1 | tr -d ' ')
        langs=$(echo "$line" | cut -d: -f2 | tr -d ' ')
        [[ -z "$plugin_name" ]] && continue

        # 如果已存在同名 plugin，更新（覆盖）
        local found=false
        local i=0
        while [[ $i -lt ${#_MF_NAMES[@]} ]]; do
            if [[ "${_MF_NAMES[$i]}" == "$plugin_name" ]]; then
                _MF_LANGS[$i]="$langs"
                found=true
                break
            fi
            i=$((i + 1))
        done
        if [[ "$found" == "false" ]]; then
            _MF_NAMES+=("$plugin_name")
            _MF_LANGS+=("$langs")
        fi
    done < "$file"
}

load_manifest() {
    local shared_file="$MANIFESTS_DIR/_shared.conf"
    local project_file="$MANIFESTS_DIR/${CURRENT_PROJECT}.conf"

    if [[ ! -f "$shared_file" ]] && [[ ! -f "$project_file" ]]; then
        log_warning "未找到配置: $shared_file 或 $project_file"
        log_info "请先运行: $0 --init -p $CURRENT_PROJECT"
        return 1
    fi

    _MF_NAMES=()
    _MF_LANGS=()

    # 1) 加载共享配置
    if [[ -f "$shared_file" ]]; then
        log_info "加载共享清单: $shared_file"
        _parse_manifest_file "$shared_file"
        log_debug "  共享: ${#_MF_NAMES[@]} 个 plugin"
    fi

    # 2) 加载项目配置（覆盖同名 plugin）
    if [[ -f "$project_file" ]]; then
        log_info "加载项目清单: $project_file"
        _parse_manifest_file "$project_file"
    fi

    # 移除 disabled 的 plugin
    local clean_names=()
    local clean_langs=()
    local i=0
    while [[ $i -lt ${#_MF_NAMES[@]} ]]; do
        if [[ "${_MF_LANGS[$i]}" != "disabled" ]]; then
            clean_names+=("${_MF_NAMES[$i]}")
            clean_langs+=("${_MF_LANGS[$i]}")
            log_debug "  ${_MF_NAMES[$i]} -> ${_MF_LANGS[$i]}"
        else
            log_debug "  ${_MF_NAMES[$i]} -> disabled (跳过)"
        fi
        i=$((i + 1))
    done
    _MF_NAMES=("${clean_names[@]}")
    _MF_LANGS=("${clean_langs[@]}")

    log_info "已加载 ${#_MF_NAMES[@]} 个 plugin 配置"
}

# 查找 plugin 在 manifest 中的配置，结果存入 _FOUND_LANGS
_FOUND_LANGS=""
_manifest_lookup_exact() {
    local name="$1"
    local i=0
    while [[ $i -lt ${#_MF_NAMES[@]} ]]; do
        if [[ "${_MF_NAMES[$i]}" == "$name" ]]; then
            _FOUND_LANGS="${_MF_LANGS[$i]}"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

manifest_lookup() {
    local name="$1"
    _FOUND_LANGS=""

    _manifest_lookup_exact "$name" && return 0

    local original_name
    original_name=$(get_original_plugin_name "$name")
    if [[ "$original_name" != "$name" ]]; then
        _manifest_lookup_exact "$original_name" && return 0
    fi

    return 1
}

# 扫描单个插件目录，追加统计信息到输出文件
_scan_named_plugin_dir() {
    local plugin_dir="${1%/}"
    local output_file="$2"
    local tag="$3"
    local name="$4"

    [[ -d "$plugin_dir" ]] || return 0
    [[ -f "$plugin_dir/pubspec.yaml" ]] || return 0
    [[ -z "$name" ]] && name=$(basename "$plugin_dir")

    local dart_count swift_count objc_count
    dart_count=$(find "$plugin_dir" -name "*.dart" \
        -not -path "*/test/*" -not -path "*/tests/*" \
        -not -path "*/example/*" -not -path "*/examples/*" \
        -not -path "*/integration_test/*" -not -path "*/test_driver/*" \
        2>/dev/null | wc -l | tr -d ' ')
    swift_count=$(find "$plugin_dir" -name "*.swift" -not -name "_zt_*" -not -name "Package.swift" \
        -not -path "*/Tests/*" -not -path "*/RunnerTests/*" \
        -not -path "*/test/*" -not -path "*/tests/*" \
        -not -path "*/example/*" -not -path "*/examples/*" \
        -not -path "*/integration_test/*" -not -path "*/test_driver/*" \
        -not -path "*/macos/*" \
        2>/dev/null | wc -l | tr -d ' ')
    objc_count=$(find "$plugin_dir" \( -name "*.m" -o -name "*.mm" \) -not -name "_zt_*" \
        -not -path "*/Tests/*" -not -path "*/RunnerTests/*" \
        -not -path "*/test/*" -not -path "*/tests/*" \
        -not -path "*/example/*" -not -path "*/examples/*" \
        -not -path "*/integration_test/*" -not -path "*/test_driver/*" \
        -not -path "*/macos/*" \
        2>/dev/null | wc -l | tr -d ' ')

    local langs_avail=""
    [[ $dart_count -gt 0 ]] && langs_avail="${langs_avail}dart "
    [[ $swift_count -gt 0 ]] && langs_avail="${langs_avail}swift "
    [[ $objc_count -gt 0 ]] && langs_avail="${langs_avail}objc "

    local stats=""
    [[ $dart_count -gt 0 ]] && stats="${stats}${dart_count} dart, "
    [[ $swift_count -gt 0 ]] && stats="${stats}${swift_count} swift, "
    [[ $objc_count -gt 0 ]] && stats="${stats}${objc_count} objc, "
    stats="${stats%, }"
    [[ -z "$stats" ]] && stats="无源码"
    [[ -n "$tag" ]] && stats="${stats} ${tag}"

    langs_avail=$(echo "$langs_avail" | sed 's/ *$//' | tr ' ' ',')
    echo "${name}|${stats}|${langs_avail}" >> "$output_file"
}

# 扫描单个目录下的插件，追加统计信息到输出文件
_scan_dir_plugins() {
    local scan_dir="$1"
    local output_file="$2"
    local tag="$3"  # 可选标签，如 "[flutter_base]"

    for plugin_dir in "$scan_dir"/*/; do
        _scan_named_plugin_dir "$plugin_dir" "$output_file" "$tag" ""
    done
}

# 扫描 plugins/ (及 flutter_base/) 下所有插件，返回统计信息
_scan_plugins_info() {
    local output_file="$1"
    > "$output_file"

    _scan_dir_plugins "$PLUGINS_DIR" "$output_file" ""

    if project_uses_flutter_base "$CURRENT_PROJECT" && [[ -d "$FLUTTER_BASE_DIR" ]]; then
        _scan_dir_plugins "$FLUTTER_BASE_DIR" "$output_file" "[flutter_base]"
    fi

    while IFS='|' read -r package_name package_dir package_tag; do
        [[ -z "$package_name" || -z "$package_dir" ]] && continue
        _scan_named_plugin_dir "$package_dir" "$output_file" "$package_tag" "$package_name"
    done < <(collect_extra_path_packages)
}

# 生成初始清单模板
generate_manifest_template() {
    mkdir -p "$MANIFESTS_DIR"
    local manifest_file="$MANIFESTS_DIR/${CURRENT_PROJECT}.conf"
    local shared_file="$MANIFESTS_DIR/_shared.conf"

    local scan_tmp
    scan_tmp=$(mktemp)
    _scan_plugins_info "$scan_tmp"

    # 1) 生成 _shared.conf（如果不存在）
    if [[ ! -f "$shared_file" ]]; then
        {
            echo "# ============================================="
            echo "#   共享依赖字符串混淆配置"
            echo "#"
            echo "#   多个项目共用的 plugin 配置写在这里"
            echo "#   各项目的 <project>.conf 可覆盖此处设定"
            echo "#   设为 disabled 可显式禁用某个 plugin"
            echo "#"
            echo "#   格式: plugin_name: lang1,lang2,..."
            echo "#   可选语言: dart, swift, objc (逗号分隔)"
            echo "#   特殊值:   disabled"
            echo "# ============================================="
            echo ""

            while IFS='|' read -r name stats langs_avail; do
                echo "# ${name}  (${stats})"
                if [[ -n "$langs_avail" ]]; then
                    echo "# ${name}: ${langs_avail}"
                else
                    echo "# ${name}: disabled"
                fi
                echo ""
            done < "$scan_tmp"
        } > "$shared_file"

        log_success "已生成共享清单: $shared_file"
    fi

    # 2) 生成项目清单
    if [[ -f "$manifest_file" ]]; then
        log_warning "项目清单已存在: $manifest_file"
        log_info "如需重新生成，请先删除"
        rm -f "$scan_tmp"
        return
    fi

    {
        echo "# ============================================="
        echo "#   ${CURRENT_PROJECT} 依赖字符串混淆清单"
        echo "#"
        echo "#   此文件为项目专属配置，会与 _shared.conf 合并"
        echo "#   加载顺序: _shared.conf → ${CURRENT_PROJECT}.conf"
        echo "#   同名 plugin 以此文件为准（覆盖 _shared）"
        echo "#"
        echo "#   格式: plugin_name: lang1,lang2,..."
        echo "#   可选语言: dart, swift, objc (逗号分隔)"
        echo "#   特殊值:   disabled（可用于禁用 _shared 中的 plugin）"
        echo "#"
        echo "#   用法: 取消某行注释即可开启该 plugin 的混淆"
        echo "#   建议: 一个一个开启，验证通过后再加下一个"
        echo "# ============================================="
        echo ""

        while IFS='|' read -r name stats langs_avail; do
            echo "# ${name}  (${stats})"
            if [[ -n "$langs_avail" ]]; then
                echo "# ${name}: ${langs_avail}"
            else
                echo "# ${name}: disabled"
            fi
            echo ""
        done < "$scan_tmp"
    } > "$manifest_file"

    rm -f "$scan_tmp"
    log_success "已生成项目清单: $manifest_file"
    log_info "共享配置: $shared_file（多项目通用的 plugin 放这里）"
    log_info "项目配置: $manifest_file（项目专属覆盖）"
}

# 生成跳过规则模板（仅当目录不存在时）
generate_skip_rules_template() {
    if [[ -d "$SKIP_RULES_DIR" ]] && [[ -f "$SKIP_RULES_DIR/common.conf" ]]; then
        log_info "跳过规则目录已存在: $SKIP_RULES_DIR/"
        return
    fi
    mkdir -p "$SKIP_RULES_DIR"
    log_success "跳过规则目录: $SKIP_RULES_DIR/"
    log_info "  编辑 common.conf (通用), dart.conf, swift.conf, objc.conf"
}

# =============================================
# 跳过规则加载
# =============================================

# 从 conf 文件加载规则，通过 eval 追加到指定数组（bash 3.x 兼容）
_load_skip_file() {
    local file="$1"
    local exact_var="$2"
    local regex_var="$3"

    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" ]] && continue
        if [[ "$line" == /* ]] && [[ "$line" == */ ]]; then
            local pattern="${line:1:${#line}-2}"
            eval "${regex_var}+=(\"\$pattern\")"
        else
            eval "${exact_var}+=(\"\$line\")"
        fi
    done < "$file"
}

load_skip_rules() {
    log_info "加载跳过规则: $SKIP_RULES_DIR/"

    _load_skip_file "$SKIP_RULES_DIR/common.conf" _SKIP_EXACT_COMMON _SKIP_REGEX_COMMON
    _load_skip_file "$SKIP_RULES_DIR/dart.conf"   _SKIP_EXACT_DART   _SKIP_REGEX_DART
    _load_skip_file "$SKIP_RULES_DIR/swift.conf"   _SKIP_EXACT_SWIFT  _SKIP_REGEX_SWIFT
    _load_skip_file "$SKIP_RULES_DIR/objc.conf"    _SKIP_EXACT_OBJC   _SKIP_REGEX_OBJC

    log_debug "  common: ${#_SKIP_EXACT_COMMON[@]} 精确 + ${#_SKIP_REGEX_COMMON[@]} 正则"
    log_debug "  dart:   ${#_SKIP_EXACT_DART[@]} 精确 + ${#_SKIP_REGEX_DART[@]} 正则"
    log_debug "  swift:  ${#_SKIP_EXACT_SWIFT[@]} 精确 + ${#_SKIP_REGEX_SWIFT[@]} 正则"
    log_debug "  objc:   ${#_SKIP_EXACT_OBJC[@]} 精确 + ${#_SKIP_REGEX_OBJC[@]} 正则"

    _build_perl_skip_patterns
}

# 构建 perl 可用的跳过规则（精确 + 正则合并为一个 perl 表达式）
_PERL_SKIP_SWIFT=""
_PERL_SKIP_OBJC=""

_build_perl_skip_patterns() {
    # Swift: common + swift 精确 → perl hash, 正则 → perl alternation
    local exact_items=()
    local regex_items=()

    for e in "${_SKIP_EXACT_COMMON[@]}" "${_SKIP_EXACT_SWIFT[@]}"; do
        # 转义 perl 特殊字符
        local esc
        esc=$(printf '%s' "$e" | perl -pe 's/([\\\/\.\+\*\?\(\)\[\]\{\}\^\$\|])/\\$1/g')
        exact_items+=("^${esc}\$")
    done
    for r in "${_SKIP_REGEX_COMMON[@]}" "${_SKIP_REGEX_SWIFT[@]}"; do
        regex_items+=("$r")
    done

    local all_patterns=("${exact_items[@]}" "${regex_items[@]}")
    if [[ ${#all_patterns[@]} -gt 0 ]]; then
        _PERL_SKIP_SWIFT=$(IFS='|'; echo "${all_patterns[*]}")
    fi

    # ObjC: common + objc
    exact_items=()
    regex_items=()
    for e in "${_SKIP_EXACT_COMMON[@]}" "${_SKIP_EXACT_OBJC[@]}"; do
        local esc
        esc=$(printf '%s' "$e" | perl -pe 's/([\\\/\.\+\*\?\(\)\[\]\{\}\^\$\|])/\\$1/g')
        exact_items+=("^${esc}\$")
    done
    for r in "${_SKIP_REGEX_COMMON[@]}" "${_SKIP_REGEX_OBJC[@]}"; do
        regex_items+=("$r")
    done

    all_patterns=("${exact_items[@]}" "${regex_items[@]}")
    if [[ ${#all_patterns[@]} -gt 0 ]]; then
        _PERL_SKIP_OBJC=$(IFS='|'; echo "${all_patterns[*]}")
    fi
}

# 检查字符串是否应跳过 (shell 层面，用于 Swift/ObjC 提取后的二次过滤)
should_skip_string() {
    local str="$1"
    local lang="$2"  # swift | objc

    # 长度检查
    [[ ${#str} -lt 3 ]] && return 0

    # common 精确匹配
    local e
    for e in "${_SKIP_EXACT_COMMON[@]}"; do
        [[ "$str" == "$e" ]] && return 0
    done

    # common 正则匹配
    local r
    for r in "${_SKIP_REGEX_COMMON[@]}"; do
        echo "$str" | grep -qE "$r" 2>/dev/null && return 0
    done

    # 语言专用
    if [[ "$lang" == "swift" ]]; then
        for e in "${_SKIP_EXACT_SWIFT[@]}"; do
            [[ "$str" == "$e" ]] && return 0
        done
        for r in "${_SKIP_REGEX_SWIFT[@]}"; do
            echo "$str" | grep -qE "$r" 2>/dev/null && return 0
        done
    elif [[ "$lang" == "objc" ]]; then
        for e in "${_SKIP_EXACT_OBJC[@]}"; do
            [[ "$str" == "$e" ]] && return 0
        done
        for r in "${_SKIP_REGEX_OBJC[@]}"; do
            echo "$str" | grep -qE "$r" 2>/dev/null && return 0
        done
    fi

    return 1
}

# =============================================
# Swift 字符串混淆
# =============================================

# Swift/ObjC 单文件混淆：提取 + 跳过检查 + 编码 + 替换 全在一个 perl 进程完成
# 用法: _obfuscate_native_file <file> <lang> <skip_regex> <dry_run>
# 输出到 stdout: REPORT:行内容 / SUMMARY:count:skipped
_obfuscate_native_file() {
    local file="$1"
    local lang="$2"       # swift | objc
    local skip_re="$3"
    local dry="$4"        # 1 | 0

    perl -CSD -0777 -e '
        use strict; use warnings;
        use Encode qw(encode);
        my ($file, $lang, $skip_re_str, $dry) = @ARGV;

        open(my $fh, "<:raw", $file) or die "Cannot read $file: $!";
        local $/; my $c = <$fh>; close($fh);

        # 历史兼容：将旧版 objc statement-expression 编码回收为字面量形式，
        # 避免在 Log(fmt, ...) 这类依赖字面量拼接的宏中触发语法错误。
        sub objc_octal_literal {
            my @raw = @_;
            return "\@\"" . join("", map { sprintf("\\%03o", $_) } @raw) . "\"";
        }
        if ($lang eq "objc") {
            $c =~ s#\(\{\s*static const unsigned char _b\[\]\s*=\s*\{([^}]*)\}\s*;\s*\[\[NSString alloc\]\s*initWithBytes:_b\s*length:\d+\s*encoding:NSUTF8StringEncoding\]\s*;\s*\}\)#do {
                my @raw = map {
                    /\b0x([0-9a-fA-F]{1,2})\b/ ? hex($1) : ()
                } split(/\s*,\s*/, $1);
                @raw ? objc_octal_literal(@raw) : $&
            }#gse;
            $c =~ s#\@"((?:\\\\[0-7]{3})+)"#do {
                my $val = $1;
                $val =~ s/\\\\/\\/g;
                "\@\"" . $val . "\"";
            }#ge;
        }

        # 跳过规则（合并为一个正则）
        my $skip_re = length($skip_re_str) > 0 ? qr/$skip_re_str/ : undef;

        # 构建行级跳过范围
        my @skip_ranges;
        my $p = 0;
        for my $line (split /^/m, $c) {
            my $len = length($line);
            if ($lang eq "swift") {
                if ($line =~ /^\s*\/\// || $line =~ /^\s*import / ||
                    $line =~ /^\s*case\s+"/ || $line =~ /^\s*case\s+\w+\s*=\s*"/ ||
                    $line =~ /#selector/ ||
                    $line =~ /#available/ || $line =~ /^\s*#error\b/ ||
                    $line =~ /^\s*#warning\b/ ||
                    $line =~ /^\s*\@available\b/ || $line =~ /^\s*\@objc\b/ ||
                    $line =~ /\\\(/) {
                    push @skip_ranges, [$p, $p + $len];
                }
            } else {
                if ($line =~ /^\s*\/\// || $line =~ /^\s*#import / ||
                    $line =~ /^\s*#include / || $line =~ /^\s*\@import / ||
                    $line =~ /NSLocalizedString/) {
                    push @skip_ranges, [$p, $p + $len];
                }
            }
            $p += $len;
        }
        sub in_skip {
            for my $r (@skip_ranges) { return 1 if $_[0] >= $r->[0] && $_[0] < $r->[1]; }
            return 0;
        }

        # 编码函数
        sub swift_encode {
            my $s = shift;
            my @b = map { sprintf("0x%02x", $_) } unpack("C*", encode("UTF-8", $s));
            return "String(bytes: [" . join(", ", @b) . "] as [UInt8], encoding: .utf8)!";
        }
        sub objc_encode {
            my $s = shift;
            my @raw = unpack("C*", encode("UTF-8", $s));
            return objc_octal_literal(@raw);
        }

        # Swift: 跳过三引号字符串 """...""" 的范围
        if ($lang eq "swift") {
            my $tmp = $c;
            pos($tmp) = 0;
            while ($tmp =~ /"""/g) {
                my $start = pos($tmp) - 3;
                if ($tmp =~ /"""/g) {
                    my $end = pos($tmp);
                    push @skip_ranges, [$start, $end];
                }
            }
        }

        # ObjC: 构建花括号深度表，沿用历史行为继续跳过 file-scope 初始化，
        # 避免这次修复顺带扩大混淆范围。
        my @brace_depth;
        if ($lang eq "objc") {
            my $depth = 0;
            for my $i (0 .. length($c) - 1) {
                my $ch = substr($c, $i, 1);
                if ($ch eq "{") { $depth++; }
                $brace_depth[$i] = $depth;
                if ($ch eq "}") { $depth-- if $depth > 0; }
            }
        }

        my @replacements;
        my $count = 0;
        my $skipped = 0;

        # ObjC: @"..." 可能有相邻拼接
        # Swift: "..." 无拼接
        my $re = ($lang eq "objc")
            ? qr/\@"((?:[^"\\]|\\.)*)"/
            : qr/"((?:[^"\\]|\\.)*)"/;

        pos($c) = 0;
        while ($c =~ /$re/g) {
            my $match_start = pos($c) - length($&);
            next if in_skip($match_start);

            # ObjC: 跳过 file-scope (depth 0) 的字符串初始化
            if ($lang eq "objc" && ($brace_depth[$match_start] // 0) == 0) {
                next;
            }

            my $val = $1;

            if ($lang eq "swift") {
                next if $val =~ /\\\(/;
            }

            # ObjC: 跳过宏/字面量拼接 (MACRO @"..." 或 @"A" @"B")
            # ({...}) 语句表达式不能参与编译期字符串拼接
            if ($lang eq "objc" && $match_start > 0) {
                my $before = substr($c, 0, $match_start);
                $before =~ s/\s+$//;
                # @"A" @"B" 字面量拼接
                if ($before =~ /"$/) {
                    $skipped++;
                    next;
                }
                # MACRO @"..." — 前方标识符非关键字则视为宏拼接
                if ($before =~ /([A-Za-z_]\w*)$/) {
                    my $ident = $1;
                    unless ($ident =~ /^(return|goto|sizeof|typeof)$/) {
                        $skipped++;
                        next;
                    }
                }
            }

            # ObjC: 合并相邻 @"A" @"B"
            if ($lang eq "objc") {
                while ($c =~ /\G\s*\@"((?:[^"\\]|\\.)*)"/gc) {
                    $val .= $1;
                }
            }
            my $span = pos($c) - $match_start;

            next if $val =~ /^_zt_/;
            next if length($val) < 3;
            next if $val =~ /^[0-9.,\s_\-]+$/;
            next if $val =~ /^%[0-9ldfsegx\@.]+$/;
            next unless $val =~ /[a-zA-Z\x{4e00}-\x{9fa5}]/;

            if (defined $skip_re && $val =~ $skip_re) {
                $skipped++;
                next;
            }

            my $before = substr($c, 0, $match_start);
            my $line = ($before =~ tr/\n//) + 1;
            my $enc = ($lang eq "swift") ? swift_encode($val) : objc_encode($val);

            push @replacements, {
                off => $match_start, span => $span,
                val => $val, enc => $enc, line => $line
            };
            $count++;
        }

        # 按 offset 倒序替换
        unless ($dry) {
            for my $r (sort { $b->{off} <=> $a->{off} } @replacements) {
                substr($c, $r->{off}, $r->{span}) = $r->{enc};
            }
            open(my $out, ">:raw", $file) or die "Cannot write $file: $!";
            print $out $c;
            close($out);
        }

        # 报告输出
        for my $r (sort { $a->{off} <=> $b->{off} } @replacements) {
            my $prefix = ($lang eq "objc") ? "@" : "";
            printf "REPORT:L%d: %s\"%s\" -> (bytes)\n", $r->{line}, $prefix, $r->{val};
        }
        printf "SUMMARY:%d:%d\n", $count, $skipped;
    ' "$file" "$lang" "$skip_re" "$dry"
}

obfuscate_swift_file() {
    local file="$1"
    local fname
    fname=$(basename "$file")
    local rel_file="${file#$PROJECT_ROOT/}"
    local dry_flag=0
    [[ "$DRY_RUN" == "true" ]] && dry_flag=1

    local output
    output=$(_obfuscate_native_file "$file" "swift" "$_PERL_SKIP_SWIFT" "$dry_flag" 2>/dev/null)

    local summary_line
    summary_line=$(echo "$output" | grep '^SUMMARY:')
    local count skipped
    count=$(echo "$summary_line" | cut -d: -f2)
    skipped=$(echo "$summary_line" | cut -d: -f3)
    count=${count:-0}
    skipped=${skipped:-0}

    if [[ $count -eq 0 ]]; then
        log_debug "  $fname: 跳过 (无可混淆, skipped=$skipped)"
        return 0
    fi

    _REPORT_SWIFT_FILES=$((_REPORT_SWIFT_FILES + 1))
    _REPORT_SWIFT_STRINGS=$((_REPORT_SWIFT_STRINGS + count))
    _REPORT_ENTRIES+=("    [swift] $rel_file  ($count 个字符串, 跳过 $skipped)")

    while IFS= read -r line; do
        _REPORT_ENTRIES+=("      ${line#REPORT:}")
    done < <(echo "$output" | grep '^REPORT:')

    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug "  $fname: [DRY-RUN] 将混淆 $count 个字符串 (跳过 $skipped)"
    else
        log_debug "  $fname: 混淆 $count 个字符串 (跳过 $skipped)"
    fi
}

obfuscate_objc_file() {
    local file="$1"
    local fname
    fname=$(basename "$file")
    local rel_file="${file#$PROJECT_ROOT/}"
    local dry_flag=0
    [[ "$DRY_RUN" == "true" ]] && dry_flag=1

    local output
    output=$(_obfuscate_native_file "$file" "objc" "$_PERL_SKIP_OBJC" "$dry_flag" 2>/dev/null)

    local summary_line
    summary_line=$(echo "$output" | grep '^SUMMARY:')
    local count skipped
    count=$(echo "$summary_line" | cut -d: -f2)
    skipped=$(echo "$summary_line" | cut -d: -f3)
    count=${count:-0}
    skipped=${skipped:-0}

    if [[ $count -eq 0 ]]; then
        log_debug "  $fname: 跳过 (无可混淆, skipped=$skipped)"
        return 0
    fi

    _REPORT_OBJC_FILES=$((_REPORT_OBJC_FILES + 1))
    _REPORT_OBJC_STRINGS=$((_REPORT_OBJC_STRINGS + count))
    _REPORT_ENTRIES+=("    [objc]  $rel_file  ($count 个字符串, 跳过 $skipped)")

    while IFS= read -r line; do
        _REPORT_ENTRIES+=("      ${line#REPORT:}")
    done < <(echo "$output" | grep '^REPORT:')

    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug "  $fname: [DRY-RUN] 将混淆 $count 个字符串 (跳过 $skipped)"
    else
        log_debug "  $fname: 混淆 $count 个字符串 (跳过 $skipped)"
    fi
}

# =============================================
# Dart 字符串混淆 (调用 dart_obfuscator)
# =============================================

check_dart() {
    if [[ -x "$PROJECT_ROOT/.fvm/flutter_sdk/bin/dart" ]]; then
        DART_CMD="$PROJECT_ROOT/.fvm/flutter_sdk/bin/dart"
    elif command -v fvm &> /dev/null; then
        DART_CMD="fvm dart"
    elif command -v dart &> /dev/null; then
        DART_CMD="dart"
    else
        log_error "未找到 Dart 环境"
        return 1
    fi
}

DART_KERNEL=""
DART_RUNTIME_SIGNATURE=""

get_dart_runtime_signature() {
    $DART_CMD --version 2>&1 | head -1 | tr -d '\r'
}

compile_dart_kernel() {
    local kernel="$DART_OBFUSCATOR_DIR/build/obfuscate.dill"
    local meta="$DART_OBFUSCATOR_DIR/build/obfuscate.dill.meta"
    local src="$DART_OBFUSCATOR_DIR/bin/obfuscate.dart"

    mkdir -p "$DART_OBFUSCATOR_DIR/build"
    log_step "预编译 Dart 混淆工具 (kernel snapshot)..."
    $DART_CMD compile kernel "$src" -o "$kernel" 2>/dev/null

    if [[ -f "$kernel" ]]; then
        printf '%s\n' "$DART_RUNTIME_SIGNATURE" > "$meta"
    fi
}

kernel_needs_rebuild() {
    local kernel="$DART_OBFUSCATOR_DIR/build/obfuscate.dill"
    local meta="$DART_OBFUSCATOR_DIR/build/obfuscate.dill.meta"
    local src="$DART_OBFUSCATOR_DIR/bin/obfuscate.dart"

    [[ ! -f "$kernel" ]] && return 0
    [[ ! -f "$meta" ]] && return 0
    [[ "$src" -nt "$kernel" ]] && return 0

    local newer_source=""
    newer_source=$(find "$DART_OBFUSCATOR_DIR/bin" "$DART_OBFUSCATOR_DIR/lib" \
        -name "*.dart" -newer "$kernel" -print -quit 2>/dev/null || true)
    [[ -n "$newer_source" ]] && return 0

    local saved_signature=""
    saved_signature=$(cat "$meta" 2>/dev/null | head -1 | tr -d '\r')
    [[ "$saved_signature" != "$DART_RUNTIME_SIGNATURE" ]] && return 0

    return 1
}

init_dart_obfuscator() {
    if [[ ! -d "$DART_OBFUSCATOR_DIR" ]]; then
        log_warning "Dart 混淆工具不存在: $DART_OBFUSCATOR_DIR"
        return 1
    fi

    cd "$DART_OBFUSCATOR_DIR"
    if [[ ! -d ".dart_tool" ]] || [[ ! -f "pubspec.lock" ]]; then
        log_step "安装 Dart 混淆工具依赖..."
        $DART_CMD pub get
    fi

    if [[ "${DEP_STRINGS_USE_KERNEL:-false}" == "true" ]]; then
        local kernel="$DART_OBFUSCATOR_DIR/build/obfuscate.dill"
        DART_RUNTIME_SIGNATURE=$(get_dart_runtime_signature)
        if kernel_needs_rebuild; then
            compile_dart_kernel
        fi
        [[ -f "$kernel" ]] && DART_KERNEL="$kernel"
    fi
    cd "$PROJECT_ROOT"
}

obfuscate_dart_plugin() {
    local plugin_dir="${1%/}"
    local plugin_name="$2"
    plugin_dir=$(normalize_dir_path "$plugin_dir")

    local dart_pkgs=()
    if [[ -d "$plugin_dir/lib" ]] && [[ -f "$plugin_dir/pubspec.yaml" ]]; then
        dart_pkgs+=("$plugin_dir")
    fi
    while IFS= read -r sub; do
        [[ -d "$sub/lib" ]] || continue
        [[ -f "$sub/pubspec.yaml" ]] || continue
        is_queued_plugin_task_dir "$sub" && continue
        dart_pkgs+=("${sub%/}")
    done < <(find "$plugin_dir" -mindepth 1 -maxdepth 2 -type d 2>/dev/null)

    if [[ ${#dart_pkgs[@]} -eq 0 ]]; then
        log_debug "  $plugin_name: 无 Dart 包目录"
        return 0
    fi

    for dart_pkg in "${dart_pkgs[@]}"; do
        # 去除末尾的 /
        dart_pkg="${dart_pkg%/}"
        local dart_lib="$dart_pkg/lib"
        local dart_count
        dart_count=$(find "$dart_lib" -name "*.dart" \
            -not -path "*/test/*" -not -path "*/tests/*" \
            -not -path "*/example/*" -not -path "*/examples/*" \
            -not -path "*/integration_test/*" -not -path "*/test_driver/*" \
            2>/dev/null | wc -l | tr -d ' ')
        [[ $dart_count -eq 0 ]] && continue

        local rel_path="${dart_lib#$PROJECT_ROOT/}"
        log_debug "  $plugin_name: 处理 $dart_count 个 Dart 文件 ($rel_path)"

        local args=("-t" "$dart_lib" "--string" "-m" "bytes")
        [[ -n "$CURRENT_PROJECT" ]] && args+=("-p" "$CURRENT_PROJECT")
        [[ "$DRY_RUN" == "true" ]] && args+=("-d")
        [[ "$VERBOSE" == "true" ]] && args+=("-v")

        cd "$DART_OBFUSCATOR_DIR"
        local dart_report="${DART_STRING_OBFUSCATION_REPORT:-$DART_OBFUSCATOR_DIR/build/string_obfuscation_report_${CURRENT_PROJECT}.txt}"
        mkdir -p "$(dirname "$dart_report")"
        rm -f "$dart_report" 2>/dev/null || true

        local dart_tmpfile dart_rc=0 retry_with_run=false
        dart_tmpfile=$(mktemp)
        if [[ -n "$DART_KERNEL" ]]; then
            # .dill kernel snapshots must be invoked directly, not via `dart run`
            DART_STRING_OBFUSCATION_REPORT="$dart_report" $DART_CMD "$DART_KERNEL" "${args[@]}" > "$dart_tmpfile" 2>&1 || dart_rc=$?
        else
            DART_STRING_OBFUSCATION_REPORT="$dart_report" $DART_CMD run bin/obfuscate.dart "${args[@]}" > "$dart_tmpfile" 2>&1 || dart_rc=$?
        fi

        local clean_output
        clean_output=$(perl -pe 's/\e\[[0-9;]*m//g' "$dart_tmpfile")

        if [[ $dart_rc -ne 0 ]] && echo "$clean_output" | grep -q 'Invalid kernel binary format version'; then
            [[ "$VERBOSE" == "true" ]] && log_info "  $plugin_name: 检测到 kernel 版本不匹配，使用当前 Dart 重新编译" || true
            rm -f "$DART_OBFUSCATOR_DIR/build/obfuscate.dill" "$DART_OBFUSCATOR_DIR/build/obfuscate.dill.meta"
            compile_dart_kernel
            DART_KERNEL="$DART_OBFUSCATOR_DIR/build/obfuscate.dill"

            : > "$dart_tmpfile"
            dart_rc=0
            if [[ -n "$DART_KERNEL" ]]; then
                DART_STRING_OBFUSCATION_REPORT="$dart_report" $DART_CMD "$DART_KERNEL" "${args[@]}" > "$dart_tmpfile" 2>&1 || dart_rc=$?
            else
                retry_with_run=true
            fi
            clean_output=$(perl -pe 's/\e\[[0-9;]*m//g' "$dart_tmpfile")
        fi

        if [[ $dart_rc -ne 0 ]] && [[ -n "$DART_KERNEL" ]] && echo "$clean_output" | grep -q "Can't load Kernel binary"; then
            retry_with_run=true
        fi

        if [[ $dart_rc -ne 0 ]] && [[ -n "$DART_KERNEL" ]] && [[ "$retry_with_run" != "true" ]]; then
            [[ "$VERBOSE" == "true" ]] && log_info "  $plugin_name: kernel 执行失败，回退到 dart run" || true
            retry_with_run=true
        fi

        if [[ "$retry_with_run" == "true" ]]; then
            : > "$dart_tmpfile"
            dart_rc=0
            DART_STRING_OBFUSCATION_REPORT="$dart_report" $DART_CMD run bin/obfuscate.dart "${args[@]}" > "$dart_tmpfile" 2>&1 || dart_rc=$?
            clean_output=$(perl -pe 's/\e\[[0-9;]*m//g' "$dart_tmpfile")
        fi

        rm -f "$dart_tmpfile"
        cd "$PROJECT_ROOT"

        if [[ $dart_rc -ne 0 ]]; then
            local err_msg
            err_msg=$(echo "$clean_output" | grep -E "^错误:|^Error|Can't load Kernel binary" | head -1)
            if [[ -z "$err_msg" ]]; then
                err_msg=$(echo "$clean_output" | sed -n '/[^[:space:]]/ { p; q; }')
            fi
            log_warning "  $plugin_name: Dart 混淆失败 (rc=$dart_rc) ${err_msg}"
            _REPORT_ENTRIES+=("    [dart]  $rel_path/  (失败: $err_msg)")
            continue
        fi

        local files_count strings_count
        files_count=$(echo "$clean_output" | grep -E '[0-9]+ 个文件' | tail -1 | grep -oE '[0-9]+ 个文件' | grep -oE '[0-9]+' || echo "0")
        strings_count=$(echo "$clean_output" | grep -E '[0-9]+ 个字符串' | tail -1 | grep -oE '[0-9]+ 个字符串' | grep -oE '[0-9]+' || echo "0")

        if [[ $strings_count -gt 0 ]]; then
            _REPORT_DART_FILES=$((_REPORT_DART_FILES + files_count))
            _REPORT_DART_STRINGS=$((_REPORT_DART_STRINGS + strings_count))
            _REPORT_ENTRIES+=("    [dart]  $rel_path/  ($files_count 文件, $strings_count 字符串)")

            if [[ -f "$dart_report" ]]; then
                while IFS= read -r rline; do
                    case "$rline" in
                        "## "*)
                            _REPORT_ENTRIES+=("      ${rline#\#\# }") ;;
                        "  [混淆]"*|"  [跳过:"*)
                            _REPORT_ENTRIES+=("        ${rline#  }") ;;
                    esac
                done < "$dart_report"
            fi
        else
            log_debug "  $plugin_name: Dart 无可混淆字符串"
            _REPORT_ENTRIES+=("    [dart]  $rel_path/  (无可混淆字符串)")
        fi
    done
}

# =============================================
# 处理单个 plugin
# =============================================

process_plugin() {
    local plugin_dir="${1%/}"
    local plugin_name="${2:-}"
    [[ -z "$plugin_name" ]] && plugin_name=$(basename "$plugin_dir")

    if ! manifest_lookup "$plugin_name"; then
        log_debug "$plugin_name: 不在清单中，跳过"
        _REPORT_PLUGINS_SKIPPED=$((_REPORT_PLUGINS_SKIPPED + 1))
        return
    fi

    local config="$_FOUND_LANGS"
    if [[ "$config" == "disabled" ]]; then
        log_debug "$plugin_name: disabled"
        _REPORT_PLUGINS_SKIPPED=$((_REPORT_PLUGINS_SKIPPED + 1))
        _REPORT_ENTRIES+=("  $plugin_name: disabled")
        return
    fi

    log_info "$plugin_name: 混淆 [$config]"
    _REPORT_ENTRIES+=("")
    _REPORT_ENTRIES+=("  [$plugin_name] langs=$config")
    _REPORT_PLUGINS_PROCESSED=$((_REPORT_PLUGINS_PROCESSED + 1))

    local do_dart=false do_swift=false do_objc=false
    [[ "$config" == *dart* ]] && do_dart=true
    [[ "$config" == *swift* ]] && do_swift=true
    [[ "$config" == *objc* ]] && do_objc=true

    if [[ "$do_dart" == "true" ]]; then
        obfuscate_dart_plugin "$plugin_dir" "$plugin_name"
    fi

    if [[ "$do_swift" == "true" ]]; then
        while IFS= read -r swift_file; do
            [[ -z "$swift_file" ]] && continue
            local bname
            bname=$(basename "$swift_file")
            [[ "$bname" == _zt_* ]] && continue
            [[ "$bname" == "Package.swift" ]] && continue
            [[ "$bname" == *.g.swift ]] && continue
            is_non_ios_native_path "$swift_file" && continue
            is_under_other_queued_task_dir "$swift_file" "$plugin_dir" && continue
            obfuscate_swift_file "$swift_file"
        done < <(find "$plugin_dir" -name "*.swift" -type f 2>/dev/null | sort)
    fi

    if [[ "$do_objc" == "true" ]]; then
        while IFS= read -r objc_file; do
            [[ -z "$objc_file" ]] && continue
            local bname
            bname=$(basename "$objc_file")
            [[ "$bname" == _zt_* ]] && continue
            [[ "$bname" == *.g.m ]] && continue
            [[ "$bname" == *.g.mm ]] && continue
            is_non_ios_native_path "$objc_file" && continue
            is_under_other_queued_task_dir "$objc_file" "$plugin_dir" && continue
            obfuscate_objc_file "$objc_file"
        done < <(find "$plugin_dir" -type f \( -name "*.m" -o -name "*.mm" \) 2>/dev/null | sort)
    fi
}

# =============================================
# 报告生成
# =============================================

generate_report() {
    local report_status="${1:-success}"
    local report_exit_code="${2:-0}"
    local mode="实际执行"
    [[ "$DRY_RUN" == "true" ]] && mode="DRY-RUN"

    local project_tag="${CURRENT_PROJECT:-unknown}"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    REPORT_STARTED_AT="${REPORT_STARTED_AT:-$(date +"%Y-%m-%dT%H:%M:%S%z")}"
    REPORT_STARTED_EPOCH="${REPORT_STARTED_EPOCH:-$(date +%s)}"
    REPORT_FILE="$SCRIPT_DIR/reports/obf_${project_tag}_dep_strings_${timestamp}.txt"
    mkdir -p "$(dirname "$REPORT_FILE")"

    local total=$((_REPORT_DART_STRINGS + _REPORT_SWIFT_STRINGS + _REPORT_OBJC_STRINGS))

    {
        echo "# 依赖字符串混淆报告"
        echo "# 项目: $project_tag"
        echo "# 时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 模式: $mode"
        echo "# 状态: $report_status"
        echo "# 退出码: $report_exit_code"
        echo ""
        echo "## 统计"
        echo "  处理插件: $_REPORT_PLUGINS_PROCESSED 个"
        echo "  跳过插件: $_REPORT_PLUGINS_SKIPPED 个"
        echo ""
        echo "  Dart:  $_REPORT_DART_FILES 文件, $_REPORT_DART_STRINGS 字符串"
        echo "  Swift: $_REPORT_SWIFT_FILES 文件, $_REPORT_SWIFT_STRINGS 字符串"
        echo "  ObjC:  $_REPORT_OBJC_FILES 文件, $_REPORT_OBJC_STRINGS 字符串"
        echo ""
        echo "  总计: $total 字符串"
        echo ""
        echo "## 详情"
        for entry in "${_REPORT_ENTRIES[@]}"; do
            echo "$entry"
        done
    } > "$REPORT_FILE"

    log_success "报告: $REPORT_FILE"
}

# =============================================
# 主流程
# =============================================

run() {
    echo ""
    echo "=========================================="
    echo "      依赖字符串混淆 (Dep String Obfuscation)"
    echo "=========================================="
    echo ""

    load_manifest || return 1
    load_skip_rules

    # 检查是否需要 Dart 环境
    local need_dart=false
    local i=0
    while [[ $i -lt ${#_MF_LANGS[@]} ]]; do
        [[ "${_MF_LANGS[$i]}" == *dart* ]] && need_dart=true && break
        i=$((i + 1))
    done
    if [[ "$need_dart" == "true" ]]; then
        check_dart || return 1
        init_dart_obfuscator || log_warning "Dart 混淆工具初始化失败，将跳过 Dart 混淆"
    fi

    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
        log_step "[DRY-RUN] 开始依赖字符串混淆..."
    else
        log_step "开始依赖字符串混淆..."
    fi
    echo ""

    _PLUGIN_TASK_DIRS=()
    _PLUGIN_TASK_NAMES=()

    for plugin_dir in "$PLUGINS_DIR"/*/; do
        [[ -d "$plugin_dir" ]] || continue
        local pname
        pname=$(basename "$plugin_dir")
        if [[ -n "$SINGLE_PLUGIN" ]] && [[ "$pname" != "$SINGLE_PLUGIN" ]]; then
            continue
        fi
        enqueue_plugin_task "$plugin_dir" "$pname"
    done

    # flutter_base 子模块（已注册项目）
    if project_uses_flutter_base "$CURRENT_PROJECT" && [[ -d "$FLUTTER_BASE_DIR" ]]; then
        log_info "扫描 flutter_base/ 子模块..."
        for module_dir in "$FLUTTER_BASE_DIR"/*/; do
            [[ -d "$module_dir" ]] || continue
            [[ -f "$module_dir/pubspec.yaml" ]] || continue
            local mname
            mname=$(basename "$module_dir")
            if [[ -n "$SINGLE_PLUGIN" ]] && [[ "$mname" != "$SINGLE_PLUGIN" ]]; then
                continue
            fi
            enqueue_plugin_task "$module_dir" "$mname"
        done
    fi

    while IFS='|' read -r package_name package_dir package_tag; do
        [[ -z "$package_name" || -z "$package_dir" ]] && continue
        if [[ -n "$SINGLE_PLUGIN" ]] && [[ "$package_name" != "$SINGLE_PLUGIN" ]]; then
            continue
        fi
        [[ "$VERBOSE" == "true" ]] && log_info "扫描额外 path 依赖: $package_name $package_tag" || true
        enqueue_plugin_task "$package_dir" "$package_name"
    done < <(collect_extra_path_packages)

    run_plugin_tasks_parallel || return 1

    echo ""
    echo "=========================================="
    local total=$((_REPORT_DART_STRINGS + _REPORT_SWIFT_STRINGS + _REPORT_OBJC_STRINGS))
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "[DRY-RUN] 预览完成"
    else
        log_success "依赖字符串混淆完成"
    fi
    echo "  处理插件: $_REPORT_PLUGINS_PROCESSED 个"
    echo "  Dart:  $_REPORT_DART_FILES 文件, $_REPORT_DART_STRINGS 字符串"
    echo "  Swift: $_REPORT_SWIFT_FILES 文件, $_REPORT_SWIFT_STRINGS 字符串"
    echo "  ObjC:  $_REPORT_OBJC_FILES 文件, $_REPORT_OBJC_STRINGS 字符串"
    echo "  总计:  $total 字符串"
    echo "=========================================="

    generate_report
}

# =============================================
# 帮助
# =============================================

usage() {
    cat << EOF
依赖字符串混淆脚本 — 混淆 plugins/、flutter_base/、本地 path 依赖中的 Dart/Swift/ObjC 字符串

用法: $0 [选项]

选项:
  -p, --project NAME     项目代码 (hlw, ph, hjsq, tiktok, 91cg, 51pc, yms, acfun, tx, douyin, mrds, oio, bili, 91porn, 91porn2, txpjb, xjpjb, hlbdy, nnrj)
                         如不指定，自动从 ab_config.yaml 读取
  --plugin NAME          仅处理指定 plugin（调试用）
  --init                 生成清单模板（不执行混淆）
  -d, --dry-run          模拟运行，不实际修改文件
  -v, --verbose          详细输出
  -h, --help             显示帮助

清单文件:
  scripts/dep_strings_manifests/_shared.conf       # 多项目共享配置
  scripts/dep_strings_manifests/<project>.conf     # 项目专属配置（覆盖 _shared）

  加载顺序: _shared.conf → <project>.conf（后者覆盖前者同名 plugin）
  格式: plugin_name: lang1,lang2,...
  可选语言: dart, swift, objc
  特殊值:   disabled（可用于在项目中禁用 _shared 的 plugin）
  执行方式: 按 plugin/package 自动并行处理，无需配置并发参数

  示例:
    flutter_html-3.0.0-alpha.6: dart
    screen_brightness_ios: swift,objc
    permission_handler_apple: objc
    go_router-4.3.0: disabled

跳过规则:
  scripts/dep_strings_skip/common.conf    # 通用跳过（所有语言）
  scripts/dep_strings_skip/dart.conf      # Dart 专用跳过
  scripts/dep_strings_skip/swift.conf     # Swift 专用跳过
  scripts/dep_strings_skip/objc.conf      # ObjC 专用跳过

  支持精确匹配和正则: /^pattern$/

工作流:
  1. $0 --init -p hlw                         # 生成 _shared.conf + hlw.conf
  2. 编辑 _shared.conf（通用 plugin）或 hlw.conf（项目专属）
  3. 编辑 dep_strings_skip/*.conf 调整跳过规则
  4. $0 -p hlw -d -v                           # dry-run 预览
  5. $0 -p hlw                                 # 执行混淆
  6. fvm flutter build ios --release           # 验证编译

也可通过 obfuscate_frameworks.sh 调用:
  ./scripts/obfuscate_frameworks.sh dep-strings
  ./scripts/obfuscate_frameworks.sh dep-strings -d -v
EOF
    exit 0
}

# =============================================
# 入口
# =============================================

main() {
    REPORT_COMMAND_LINE="$0 $*"
    REPORT_STARTED_AT=$(date +"%Y-%m-%dT%H:%M:%S%z")
    REPORT_STARTED_EPOCH=$(date +%s)
    trap 'rc=$?; if [[ $rc -ne 0 && "${REPORT_TRAP_ENABLED:-false}" == "true" && -z "$REPORT_FILE" ]]; then generate_report "failed" "$rc" >/dev/null 2>&1 || true; fi' EXIT

    local do_init=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--project)   CURRENT_PROJECT="$2"; shift 2 ;;
            --plugin)       SINGLE_PLUGIN="$2"; shift 2 ;;
            --init)         do_init=true; shift ;;
            -d|--dry-run)   DRY_RUN=true; shift ;;
            -v|--verbose)   VERBOSE=true; shift ;;
            -h|--help)      usage ;;
            *)              log_error "未知参数: $1"; usage ;;
        esac
    done

    if [[ -z "$CURRENT_PROJECT" ]]; then
        CURRENT_PROJECT=$(detect_current_project) || true
        if [[ -n "$CURRENT_PROJECT" ]]; then
            log_info "自动检测到项目: $CURRENT_PROJECT"
        else
            log_error "未指定项目，请使用 -p 参数"
            exit 1
        fi
    fi

    reject_retired_project "$CURRENT_PROJECT"

    if [[ "$do_init" == "true" ]]; then
        generate_manifest_template
        generate_skip_rules_template
        return
    fi

    REPORT_TRAP_ENABLED=true
    run
}

main "$@"
