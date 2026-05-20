#!/bin/bash

# ============================================================
# 图片资源压缩优化脚本
# 用于压缩 assets/secondary 中的图片资源
# 在 iOS 显示质量和包体积之间取得平衡
#
# 依赖工具（按优先级）:
#   PNG:  pngquant (lossy) + oxipng (lossless)
#   JPG:  sips (macOS 内置)
#   GIF:  gifsicle (可选)
#
# 安装依赖: brew install pngquant oxipng
# ============================================================

set -uo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 默认配置
TARGET_DIR="$PROJECT_ROOT/assets/secondary"
PNG_QUALITY="60-80"       # pngquant lossy 质量范围
JPG_QUALITY=80            # JPEG 压缩质量 (1-100)
SKIP_THRESHOLD=1024       # 跳过小于此大小的文件 (bytes)
DRY_RUN=false
VERBOSE=false
INSTALL_DEPS=false

# 统计变量
TOTAL_FILES=0
OPTIMIZED_FILES=0
SKIPPED_FILES=0
FAILED_FILES=0
TOTAL_BEFORE=0
TOTAL_AFTER=0

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $1"; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo -e "  ${NC}$1"; }

usage() {
    echo "用法: $(basename "$0") [选项] [目录]"
    echo ""
    echo "压缩优化图片资源，平衡 iOS 显示质量和包体积"
    echo ""
    echo "参数:"
    echo "  目录                    要优化的图片目录 (默认: assets/secondary)"
    echo ""
    echo "选项:"
    echo "  -q, --png-quality Q     PNG 压缩质量范围 (默认: $PNG_QUALITY)"
    echo "  -j, --jpg-quality Q     JPG 压缩质量 (默认: $JPG_QUALITY)"
    echo "  -t, --threshold BYTES   跳过小于此大小的文件 (默认: ${SKIP_THRESHOLD}B)"
    echo "  -d, --dry-run           模拟运行，只统计不修改"
    echo "  -v, --verbose           详细输出"
    echo "  --install               自动安装缺少的依赖 (brew)"
    echo "  -h, --help              显示帮助"
    echo ""
    echo "示例:"
    echo "  $(basename "$0")                        # 默认优化 assets/secondary"
    echo "  $(basename "$0") -d                     # 模拟运行，查看预估效果"
    echo "  $(basename "$0") -q 50-70 -j 75         # 更激进的压缩"
    echo "  $(basename "$0") /path/to/images        # 优化指定目录"
    echo "  $(basename "$0") --install              # 自动安装依赖并优化"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -q|--png-quality)
                PNG_QUALITY="$2"; shift 2 ;;
            -j|--jpg-quality)
                JPG_QUALITY="$2"; shift 2 ;;
            -t|--threshold)
                SKIP_THRESHOLD="$2"; shift 2 ;;
            -d|--dry-run)
                DRY_RUN=true; shift ;;
            -v|--verbose)
                VERBOSE=true; shift ;;
            --install)
                INSTALL_DEPS=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            -*)
                log_error "未知选项: $1"; usage; exit 1 ;;
            *)
                TARGET_DIR="$1"; shift ;;
        esac
    done
}

format_size() {
    local bytes=$1
    if [[ $bytes -ge 1048576 ]]; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1048576}')MB"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.1f", b/1024}')KB"
    else
        echo "${bytes}B"
    fi
}

format_percent() {
    local before=$1 after=$2
    if [[ $before -eq 0 ]]; then
        echo "0%"
    else
        echo "$(awk -v a="$before" -v b="$after" 'BEGIN {printf "%.1f", (a-b)/a*100}')%"
    fi
}

# 检查并安装依赖
check_dependencies() {
    log_step "检查依赖工具..."

    local has_pngquant=false
    local has_oxipng=false
    local has_gifsicle=false
    local missing=()

    command -v pngquant &>/dev/null && has_pngquant=true || missing+=("pngquant")
    command -v oxipng &>/dev/null && has_oxipng=true || missing+=("oxipng")
    command -v gifsicle &>/dev/null && has_gifsicle=true

    # sips 是 macOS 内置工具
    if ! command -v sips &>/dev/null; then
        log_error "sips 不可用（非 macOS？），JPG 压缩将不可用"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warning "缺少工具: ${missing[*]}"

        if [[ "$INSTALL_DEPS" == "true" ]]; then
            if command -v brew &>/dev/null; then
                log_info "正在通过 Homebrew 安装: ${missing[*]}"
                brew install "${missing[@]}"
                # 重新检查
                command -v pngquant &>/dev/null && has_pngquant=true
                command -v oxipng &>/dev/null && has_oxipng=true
            else
                log_error "Homebrew 未安装，无法自动安装依赖"
                log_info "请手动安装: brew install ${missing[*]}"
            fi
        else
            log_info "使用 --install 参数可自动安装，或手动: brew install ${missing[*]}"
            if [[ "$has_pngquant" == "false" ]]; then
                log_warning "pngquant 未安装，PNG 将使用 sips 降级压缩（效果有限）"
            fi
        fi
    fi

    HAS_PNGQUANT=$has_pngquant
    HAS_OXIPNG=$has_oxipng
    HAS_GIFSICLE=$has_gifsicle

    log_info "工具状态: pngquant=$HAS_PNGQUANT oxipng=$HAS_OXIPNG sips=$(command -v sips &>/dev/null && echo true || echo false)"
}

