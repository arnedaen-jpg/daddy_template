#!/bin/bash

# ============================================================
# Full B-side obfuscation pipeline
# Runs:
#   sync_secondary.sh -> obfuscate_code.sh --all -> obfuscate_frameworks.sh run
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_NAMES_FILE="$SCRIPT_DIR/project_names.conf"

PROJECT_NAME=""
SOURCE_PATH=""

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

usage() {
    cat <<EOF
一键 B 面同步 + 全量混淆流水线

用法:
  $0 -p <项目代号> -s <B面源码路径>
  $0 <项目代号> <B面源码路径>

示例:
  $0 -p dq -s /Users/t-yh/dqiu/xty
  $0 dq /Users/t-yh/dqiu/xty

选项:
  -p, --project NAME     项目代号
  -s, --source PATH      B 面源码路径
  -l, --list             列出项目代号和业务名称映射
  -h, --help             显示帮助

项目名称映射:
  $PROJECT_NAMES_FILE
EOF
}

trim_awk='
function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
}
'

project_display_name() {
    local code="$1"
    [[ -f "$PROJECT_NAMES_FILE" ]] || return 0

    awk -F'|' -v code="$code" "$trim_awk"'
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            key = trim($1)
            name = trim($2)
            if (key == code) {
                print name
                exit
            }
        }
    ' "$PROJECT_NAMES_FILE"
}

project_is_supported() {
    local code="$1"
    [[ -n "$code" && -f "$PROJECT_NAMES_FILE" ]] || return 1

    awk -F'|' -v code="$code" "$trim_awk"'
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        trim($1) == code { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$PROJECT_NAMES_FILE"
}

list_projects() {
    if [[ ! -f "$PROJECT_NAMES_FILE" ]]; then
        log_error "项目名称映射不存在: $PROJECT_NAMES_FILE"
        exit 1
    fi

    printf "%-14s %s\n" "项目代号" "业务名称"
    printf "%-14s %s\n" "--------" "--------"
    awk -F'|' "$trim_awk"'
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            key = trim($1)
            name = trim($2)
            if (key != "") printf "%-14s %s\n", key, name
        }
    ' "$PROJECT_NAMES_FILE"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                PROJECT_NAME="$2"
                shift 2
                ;;
            -s|--source)
                SOURCE_PATH="$2"
                shift 2
                ;;
            -l|--list)
                list_projects
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                log_error "未知参数: $1"
                usage
                exit 1
                ;;
            *)
                if [[ -z "$PROJECT_NAME" ]]; then
                    PROJECT_NAME="$1"
                elif [[ -z "$SOURCE_PATH" ]]; then
                    SOURCE_PATH="$1"
                else
                    log_error "多余参数: $1"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

validate_inputs() {
    if [[ -z "$PROJECT_NAME" || -z "$SOURCE_PATH" ]]; then
        log_error "请指定项目代号和 B 面源码路径"
        usage
        exit 1
    fi

    if ! project_is_supported "$PROJECT_NAME"; then
        log_error "未支持的项目代号: $PROJECT_NAME"
        log_info "可用项目:"
        list_projects
        exit 1
    fi

    if [[ ! -d "$SOURCE_PATH" ]]; then
        log_error "B 面源码路径不存在: $SOURCE_PATH"
        exit 1
    fi

    if [[ ! -f "$SOURCE_PATH/pubspec.yaml" ]]; then
        log_error "B 面源码路径缺少 pubspec.yaml: $SOURCE_PATH"
        exit 1
    fi
}

run_step() {
    local label="$1"
    shift

    echo ""
    log_step "$label"
    "$@"
}

main() {
    parse_args "$@"
    validate_inputs

    local display_name
    display_name=$(project_display_name "$PROJECT_NAME")
    [[ -z "$display_name" ]] && display_name="$PROJECT_NAME"

    cd "$PROJECT_ROOT"

    log_info "项目: $PROJECT_NAME ($display_name)"
    log_info "B 面源码: $SOURCE_PATH"

    run_step "[1/3] 同步 B 面代码" \
        "$SCRIPT_DIR/sync_secondary.sh" -p "$PROJECT_NAME" -s "$SOURCE_PATH"

    run_step "[2/3] Dart 代码全量混淆" \
        "$SCRIPT_DIR/obfuscate_code.sh" -p "$PROJECT_NAME" --all

    run_step "[3/3] Framework / Pod / 依赖字符串混淆" \
        "$SCRIPT_DIR/obfuscate_frameworks.sh" run -p "$PROJECT_NAME"

    echo ""
    log_success "全量混淆流水线完成: $PROJECT_NAME ($display_name)"
}

main "$@"
