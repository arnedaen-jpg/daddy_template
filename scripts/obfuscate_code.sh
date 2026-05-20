#!/bin/bash

# ============================================================
# B面代码混淆脚本
# 使用 Dart AST 分析工具进行精确混淆
# 
# 混淆功能（可独立开启）：
#   1. 字符串混淆 --string    路由路径、API路径、敏感词、URL等
#   2. 调用栈混淆 --callstack 针对核心类方法包装调用，增加调用栈深度
#   3. 文件膨胀  --bloat      注入项目专属冗余代码（4.3a 差异化）
#   4. 业务噪音  --noise      在 build/initState/getHomePage 中注入噪音
#   5. AST变异   --mutation   在方法体中插入 dummy 代码
#   6. 符号扭曲  --symbols    extension/generic/mixin 结构生成
# 调用栈混淆说明：
#   - 只针对项目核心文件（如 api_service.dart, user_service.dart 等）
#   - 在方法体中注入包装调用，确保代码会被执行（不会被 tree shaking）
#   - 每个项目的核心文件列表不同，通过 -p 参数指定项目
# 
# 不包含：
#   - 资源混淆（已在 sync_secondary.sh 中完成）
#   - Flutter 官方混淆（在构建时通过 --obfuscate 完成）
# ============================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DART_OBFUSCATOR_DIR="$SCRIPT_DIR/dart_obfuscator"
REPORT_DIR="$SCRIPT_DIR/reports"

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# 从 ab_config.yaml 读取配置
read_ab_config() {
    local key="$1"
    local config_file="$PROJECT_ROOT/ab_config.yaml"
    
    if [[ -f "$config_file" ]]; then
        # 简单的 yaml 解析：key: value 格式
        local value=$(grep "^${key}:" "$config_file" | head -1 | sed "s/^${key}: *//" | tr -d '\r\n"')
        echo "$value"
    fi
}

# 自动检测当前B面项目
detect_current_project() {
    # 优先从 ab_config.yaml 读取
    local project=$(read_ab_config "project")
    if [[ -n "$project" ]]; then
        echo "$project"
        return 0
    fi
    
    # 兼容旧版：从 .current_secondary_project 文件读取
    local project_file="$PROJECT_ROOT/.current_secondary_project"
    if [[ -f "$project_file" ]]; then
        project=$(cat "$project_file" | tr -d '\n\r ')
        if [[ -n "$project" ]]; then
            echo "$project"
            return 0
        fi
    fi
    
    # 备选：从 sync_secondary.log 中读取最近的项目
    local log_file="$PROJECT_ROOT/sync_secondary.log"
    if [[ -f "$log_file" ]]; then
        project=$(grep "^源项目:" "$log_file" | tail -1 | sed 's/源项目: *//' | tr -d '\n\r ')
        if [[ -n "$project" ]]; then
            echo "$project"
            return 0
        fi
    fi
    
    return 1
}

# 显示帮助
show_help() {   
    cat << EOF
B面代码混淆脚本（Dart AST 版）

用法: $0 [选项] [混淆功能]

可选参数:
  -p, --project NAME         项目代码 (dq=斗球/直播, lgt=聊个天/IM)
                             如不指定，自动从 ab_config.yaml 读取
                             （sync_secondary.sh 执行后会自动生成）

混淆功能（可组合使用，至少选一个）:
  --string                   字符串混淆（API路径、URL、敏感词、中文文本）
  --callstack                调用栈混淆（针对核心类方法包装调用）
  --bloat                    文件膨胀（4.3a 差异化，项目专属冗余代码）
  --noise                    业务噪音（build/initState/getHomePage 注入）
  --mutation                 AST变异（方法体插入 dummy 代码）
  --symbols                  符号扭曲（extension/generic/mixin）
  --all                      启用所有混淆功能（含 string/callstack/bloat/noise/mutation/symbols）

字符串混淆配置:
  -m, --method METHOD        混淆方法: bytes, concat, base64, xor (默认: bytes)
  -k, --xor-key KEY          XOR 密钥 (默认: 42)

调用栈混淆配置:
  --depth INT                调用栈深度 1-5 (默认: 3)

其他选项:
  -t, --target DIR           目标目录 (默认: lib/modules/secondary)
  -d, --dry-run              模拟运行，不实际修改文件
  -v, --verbose              详细输出
  -h, --help                 显示帮助

核心文件（--callstack 针对的文件，详见 scripts/dart_obfuscator）:
  dq:  同原 tx（主入口/请求/加解密/WS 等核心文件名）
  lgt: 同原 acfun（全量服务/API/路由，偏 IM/社区）

示例:
  $0 --string                     # 字符串混淆
  $0 -p ph --string               # ph 项目字符串混淆
  $0 -p ph --callstack            # ph 项目调用栈混淆
  $0 -p ph --callstack --depth 4  # 调用栈深度 4
  $0 -p ph --bloat                # 文件膨胀（4.3a）
  $0 -p ph --noise --mutation     # 业务噪音 + AST变异
  $0 --all                        # 所有混淆
  $0 --string -d                  # 模拟运行（不修改文件）
EOF
}