# 优化单个 PNG 文件
optimize_png() {
    local file="$1"
    local before_size
    before_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)

    if [[ $before_size -lt $SKIP_THRESHOLD ]]; then
        log_verbose "跳过 (${before_size}B < ${SKIP_THRESHOLD}B): $(basename "$file")"
        SKIPPED_FILES=$((SKIPPED_FILES + 1))
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
        TOTAL_AFTER=$((TOTAL_AFTER + before_size))
        OPTIMIZED_FILES=$((OPTIMIZED_FILES + 1))
        return
    fi

    local tmp_file="${file}.opt.tmp"

    if [[ "$HAS_PNGQUANT" == "true" ]]; then
        # pngquant: lossy PNG 压缩，质量极佳
        if pngquant --quality="$PNG_QUALITY" --speed 3 --strip --force --output "$tmp_file" "$file" 2>/dev/null; then
            # oxipng: 在 pngquant 基础上做 lossless 进一步优化
            if [[ "$HAS_OXIPNG" == "true" ]]; then
                oxipng -o 2 -q --strip safe "$tmp_file" 2>/dev/null || true
            fi

            local after_size
            after_size=$(stat -f%z "$tmp_file" 2>/dev/null || stat -c%s "$tmp_file" 2>/dev/null)

            if [[ $after_size -lt $before_size ]]; then
                mv "$tmp_file" "$file"
                TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
                TOTAL_AFTER=$((TOTAL_AFTER + after_size))
                OPTIMIZED_FILES=$((OPTIMIZED_FILES + 1))
                log_verbose "PNG $(format_size $before_size) -> $(format_size $after_size) ($(format_percent $before_size $after_size)): $(basename "$file")"
                return
            else
                rm -f "$tmp_file"
                log_verbose "PNG 已最优，跳过: $(basename "$file")"
                TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
                TOTAL_AFTER=$((TOTAL_AFTER + before_size))
                SKIPPED_FILES=$((SKIPPED_FILES + 1))
                return
            fi
        else
            rm -f "$tmp_file"
            # pngquant 可能因为已经是 256 色以下而跳过，尝试 oxipng
            if [[ "$HAS_OXIPNG" == "true" ]]; then
                cp "$file" "$tmp_file"
                oxipng -o 2 -q --strip safe "$tmp_file" 2>/dev/null || true
                local after_size
                after_size=$(stat -f%z "$tmp_file" 2>/dev/null || stat -c%s "$tmp_file" 2>/dev/null)
                if [[ $after_size -lt $before_size ]]; then
                    mv "$tmp_file" "$file"
                    TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
                    TOTAL_AFTER=$((TOTAL_AFTER + after_size))
                    OPTIMIZED_FILES=$((OPTIMIZED_FILES + 1))
                    log_verbose "PNG(oxipng) $(format_size $before_size) -> $(format_size $after_size): $(basename "$file")"
                    return
                fi
                rm -f "$tmp_file"
            fi
            TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
            TOTAL_AFTER=$((TOTAL_AFTER + before_size))
            SKIPPED_FILES=$((SKIPPED_FILES + 1))
            return
        fi
    elif [[ "$HAS_OXIPNG" == "true" ]]; then
        cp "$file" "$tmp_file"
        oxipng -o 3 -q --strip safe "$tmp_file" 2>/dev/null || true
        local after_size
        after_size=$(stat -f%z "$tmp_file" 2>/dev/null || stat -c%s "$tmp_file" 2>/dev/null)
        if [[ $after_size -lt $before_size ]]; then
            mv "$tmp_file" "$file"
            TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
            TOTAL_AFTER=$((TOTAL_AFTER + after_size))
            OPTIMIZED_FILES=$((OPTIMIZED_FILES + 1))
            log_verbose "PNG(oxipng) $(format_size $before_size) -> $(format_size $after_size): $(basename "$file")"
        else
            rm -f "$tmp_file"
            TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
            TOTAL_AFTER=$((TOTAL_AFTER + before_size))
            SKIPPED_FILES=$((SKIPPED_FILES + 1))
        fi
    else
        # Fallback: sips (macOS) - 效果有限，但聊胜于无
        if command -v sips &>/dev/null; then
            cp "$file" "$tmp_file"
            sips -s format png "$tmp_file" &>/dev/null || true
            local after_size
            after_size=$(stat -f%z "$tmp_file" 2>/dev/null || stat -c%s "$tmp_file" 2>/dev/null)
            if [[ $after_size -lt $before_size ]]; then
                mv "$tmp_file" "$file"
                TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
                TOTAL_AFTER=$((TOTAL_AFTER + after_size))
                OPTIMIZED_FILES=$((OPTIMIZED_FILES + 1))
                log_verbose "PNG(sips) $(format_size $before_size) -> $(format_size $after_size): $(basename "$file")"
            else
                rm -f "$tmp_file"
                TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
                TOTAL_AFTER=$((TOTAL_AFTER + before_size))
                SKIPPED_FILES=$((SKIPPED_FILES + 1))
            fi
        else
            TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
            TOTAL_AFTER=$((TOTAL_AFTER + before_size))
            SKIPPED_FILES=$((SKIPPED_FILES + 1))
        fi
    fi
}

# 优化单个 JPG 文件
optimize_jpg() {
    local file="$1"
    local before_size
    before_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)

    if [[ $before_size -lt $SKIP_THRESHOLD ]]; then
        log_verbose "跳过 (${before_size}B < ${SKIP_THRESHOLD}B): $(basename "$file")"
        SKIPPED_FILES=$((SKIPPED_FILES + 1))
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
        TOTAL_AFTER=$((TOTAL_AFTER + before_size))
        OPTIMIZED_FILES=$((OPTIMIZED_FILES + 1))
        return
    fi

    if command -v sips &>/dev/null; then
        local tmp_file="${file}.opt.tmp"
        cp "$file" "$tmp_file"
        sips -s format jpeg -s formatOptions "$JPG_QUALITY" "$tmp_file" &>/dev/null || true
        local after_size
        after_size=$(stat -f%z "$tmp_file" 2>/dev/null || stat -c%s "$tmp_file" 2>/dev/null)

        if [[ $after_size -lt $before_size ]]; then
            mv "$tmp_file" "$file"
            TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
            TOTAL_AFTER=$((TOTAL_AFTER + after_size))
            OPTIMIZED_FILES=$((OPTIMIZED_FILES + 1))
            log_verbose "JPG $(format_size $before_size) -> $(format_size $after_size) ($(format_percent $before_size $after_size)): $(basename "$file")"
        else
            rm -f "$tmp_file"
            TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
            TOTAL_AFTER=$((TOTAL_AFTER + before_size))
            SKIPPED_FILES=$((SKIPPED_FILES + 1))
        fi
    else
        TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
        TOTAL_AFTER=$((TOTAL_AFTER + before_size))
        SKIPPED_FILES=$((SKIPPED_FILES + 1))
    fi
}

# 优化单个 GIF 文件
optimize_gif() {
    local file="$1"
    local before_size
    before_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)

    if [[ $before_size -lt $SKIP_THRESHOLD ]]; then
        SKIPPED_FILES=$((SKIPPED_FILES + 1))
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
        TOTAL_AFTER=$((TOTAL_AFTER + before_size))
        return
    fi

    if [[ "$HAS_GIFSICLE" == "true" ]]; then
        local tmp_file="${file}.opt.tmp"
        gifsicle -O3 --lossy=80 "$file" -o "$tmp_file" 2>/dev/null || true
        if [[ -f "$tmp_file" ]]; then
            local after_size
            after_size=$(stat -f%z "$tmp_file" 2>/dev/null || stat -c%s "$tmp_file" 2>/dev/null)
            if [[ $after_size -lt $before_size ]]; then
                mv "$tmp_file" "$file"
                TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
                TOTAL_AFTER=$((TOTAL_AFTER + after_size))
                OPTIMIZED_FILES=$((OPTIMIZED_FILES + 1))
                log_verbose "GIF $(format_size $before_size) -> $(format_size $after_size): $(basename "$file")"
                return
            fi
            rm -f "$tmp_file"
        fi
    fi

    TOTAL_BEFORE=$((TOTAL_BEFORE + before_size))
    TOTAL_AFTER=$((TOTAL_AFTER + before_size))
    SKIPPED_FILES=$((SKIPPED_FILES + 1))
}