# 检查 Dart 环境
check_dart() {
    if command -v fvm &> /dev/null; then
        DART_CMD="fvm dart"
    elif command -v dart &> /dev/null; then
        DART_CMD="dart"
    else
        log_error "未找到 Dart 环境"
        log_info "请安装 Dart SDK 或 Flutter SDK"
        exit 1
    fi
}

# 初始化 Dart 混淆工具
init_dart_obfuscator() {
    if [[ ! -d "$DART_OBFUSCATOR_DIR" ]]; then
        log_error "Dart 混淆工具不存在: $DART_OBFUSCATOR_DIR"
        exit 1
    fi
    
    # 清理主项目的 analyzer 缓存，避免使用过期的 offset 信息
    log_step "清理 analyzer 缓存..."
    rm -rf "$PROJECT_ROOT/.dart_tool/analyzer" 2>/dev/null
    rm -rf "$PROJECT_ROOT/.dart_tool/build" 2>/dev/null
    
    cd "$DART_OBFUSCATOR_DIR"
    
    # 检查是否需要安装依赖
    if [[ ! -d ".dart_tool" ]] || [[ ! -f "pubspec.lock" ]]; then
        log_step "安装 Dart 混淆工具依赖..."
        $DART_CMD pub get
    fi
    
    cd "$PROJECT_ROOT"
}

# 初始化日志文件（tee 同时输出到终端和文件）
setup_log() {
    local project_tag="$1"
    local is_dry_run="$2"
    [[ "$is_dry_run" == "true" ]] && return

    mkdir -p "$REPORT_DIR"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="$REPORT_DIR/code_${project_tag}_${timestamp}.log"

    exec > >(tee -a "$LOG_FILE") 2>&1
}

# 主函数
main() {
    echo ""
    echo "=========================================="
    echo "       B面代码混淆脚本 (Dart AST)"
    echo "=========================================="
    echo ""

    # 检查是否有参数
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi
    
    # 检查帮助参数
    for arg in "$@"; do
        if [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
            show_help
            exit 0
        fi
    done
    
    # 检测 dry-run
    local is_dry_run=false
    for arg in "$@"; do
        if [[ "$arg" == "-d" ]] || [[ "$arg" == "--dry-run" ]]; then
            is_dry_run=true
            break
        fi
    done

    # 检查 Dart 环境
    check_dart
    
    # 初始化 Dart 混淆工具
    init_dart_obfuscator
    
    # 默认目标目录（绝对路径）
    local target_dir="$PROJECT_ROOT/lib/modules/secondary"
    
    # 检查用户是否指定了 -t/--target 参数
    local has_target=false
    for arg in "$@"; do
        if [[ "$arg" == "-t" ]] || [[ "$arg" == "--target" ]]; then
            has_target=true
            break
        fi
    done
    
    # 检查是否指定了项目参数
    local has_project=false
    local explicit_project=""
    local next_is_project=false
    for arg in "$@"; do
        if [[ "$next_is_project" == "true" ]]; then
            explicit_project="$arg"
            next_is_project=false
        fi
        if [[ "$arg" == "-p" ]] || [[ "$arg" == "--project" ]]; then
            has_project=true
            next_is_project=true
        fi
    done
    
    # 如果没有指定项目，尝试自动检测
    local auto_project=""
    if [[ "$has_project" == "false" ]]; then
        auto_project=$(detect_current_project)
        if [[ -n "$auto_project" ]]; then
            log_info "自动检测到当前B面项目: $auto_project"
        else
            log_warning "未检测到当前项目，部分功能可能受限"
            log_info "提示：先运行 sync_secondary.sh -p <项目> 或手动指定 -p 参数"
        fi
    fi

    # 启动日志记录
    local project_tag="${explicit_project:-${auto_project:-unknown}}"
    setup_log "$project_tag" "$is_dry_run"
    
    # 调用 Dart 混淆工具
    log_step "启动 Dart 混淆工具..."
    cd "$DART_OBFUSCATOR_DIR"
    
    # 构建参数
    local args=()
    
    # 添加默认目标目录（如果未指定）
    if [[ "$has_target" == "false" ]]; then
        args+=("-t" "$target_dir")
    fi
    
    # 添加自动检测的项目（如果未指定）
    if [[ "$has_project" == "false" ]] && [[ -n "$auto_project" ]]; then
        args+=("-p" "$auto_project")
    fi
    
    # 添加用户传入的所有参数
    args+=("$@")
    
    $DART_CMD run bin/obfuscate.dart "${args[@]}"

    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        echo ""
        log_info "日志已保存: $LOG_FILE"
    fi
}

main "$@"