# 打印统计报告
print_report() {
    local saved=$((TOTAL_BEFORE - TOTAL_AFTER))

    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}        图片优化统计报告${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""
    echo -e "  目标目录:     $TARGET_DIR"
    echo -e "  扫描文件:     ${TOTAL_FILES} 个"
    echo -e "  优化文件:     ${GREEN}${OPTIMIZED_FILES}${NC} 个"
    echo -e "  跳过文件:     ${SKIPPED_FILES} 个"
    [[ $FAILED_FILES -gt 0 ]] && echo -e "  失败文件:     ${RED}${FAILED_FILES}${NC} 个"
    echo ""
    echo -e "  优化前总大小: $(format_size $TOTAL_BEFORE)"
    echo -e "  优化后总大小: $(format_size $TOTAL_AFTER)"
    echo -e "  节省空间:     ${GREEN}$(format_size $saved)${NC} ($(format_percent $TOTAL_BEFORE $TOTAL_AFTER))"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}[DRY-RUN] 以上为预估统计，未实际修改文件${NC}"
        echo ""
    fi

    echo -e "${BOLD}============================================${NC}"
}

main() {
    parse_args "$@"

    if [[ "$DRY_RUN" != "true" ]]; then
        echo -e "${BOLD}============================================${NC}"
        echo -e "${BOLD}        图片资源压缩优化${NC}"
        echo -e "${BOLD}============================================${NC}"
    else
        echo -e "${BOLD}============================================${NC}"
        echo -e "${BOLD}        图片资源压缩优化 (模拟运行)${NC}"
        echo -e "${BOLD}============================================${NC}"
    fi
    echo ""

    if [[ ! -d "$TARGET_DIR" ]]; then
        log_error "目录不存在: $TARGET_DIR"
        exit 1
    fi

    check_dependencies

    # 收集所有图片文件
    log_step "扫描图片文件..."

    local -a png_files=()
    local -a jpg_files=()
    local -a gif_files=()

    while IFS= read -r -d '' file; do
        png_files+=("$file")
    done < <(find "$TARGET_DIR" -type f \( -name "*.png" -o -name "*.PNG" \) -print0 2>/dev/null)

    while IFS= read -r -d '' file; do
        jpg_files+=("$file")
    done < <(find "$TARGET_DIR" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.JPG" -o -name "*.JPEG" \) -print0 2>/dev/null)

    while IFS= read -r -d '' file; do
        gif_files+=("$file")
    done < <(find "$TARGET_DIR" -type f \( -name "*.gif" -o -name "*.GIF" \) -print0 2>/dev/null)

    local png_count=${#png_files[@]}
    local jpg_count=${#jpg_files[@]}
    local gif_count=${#gif_files[@]}
    TOTAL_FILES=$((png_count + jpg_count + gif_count))

    log_info "发现: PNG=${png_count}  JPG=${jpg_count}  GIF=${gif_count}  总计=${TOTAL_FILES}"

    if [[ $TOTAL_FILES -eq 0 ]]; then
        log_warning "未找到图片文件"
        exit 0
    fi

    # 优化 PNG
    if [[ $png_count -gt 0 ]]; then
        log_step "优化 PNG 文件 ($png_count 个)..."
        local i=0
        for file in "${png_files[@]}"; do
            i=$((i + 1))
            if [[ $((i % 50)) -eq 0 ]] || [[ $i -eq $png_count ]]; then
                printf "\r  进度: %d/%d" "$i" "$png_count"
            fi
            optimize_png "$file"
        done
        echo ""
    fi

    # 优化 JPG
    if [[ $jpg_count -gt 0 ]]; then
        log_step "优化 JPG 文件 ($jpg_count 个)..."
        local i=0
        for file in "${jpg_files[@]}"; do
            i=$((i + 1))
            if [[ $((i % 50)) -eq 0 ]] || [[ $i -eq $jpg_count ]]; then
                printf "\r  进度: %d/%d" "$i" "$jpg_count"
            fi
            optimize_jpg "$file"
        done
        echo ""
    fi

    # 优化 GIF
    if [[ $gif_count -gt 0 ]]; then
        log_step "优化 GIF 文件 ($gif_count 个)..."
        for file in "${gif_files[@]}"; do
            optimize_gif "$file"
        done
    fi

    print_report
}

main "$@"
