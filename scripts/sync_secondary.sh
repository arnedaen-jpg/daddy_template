#!/bin/bash

# ============================================================
# 次要模块代码同步脚本（本地文件版）
# 从本地 B 面项目同步到「脚本所在工程」：本脚本应位于目标工程的 scripts/ 下并从该工程执行
#（PROJECT_ROOT = 脚本父目录 = 工程根；与原始 zeus_template 行为一致）
# 核心功能：复制代码 + 批量替换包名为相对路径
# ============================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 工程根 = 脚本父目录（本脚本随工程存在于「工程/scripts」下，并从该工程执行）。
# AB 包工厂已改为优先调用「工程自身」的这份脚本，确保 PROJECT_ROOT / assets / Base64 相对路径都指向当前工程。
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$SCRIPT_DIR/reports"
LOG_FILE=""

# 默认目标路径
TARGET_SIDE_B_DIR="$PROJECT_ROOT/lib/modules/secondary"
TARGET_ASSETS_DIR="$PROJECT_ROOT/assets/secondary"
TARGET_PLUGINS_DIR="$PROJECT_ROOT/plugins"
TARGET_INFO_PLIST="$PROJECT_ROOT/ios/Runner/Info.plist"

# 项目专用适配文件目录
COMPAT_DIR="$SCRIPT_DIR/compat"

# Source 项目专用适配文件
# 在 parse_args 确定 PROJECT_NAME 后调用
source_compat_file() {
    local compat_file="$COMPAT_DIR/compat_${PROJECT_NAME}.sh"
    if [[ -f "$compat_file" ]]; then
        source "$compat_file"
        log_info "已加载项目适配: compat_${PROJECT_NAME}.sh"
    else
        log_warning "未找到项目适配文件: $compat_file"
    fi
}

# 日志函数
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

# 初始化日志文件（tee 同时输出到终端和文件）
setup_log() {
    local project_tag="$1"
    [[ "$DRY_RUN" == "true" ]] && return

    mkdir -p "$REPORT_DIR"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="$REPORT_DIR/sync_${project_tag}_${timestamp}.log"

    exec > >(tee -a "$LOG_FILE") 2>&1
}

# 配置文件路径
CONFIG_FILE="$SCRIPT_DIR/sync_secondary.conf"

# 默认项目配置（可被配置文件覆盖）
# 仅保留 dq（斗球/直播，源: xty）与 lgt（聊个天/IM，原 tx 体系）
PROJECT_DQ=""
PROJECT_LGT=""
PACKAGE_DQ="xty"
PACKAGE_LGT="lgt"

# 加载配置文件
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "已加载配置文件: $CONFIG_FILE"
    fi
}

# 根据项目名获取路径
get_project_path() {
    local name="$1"
    case "$name" in
        dq)  echo "$PROJECT_DQ" ;;
        lgt) echo "$PROJECT_LGT" ;;
        *)   echo "" ;;
    esac
}

# 根据项目名获取原始包名
get_project_package() {
    local name="$1"
    case "$name" in
        dq)  echo "$PACKAGE_DQ" ;;
        lgt) echo "$PACKAGE_LGT" ;;
        *)   echo "" ;;
    esac
}

get_app_package_name() {
    local current_package_name=""
    local template_package_name=""

    if [[ -f "$PROJECT_ROOT/pubspec.yaml" ]]; then
        current_package_name=$(grep "^name:" "$PROJECT_ROOT/pubspec.yaml" | head -1 | sed 's/name: *//' | tr -d ' \r\n')
    fi
    if [[ -f "$PROJECT_ROOT/pubspec.yaml.template" ]]; then
        template_package_name=$(grep "^name:" "$PROJECT_ROOT/pubspec.yaml.template" | head -1 | sed 's/name: *//' | tr -d ' \r\n')
    fi

    if [[ -n "$current_package_name" && "$current_package_name" != "daddy_template" ]]; then
        echo "$current_package_name"
    elif [[ -n "$template_package_name" && "$template_package_name" != "daddy_template" ]]; then
        echo "$template_package_name"
    else
        echo "$current_package_name"
    fi
}

# 从标准输入中选出最高版本号（支持 x.y / x.y.z）
pick_max_version() {
    awk '
        function vercmp(v1, v2,    n1, n2, i, a, b, len) {
            n1 = split(v1, a, ".")
            n2 = split(v2, b, ".")
            len = (n1 > n2 ? n1 : n2)
            for (i = 1; i <= len; i++) {
                if ((a[i] + 0) > (b[i] + 0)) return 1
                if ((a[i] + 0) < (b[i] + 0)) return -1
            }
            return 0
        }
        NF {
            if (max_ver == "" || vercmp($0, max_ver) > 0) {
                max_ver = $0
            }
        }
        END {
            if (max_ver != "") {
                print max_ver
            }
        }
    '
}

# 从 Xcode project.pbxproj 中提取 iOS 部署目标版本
# 优先读取 Runner 应用 target 的配置，避免误取到 PBXProject 级别的旧版本
get_ios_deployment_target_from_pbxproj() {
    local pbxproj="$1"
    [[ -f "$pbxproj" ]] || return 1

    local runner_config_list_id=""
    runner_config_list_id=$(
        awk '
            /^[[:space:]]*[A-Z0-9]+ \/\* Runner \*\/ = \{/ {
                in_target = 1
                is_native = 0
                is_app = 0
                config_id = ""
            }
            in_target && /isa = PBXNativeTarget;/ {
                is_native = 1
            }
            in_target && /buildConfigurationList = / && /Build configuration list for PBXNativeTarget "Runner"/ {
                config_id = $0
                sub(/.*buildConfigurationList = /, "", config_id)
                sub(/ \/\* Build configuration list for PBXNativeTarget "Runner" \*\/;.*/, "", config_id)
            }
            in_target && /productType = "com\.apple\.product-type\.application";/ {
                is_app = 1
            }
            in_target && /^[[:space:]]*};$/ {
                if (is_native && is_app && config_id != "") {
                    print config_id
                    exit
                }
                in_target = 0
            }
        ' "$pbxproj"
    )

    local runner_versions=""
    if [[ -n "$runner_config_list_id" ]]; then
        local config_ids=""
        config_ids=$(
            awk -v list_id="$runner_config_list_id" '
                $0 ~ "^[[:space:]]*" list_id " /\\* Build configuration list for PBXNativeTarget \"Runner\" \\*/ = \\{" {
                    in_list = 1
                    capture = 0
                    next
                }
                in_list && /buildConfigurations = \(/ {
                    capture = 1
                    next
                }
                in_list && capture && /\/\*/ {
                    line = $0
                    sub(/^[[:space:]]*/, "", line)
                    sub(/ \/\* .*/, "", line)
                    print line
                }
                in_list && capture && /\);/ {
                    exit
                }
            ' "$pbxproj"
        )

        if [[ -n "$config_ids" ]]; then
            while IFS= read -r config_id; do
                [[ -z "$config_id" ]] && continue
                awk -v config_id="$config_id" '
                    $0 ~ "^[[:space:]]*" config_id " /\\* " {
                        in_config = 1
                        next
                    }
                    in_config && /IPHONEOS_DEPLOYMENT_TARGET = / {
                        version = $0
                        sub(/.*IPHONEOS_DEPLOYMENT_TARGET = /, "", version)
                        sub(/;.*/, "", version)
                        print version
                        exit
                    }
                    in_config && /^[[:space:]]*};$/ {
                        exit
                    }
                ' "$pbxproj"
            done <<< "$config_ids" | pick_max_version
            return 0
        fi
    fi

    # 兜底：Runner target 解析失败时，取整个 pbxproj 中的最高 deployment target
    grep -oE "IPHONEOS_DEPLOYMENT_TARGET = [0-9]+(\.[0-9]+)+" "$pbxproj" \
        | grep -oE "[0-9]+(\.[0-9]+)+" \
        | pick_max_version
}

# 显示帮助信息
show_help() {
    echo "使用方法: $0 -p <项目代码> -s <源路径> [选项]"
    echo ""
    echo "必需参数:"
    echo "  -p, --project NAME    项目代码 (dq, lgt)  # dq=斗球/直播, lgt=聊个天/IM"
    echo "  -s, --source PATH     源项目路径"
    echo ""
    echo "可选参数:"
    echo "  -n, --package NAME    源项目包名（默认从 pubspec.yaml 读取）"
    echo "  -l, --list            列出预设项目配置"
    echo "  -d, --dry-run         模拟运行，不实际复制文件"
    echo "  --no-pull             跳过 git pull --ff-only（源仓库 origin 不可达 / 离线场景）；用源项目当前工作区版本同步"
    echo "  --base64-map          (默认开启) 生成 secondary 图片 Base64 映射；写入 lib/utils 下 Base64 支持 Dart；同步结束后删除"
    echo "                        assets/secondary 下图片（不删 JSON/字体等），避免打进包"
    echo "  --keep-secondary-images  与 --base64-map 同用时保留 secondary 图片文件不删"
    echo "  --replace-image-entry 批量替换 Image.asset 为 BaseHHImage"
    echo "  --init-config         生成默认配置文件"
    echo "  -h, --help            显示帮助信息"
    echo ""
    echo "配置文件: $CONFIG_FILE"
    echo "  配置文件可以预设项目路径，之后只需指定 -p 即可"
    echo ""
    echo "资源文件混淆说明:"
    echo "  为避免苹果机审检测相似特征，同步时会自动混淆资源文件。"
    echo "  混淆种子优先级: iOS bundle id > 项目名"
    echo "  默认自动使用 iOS 工程的 bundle id，确保："
    echo "    - 同一 AB 包每次构建结果一致"
    echo "    - 不同 AB 包（不同 bundle id）生成不同的文件名/hash"
    echo ""
    echo "示例:"
    echo "  $0 -p dq -s /Users/t-yh/dqiu/xty          # 同步斗球 (dq)"
    echo "  $0 -p lgt -s /path/to/lgt_app             # 同步聊个天 (lgt)"
    echo "  $0 --init-config                           # 生成配置文件模板"
}

# 生成配置文件
init_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_warning "配置文件已存在: $CONFIG_FILE"
        echo "是否覆盖? (y/N)"
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "已取消"
            exit 0
        fi
    fi

    cat > "$CONFIG_FILE" << 'EOF'
# sync_secondary.sh 配置文件
# 仅支持 dq（斗球/直播）与 lgt（聊个天/IM）

# 项目路径
PROJECT_DQ="/Users/t-yh/dqiu/xty"
PROJECT_LGT="/path/to/lgt"

# 源工程 pubspec name（一般与目录无关；也可用 -n 覆盖）
PACKAGE_DQ="xty"
PACKAGE_LGT="lgt"
EOF

    log_success "配置文件已生成: $CONFIG_FILE"
    echo "请编辑配置文件，设置正确的项目路径"
}

# 列出预设项目
list_projects() {
    echo "预设项目列表 (dq=斗球/直播, lgt=聊个天/IM):"
    echo ""
    echo "配置文件: $CONFIG_FILE"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}(配置文件不存在，请运行 --init-config 生成)${NC}"
    fi
    echo ""

    if [[ -n "$PROJECT_DQ" ]] && [[ -d "$PROJECT_DQ" ]]; then
        echo -e "  ${GREEN}dq${NC}  -> $PROJECT_DQ (包名: $PACKAGE_DQ)"
    elif [[ -n "$PROJECT_DQ" ]]; then
        echo -e "  ${RED}dq${NC}  -> $PROJECT_DQ (路径不存在)"
    else
        echo -e "  ${YELLOW}dq${NC}  -> (未配置)"
    fi

    if [[ -n "$PROJECT_LGT" ]] && [[ -d "$PROJECT_LGT" ]]; then
        echo -e "  ${GREEN}lgt${NC} -> $PROJECT_LGT (包名: $PACKAGE_LGT)"
    elif [[ -n "$PROJECT_LGT" ]]; then
        echo -e "  ${RED}lgt${NC} -> $PROJECT_LGT (路径不存在)"
    else
        echo -e "  ${YELLOW}lgt${NC} -> (未配置)"
    fi
}

# 变量初始化
SOURCE_PATH=""
PROJECT_NAME=""
SOURCE_PACKAGE=""
DRY_RUN=false
NO_PULL=false
GENERATE_BASE64_MAP=false
REPLACE_IMAGE_ENTRY=false
# 与 --base64-map 同用时默认在脚本末尾删除 assets/secondary 内图片；--keep-secondary-images 可关闭
DELETE_SECONDARY_IMAGES=false
KEEP_SECONDARY_IMAGES=false
SOURCE_GIT_BRANCH=""
SOURCE_GIT_UPSTREAM=""
SOURCE_GIT_COMMIT=""
SOURCE_GIT_COMMIT_SHORT=""
SOURCE_GIT_COMMIT_TIME=""
SOURCE_GIT_DIRTY="false"

# 解析命令行参数
parse_args() {
    # 临时变量，用于存储命令行指定的路径
    local cmd_source_path=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--project)
                PROJECT_NAME="$2"
                # 验证项目代码是否有效
                if [[ "$PROJECT_NAME" != "dq" && "$PROJECT_NAME" != "lgt" ]]; then
                    log_error "无效的项目代码: $PROJECT_NAME"
                    echo "有效的项目代码: dq, lgt"
                    exit 1
                fi
                # 从配置文件获取路径和包名
                SOURCE_PATH=$(get_project_path "$PROJECT_NAME")
                SOURCE_PACKAGE=$(get_project_package "$PROJECT_NAME")
                shift 2
                ;;
            -s|--source)
                cmd_source_path="$2"
                shift 2
                ;;
            -n|--package)
                SOURCE_PACKAGE="$2"
                shift 2
                ;;
            -l|--list)
                list_projects
                exit 0
                ;;
            --no-pull)
                NO_PULL=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --base64-map)
                GENERATE_BASE64_MAP=true
                REPLACE_IMAGE_ENTRY=true
                DELETE_SECONDARY_IMAGES=true
                shift
                ;;
            --keep-secondary-images)
                KEEP_SECONDARY_IMAGES=true
                shift
                ;;
            --replace-image-entry)
                REPLACE_IMAGE_ENTRY=true
                shift
                ;;
            --init-config)
                init_config
                exit 0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 如果命令行指定了路径，优先使用命令行路径
    if [[ -n "$cmd_source_path" ]]; then
        SOURCE_PATH="$cmd_source_path"
    fi

    # 检查必需参数
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "请指定项目代码 (-p dq|lgt)"
        echo ""
        show_help
        exit 1
    fi

    if [[ -z "$SOURCE_PATH" ]]; then
        log_error "请指定源路径 (-s) 或在配置文件中配置项目路径"
        echo ""
        show_help
        exit 1
    fi

    # 如果是自定义路径但没有指定包名，尝试从 pubspec.yaml 读取
    if [[ -z "$SOURCE_PACKAGE" ]] && [[ -f "$SOURCE_PATH/pubspec.yaml" ]]; then
        SOURCE_PACKAGE=$(grep "^name:" "$SOURCE_PATH/pubspec.yaml" | sed 's/name: *//' | tr -d ' \r\n')
        log_info "从 pubspec.yaml 读取包名: $SOURCE_PACKAGE"
    fi

    if [[ -z "$SOURCE_PACKAGE" ]]; then
        log_error "无法确定源项目包名，请使用 -n 参数指定"
        exit 1
    fi

    # 默认启用 --base64-map（保持与显式传参行为一致）
    # 目标：不传 --base64-map 时，也自动生成 Base64 map + 替换 Image.asset + 同步后删除图片
    if [[ "$GENERATE_BASE64_MAP" != "true" ]]; then
        GENERATE_BASE64_MAP=true
        REPLACE_IMAGE_ENTRY=true
        DELETE_SECONDARY_IMAGES=true
        log_info "默认启用 --base64-map（生成 Base64 map + 替换 Image.asset + 同步后删除图片）"
    fi

}

# 验证源路径
validate_source() {
    log_info "验证源项目路径..."

    if [[ ! -d "$SOURCE_PATH" ]]; then
        log_error "源路径不存在: $SOURCE_PATH"
        exit 1
    fi

    if [[ ! -d "$SOURCE_PATH/lib" ]]; then
        log_error "源项目缺少 lib 目录: $SOURCE_PATH/lib"
        exit 1
    fi

    if [[ ! -f "$SOURCE_PATH/pubspec.yaml" ]]; then
        log_error "源项目缺少 pubspec.yaml"
        exit 1
    fi

    log_success "源项目验证通过: $SOURCE_PATH"
    log_info "源项目包名: $SOURCE_PACKAGE"
}

ensure_source_git_repo_ready() {
    if ! git -C "$SOURCE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_error "源项目不是 Git 仓库，无法执行 git pull: $SOURCE_PATH"
        exit 1
    fi

    SOURCE_GIT_BRANCH=$(git -C "$SOURCE_PATH" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [[ -z "$SOURCE_GIT_BRANCH" ]]; then
        log_error "源项目当前不在分支上（可能是 detached HEAD），无法执行 git pull"
        exit 1
    fi

    SOURCE_GIT_UPSTREAM=$(git -C "$SOURCE_PATH" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)
    if [[ -z "$SOURCE_GIT_UPSTREAM" ]]; then
        log_error "源项目当前分支未配置上游分支，无法执行 git pull: $SOURCE_GIT_BRANCH"
        exit 1
    fi
}

collect_source_git_info() {
    SOURCE_GIT_BRANCH=$(git -C "$SOURCE_PATH" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    SOURCE_GIT_UPSTREAM=$(git -C "$SOURCE_PATH" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)
    SOURCE_GIT_COMMIT=$(git -C "$SOURCE_PATH" rev-parse HEAD 2>/dev/null || true)
    SOURCE_GIT_COMMIT_SHORT=$(git -C "$SOURCE_PATH" rev-parse --short HEAD 2>/dev/null || true)
    SOURCE_GIT_COMMIT_TIME=$(git -C "$SOURCE_PATH" log -1 --format=%cI 2>/dev/null || true)

    if [[ -n "$(git -C "$SOURCE_PATH" status --short 2>/dev/null)" ]]; then
        SOURCE_GIT_DIRTY="true"
    else
        SOURCE_GIT_DIRTY="false"
    fi
}

update_source_repo() {
    log_step "同步前更新源项目 Git 当前分支..."

    ensure_source_git_repo_ready
    log_info "源项目当前分支: $SOURCE_GIT_BRANCH"
    log_info "源项目上游分支: $SOURCE_GIT_UPSTREAM"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 跳过 git pull，仅检查 Git 状态并读取当前版本信息"
        collect_source_git_info
    elif [[ "$NO_PULL" == "true" ]]; then
        log_info "--no-pull: 跳过 git pull，使用源项目当前工作区版本（离线/内网不通时用）"
        collect_source_git_info
        log_warning "源项目未拉取最新代码，请确认本地 $SOURCE_GIT_BRANCH 已是期望状态"
    else
        if ! git -C "$SOURCE_PATH" pull --ff-only; then
            log_error "源项目 git pull 失败，已中断同步"
            log_info "若 origin 不可达（内网/离线），可加 --no-pull 用本地工作区跑"
            exit 1
        fi
        collect_source_git_info
        log_success "源项目已更新到最新代码"
    fi

    if [[ "$SOURCE_GIT_DIRTY" == "true" ]]; then
        log_warning "源项目存在未提交修改，本次同步会包含工作区内容；ab_config.yaml 已记录 dirty 状态"
    fi

    if [[ -n "$SOURCE_GIT_COMMIT_SHORT" ]]; then
        log_info "源项目版本: ${SOURCE_GIT_BRANCH}@${SOURCE_GIT_COMMIT_SHORT}"
    fi
}

# 备份当前 次要模块代码
backup_current() {
    if [[ -d "$TARGET_SIDE_B_DIR" ]] && [[ "$(ls -A "$TARGET_SIDE_B_DIR" 2>/dev/null)" ]]; then
        local backup_dir="$PROJECT_ROOT/backups/secondary_$(date +%Y%m%d_%H%M%S)"
        log_info "备份当前 次要模块代码到: $backup_dir"

        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] 将备份到: $backup_dir"
        else
            mkdir -p "$(dirname "$backup_dir")"
            cp -r "$TARGET_SIDE_B_DIR" "$backup_dir"
            log_success "备份完成"
        fi
    fi
}

# 执行复制命令（支持 dry-run）
do_copy() {
    local src="$1"
    local dst="$2"
    local desc="$3"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 复制: $src -> $dst"
    else
        mkdir -p "$(dirname "$dst")"
        cp -r "$src" "$dst"
        log_info "已复制: $desc"
    fi
}

# 执行删除命令（支持 dry-run）
do_remove() {
    local path="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 删除: $path"
    else
        rm -rf "$path"
    fi
}

# 同步 lib 代码
sync_lib() {
    log_step "同步 lib 代码..."

    # 清空目标 secondary 目录
    if [[ -d "$TARGET_SIDE_B_DIR" ]]; then
        do_remove "${TARGET_SIDE_B_DIR:?}"/*
    else
        mkdir -p "$TARGET_SIDE_B_DIR"
    fi

    # 复制所有 lib 内容
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 复制 $SOURCE_PATH/lib/* -> $TARGET_SIDE_B_DIR/"
    else
        cp -r "$SOURCE_PATH/lib"/* "$TARGET_SIDE_B_DIR/"
    fi

    local file_count
    file_count=$(find "$SOURCE_PATH/lib" -name "*.dart" | wc -l | tr -d ' ')
    log_success "lib 同步完成: $file_count 个 Dart 文件"
}

# 替换包名为相对路径导入
# 这是核心功能：将 package:xxx/ 替换为相对路径
replace_package_imports() {
    log_step "替换包名导入为相对路径..."

    if [[ "$DRY_RUN" == "true" ]]; then
        local count
        count=$(grep -r "package:$SOURCE_PACKAGE/" "$SOURCE_PATH/lib" --include="*.dart" 2>/dev/null | wc -l | tr -d ' ')
        log_info "[DRY-RUN] 将替换 $count 处 'package:$SOURCE_PACKAGE/' 导入"
        return
    fi

    # 遍历所有 dart 文件，计算相对路径并替换
    local total_replaced=0

    while IFS= read -r -d '' file; do
        # 获取文件相对于 secondary 目录的路径
        local rel_path="${file#$TARGET_SIDE_B_DIR/}"
        # 计算目录深度
        local depth=$(echo "$rel_path" | tr -cd '/' | wc -c | tr -d ' ')

        # 构建相对路径前缀
        local prefix=""
        for ((i=0; i<depth; i++)); do
            prefix="../$prefix"
        done

        # 如果文件在根目录，前缀为 ./
        if [[ -z "$prefix" ]]; then
            prefix="./"
        fi

        # 统计当前文件的替换数量
        local file_count
        file_count=$(grep -c "package:$SOURCE_PACKAGE/" "$file" 2>/dev/null || echo "0")
        file_count=$(echo "$file_count" | tr -d '\n\r ')

        if [[ "$file_count" -gt 0 ]]; then
            # 执行替换: package:xxx/path -> 相对路径/path
            # 使用 sed 替换，macOS 和 Linux 兼容写法
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' "s|package:$SOURCE_PACKAGE/|$prefix|g" "$file"
            else
                sed -i "s|package:$SOURCE_PACKAGE/|$prefix|g" "$file"
            fi
            total_replaced=$((total_replaced + file_count))
        fi
    done < <(find "$TARGET_SIDE_B_DIR" -name "*.dart" -print0)

    log_success "包名替换完成: 共替换 $total_replaced 处导入"
}

# 修复绝对路径导入（以 / 开头的导入）
# 某些项目使用 import '/path/to/file.dart' 的绝对路径导入方式
# 这种导入方式需要转换为相对路径
fix_absolute_path_imports() {
    log_step "修复绝对路径导入..."

    if [[ "$DRY_RUN" == "true" ]]; then
        local count
        count=$(grep -r "import '/" "$TARGET_SIDE_B_DIR" --include="*.dart" 2>/dev/null | wc -l | tr -d ' ')
        log_info "[DRY-RUN] 将修复 $count 处绝对路径导入"
        return
    fi

    local total_fixed=0

    while IFS= read -r -d '' file; do
        # 获取文件相对于 secondary 目录的路径
        local rel_path="${file#$TARGET_SIDE_B_DIR/}"
        # 计算目录深度
        local depth=$(echo "$rel_path" | tr -cd '/' | wc -c | tr -d ' ')

        # 构建相对路径前缀
        local prefix=""
        for ((i=0; i<depth; i++)); do
            prefix="../$prefix"
        done

        # 如果文件在根目录，前缀为空（直接使用文件名）
        if [[ -z "$prefix" ]]; then
            prefix=""
        fi

        # 检查文件是否包含绝对路径导入
        local file_count
        file_count=$(grep -c "import '/" "$file" 2>/dev/null || echo "0")
        file_count=$(echo "$file_count" | tr -d '\n\r ')

        if [[ "$file_count" -gt 0 ]]; then
            # 替换 import '/xxx' -> import 'prefix/xxx'
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' "s|import '/|import '${prefix}|g" "$file"
            else
                sed -i "s|import '/|import '${prefix}|g" "$file"
            fi
            total_fixed=$((total_fixed + file_count))
        fi
    done < <(find "$TARGET_SIDE_B_DIR" -name "*.dart" -print0)

    log_success "绝对路径导入修复完成: 共修复 $total_fixed 处"
}

# 修复源项目中已有的相对路径导入
# 源项目的相对路径是相对于 lib/ 的，迁移后需要相对于 lib/modules/secondary/
fix_existing_relative_imports() {
    log_step "修复已有的相对路径导入..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将修复已有的相对路径导入"
        return
    fi

    local total_fixed=0

    while IFS= read -r -d '' file; do
        # 检查文件是否包含跳出 secondary 目录的相对路径
        # 这些路径以 ../ 开头，最终会跳到 lib/modules/ 或更上层

        # 获取文件相对于 secondary 目录的路径
        local rel_path="${file#$TARGET_SIDE_B_DIR/}"
        # 计算目录深度（从 secondary 根目录算起）
        local depth=$(echo "$rel_path" | tr -cd '/' | wc -c | tr -d ' ')

        # 检查是否有超出 secondary 目录的相对导入
        # 例如：在 views/mine/mine_buy/ (depth=3) 中使用 ../../../../ (4层) 会跳出 secondary
        local file_modified=false

        # 逐个检查可能的层级（从4层到10层，覆盖大多数情况）
        for ((layers=10; layers>=2; layers--)); do
            # 构建当前层级的 ../ 模式
            local pattern=""
            for ((j=0; j<layers; j++)); do
                pattern="${pattern}\\.\\./"
            done

            # 检查文件是否包含这种模式的导入
            if grep -q "import '$pattern" "$file" 2>/dev/null || grep -q "import \"$pattern" "$file" 2>/dev/null; then
                # 计算这个导入实际会跳到哪里
                # 如果 layers > depth，说明这个导入原本是要跳到 lib 根目录或更上层的
                # 迁移后，需要保持在 secondary 内部

                if [[ $layers -gt $depth ]]; then
                    # 这个导入会跳出 secondary 目录
                    # 需要移除多余的 ../ 层级，使其指向 secondary 根目录
                    local excess=$((layers - depth))

                    # 构建新的相对路径（移除多余的 ../ ）
                    local old_prefix=""
                    local new_prefix=""
                    for ((j=0; j<layers; j++)); do
                        old_prefix="${old_prefix}../"
                    done
                    for ((j=0; j<depth; j++)); do
                        new_prefix="${new_prefix}../"
                    done

                    # 如果 depth 为 0，使用 ./
                    if [[ -z "$new_prefix" ]]; then
                        new_prefix="./"
                    fi

                    # 执行替换
                    if [[ "$(uname)" == "Darwin" ]]; then
                        sed -i '' "s|'${old_prefix}|'${new_prefix}|g" "$file"
                        sed -i '' "s|\"${old_prefix}|\"${new_prefix}|g" "$file"
                    else
                        sed -i "s|'${old_prefix}|'${new_prefix}|g" "$file"
                        sed -i "s|\"${old_prefix}|\"${new_prefix}|g" "$file"
                    fi
                    file_modified=true
                fi
            fi
        done

        if [[ "$file_modified" == "true" ]]; then
            total_fixed=$((total_fixed + 1))
        fi
    done < <(find "$TARGET_SIDE_B_DIR" -name "*.dart" -print0)

    log_success "相对路径修复完成: 共修复 $total_fixed 个文件"
}

# 同步 assets
sync_assets() {
    log_step "同步 assets..."

    if [[ ! -d "$SOURCE_PATH/assets" ]]; then
        log_warning "源项目无 assets 目录，跳过"
        return
    fi

    # 清空目标 assets/secondary 目录
    if [[ -d "$TARGET_ASSETS_DIR" ]]; then
        do_remove "${TARGET_ASSETS_DIR:?}"
    fi

    do_copy "$SOURCE_PATH/assets" "$TARGET_ASSETS_DIR" "assets"

    log_success "assets 同步完成"
}

# 压缩优化图片资源（调用 optimize_images.sh）
optimize_secondary_images() {
    log_step "压缩优化图片资源..."

    if [[ ! -d "$TARGET_ASSETS_DIR" ]]; then
        log_warning "资源目录不存在: $TARGET_ASSETS_DIR，跳过图片优化"
        return
    fi

    local optimize_script="$SCRIPT_DIR/optimize_images.sh"
    if [[ ! -f "$optimize_script" ]]; then
        log_warning "优化脚本不存在: $optimize_script，跳过图片优化"
        return
    fi

    local opts=()
    if [[ "$DRY_RUN" == "true" ]]; then
        opts+=("-d")
    fi

    bash "$optimize_script" "${opts[@]}" "$TARGET_ASSETS_DIR"
}

# 生成 secondary 图片 Base64 映射文件
generate_secondary_base64_map() {
    if [[ "$GENERATE_BASE64_MAP" != "true" ]]; then
        return
    fi

    log_step "生成 secondary 图片 Base64 映射..."

    local gen_script="$SCRIPT_DIR/generate_secondary_base64_map.sh"
    local output_file="$TARGET_SIDE_B_DIR/generate/secondary_image_base64_map.dart"
    local flutter_base_output_file="$PROJECT_ROOT/flutter_base/lib/modules/secondary/generate/secondary_image_base64_map.dart"

    if [[ ! -f "$gen_script" ]]; then
        log_warning "生成脚本不存在: $gen_script，跳过 Base64 映射生成"
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将生成 Base64 映射文件: $output_file"
        if [[ -d "$PROJECT_ROOT/flutter_base" ]]; then
            log_info "[DRY-RUN] 将同时生成 flutter_base Base64 映射文件: $flutter_base_output_file"
        fi
        return
    fi

    if [[ ! -d "$TARGET_ASSETS_DIR" ]]; then
        log_warning "资源目录不存在: $TARGET_ASSETS_DIR，跳过 Base64 映射生成"
        return
    fi

    bash "$gen_script" "$TARGET_ASSETS_DIR" "$output_file"

    # 项目若含 flutter_base 包，确保其也有映射文件，便于内部复用 Base64 扩展/组件
    if [[ -d "$PROJECT_ROOT/flutter_base" ]]; then
        mkdir -p "$(dirname "$flutter_base_output_file")"
        bash "$gen_script" "$TARGET_ASSETS_DIR" "$flutter_base_output_file"
    fi
}

# 按需写入 lib/utils 下 Base64 支持 Dart（未启用 Base64/替换时不生成，避免污染工程）
ensure_base64_support_darts() {
    if [[ "$GENERATE_BASE64_MAP" != "true" && "$REPLACE_IMAGE_ENTRY" != "true" ]]; then
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将按需写入 scripts/write_base64_support_darts.sh 生成的 Dart 文件"
        return
    fi

    local writer="$SCRIPT_DIR/write_base64_support_darts.sh"
    if [[ ! -f "$writer" ]]; then
        log_warning "写入脚本不存在: $writer，跳过"
        return
    fi

    log_step "写入 Base64 支持 Dart 文件（按需）..."
    # 仅生成映射时只需 extension；要替换 Image.asset 时需 BaseHHImage + extension
    local mode="ext-only"
    if [[ "$REPLACE_IMAGE_ENTRY" == "true" ]]; then
        mode="all"
    fi
    bash "$writer" "$PROJECT_ROOT" "$mode"

    # 项目若含 flutter_base 包，也需要这些 utils（否则 flutter_base 内引用会缺文件）
    if [[ -d "$PROJECT_ROOT/flutter_base" ]]; then
        bash "$writer" "$PROJECT_ROOT/flutter_base" "$mode"
    fi
}

# 修复 secondary 中 MyAssetImage：优先读取 Base64 映射，避免 secondary 图片删除后仍走 AssetBundle
patch_secondary_my_asset_image_to_base64() {
    if [[ "$GENERATE_BASE64_MAP" != "true" ]]; then
        return
    fi

    local target_file="$TARGET_SIDE_B_DIR/ui_layer/screens/common_widgets/my_image.dart"
    if [[ ! -f "$target_file" ]]; then
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将修复 MyAssetImage：优先从 Base64 映射加载 secondary 图片"
        return
    fi

    python3 - "$target_file" "$PROJECT_ROOT/lib/utils/secondary_image_base64_ext.dart" << 'PY'
import os
import re
import sys
from pathlib import Path

file_path = Path(sys.argv[1])
helper_file = Path(sys.argv[2])

if not file_path.exists():
    raise SystemExit(0)

content = file_path.read_text(encoding="utf-8")
changed = False

if "secondary_image_base64_ext.dart" not in content:
    rel_import = Path(os.path.relpath(helper_file, file_path.parent)).as_posix()
    target_import = f"import '{rel_import}';"
    import_matches = list(re.finditer(r"^import\s+['\"].*?['\"];\s*$", content, flags=re.M))
    if import_matches:
        insert_at = import_matches[-1].end()
        content = content[:insert_at] + "\n" + target_import + content[insert_at:]
    else:
        content = target_import + "\n" + content
    changed = True

if "key.name.base64data()" not in content:
    pattern = re.compile(
        r"(?P<indent>\s*)final byte = Uint8List\.sublistView\(await key\.bundle\.load\(key\.name\)\);\n"
        r"(?P=indent)final newByte = _d\(byte\);\n"
        r"(?P=indent)buffer = await ui\.ImmutableBuffer\.fromUint8List\(newByte\);"
    )

    def repl(match: re.Match) -> str:
        indent = match.group("indent")
        return (
            f"{indent}final mappedBytes = key.name.base64data();\n"
            f"{indent}final byte = mappedBytes.isNotEmpty\n"
            f"{indent}    ? mappedBytes\n"
            f"{indent}    : Uint8List.sublistView(await key.bundle.load(key.name));\n"
            f"{indent}final newByte = _d(byte);\n"
            f"{indent}buffer = await ui.ImmutableBuffer.fromUint8List(newByte);"
        )

    content, count = pattern.subn(repl, content, count=1)
    if count > 0:
        changed = True

if changed:
    file_path.write_text(content, encoding="utf-8")
    print(f"[INFO] MyAssetImage Base64 修复完成: {file_path.name}")
PY
}

# 批量替换 secondary 中 Image.asset(...) 为 BaseHHImage(...)（参数原样保留）
replace_image_asset_entries() {
    if [[ "$REPLACE_IMAGE_ENTRY" != "true" ]]; then
        return
    fi

    log_step "批量替换 Image.asset 为 BaseHHImage..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将批量替换 secondary 中的 Image.asset(...) 为 BaseHHImage(...)"
        return
    fi

    python3 - "$TARGET_SIDE_B_DIR" "$PROJECT_NAME" "$GENERATE_BASE64_MAP" << 'PY'
import re
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
project_name = sys.argv[2] if len(sys.argv) > 2 else ""
generate_base64_map = sys.argv[3] if len(sys.argv) > 3 else "false"
if not root.exists():
    print("[WARNING] secondary 目录不存在，跳过替换")
    raise SystemExit(0)

prefix = "Image.asset("
project_root = root.parents[2]
base_hh_file = project_root / "lib" / "utils" / "base_hh_image.dart"


def _is_ident_continue_char(c: str) -> bool:
    """前一个字符若为标识符延续，则说明 Image 是更长名字的一部分（如 CCCCImage.asset）。"""
    if not c:
        return False
    return c.isalnum() or c in "_$"


def find_next_standalone_image_asset(text: str, start: int) -> int:
    """查找「代码区」里独立的 Image.asset(，跳过 CCCCImage.asset、ExtendedImage.asset 等误匹配。

    关键：搜索时必须同步跳过注释 / 字符串里的 Image.asset(。否则一旦命中被注释掉的
    `// Image.asset(`，随后的 find_matching_paren 会因注释里的 ) 被忽略而一路吞进下方真实代码，
    把紧跟其后的真实 Image.asset(...) 整段当成「参数」原样保留，导致它被漏改写
    （dqiu material_data_item.dart 两个 Image.asset 块之间夹了一行 `// Image.asset(` 即触发此 bug）。
    """
    in_single = in_double = in_line_comment = in_block_comment = False
    escape = False
    i = start
    n = len(text)

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if in_line_comment:
            if c == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_block_comment:
            if c == "*" and nxt == "/":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_single:
            if not escape and c == "'":
                in_single = False
            escape = (c == "\\") and not escape
            i += 1
            continue
        if in_double:
            if not escape and c == '"':
                in_double = False
            escape = (c == "\\") and not escape
            i += 1
            continue

        if c == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue
        if c == "'":
            in_single = True
            escape = False
            i += 1
            continue
        if c == '"':
            in_double = True
            escape = False
            i += 1
            continue

        if text.startswith(prefix, i) and (i == 0 or not _is_ident_continue_char(text[i - 1])):
            return i
        i += 1

    return -1


def find_matching_paren(text: str, start_idx: int) -> int:
    depth = 0
    in_single = False
    in_double = False
    in_line_comment = False
    in_block_comment = False
    escape = False

    i = start_idx
    while i < len(text):
        c = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if in_line_comment:
            if c == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_block_comment:
            if c == "*" and nxt == "/":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue

        if in_single:
            if not escape and c == "'":
                in_single = False
            escape = (c == "\\") and not escape
            i += 1
            continue
        if in_double:
            if not escape and c == '"':
                in_double = False
            escape = (c == "\\") and not escape
            i += 1
            continue

        if c == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue
        if c == "'":
            in_single = True
            escape = False
            i += 1
            continue
        if c == '"':
            in_double = True
            escape = False
            i += 1
            continue

        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1

    return -1


def import_target_for(file_path: Path, content: str) -> Path:
    match = re.search(r"^\s*part\s+of\s+['\"]([^'\"]+)['\"]\s*;", content, flags=re.M)
    if not match:
        return file_path
    host_path = (file_path.parent / match.group(1)).resolve()
    return host_path if host_path.exists() else file_path


def ensure_base_hh_import(file_path: Path) -> None:
    source_content = file_path.read_text(encoding="utf-8")
    target_path = import_target_for(file_path, source_content)
    content = target_path.read_text(encoding="utf-8")
    if "base_hh_image.dart" in content:
        return
    rel_import = Path(os.path.relpath(base_hh_file, target_path.parent)).as_posix()
    target_import = f"import '{rel_import}';"
    import_matches = list(re.finditer(r"^import\s+['\"].*?['\"];\s*$", content, flags=re.M))
    if import_matches:
        last = import_matches[-1]
        insert_at = last.end()
        content = content[:insert_at] + "\n" + target_import + content[insert_at:]
    else:
        content = target_import + "\n" + content
    target_path.write_text(content, encoding="utf-8")


replaced_files = 0
replaced_count = 0

for file in root.rglob("*.dart"):
    content = file.read_text(encoding="utf-8")
    out = []
    i = 0
    local_count = 0

    while True:
        idx = find_next_standalone_image_asset(content, i)
        if idx < 0:
            out.append(content[i:])
            break

        out.append(content[i:idx])
        open_paren = idx + len("Image.asset")
        close_paren = find_matching_paren(content, open_paren)
        if close_paren < 0:
            out.append(content[idx:idx + len(prefix)])
            i = idx + len(prefix)
            continue

        # 统一替换为 BaseHHImage.image(...)，保持返回类型为 Image（兼容大多数 Image.asset 调用场景）
        out.append("BaseHHImage.image")
        out.append(content[open_paren : close_paren + 1])
        local_count += 1
        i = close_paren + 1

    if local_count == 0:
        continue

    content = "".join(out)
    replaced_files += 1
    replaced_count += local_count

    file.write_text(content, encoding="utf-8")
    ensure_base_hh_import(file)

print(f"[INFO] Image.asset -> BaseHHImage 替换完成: 文件 {replaced_files} 个, 替换 {replaced_count} 处")
PY
}

# 批量替换 secondary 中 AssetImage/ExactAssetImage(...) 为 secondaryAssetProvider(...)
# 用于 Base64 图片映射后仍保留 DecorationImage/backgroundImage 等 ImageProvider 场景。
replace_asset_image_providers() {
    if [[ "$GENERATE_BASE64_MAP" != "true" ]]; then
        return
    fi

    log_step "批量替换 AssetImage 为 secondaryAssetProvider..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将批量替换 secondary 中的 AssetImage/ExactAssetImage(...) 为 secondaryAssetProvider(...)"
        return
    fi

    python3 - "$TARGET_SIDE_B_DIR" << 'PY'
import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
if not root.exists():
    print("[WARNING] secondary 目录不存在，跳过替换")
    raise SystemExit(0)

project_root = root.parents[2]
helper_file = project_root / "lib" / "utils" / "base_hh_image.dart"
pattern = re.compile(r"(?<![\w$])(ExactAssetImage|AssetImage)\(")


def import_target_for(file_path: Path, content: str) -> Path:
    match = re.search(r"^\s*part\s+of\s+['\"]([^'\"]+)['\"]\s*;", content, flags=re.M)
    if not match:
        return file_path
    host_path = (file_path.parent / match.group(1)).resolve()
    return host_path if host_path.exists() else file_path


def ensure_helper_import(file_path: Path) -> None:
    source_content = file_path.read_text(encoding="utf-8")
    target_path = import_target_for(file_path, source_content)
    content = target_path.read_text(encoding="utf-8")
    if "base_hh_image.dart" in content:
        return
    rel_import = Path(os.path.relpath(helper_file, target_path.parent)).as_posix()
    target_import = f"import '{rel_import}';"
    import_matches = list(re.finditer(r"^import\s+['\"].*?['\"];\s*$", content, flags=re.M))
    if import_matches:
        insert_at = import_matches[-1].end()
        content = content[:insert_at] + "\n" + target_import + content[insert_at:]
    else:
        content = target_import + "\n" + content
    target_path.write_text(content, encoding="utf-8")


def find_matching_paren(text: str, open_index: int) -> int:
    depth = 0
    i = open_index
    in_string = None
    while i < len(text):
        ch = text[i]
        if in_string is not None:
            if ch == "\\":
                i += 2
                continue
            if ch == in_string:
                in_string = None
            i += 1
            continue

        if ch in ("'", '"'):
            in_string = ch
            i += 1
            continue

        if ch == "/" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == "/":
                i = text.find("\n", i + 2)
                if i < 0:
                    return -1
                continue
            if nxt == "*":
                end = text.find("*/", i + 2)
                if end < 0:
                    return -1
                i = end + 2
                continue

        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1

    return -1


def relax_const_constructors(content: str) -> tuple[str, int]:
    total = 0
    for ctor_name in ("BoxDecoration", "DecorationImage"):
        pattern = re.compile(rf"(?<![\w$])const\s+{ctor_name}\(")
        parts = []
        index = 0
        while True:
            match = pattern.search(content, index)
            if not match:
                parts.append(content[index:])
                break

            start = match.start()
            open_paren = match.end() - 1
            close_paren = find_matching_paren(content, open_paren)
            if close_paren < 0:
                parts.append(content[index:])
                break

            body = content[open_paren + 1 : close_paren]
            if "secondaryAssetProvider(" in body:
                parts.append(content[index:start])
                parts.append(f"{ctor_name}(")
                parts.append(content[open_paren + 1 : close_paren + 1])
                total += 1
            else:
                parts.append(content[index : close_paren + 1])
            index = close_paren + 1

        content = "".join(parts)
    return content, total


def strip_const_secondary_asset_provider(content: str) -> tuple[str, int]:
    """secondaryAssetProvider 是函数，不能 const；AssetImage 替换后常残留 const。"""
    pat = re.compile(r"(?<![\w$])const\s+secondaryAssetProvider\s*\(")
    new_content, n = pat.subn("secondaryAssetProvider(", content)
    return new_content, n


replaced_files = 0
replaced_count = 0
relaxed_const_count = 0
stripped_const_sap = 0

for file_path in root.rglob("*.dart"):
    content = file_path.read_text(encoding="utf-8")
    new_content, count = pattern.subn("secondaryAssetProvider(", content)
    new_content, relaxed_count = relax_const_constructors(new_content)
    new_content, sc = strip_const_secondary_asset_provider(new_content)
    stripped_const_sap += sc
    if count == 0 and relaxed_count == 0 and sc == 0:
        continue
    file_path.write_text(new_content, encoding="utf-8")
    if count > 0:
        ensure_helper_import(file_path)
    replaced_files += 1
    replaced_count += count
    relaxed_const_count += relaxed_count

_sap_extra = f", 去除 const secondaryAssetProvider {stripped_const_sap} 处" if stripped_const_sap else ""
print(
    f"[INFO] AssetImage -> secondaryAssetProvider 替换完成: 文件 {replaced_files} 个, "
    f"替换 {replaced_count} 处, 去除 const {relaxed_const_count} 处{_sap_extra}"
)

# --- Pass 2 (合并自 zeus 上游): rewrite AssetImage subclasses to delegate to secondaryAssetProvider ---
# E.g. DecryptedAssetImageProvider extends AssetImage → becomes a function alias.
# 修复 Base64 模式下自定义 AssetImage 子类编译失败问题。
subclass_def_re = re.compile(
    r"class\s+(\w+)\s+extends\s+(?:AssetImage|ExactAssetImage)\s*\{",
)
subclass_names: list[str] = []
subclass_locations: dict[str, Path] = {}

for file_path in root.rglob("*.dart"):
    content = file_path.read_text(encoding="utf-8")
    for m in subclass_def_re.finditer(content):
        name = m.group(1)
        subclass_names.append(name)
        subclass_locations[name] = file_path

if subclass_names:
    for name, file_path in subclass_locations.items():
        content = file_path.read_text(encoding="utf-8")
        cls_re = re.compile(
            rf"class\s+{re.escape(name)}\s+extends\s+\w+\s*\{{",
        )
        m = cls_re.search(content)
        if not m:
            continue
        open_brace = m.end() - 1
        depth = 0
        i = open_brace
        while i < len(content):
            if content[i] == "{":
                depth += 1
            elif content[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if depth != 0:
            continue
        close_brace = i
        replacement = (
            f"ImageProvider<Object> {name}("
            f"String assetName, {{AssetBundle? bundle, String? package}}) =>\n"
            f"    secondaryAssetProvider(assetName, bundle: bundle, package: package);"
        )
        content = content[:m.start()] + replacement + content[close_brace + 1:]
        file_path.write_text(content, encoding="utf-8")
        ensure_helper_import(file_path)
        print(f"[INFO] 子类 {name} -> secondaryAssetProvider 函数代理 ({file_path.name})")

    for name in subclass_names:
        const_sub_re = re.compile(rf"\bconst\s+{re.escape(name)}\(")
        for file_path in root.rglob("*.dart"):
            content = file_path.read_text(encoding="utf-8")
            new_content, n = const_sub_re.subn(f"{name}(", content)
            if n > 0:
                file_path.write_text(new_content, encoding="utf-8")
                print(f"[INFO] 去除 const {name} {n} 处 ({file_path.name})")

    print(f"[INFO] AssetImage 子类处理完成: {', '.join(subclass_names)}")
PY
}

# 删除 assets/secondary 下图片文件（保留 JSON / 字体 / lottie 等非图片资源），减小打进 IPA 的体积
delete_secondary_image_files() {
    if [[ "$DELETE_SECONDARY_IMAGES" != "true" ]]; then
        return
    fi

    log_step "删除 assets/secondary 下的图片文件（仅栅格图，其它资源保留；SVG 不删）..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将删除 $TARGET_ASSETS_DIR 内图片文件"
        return
    fi

    if [[ ! -d "$TARGET_ASSETS_DIR" ]]; then
        log_warning "资源目录不存在: $TARGET_ASSETS_DIR，跳过删除图片"
        return
    fi

    local deleted=0
    while IFS= read -r -d '' f; do
        rm -f "$f"
        deleted=$((deleted + 1))
    done < <(find "$TARGET_ASSETS_DIR" -type f \( \
        -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \
        -o -iname "*.gif" -o -iname "*.webp" -o -iname "*.bmp" \
        -o -iname "*.ico" -o -iname "*.heic" \
        -o -iname "*.tif" -o -iname "*.tiff" \
        \) ! -path "*/lottie/*" -print0 2>/dev/null)

    log_success "已删除 secondary 栅格图片文件: $deleted 个（SVG/JSON/字体等未删；lottie/ 下图片保留）"
}

# 为 pubspec 里登记的资源目录补 .gitkeep。
# Base64 化后 delete_secondary_image_files 会清空图片目录，而 git 不跟踪空目录——
# 全新 clone / CI 上这些目录不存在，pubspec 的目录条目会触发
# “Error: unable to find directory entry in pubspec.yaml: assets/secondary/xxx/”。
# 给空目录写入 .gitkeep 即可保证其在 clone 后仍存在（占位文件被一并打包，无副作用）。
ensure_asset_dir_placeholders() {
    local pubspec="$PROJECT_ROOT/pubspec.yaml"
    [[ -f "$pubspec" ]] || return 0

    log_step "为 pubspec 资源目录补 .gitkeep（避免全新 clone/CI 报 unable to find directory entry）..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将为 pubspec 中以 / 结尾的资源目录里「无普通文件」的目录写入 .gitkeep"
        return
    fi

    local kept=0
    local dir abs
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        # 跳过绝对路径 / 含 .. 的条目，避免越界创建
        case "$dir" in
            /*|*..*) continue ;;
        esac
        abs="$PROJECT_ROOT/$dir"
        mkdir -p "$abs" 2>/dev/null || true
        # 仅当本目录没有任何「非隐藏的普通文件」时补占位：
        # .DS_Store 等隐藏文件常被 .gitignore 忽略，不能保证 clone 后目录存在，故视作空。
        if [[ -z "$(find "$abs" -mindepth 1 -maxdepth 1 -type f ! -name '.*' 2>/dev/null)" ]]; then
            : > "$abs/.gitkeep" 2>/dev/null && kept=$((kept + 1))
        fi
    done < <(grep -oE '^[[:space:]]*-[[:space:]]+[^[:space:]#]+/[[:space:]]*$' "$pubspec" \
             | sed -E 's/^[[:space:]]*-[[:space:]]+//; s/[[:space:]]+$//')

    log_success "已为 $kept 个空资源目录写入 .gitkeep（全新 clone/CI 不再因空目录报错）"
}

# 修改图片元数据，生成不同的文件 hash（快速版本）
# 参数: $1 = 图片文件路径, $2 = 唯一标记
# 方法：在文件末尾添加唯一的隐藏标记，不影响图片显示
# 注意：使用快速的字节追加方式，避免调用外部工具
modify_image_metadata_fast() {
    local file="$1"
    local marker="$2"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    
    case "$ext" in
        png)
            # PNG: 在 IEND 后追加数据（解析器会忽略）
            printf "\x00\x00\x00\x00tEXtComment\x00%s" "$marker" >> "$file" 2>/dev/null
            ;;
        jpg|jpeg)
            # JPEG: 在 EOI (0xFFD9) 后追加 COM 标记
            printf "\xFF\xFE\x00\x22%s" "$marker" >> "$file" 2>/dev/null
            ;;
        webp)
            # WebP: 在末尾追加自定义数据
            printf "EXIF%s" "$marker" >> "$file" 2>/dev/null
            ;;
        gif)
            # GIF: 在 trailer 后追加数据
            printf "\x21\xFE%s\x00" "$marker" >> "$file" 2>/dev/null
            ;;
    esac
}

batch_modify_metadata_exiftool() {
    local file_list="$1"
    local seed="$2"
    
    if ! command -v exiftool &> /dev/null; then
        return 1
    fi
    
    local count=$(wc -l < "$file_list" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi
    
    log_info "使用 exiftool 批量修改元数据 ($count 个文件)..."
    
    # exiftool 支持从文件读取参数，一次处理所有文件
    # 使用 -@ 从文件读取文件列表
    exiftool -overwrite_original -Comment="$seed" -@ "$file_list" 2>/dev/null
    
    return $?
}

# 语义词库文件路径
SEMANTIC_WORDS_FILE="$SCRIPT_DIR/semantic_words.conf"

# 词库缓存（避免重复读取文件）
declare -a CACHED_PREFIXES
declare -a CACHED_MIDDLES
declare -a CACHED_SUFFIXES
WORDS_LOADED=false

# 从配置文件加载词库
load_semantic_words() {
    if [[ "$WORDS_LOADED" == "true" ]]; then
        return
    fi
    
    # 默认词库（作为后备）
    CACHED_PREFIXES=("icon" "img" "bg" "asset" "res" "pic" "image" "btn" "logo" "banner" "thumb" "cover")
    CACHED_MIDDLES=("home" "main" "app" "user" "item" "view" "page" "header" "nav" "menu" "card" "list" "detail" "setting" "common" "default")
    CACHED_SUFFIXES=("normal" "selected" "active" "small" "large" "light" "dark" "left" "right" "center")
    
    if [[ ! -f "$SEMANTIC_WORDS_FILE" ]]; then
        log_warning "词库文件不存在: $SEMANTIC_WORDS_FILE，使用默认词库"
        WORDS_LOADED=true
        return
    fi
    
    local current_section=""
    local prefixes_tmp=()
    local middles_tmp=()
    local suffixes_tmp=()
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过空行和注释
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        # 去除首尾空格
        line=$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        
        # 检测分区
        if [[ "$line" =~ ^\[([A-Z]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi
        
        # 根据分区添加词汇
        case "$current_section" in
            PREFIXES)
                prefixes_tmp+=("$line")
                ;;
            MIDDLES)
                middles_tmp+=("$line")
                ;;
            SUFFIXES)
                suffixes_tmp+=("$line")
                ;;
        esac
    done < "$SEMANTIC_WORDS_FILE"
    
    # 如果成功读取，使用文件中的词库
    [[ ${#prefixes_tmp[@]} -gt 0 ]] && CACHED_PREFIXES=("${prefixes_tmp[@]}")
    [[ ${#middles_tmp[@]} -gt 0 ]] && CACHED_MIDDLES=("${middles_tmp[@]}")
    [[ ${#suffixes_tmp[@]} -gt 0 ]] && CACHED_SUFFIXES=("${suffixes_tmp[@]}")
    
    WORDS_LOADED=true
}

# 生成语义化的文件名
# 参数: $1 = 种子, $2 = 原文件名, $3 = 文件索引
# 返回: 语义化的文件名（不含扩展名）
generate_semantic_filename() {
    local seed="$1"
    local original="$2"
    local index="$3"
    
    # 确保词库已加载
    load_semantic_words
    
    # 基于种子和原文件名生成确定性的索引
    local hash_input="${seed}_${original}"
    local hash_value
    if [[ "$(uname)" == "Darwin" ]]; then
        hash_value=$(echo -n "$hash_input" | md5)
    else
        hash_value=$(echo -n "$hash_input" | md5sum | cut -d' ' -f1)
    fi
    
    # 从哈希值中提取数字作为索引（确保确定性）
    local prefix_idx=$(( 16#${hash_value:0:2} % ${#CACHED_PREFIXES[@]} ))
    local middle_idx=$(( 16#${hash_value:2:2} % ${#CACHED_MIDDLES[@]} ))
    local suffix_idx=$(( 16#${hash_value:4:2} % ${#CACHED_SUFFIXES[@]} ))
    local num_suffix=$(( 16#${hash_value:6:2} % 100 ))
    
    # 组合生成文件名
    # 格式: prefix_middle_suffix_NN 或 prefix_middle_NN (随机选择)
    local use_suffix=$(( 16#${hash_value:8:1} % 2 ))
    
    if [[ "$use_suffix" -eq 1 ]]; then
        printf "%s_%s_%s_%02d" "${CACHED_PREFIXES[$prefix_idx]}" "${CACHED_MIDDLES[$middle_idx]}" "${CACHED_SUFFIXES[$suffix_idx]}" "$num_suffix"
    else
        printf "%s_%s_%02d" "${CACHED_PREFIXES[$prefix_idx]}" "${CACHED_MIDDLES[$middle_idx]}" "$num_suffix"
    fi
}

obfuscate_asset_filenames() {
    log_step "混淆资源文件..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将混淆资源文件名和元数据"
        return
    fi

    local assets_dir="$TARGET_ASSETS_DIR"
    local image_path_file="$TARGET_SIDE_B_DIR/generate/app_image_path.dart"

    # 检查资源目录是否存在
    if [[ ! -d "$assets_dir" ]]; then
        log_warning "资源目录不存在: $assets_dir，跳过混淆"
        return
    fi

    # 检查 app_image_path.dart 是否存在
    if [[ ! -f "$image_path_file" ]]; then
        log_warning "图片路径配置文件不存在: $image_path_file"
        log_warning "将只重命名文件，不更新代码引用"
    fi

    # 生成种子：优先级 iOS bundle id > 项目名
    # 这确保同一包每次构建结果一致，不同包之间不同
    local seed=""
    local pbxproj="$PROJECT_ROOT/ios/Runner.xcodeproj/project.pbxproj"
    if [[ -f "$pbxproj" ]]; then
        seed=$(grep "PRODUCT_BUNDLE_IDENTIFIER" "$pbxproj" | grep -v "RunnerTests" | head -1 | sed 's/.*= *//; s/;.*//' | tr -d ' ')
        if [[ -n "$seed" ]]; then
            log_info "使用 iOS bundle id 作为混淆种子"
        fi
    fi
    
    # 后备：使用项目名
    if [[ -z "$seed" ]]; then
        seed="${PROJECT_NAME}_default"
        log_warning "未找到 bundle id，使用项目名作为混淆种子"
    fi
    
    log_info "混淆种子: $seed"
    
    # 临时文件用于批量处理
    local used_names_file=$(mktemp)
    local rename_map_file=$(mktemp)
    local new_files_list=$(mktemp)
    local sed_script_file=$(mktemp)
    local bare_ref_names_file=$(mktemp)
    trap "rm -f '$used_names_file' '$rename_map_file' '$new_files_list' '$sed_script_file' '$bare_ref_names_file'" EXIT

    local rename_count=0
    local failed=0
    local file_index=0
    
    # 计时函数
    local step_start step_end
    step_start=$(date +%s)

    log_info "第1步: 收集文件并生成重命名映射..."
    
    # 预加载词库（避免重复读取）
    load_semantic_words
    
    # 先收集所有文件路径到数组（一次性 find）
    # 排除 lottie 目录（因为 lottie JSON 内部会引用图片文件名，混淆会破坏动画）
    local find_start=$(date +%s)
    local -a all_files=()
    while IFS= read -r -d '' file; do
        all_files+=("$file")
    done < <(find "$assets_dir" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.webp" -o -name "*.gif" -o -name "*.PNG" -o -name "*.JPG" -o -name "*.JPEG" \) ! -path "*/lottie/*" -print0)
    local find_end=$(date +%s)
    log_info "  - find 耗时: $((find_end - find_start))s, 找到 ${#all_files[@]} 个文件"
    
    if [[ ${#all_files[@]} -eq 0 ]]; then
        log_info "无资源文件需要混淆"
        return
    fi
    
    # 预扫描代码，检测动态引用的文件名
    # 三种情况需要跳过重命名：
    # 1. 文件名直接出现在代码中作为字符串片段，如 'zaixiankefu'
    # 2. 字符串插值模式：'xxx/filename-$var.png' 对应 filename-1, filename-2 等
    # 3. 字符串拼接模式：'filename' + var + '.png' 对应 filename1, filename2 等
    local scan_start=$(date +%s)
    local skip_names_file=$(mktemp)
    
    if [[ -d "$TARGET_SIDE_B_DIR" ]]; then
        # 收集所有文件名（不带扩展名）
        local all_basenames_file=$(mktemp)
        for file in "${all_files[@]}"; do
            basename "${file%.*}"
        done | sort -u > "$all_basenames_file"
        
        # 方法1: 检测完整文件名作为独立字符串
        local detected_strings=$(mktemp)
        find "$TARGET_SIDE_B_DIR" -name "*.dart" -type f -print0 2>/dev/null | \
            xargs -0 grep -ohE "'[a-zA-Z0-9_-]+'" 2>/dev/null | \
            tr -d "'" | sort -u > "$detected_strings" || true
        find "$TARGET_SIDE_B_DIR" -name "*.dart" -type f -print0 2>/dev/null | \
            xargs -0 grep -ohE '"[a-zA-Z0-9_-]+"' 2>/dev/null | \
            tr -d '"' | sort -u >> "$detected_strings" || true
        
        # 找出交集：文件名出现在代码中作为独立字符串（静态裸名引用）
        # 这些文件仍然可以安全重命名，只需同时更新裸名引用（如 LocalPNG(name: 'hl_xxx')）
        comm -12 <(sort -u "$all_basenames_file") <(sort -u "$detected_strings") >> "$bare_ref_names_file"
        
        # 方法2a: 检测 $var 简单插值模式（变量在文件名末尾）
        # 从路径中提取 'xxx-$var.png' 或 'xxx_$var.png' 中的前缀
        local interpolation_prefixes=$(mktemp)
        find "$TARGET_SIDE_B_DIR" -name "*.dart" -type f -print0 2>/dev/null | \
            xargs -0 grep -ohE '/[a-zA-Z0-9_-]+[-_]\$[a-zA-Z][a-zA-Z0-9_]*\.(png|jpg|jpeg|gif|webp|svg|svga|json)' 2>/dev/null | \
            sed 's|.*/\([a-zA-Z0-9_-]*\)[-_]\$.*|\1|' | sort -u >> "$interpolation_prefixes" || true

        # 方法2a-2: 无扩展名的插值/拼接前缀（如 "icon_live_caisedanmu${idx+1}"），
        # 常见于 svg/svga 通过统一目录 + 名称拼接的场景。抽取 $ 之前的静态前缀。
        find "$TARGET_SIDE_B_DIR" -name "*.dart" -type f -print0 2>/dev/null | \
            xargs -0 grep -ohE '"[a-zA-Z0-9_/-]*[a-zA-Z_]\$[{a-zA-Z]' 2>/dev/null | \
            sed 's|.*"\([a-zA-Z0-9_-]*[a-zA-Z_]\)\$.*|\1|' | rg -x '[a-zA-Z0-9_-]{3,}' 2>/dev/null | sort -u >> "$interpolation_prefixes" || true
        
        # 方法2b: 检测 ${var} 花括号插值模式（变量可在文件名任意位置）
        # 例如: 'tab_${icon}_icon.png' → 将 ${var} 替换为 .* 后匹配所有实际文件
        local curly_patterns_file=$(mktemp)
        find "$TARGET_SIDE_B_DIR" -name "*.dart" -type f -print0 2>/dev/null | \
            xargs -0 grep -ohE '[a-zA-Z0-9_-]+\$[{][^}]+[}][a-zA-Z0-9_.-]*\.(png|jpg|jpeg|gif|webp)' 2>/dev/null | \
            sort -u > "$curly_patterns_file" || true
        
        if [[ -s "$curly_patterns_file" ]]; then
            while IFS= read -r raw_pattern; do
                local name_part="${raw_pattern%.*}"
                local regex_part=$(echo "$name_part" | sed 's/\$[{][^}]*[}]/.*/g')
                grep -E "^${regex_part}$" "$all_basenames_file" >> "$skip_names_file" 2>/dev/null || true
            done < "$curly_patterns_file"
        fi
        rm -f "$curly_patterns_file"

        # 方法3: 检测字符串拼接模式
        # 'filename' + var 中的 filename
        find "$TARGET_SIDE_B_DIR" -name "*.dart" -type f -print0 2>/dev/null | \
            xargs -0 grep -ohE "'[a-zA-Z0-9_-]+'\s*\+" 2>/dev/null | \
            sed "s/'\([^']*\)'.*/\1/" | sort -u >> "$interpolation_prefixes" || true
        
        # 对每个前缀，找出所有匹配的文件名（前缀后跟数字或分隔符+数字）
        if [[ -s "$interpolation_prefixes" ]]; then
            while IFS= read -r prefix; do
                if [[ -n "$prefix" ]] && [[ ${#prefix} -ge 3 ]]; then
                    # 匹配: prefix1, prefix2, prefix-1, prefix_1 等
                    grep -E "^${prefix}[-_]?[0-9]" "$all_basenames_file" >> "$skip_names_file" 2>/dev/null || true
                fi
            done < "$interpolation_prefixes"
        fi
        
        rm -f "$all_basenames_file" "$detected_strings" "$interpolation_prefixes"
    fi
    
    # 去重
    sort -u "$skip_names_file" -o "$skip_names_file"
    
    local skip_count=$(wc -l < "$skip_names_file" | tr -d ' ')
    local scan_end=$(date +%s)
    local bare_ref_count_early=$(wc -l < "$bare_ref_names_file" | tr -d ' ')
    if [[ "$skip_count" -gt 0 ]]; then
        log_info "  - 检测到 $skip_count 个动态引用(插值/拼接)文件名，将跳过重命名"
    fi
    if [[ "$bare_ref_count_early" -gt 0 ]]; then
        log_info "  - 检测到 $bare_ref_count_early 个静态裸名引用文件名，将重命名并更新裸名"
    fi
    log_info "  - 代码扫描耗时: $((scan_end - scan_start))s"
    
    # 预计算所有文件的 hash（批量计算更快）
    local hash_start=$(date +%s)
    local -a file_hashes=()
    for file in "${all_files[@]}"; do
        local old_name=$(basename "$file")
        local hash_input="${seed}_${old_name}"
        if [[ "$(uname)" == "Darwin" ]]; then
            file_hashes+=("$(echo -n "$hash_input" | md5)")
        else
            file_hashes+=("$(echo -n "$hash_input" | md5sum | cut -d' ' -f1)")
        fi
    done
    local hash_end=$(date +%s)
    log_info "  - hash计算耗时: $((hash_end - hash_start))s"
    
    # 生成重命名映射
    local map_start=$(date +%s)
    local skipped_dynamic=0
    
    for i in "${!all_files[@]}"; do
        local file="${all_files[$i]}"
        local hash_value="${file_hashes[$i]}"
        local dir=$(dirname "$file")
        local old_name=$(basename "$file")
        local name_without_ext="${old_name%.*}"
        local ext="${old_name##*.}"
        # 转小写（兼容 bash 3.x）
        local ext_lower
        case "$ext" in
            PNG|Png) ext_lower="png" ;;
            JPG|Jpg) ext_lower="jpg" ;;
            JPEG|Jpeg) ext_lower="jpeg" ;;
            WEBP|Webp) ext_lower="webp" ;;
            GIF|Gif) ext_lower="gif" ;;
            *) ext_lower="$ext" ;;
        esac
        
        # 检测是否是动态引用的文件
        # skip_rename: 真正的动态引用（插值/拼接），无法安全重命名
        # needs_bare_sed: 静态裸名引用（如 LocalPNG(name: 'hl_xxx')），可以重命名并替换裸名
        local skip_rename=false
        local needs_bare_sed=false
        if [[ -s "$skip_names_file" ]] && grep -qFx "$name_without_ext" "$skip_names_file" 2>/dev/null; then
            skip_rename=true
            skipped_dynamic=$((skipped_dynamic + 1))
        elif [[ -s "$bare_ref_names_file" ]] && grep -qFx "$name_without_ext" "$bare_ref_names_file" 2>/dev/null; then
            needs_bare_sed=true
        fi
        
        local new_name
        local new_rel
        
        if [[ "$skip_rename" == "true" ]]; then
            # 真正的动态引用（插值/拼接），保持原文件名，只做元数据修改
            new_name="$old_name"
            new_rel="${dir#$PROJECT_ROOT/}/$old_name"
        else
            # 使用预计算的 hash 生成文件名
            local prefix_idx=$(( 16#${hash_value:0:2} % ${#CACHED_PREFIXES[@]} ))
            local middle_idx=$(( 16#${hash_value:2:2} % ${#CACHED_MIDDLES[@]} ))
            local suffix_idx=$(( 16#${hash_value:4:2} % ${#CACHED_SUFFIXES[@]} ))
            local num_suffix=$(( 16#${hash_value:6:2} % 100 ))
            local use_suffix=$(( 16#${hash_value:8:1} % 2 ))
            
            local base_name
            if [[ "$use_suffix" -eq 1 ]]; then
                base_name=$(printf "%s_%s_%s_%02d" "${CACHED_PREFIXES[$prefix_idx]}" "${CACHED_MIDDLES[$middle_idx]}" "${CACHED_SUFFIXES[$suffix_idx]}" "$num_suffix")
            else
                base_name=$(printf "%s_%s_%02d" "${CACHED_PREFIXES[$prefix_idx]}" "${CACHED_MIDDLES[$middle_idx]}" "$num_suffix")
            fi
            new_name="${base_name}.${ext_lower}"
            
            # 检查重名（使用简单的文本匹配）
            local collision_count=0
            while grep -qFx "$new_name" "$used_names_file" 2>/dev/null; do
                collision_count=$((collision_count + 1))
                new_name="${base_name}_${collision_count}.${ext_lower}"
            done
            
            new_rel="${dir#$PROJECT_ROOT/}/$new_name"
        fi
        
        echo "$new_name" >> "$used_names_file"
        
        # 记录映射
        local old_rel="${file#$PROJECT_ROOT/}"
        echo "${old_rel}|${new_rel}|${dir}/${new_name}|${hash_value}" >> "$rename_map_file"
        
        # 对裸名引用的文件（如 LocalPNG(name: 'hl_xxx')），
        # 额外生成裸名替换规则，确保代码中的裸名引用也被更新
        if [[ "$needs_bare_sed" == "true" ]] && [[ "$old_name" != "$new_name" ]]; then
            local new_bare="${new_name%.*}"
            echo "s|'${name_without_ext}'|'${new_bare}'|g" >> "$sed_script_file"
            echo "s|\"${name_without_ext}\"|\"${new_bare}\"|g" >> "$sed_script_file"
        fi
    done
    
    if [[ "$skipped_dynamic" -gt 0 ]]; then
        log_info "  - 跳过动态引用文件(插值/拼接): $skipped_dynamic 个"
    fi
    
    local bare_ref_count=$(wc -l < "$bare_ref_names_file" | tr -d ' ')
    if [[ "$bare_ref_count" -gt 0 ]]; then
        log_info "  - 检测到裸名引用文件(LocalPNG等): $bare_ref_count 个，将重命名并更新裸名引用"
    fi
    
    rm -f "$skip_names_file" "$bare_ref_names_file"
    local map_end=$(date +%s)
    log_info "  - 映射生成耗时: $((map_end - map_start))s"
    
    step_end=$(date +%s)
    log_info "第1步完成，总耗时: $((step_end - step_start))s"

    step_start=$(date +%s)
    log_info "第2步: 批量重命名文件..."
    
    # 执行重命名
    while IFS='|' read -r old_rel new_rel new_file hash_value; do
        local old_file="$PROJECT_ROOT/$old_rel"
        if [[ -f "$old_file" ]] && [[ "$old_file" != "$new_file" ]]; then
            if mv "$old_file" "$new_file" 2>/dev/null; then
                echo "s|$old_rel|$new_rel|g" >> "$sed_script_file"
                echo "${new_file}|${hash_value}" >> "$new_files_list"
                rename_count=$((rename_count + 1))
            else
                failed=$((failed + 1))
            fi
        elif [[ -f "$old_file" ]]; then
            echo "${old_file}|${hash_value}" >> "$new_files_list"
        fi
    done < "$rename_map_file"
    
    step_end=$(date +%s)
    log_info "第2步完成，重命名 $rename_count 个，耗时: $((step_end - step_start))s"

    step_start=$(date +%s)
    log_info "第3步: 批量更新代码引用..."
    
    if [[ -s "$sed_script_file" ]]; then
        local updated_files=0
        
        if [[ -f "$image_path_file" ]]; then
            # 优先更新集中管理的图片路径文件
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' -f "$sed_script_file" "$image_path_file"
            else
                sed -i -f "$sed_script_file" "$image_path_file"
            fi
            updated_files=1
            log_info "  已更新: app_image_path.dart"
        fi
        
        # 扫描所有 dart 文件，查找并更新图片路径引用
        log_info "  扫描所有 dart 文件中的图片引用..."
        
        # 构建 grep 模式（所有旧文件名 + 裸名，确保覆盖 LocalPNG(name:'xxx') 模式）
        local grep_pattern=$(cut -d'|' -f1 "$rename_map_file" | xargs -I{} basename {} | while read -r fn; do echo "$fn"; echo "${fn%.*}"; done | sort -u | tr '\n' '|' | sed 's/|$//')
        
        if [[ -n "$grep_pattern" ]]; then
            # 查找包含旧图片路径的 dart 文件
            local dart_files_to_update=$(mktemp)
            find "$TARGET_SIDE_B_DIR" -name "*.dart" -type f -print0 2>/dev/null | \
                xargs -0 grep -l -E "$grep_pattern" 2>/dev/null > "$dart_files_to_update" || true
            
            local dart_count=$(wc -l < "$dart_files_to_update" | tr -d ' ')
            if [[ "$dart_count" -gt 0 ]]; then
                log_info "  找到 $dart_count 个 dart 文件需要更新"
                
                while IFS= read -r dart_file; do
                    if [[ -f "$dart_file" ]] && [[ "$dart_file" != "$image_path_file" ]]; then
                        if [[ "$(uname)" == "Darwin" ]]; then
                            sed -i '' -f "$sed_script_file" "$dart_file"
                        else
                            sed -i -f "$sed_script_file" "$dart_file"
                        fi
                        updated_files=$((updated_files + 1))
                    fi
                done < "$dart_files_to_update"
            fi
            rm -f "$dart_files_to_update"
        fi
        
        log_info "  共更新 $updated_files 个文件"
    fi
    
    step_end=$(date +%s)
    log_info "第3步完成，耗时: $((step_end - step_start))s"

    step_start=$(date +%s)
    log_info "第4步: 批量修改图片元数据..."
    
    # 批量修改元数据（使用预计算的 hash，避免重复计算）
    # 仅对位图追加元数据；svg/svga/json 等文本/结构化文件追加字节会损坏内容，跳过。
    local metadata_count=0
    while IFS='|' read -r new_file hash_value; do
        if [[ -f "$new_file" ]]; then
            case "${new_file##*.}" in
                png|jpg|jpeg|webp|gif|PNG|JPG|JPEG|WEBP|GIF)
                    modify_image_metadata_fast "$new_file" "$hash_value"
                    metadata_count=$((metadata_count + 1))
                    ;;
                *) ;;
            esac
        fi
    done < "$new_files_list"
    
    step_end=$(date +%s)
    log_info "第4步完成，修改 $metadata_count 个，耗时: $((step_end - step_start))s"

    if [[ "$rename_count" -gt 0 ]] || [[ "$metadata_count" -gt 0 ]]; then
        log_success "资源文件混淆完成: 重命名 $rename_count 个, 修改元数据 $metadata_count 个"
        if [[ "$failed" -gt 0 ]]; then
            log_warning "失败 $failed 个"
        fi
    fi
}

# 同步 plugins/ 与 plugin/（dq/xty：path 依赖放在 B 面根目录 plugin/ 单数；旧项目可能用 plugins/）
sync_plugins() {
    if [[ ! -d "$SOURCE_PATH/plugins" ]]; then
        return
    fi

    log_step "同步 plugins..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将同步 plugins 目录"
        return
    fi

    # 清空并创建目标 plugins 目录
    if [[ -d "$TARGET_PLUGINS_DIR" ]]; then
        rm -rf "$TARGET_PLUGINS_DIR"
    fi
    mkdir -p "$TARGET_PLUGINS_DIR"

    # 使用 rsync 复制，排除 Flutter 构建临时文件和无效符号链接
    # --exclude 排除 ephemeral 目录、.plugin_symlinks、build 目录、测试目录等
    if command -v rsync &> /dev/null; then
        rsync -a --copy-links \
            --exclude='ephemeral/' \
            --exclude='.plugin_symlinks/' \
            --exclude='build/' \
            --exclude='.dart_tool/' \
            --exclude='*.iml' \
            --exclude='dev_packages/' \
            --exclude='example/' \
            --exclude='test/' \
            --exclude='integration_test/' \
            --exclude='pigeons/' \
            "$SOURCE_PATH/plugins/" "$TARGET_PLUGINS_DIR/"
        log_info "使用 rsync 同步 plugins（已排除临时文件、测试目录和代码生成源）"
    else
        # 回退到 cp，但跳过有问题的目录
        for plugin_dir in "$SOURCE_PATH/plugins"/*; do
            if [[ -d "$plugin_dir" ]]; then
                local plugin_name
                plugin_name=$(basename "$plugin_dir")
                # 使用 cp 但忽略错误
                cp -r "$plugin_dir" "$TARGET_PLUGINS_DIR/$plugin_name" 2>/dev/null || {
                    log_warning "复制 plugin $plugin_name 时有部分文件跳过"
                }
                log_info "已复制: plugin: $plugin_name"
            fi
        done
    fi

    # 清理可能复制过来的无效符号链接
    find "$TARGET_PLUGINS_DIR" -type l ! -exec test -e {} \; -delete 2>/dev/null || true

    log_success "plugins 同步完成"
}

# 同步 flutter_base（源项目含该包时）
sync_flutter_base() {
    if [[ ! -d "$SOURCE_PATH/flutter_base" ]]; then
        return
    fi

    log_step "同步 flutter_base..."

    local target_flutter_base="$PROJECT_ROOT/flutter_base"

    if [[ -d "$target_flutter_base" ]]; then
        do_remove "$target_flutter_base"
    fi

    do_copy "$SOURCE_PATH/flutter_base" "$target_flutter_base" "flutter_base"

    log_success "flutter_base 同步完成"
}

# 同步 iOS 权限配置（Info.plist）
# 从源项目的 Info.plist 中提取权限相关的 key 并合并到目标项目
sync_ios_permissions() {
    log_step "同步 iOS 权限配置..."

    local source_plist="$SOURCE_PATH/ios/Runner/Info.plist"

    if [[ ! -f "$source_plist" ]]; then
        log_warning "源项目无 iOS Info.plist，跳过"
        return
    fi

    if [[ ! -f "$TARGET_INFO_PLIST" ]]; then
        log_error "目标 Info.plist 不存在: $TARGET_INFO_PLIST"
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将同步 iOS 权限配置"
        return
    fi

    # 权限相关的 key 前缀列表
    # NS* 开头的通常是权限相关
    local permission_keys=(
        "NSAppleMusicUsageDescription"
        "NSBluetoothAlwaysUsageDescription"
        "NSBluetoothPeripheralUsageDescription"
        "NSCalendarsFullAccessUsageDescription"
        "NSCalendarsUsageDescription"
        "NSCameraUsageDescription"
        "NSContactsUsageDescription"
        "NSFaceIDUsageDescription"
        "NSHealthShareUsageDescription"
        "NSHealthUpdateUsageDescription"
        "NSHomeKitUsageDescription"
        "NSLocalNetworkUsageDescription"
        "NSLocationAlwaysAndWhenInUseUsageDescription"
        "NSLocationAlwaysUsageDescription"
        "NSLocationUsageDescription"
        "NSLocationWhenInUseUsageDescription"
        "NSMicrophoneUsageDescription"
        "NSMotionUsageDescription"
        "NSNearbyInteractionAllowOnceUsageDescription"
        "NSNearbyInteractionUsageDescription"
        "NSPhotoLibraryAddUsageDescription"
        "NSPhotoLibraryUsageDescription"
        "NSRemindersFullAccessUsageDescription"
        "NSRemindersUsageDescription"
        "NSSpeechRecognitionUsageDescription"
        "NSUserTrackingUsageDescription"
        "NSVideoSubscriberAccountUsageDescription"
        "ITSAppUsesNonExemptEncryption"
        "UIBackgroundModes"
        "LSApplicationQueriesSchemes"
        "CFBundleURLTypes"
        "NSBonjourServices"
    )

    # 备份目标 Info.plist
    cp "$TARGET_INFO_PLIST" "${TARGET_INFO_PLIST}.bak"
    log_info "已备份 Info.plist"

    local added_count=0

    # 使用 PlistBuddy 来操作 plist（macOS 自带）
    if ! command -v /usr/libexec/PlistBuddy &> /dev/null; then
        log_warning "PlistBuddy 不可用，跳过权限同步"
        return
    fi

    for key in "${permission_keys[@]}"; do
        # 检查源项目是否有这个 key
        local source_value
        source_value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$source_plist" 2>/dev/null) || continue

        # 检查目标项目是否已有这个 key
        if /usr/libexec/PlistBuddy -c "Print :$key" "$TARGET_INFO_PLIST" &>/dev/null; then
            log_info "  跳过已存在: $key"
            continue
        fi

        # 获取 key 的类型
        local key_type
        key_type=$(/usr/libexec/PlistBuddy -c "Print :$key" "$source_plist" 2>/dev/null | head -1)

        # 根据类型添加
        if [[ "$key_type" == "Array {"* ]] || [[ "$source_value" == "Array {"* ]]; then
            # 数组类型 - 需要特殊处理
            # 先添加空数组
            /usr/libexec/PlistBuddy -c "Add :$key array" "$TARGET_INFO_PLIST" 2>/dev/null

            # 逐个添加数组元素
            local i=0
            while true; do
                local item
                item=$(/usr/libexec/PlistBuddy -c "Print :$key:$i" "$source_plist" 2>/dev/null) || break
                /usr/libexec/PlistBuddy -c "Add :$key: string '$item'" "$TARGET_INFO_PLIST" 2>/dev/null
                ((i++))
            done

            log_success "  添加数组: $key ($i 项)"
            ((added_count++))
        elif [[ "$source_value" == "true" ]] || [[ "$source_value" == "false" ]]; then
            # 布尔类型
            /usr/libexec/PlistBuddy -c "Add :$key bool $source_value" "$TARGET_INFO_PLIST"
            log_success "  添加: $key = $source_value"
            ((added_count++))
        elif [[ "$source_value" =~ ^[0-9]+$ ]]; then
            # 整数类型
            /usr/libexec/PlistBuddy -c "Add :$key integer $source_value" "$TARGET_INFO_PLIST"
            log_success "  添加: $key = $source_value"
            ((added_count++))
        else
            # 字符串类型
            /usr/libexec/PlistBuddy -c "Add :$key string '$source_value'" "$TARGET_INFO_PLIST"
            log_success "  添加: $key"
            ((added_count++))
        fi
    done

    # 特殊处理：复杂的字典类型（如 CFBundleURLTypes）
    # 这些需要完整复制
    sync_complex_plist_keys "$source_plist"

    if [[ "$added_count" -gt 0 ]]; then
        log_success "iOS 权限配置同步完成: 添加 $added_count 个配置项"
    else
        log_info "iOS 权限配置同步完成: 无新配置需要添加"
    fi
}

# 同步复杂的 plist key（如 CFBundleURLTypes）
sync_complex_plist_keys() {
    local source_plist="$1"

    # CFBundleURLTypes - URL Schemes 配置
    if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$source_plist" &>/dev/null; then
        if ! /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$TARGET_INFO_PLIST" &>/dev/null; then
            log_info "  同步 CFBundleURLTypes..."

            # 使用 plutil 转换为 json，提取后再转回来
            local temp_json="/tmp/url_types_$$.json"

            # 提取 CFBundleURLTypes 到临时文件
            /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$source_plist" -x > "/tmp/url_types_$$.plist" 2>/dev/null

            # 使用 plutil 合并
            /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$TARGET_INFO_PLIST" 2>/dev/null

            # 逐个复制 URL Types
            local i=0
            while /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:$i" "$source_plist" &>/dev/null; do
                /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes: dict" "$TARGET_INFO_PLIST"

                # 复制每个属性
                local name
                name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:$i:CFBundleURLName" "$source_plist" 2>/dev/null) && \
                    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:$i:CFBundleURLName string '$name'" "$TARGET_INFO_PLIST" 2>/dev/null

                local role
                role=$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:$i:CFBundleTypeRole" "$source_plist" 2>/dev/null) && \
                    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:$i:CFBundleTypeRole string '$role'" "$TARGET_INFO_PLIST" 2>/dev/null

                # 复制 URL Schemes 数组
                if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:$i:CFBundleURLSchemes" "$source_plist" &>/dev/null; then
                    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:$i:CFBundleURLSchemes array" "$TARGET_INFO_PLIST" 2>/dev/null

                    local j=0
                    while true; do
                        local scheme
                        scheme=$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:$i:CFBundleURLSchemes:$j" "$source_plist" 2>/dev/null) || break
                        /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:$i:CFBundleURLSchemes: string '$scheme'" "$TARGET_INFO_PLIST" 2>/dev/null
                        ((j++))
                    done
                fi

                ((i++))
            done

            log_success "  已同步 CFBundleURLTypes ($i 项)"

            rm -f "/tmp/url_types_$$.plist" "/tmp/url_types_$$.json"
        fi
    fi
}

# 同步 iOS Podfile 配置
# 从源项目复制 platform 和 use_modular_headers! 配置
# 解决 iOS 18.5 模拟器 libswiftWebKit.dylib 找不到的问题
sync_ios_podfile() {
    log_step "同步 iOS Podfile 配置..."

    local source_podfile="$SOURCE_PATH/ios/Podfile"
    local target_podfile="$PROJECT_ROOT/ios/Podfile"
    local source_pbxproj="$SOURCE_PATH/ios/Runner.xcodeproj/project.pbxproj"

    if [[ ! -f "$source_podfile" ]]; then
        log_warning "源项目无 iOS Podfile，跳过"
        return
    fi

    if [[ ! -f "$target_podfile" ]]; then
        log_warning "目标 Podfile 不存在: $target_podfile"
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将同步 iOS Podfile 配置"
        return
    fi

    # 备份目标 Podfile
    cp "$target_podfile" "${target_podfile}.bak"
    log_info "已备份 Podfile"

    local modified=false

    # 1. 从源项目 project.pbxproj 获取实际的 iOS 部署目标版本
    # 这比 Podfile 中的注释行更可靠
    local ios_version=""
    if [[ -f "$source_pbxproj" ]]; then
        ios_version=$(get_ios_deployment_target_from_pbxproj "$source_pbxproj")
    fi
    
    # 如果 pbxproj 中没找到，尝试从 Podfile 获取
    if [[ -z "$ios_version" ]]; then
        ios_version=$(grep -oE "platform\s*:ios,\s*'[0-9]+\.[0-9]+'" "$source_podfile" | grep -oE "[0-9]+\.[0-9]+" | head -1)
    fi
    
    # 默认使用 12.0（大多数现代 Flutter 插件的最低要求）
    if [[ -z "$ios_version" ]]; then
        ios_version="12.0"
        log_info "  未检测到 iOS 版本，使用默认 $ios_version"
    else
        log_info "  检测到 iOS 部署目标: $ios_version"
    fi
    
    # 更新目标 Podfile 的 platform 行（取消注释并设置版本）
    if grep -qE "^#?[[:space:]]*platform[[:space:]]*:ios" "$target_podfile"; then
        # 删除旧的 platform 行（包括注释的）
        sed -i '' '/^#*[[:space:]]*platform[[:space:]]*:ios/d' "$target_podfile"
        # 在文件第二行（注释行之后）添加新的 platform 行
        sed -i '' "2a\\
platform :ios, '$ios_version'
" "$target_podfile"
        log_success "  已设置 platform :ios, '$ios_version'"
        modified=true
    else
        # 如果没有 platform 行，在文件开头添加
        sed -i '' "1a\\
platform :ios, '$ios_version'
" "$target_podfile"
        log_success "  已添加 platform :ios, '$ios_version'"
        modified=true
    fi

    # 2. 确保 use_modular_headers! 存在
    if grep -q "use_modular_headers!" "$source_podfile"; then
        if ! grep -q "use_modular_headers!" "$target_podfile"; then
            # 在 use_frameworks! 后面添加 use_modular_headers!
            sed -i '' 's/use_frameworks!/use_frameworks!\
  use_modular_headers!/' "$target_podfile"
            log_success "  已添加 use_modular_headers!"
            modified=true
        else
            log_info "  use_modular_headers! 已存在"
        fi
    fi

    if [[ "$modified" == "true" ]]; then
        log_success "iOS Podfile 配置同步完成"
    else
        log_info "iOS Podfile 配置同步完成: 无需修改"
    fi
}

# 生成入口文件
generate_entry_file() {
    log_step "生成入口文件..."

    local entry_file="$TARGET_SIDE_B_DIR/module_entry.dart"

    # 检查是否已有 main.dart 或类似入口
    local main_file=""
    if [[ -f "$TARGET_SIDE_B_DIR/main.dart" ]]; then
        main_file="main.dart"
    elif [[ -f "$TARGET_SIDE_B_DIR/app.dart" ]]; then
        main_file="app.dart"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将生成入口文件: $entry_file"
        return
    fi

    # 根据不同项目生成不同的入口文件
    case "$PROJECT_NAME" in
        dq)
            generate_dq_entry_file "$entry_file"
            ;;
        lgt)
            generate_lgt_entry_file "$entry_file"
            ;;
        *)
            generate_default_entry_file "$entry_file"
            ;;
    esac

    log_success "入口文件生成完成: $entry_file"

    if [[ -n "$main_file" ]]; then
        log_info "提示: 源项目入口文件是 $main_file"
    fi
}

# 注意: 各项目的 generate_*_entry_file() 函数已移至 scripts/compat/compat_*.sh
# 由 source_compat_file() 在运行时加载

# 生成默认入口文件
generate_default_entry_file() {
    local entry_file="$1"
    cat > "$entry_file" << 'EOF'
import 'package:flutter/material.dart';

/// 次要模块入口
class ModuleEntry {
  static bool _initialized = false;

  /// 初始化 次要模块模块
  static Future<void> initialize() async {
    if (_initialized) return;
    // TODO: 添加 次要模块初始化逻辑
    _initialized = true;
  }

  /// 获取 次要模块首页
  static Widget getHomePage() {
    // TODO: 根据实际 次要模块代码调整
    return const Scaffold(
      body: Center(child: Text('次要模块首页 - 请配置')),
    );
  }

  static Map<String, WidgetBuilder> getRoutes() {
    return {};
  }
}
EOF
}

# 修复 Flutter API 兼容性问题
# 处理 Flutter 版本升级导致的 API 变更
fix_flutter_api_compatibility() {
    log_step "修复 Flutter API 兼容性问题..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将修复 Flutter API 兼容性问题"
        return
    fi

    local total_fixed=0

    # 1. TabBarTheme -> TabBarThemeData (Flutter 3.x+ 变更)
    # 修复 copyWith(tabBarTheme: TabBarTheme(...)) -> copyWith(tabBarTheme: TabBarThemeData(...))
    while IFS= read -r -d '' file; do
        if grep -q "tabBarTheme: TabBarTheme(" "$file" 2>/dev/null; then
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' 's/tabBarTheme: TabBarTheme(/tabBarTheme: TabBarThemeData(/g' "$file"
            else
                sed -i 's/tabBarTheme: TabBarTheme(/tabBarTheme: TabBarThemeData(/g' "$file"
            fi
            log_info "  修复 TabBarTheme: $(basename "$file")"
            total_fixed=$((total_fixed + 1))
        fi
    done < <(find "$TARGET_SIDE_B_DIR" -name "*.dart" -print0)

    # 2. 修复 MyTabBarTheme extends TabBarTheme -> extends TabBarThemeData
    while IFS= read -r -d '' file; do
        if grep -q "extends TabBarTheme {" "$file" 2>/dev/null; then
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' 's/extends TabBarTheme {/extends TabBarThemeData {/g' "$file"
            else
                sed -i 's/extends TabBarTheme {/extends TabBarThemeData {/g' "$file"
            fi
            log_info "  修复 TabBarTheme 继承: $(basename "$file")"
            total_fixed=$((total_fixed + 1))
        fi
    done < <(find "$TARGET_SIDE_B_DIR" -name "*.dart" -print0)

    # 3. 修复 late final TabBarTheme -> late final TabBarThemeData
    while IFS= read -r -d '' file; do
        if grep -q "late final TabBarTheme " "$file" 2>/dev/null; then
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' 's/late final TabBarTheme /late final TabBarThemeData /g' "$file"
            else
                sed -i 's/late final TabBarTheme /late final TabBarThemeData /g' "$file"
            fi
            log_info "  修复 TabBarTheme 变量声明: $(basename "$file")"
            total_fixed=$((total_fixed + 1))
        fi
    done < <(find "$TARGET_SIDE_B_DIR" -name "*.dart" -print0)

    # 4. Dio 4→5 兼容：connectTimeout/receiveTimeout/sendTimeout 从 int(ms) 变为 Duration
    # 模式：connectTimeout: N * 1000 → Duration(seconds: N)
    #       connectTimeout: NNNN    → Duration(milliseconds: NNNN)
    # 注意：macOS BSD sed 不支持 \s，使用空格匹配
    while IFS= read -r -d '' file; do
        local changed=false

        # 匹配 N * 1000 模式（如 60 * 1000, 5 * 1000）→ Duration(seconds: N)
        if grep -qE '(connect|receive|send)Timeout: *[0-9]+ *\* *1000' "$file" 2>/dev/null; then
            sed -i '' -E 's/(connect|receive|send)Timeout: *([0-9]+) *\* *1000/\1Timeout: const Duration(seconds: \2)/g' "$file"
            changed=true
        fi

        # 匹配纯数字毫秒模式（如 5000, 60000）→ Duration(milliseconds: N)
        if grep -qE '(connect|receive|send)Timeout: *[0-9]{3,}[,)]' "$file" 2>/dev/null; then
            sed -i '' -E 's/(connect|receive|send)Timeout: *([0-9]+)/\1Timeout: const Duration(milliseconds: \2)/g' "$file"
            changed=true
        fi

        if [[ "$changed" == "true" ]]; then
            log_info "  修复 Dio timeout: $(basename "$file")"
            total_fixed=$((total_fixed + 1))
        fi
    done < <(find "$TARGET_SIDE_B_DIR" -name "*.dart" -print0)

    # 5. image 3→4 兼容：decodeImage(await file?.readAsBytes() ?? []) → ?? Uint8List(0)
    while IFS= read -r -d '' file; do
        if grep -q 'readAsBytes() *?? *\[\]' "$file" 2>/dev/null; then
            sed -i '' 's/readAsBytes() *?? *\[\]/readAsBytes() ?? Uint8List(0)/g' "$file"
            # 添加 dart:typed_data import（如果缺少）
            if ! grep -q "import 'dart:typed_data'" "$file" 2>/dev/null; then
                local first_import_line=$(grep -n "^import " "$file" | head -1 | cut -d: -f1)
                if [[ -n "$first_import_line" ]]; then
                    sed -i '' "${first_import_line}i\\
import 'dart:typed_data';
" "$file"
                fi
            fi
            log_info "  修复 image Uint8List: $(basename "$file")"
            total_fixed=$((total_fixed + 1))
        fi
    done < <(find "$TARGET_SIDE_B_DIR" -name "*.dart" -print0)

    if [[ "$total_fixed" -gt 0 ]]; then
        log_success "Flutter API 兼容性修复完成: 共修复 $total_fixed 处"
    else
        log_info "无需修复 Flutter API 兼容性问题"
    fi

    # 6. 修复 extends WidgetsFlutterBinding 导致 Binding 重复初始化
    # B 面代码在独立运行时自行初始化 Binding（如 _ImageCacheHooker），但嵌入 AB 模板后
    # A 面已初始化 Binding，再次实例化会报 "Binding is already initialized" 异常。
    # 同时 B 面的自定义 ImageCache（含图片解密）必须保留，否则网络图片全部加载失败。
    # 解决方案：将 HookerClass() 替换为 AppBinding.setImageCacheDelegate(_ImageCache())，
    # 通过 A 面的 DelegatingImageCache 机制注入 B 面的自定义 ImageCache。
    _fix_binding_in_dir() {
        local search_dir="$1"
        local dir_label="$2"
        while IFS= read -r -d '' file; do
            if grep -q 'extends WidgetsFlutterBinding' "$file" 2>/dev/null; then
                local hooker_class
                hooker_class=$(grep -o 'class [A-Za-z_][A-Za-z0-9_]* extends WidgetsFlutterBinding' "$file" | head -1 | awk '{print $2}')
                if [[ -n "$hooker_class" ]]; then
                    # 找到该 Hooker 覆写的 createImageCache 返回的类名
                    local cache_class
                    cache_class=$(grep -A2 'createImageCache' "$file" | grep -o 'return [A-Za-z_][A-Za-z0-9_]*()' | head -1 | sed 's/return //;s/()//')
                    if [[ -z "$cache_class" ]]; then
                        cache_class="_ImageCache"
                    fi

                    if grep -q "${hooker_class}()" "$file" 2>/dev/null; then
                        # 替换实例化调用为 AppBinding.setImageCacheDelegate
                        sed -i '' "s|    ${hooker_class}();|    AppBinding.setImageCacheDelegate(${cache_class}());|g" "$file"
                        sed -i '' "s|  ${hooker_class}();|  AppBinding.setImageCacheDelegate(${cache_class}());|g" "$file"

                        # 在 part of 所属的主文件中添加 AppBinding import。
                        # 这里需要兼容 CRLF，以及 part of 使用单/双引号两种写法。
                        local part_of_file
                        part_of_file=$(
                            sed -nE "s/^[[:space:]]*part of ['\"]([^'\"]+)['\"];?[[:space:]]*\r?$/\1/p" "$file" \
                                | head -1 \
                                | tr -d '\r'
                        )
                        if [[ -n "$part_of_file" ]]; then
                            local main_file="$(dirname "$file")/$part_of_file"
                            if [[ -f "$main_file" ]]; then
                                if ! grep -q 'app_binding.dart' "$main_file" 2>/dev/null; then
                                    local app_package_name
                                    app_package_name=$(get_app_package_name)
                                    local last_import_line
                                    last_import_line=$(grep -n "^import " "$main_file" | tail -1 | cut -d: -f1)
                                    if [[ -n "$app_package_name" ]]; then
                                        if [[ -n "$last_import_line" ]]; then
                                            sed -i '' "${last_import_line}a\\
import 'package:${app_package_name}/app_binding.dart';
" "$main_file"
                                        else
                                            sed -i '' "1i\\
import 'package:${app_package_name}/app_binding.dart';
" "$main_file"
                                        fi
                                    else
                                        log_warning "  修复 WidgetsFlutterBinding ($dir_label): $(basename "$file") 未能读取主工程包名，跳过注入 AppBinding import"
                                    fi
                                fi
                            else
                                log_warning "  修复 WidgetsFlutterBinding ($dir_label): $(basename "$file") 解析到主文件 '$part_of_file'，但文件不存在，跳过注入 AppBinding import"
                            fi
                        else
                            log_warning "  修复 WidgetsFlutterBinding ($dir_label): $(basename "$file") 未能解析 part of 主文件，跳过注入 AppBinding import"
                        fi

                        log_info "  修复 WidgetsFlutterBinding ($dir_label): $(basename "$file") → AppBinding.setImageCacheDelegate(${cache_class})"
                        total_fixed=$((total_fixed + 1))
                    fi
                fi
            fi
        done < <(find "$search_dir" -name "*.dart" -print0)
    }

    _fix_binding_in_dir "$TARGET_SIDE_B_DIR" "secondary"
    if [[ -d "$TARGET_PLUGINS_DIR" ]]; then
        _fix_binding_in_dir "$TARGET_PLUGINS_DIR" "plugins"
    fi

    # 7. 修复 plugins/utils 中的 MyNetworkImage 类缺少 webHtmlElementStrategy
    local cache_file="$TARGET_PLUGINS_DIR/utils/lib/src/cache/cache.g.dart"
    if [[ -f "$cache_file" ]]; then
        # 检查是否已经有 webHtmlElementStrategy
        if ! grep -q "webHtmlElementStrategy" "$cache_file" 2>/dev/null; then
            # 在类的最后一个 } 前添加 webHtmlElementStrategy getter
            # 找到 MyNetworkImage 类的结束位置
            if grep -q "class MyNetworkImage" "$cache_file" 2>/dev/null; then
                if [[ "$(uname)" == "Darwin" ]]; then
                    # 在 toString() 方法后添加 webHtmlElementStrategy
                    sed -i '' "s|'MyNetworkImage')}(\"\$url\", scale: \${scale.toStringAsFixed(1)})';|'MyNetworkImage')}(\"\$url\", scale: \${scale.toStringAsFixed(1)})';\\
\\
  @override\\
  WebHtmlElementStrategy get webHtmlElementStrategy =>\\
      WebHtmlElementStrategy.never;|g" "$cache_file"
                else
                    sed -i "s|'MyNetworkImage')}(\"\$url\", scale: \${scale.toStringAsFixed(1)})';|'MyNetworkImage')}(\"\$url\", scale: \${scale.toStringAsFixed(1)})';\\n\\n  @override\\n  WebHtmlElementStrategy get webHtmlElementStrategy =>\\n      WebHtmlElementStrategy.never;|g" "$cache_file"
                fi
                log_info "  修复 MyNetworkImage.webHtmlElementStrategy"
            fi
        fi
    fi
}

# 更新 assets 路径引用
update_assets_paths() {
    log_step "更新 assets 路径引用..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将更新 assets 路径引用"
        return
    fi

    # 只替换资源引用（字符串中的 assets/），不替换 import 语句中的相对路径
    # 关键修复：使用 '\./assets/' 会错误匹配 '../assets/' 中的 './assets/' 子串
    # 解决方案：只匹配引号后紧跟的 './assets/' 格式（资源字符串），不影响 import 相对路径
    local count=0
    while IFS= read -r -d '' file; do
        # 检查文件是否包含 './assets/ 或 "./assets/ 格式的资源引用（引号紧跟 ./）
        if grep -q "'\./assets/" "$file" 2>/dev/null || grep -q '"\./assets/' "$file" 2>/dev/null; then
            if [[ "$(uname)" == "Darwin" ]]; then
                # 只替换引号后紧跟的 './assets/'，避免匹配 '../assets/' 中的子串
                # 将 './assets/' 直接替换为 'assets/secondary/'
                # 跳过 import/export 语句，只处理资源字符串
                sed -i '' "/^[[:space:]]*import /!s|'\./assets/|'assets/secondary/|g" "$file"
                sed -i '' '/^[[:space:]]*import /!s|"\./assets/|"assets/secondary/|g' "$file"
            else
                sed -i "/^[[:space:]]*import /!s|'\./assets/|'assets/secondary/|g" "$file"
                sed -i '/^[[:space:]]*import /!s|"\./assets/|"assets/secondary/|g' "$file"
            fi
            count=$((count + 1))
        # 检查文件是否包含 'assets/ 但不是 assets/secondary（用于 pornhub_app 等其他项目）
        elif grep -q "'assets/[^s]" "$file" 2>/dev/null || grep -q "\"assets/[^s]" "$file" 2>/dev/null; then
            # 替换所有常见的 assets 子目录路径
            # 覆盖: images, translations, icons, fonts, player, icon, tabbar, comics, live, mine, 
            #       search, short, community, shi_pin, ann, novel, lottie 等
            local asset_dirs=(
                "images" "translations" "icons" "fonts" "player" "icon" "tabbar" 
                "comics" "live" "mine" "search" "short" "community" "shi_pin" "ann" "novel"
                "lottie" "json" "svga" "video" "audio" "animation" "file"
                "tab" "app" "play" "reader" "mv" "girl" "theme_images"
            )
            if [[ "$(uname)" == "Darwin" ]]; then
                for dir in "${asset_dirs[@]}"; do
                    sed -i '' "s|'assets/${dir}/|'assets/secondary/${dir}/|g" "$file"
                    sed -i '' "s|\"assets/${dir}/|\"assets/secondary/${dir}/|g" "$file"
                done
                # 处理根目录下的资源文件（如 'assets/xxx.png'）
                # 使用负向前瞻避免重复替换已有 secondary 的路径
                sed -i '' "s|'assets/\([^s/][^/]*\.png\)|'assets/secondary/\1|g" "$file"
                sed -i '' "s|'assets/\([^s/][^/]*\.jpg\)|'assets/secondary/\1|g" "$file"
                sed -i '' "s|'assets/\([^s/][^/]*\.gif\)|'assets/secondary/\1|g" "$file"
                sed -i '' "s|'assets/\([^s/][^/]*\.webp\)|'assets/secondary/\1|g" "$file"
                sed -i '' "s|'assets/\([^s/][^/]*\.json\)|'assets/secondary/\1|g" "$file"
                sed -i '' "s|\"assets/\([^s/][^/]*\.png\)|\"assets/secondary/\1|g" "$file"
                sed -i '' "s|\"assets/\([^s/][^/]*\.jpg\)|\"assets/secondary/\1|g" "$file"
                sed -i '' "s|\"assets/\([^s/][^/]*\.gif\)|\"assets/secondary/\1|g" "$file"
                sed -i '' "s|\"assets/\([^s/][^/]*\.webp\)|\"assets/secondary/\1|g" "$file"
                sed -i '' "s|\"assets/\([^s/][^/]*\.json\)|\"assets/secondary/\1|g" "$file"
            else
                for dir in "${asset_dirs[@]}"; do
                    sed -i "s|'assets/${dir}/|'assets/secondary/${dir}/|g" "$file"
                    sed -i "s|\"assets/${dir}/|\"assets/secondary/${dir}/|g" "$file"
                done
                sed -i "s|'assets/\([^s/][^/]*\.png\)|'assets/secondary/\1|g" "$file"
                sed -i "s|'assets/\([^s/][^/]*\.jpg\)|'assets/secondary/\1|g" "$file"
                sed -i "s|'assets/\([^s/][^/]*\.gif\)|'assets/secondary/\1|g" "$file"
                sed -i "s|'assets/\([^s/][^/]*\.webp\)|'assets/secondary/\1|g" "$file"
                sed -i "s|'assets/\([^s/][^/]*\.json\)|'assets/secondary/\1|g" "$file"
                sed -i "s|\"assets/\([^s/][^/]*\.png\)|\"assets/secondary/\1|g" "$file"
                sed -i "s|\"assets/\([^s/][^/]*\.jpg\)|\"assets/secondary/\1|g" "$file"
                sed -i "s|\"assets/\([^s/][^/]*\.gif\)|\"assets/secondary/\1|g" "$file"
                sed -i "s|\"assets/\([^s/][^/]*\.webp\)|\"assets/secondary/\1|g" "$file"
                sed -i "s|\"assets/\([^s/][^/]*\.json\)|\"assets/secondary/\1|g" "$file"
            fi
            count=$((count + 1))
        fi
    done < <(find "$TARGET_SIDE_B_DIR" -name "*.dart" -print0)

    log_success "assets 路径更新完成: 共更新 $count 个文件"
}

# 同步 SDK 版本和 flutter_lints 版本
# Dart 3.7+ 引入了 wildcard variables，导致 _ 变量名不可用
# 需要保持源项目的 SDK 版本以避免此问题
sync_sdk_version() {
    log_step "同步 SDK 版本..."

    local target_pubspec="$PROJECT_ROOT/pubspec.yaml"
    local source_pubspec="$SOURCE_PATH/pubspec.yaml"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将同步 SDK 版本"
        return
    fi

    # 提取源项目的 SDK 版本
    local source_sdk
    source_sdk=$(grep "^  sdk:" "$source_pubspec" | head -1 | sed 's/^  sdk: *//' | tr -d '\r\n')

    if [[ -z "$source_sdk" ]]; then
        log_warning "无法从源项目提取 SDK 版本，跳过"
        return
    fi

    log_info "源项目 SDK 版本: $source_sdk"

    # 更新目标项目的 SDK 版本
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|^  sdk: .*|  sdk: $source_sdk|" "$target_pubspec"
    else
        sed -i "s|^  sdk: .*|  sdk: $source_sdk|" "$target_pubspec"
    fi

    log_success "SDK 版本已同步: $source_sdk"

    # 同步 flutter_lints 版本
    local source_lints
    source_lints=$(grep "flutter_lints:" "$source_pubspec" | sed 's/.*flutter_lints: *//' | tr -d '\r\n')

    if [[ -n "$source_lints" ]]; then
        log_info "源项目 flutter_lints 版本: $source_lints"

        # 更新目标项目的 flutter_lints 版本
        if grep -q "flutter_lints:" "$target_pubspec"; then
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' "s|flutter_lints: .*|flutter_lints: $source_lints|" "$target_pubspec"
            else
                sed -i "s|flutter_lints: .*|flutter_lints: $source_lints|" "$target_pubspec"
            fi
            log_success "flutter_lints 版本已同步: $source_lints"
        fi
    fi
}

# 合并自 zeus 上游：清理 pubspec.yaml 行尾空白（避免 yaml 解析/格式问题）
trim_pubspec_trailing_whitespace() {
    local pubspec="$1"

    if [[ "$DRY_RUN" == true ]] || [[ ! -f "$pubspec" ]]; then
        return 0
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' -E 's/[[:space:]]+$//' "$pubspec"
    else
        sed -i -E 's/[[:space:]]+$//' "$pubspec"
    fi
}

# 显示 pubspec 依赖提示
show_pubspec_hints() {
    log_step "检查依赖..."

    echo ""
    log_warning "请手动将以下依赖添加到模板项目的 pubspec.yaml:"
    echo ""
    echo "源项目 pubspec.yaml 位置: $SOURCE_PATH/pubspec.yaml"
    echo ""

    # 提取关键依赖信息
    if command -v grep &> /dev/null; then
        echo "主要依赖 (前30行):"
        grep -A 100 "^dependencies:" "$SOURCE_PATH/pubspec.yaml" | grep -B 100 "^dev_dependencies:" 2>/dev/null | head -30 || true
    fi

    echo ""
    log_warning "还需要更新 pubspec.yaml 的 assets 声明，添加:"
    echo "  - assets/secondary/"
    echo ""
}

# 从模板初始化 pubspec.yaml
init_pubspec_from_template() {
    log_step "从模板初始化 pubspec.yaml..."

    local template_file="$PROJECT_ROOT/pubspec.yaml.template"
    local target_pubspec="$PROJECT_ROOT/pubspec.yaml"
    local current_package_name=""
    local template_package_name=""
    local package_name_to_keep=""

    if [[ ! -f "$template_file" ]]; then
        log_error "模板文件不存在: $template_file"
        log_info "请先创建 pubspec.yaml.template 文件"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将从模板初始化 pubspec.yaml"
        return
    fi

    if [[ -f "$target_pubspec" ]]; then
        current_package_name=$(grep "^name:" "$target_pubspec" | head -1 | sed 's/name: *//' | tr -d ' \r\n')
    fi
    template_package_name=$(grep "^name:" "$template_file" | head -1 | sed 's/name: *//' | tr -d ' \r\n')

    package_name_to_keep="$current_package_name"
    if [[ -z "$package_name_to_keep" ]]; then
        package_name_to_keep="$template_package_name"
    elif [[ "$package_name_to_keep" == "daddy_template" && -n "$template_package_name" && "$template_package_name" != "daddy_template" ]]; then
        # 兼容旧版 create_ab_project：它只改了 pubspec.yaml，没有改 pubspec.yaml.template。
        # 一旦执行过 sync，pubspec.yaml 会被模板覆盖回 daddy_template。此时优先恢复模板里的真实项目名。
        package_name_to_keep="$template_package_name"
    fi

    # 从模板复制
    cp "$template_file" "$target_pubspec"

    # 保留当前壳工程包名，避免新项目在同步后被模板名覆盖回 daddy_template。
    if [[ -n "$package_name_to_keep" ]]; then
        sed -i '' "s/^name: .*/name: $package_name_to_keep/" "$target_pubspec"
    fi

    log_success "已从模板初始化 pubspec.yaml"
}

# 合并 pubspec.yaml 依赖
merge_pubspec() {
    log_step "合并 pubspec.yaml 依赖..."

    local target_pubspec="$PROJECT_ROOT/pubspec.yaml"
    local source_pubspec="$SOURCE_PATH/pubspec.yaml"

    if [[ ! -f "$target_pubspec" ]]; then
        log_error "目标 pubspec.yaml 不存在: $target_pubspec"
        return 1
    fi

    if [[ ! -f "$source_pubspec" ]]; then
        log_error "源 pubspec.yaml 不存在: $source_pubspec"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将合并 pubspec.yaml 依赖"
        return
    fi

    # 备份原 pubspec.yaml
    cp "$target_pubspec" "$target_pubspec.bak"
    log_info "已备份 pubspec.yaml 到 pubspec.yaml.bak"

    # 执行合并
    merge_pubspec_impl
}

# 从 B 面 pubspec 的 dependency_overrides 段拆成条目块（须保留 path:/git: 等多行子项；
# 若只合并 «包名:» 单行，pub 会当成从 pub.dev 拉 any，导致 oaid_info_plugin 等本地包解析失败）
_collect_override_blocks_from_pubspec() {
    local source_pubspec="$1"
    local out_blocks="$2"
    : > "$out_blocks"
    local temp_body="/tmp/secondary_override_body_$$.yaml"
    awk '
        /^dependency_overrides:/ { grab=1; next }
        grab && /^[a-zA-Z][a-zA-Z0-9_-]*:/ { exit }
        grab { print }
    ' "$source_pubspec" > "$temp_body" 2>/dev/null || true
    [[ ! -s "$temp_body" ]] && { rm -f "$temp_body"; return 0; }

    local block=""
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        # 仅识别真实包名行（须以字母开头）；纯注释行勿单独成块，避免 tr -d 空格后误入 pubspec
        if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z][a-zA-Z0-9_-]*: ]]; then
            if [[ -n "$block" ]]; then
                if echo "$block" | grep -qE '^[[:space:]]{2}[a-zA-Z][a-zA-Z0-9_-]*:'; then
                    printf '%s\n\n' "$block" >> "$out_blocks"
                fi
            fi
            block="$line"
        else
            if [[ -n "$block" ]]; then
                block+=$'\n'"$line"
            fi
        fi
    done < "$temp_body"
    if [[ -n "$block" ]] && echo "$block" | grep -qE '^[[:space:]]{2}[a-zA-Z][a-zA-Z0-9_-]*:'; then
        printf '%s\n\n' "$block" >> "$out_blocks"
    fi
    rm -f "$temp_body"
}

# 仅当 override 含 path/git 或 plugins/ 下已有对应包时，才写入壳工程 pubspec（避免 pub.dev 拉取 oaid_info_plugin 等本地包失败）
_override_exists_in_target() {
    local pubspec="$1"
    local name="$2"
    awk -v dep="$name" '
        /^dependency_overrides:/ { in_section=1; next }
        in_section && /^[a-zA-Z][a-zA-Z0-9_-]*:/ { in_section=0 }
        in_section && $0 ~ "^  "dep":" { found=1; exit }
        END { exit found?0:1 }
    ' "$pubspec"
}

_prepare_override_block_for_shell() {
    local block="$1"
    local dep_name
    dep_name=$(echo "$block" | head -1 | sed 's/^  //' | sed 's/:.*$//' | tr -d ' ')
    if [[ -z "$dep_name" ]]; then
        return 1
    fi
    # path/git 多行块：原样保留
    if echo "$block" | grep -qE '^[[:space:]]{4,}(path|git):'; then
        echo "$block"
        return 0
    fi
    # 纯版本号单行 override（如 `http: ^1.2.2`、`intl: 0.20.2`、`rxdart: ^0.28.0`）：
    # 这正是解决依赖冲突的核心机制（B 面常用，如 audioplayers http^1.2.2 vs svgaplayer http^0.13.3），
    # 必须原样保留，否则壳工程 pub get 解析失败。
    if echo "$block" | head -1 | grep -qE '^  [a-z_][a-z_0-9]*:[[:space:]]+[^[:space:]]'; then
        echo "$block"
        return 0
    fi
    # 既无 path/git 也无版本号，但 plugins/ 下恰好有同名目录：兜底转 path override
    if [[ -d "$TARGET_PLUGINS_DIR/$dep_name" && -f "$TARGET_PLUGINS_DIR/$dep_name/pubspec.yaml" ]]; then
        echo "  ${dep_name}:"
        echo "    path: plugins/${dep_name}"
        return 0
    fi
    log_warning "跳过 dependency_override: ${dep_name}（无 path/git/版本号，且 plugins/ 中无该包）" >&2
    return 1
}

# pubspec 合并实现（使用 sed/grep）
merge_pubspec_impl() {
    local target_pubspec="$PROJECT_ROOT/pubspec.yaml"
    local source_pubspec="$SOURCE_PATH/pubspec.yaml"

    log_info "提取源项目依赖..."

    # 创建临时文件
    local temp_deps="/tmp/secondary_deps_$$.yaml"
    local temp_deps_filtered="/tmp/secondary_deps_filtered_$$.yaml"

    # 提取源项目 dependencies 部分的内容（从 dependencies: 到下一个顶级键）
    # 使用 sed 提取，只保留顶级依赖（以两个空格开头），不包括 git/path 子项
    sed -n '/^dependencies:/,/^[a-z_-]*:/p' "$source_pubspec" | \
        grep -v "^dependencies:" | \
        grep -v "^[a-z_-]*:" | \
        grep -v "^$" | \
        grep "^  [a-z]" > "$temp_deps" || true

    # 过滤掉目标已存在的依赖和 flutter 相关依赖
    > "$temp_deps_filtered"
    while IFS= read -r line; do
        # 提取依赖名（去掉版本和冒号）
        local dep_name
        dep_name=$(echo "$line" | sed 's/^  //' | sed 's/:.*$//' | tr -d ' ')

        # 跳过 flutter 相关
        if [[ "$dep_name" == "flutter" ]] || [[ "$dep_name" == "flutter_localizations" ]]; then
            continue
        fi

        # 跳过 git/path 依赖（以冒号结尾，没有版本号，允许尾随空格）
        # 这些会在后面单独处理
        local trimmed_line="${line%"${line##*[![:space:]]}"}"
        if [[ "$trimmed_line" =~ :$ ]]; then
            continue
        fi

        # 检查目标文件是否已有此依赖
        if grep -q "^  ${dep_name}:" "$target_pubspec"; then
            log_info "  跳过已存在: $dep_name"
            continue
        fi

        echo "$line" >> "$temp_deps_filtered"
    done < "$temp_deps"

    # 现在处理 git 依赖格式（多行格式）
    local temp_git_deps="/tmp/secondary_git_deps_$$.yaml"
    > "$temp_git_deps"

    # 提取 git 依赖（格式如 name:\n    git:\n      url: xxx\n      ref: xxx）
    local in_git_dep=false
    local current_dep=""
    local current_block=""

    while IFS= read -r line; do
        # 顶级依赖开始（两个空格 + 字母）
        if [[ "$line" =~ ^[\ ]{2}[a-z_-]+: ]]; then
            # 保存之前的 git 依赖块
            if [[ "$in_git_dep" == "true" ]] && [[ -n "$current_block" ]]; then
                # 检查是否已存在，且不是 flutter 相关
                if [[ "$current_dep" != "flutter" ]] && [[ "$current_dep" != "flutter_localizations" ]]; then
                    if ! grep -q "^  ${current_dep}:" "$target_pubspec"; then
                        echo "$current_block" >> "$temp_git_deps"
                    fi
                fi
            fi

            current_dep=$(echo "$line" | sed 's/^  //' | sed 's/:.*$//')
            current_block="$line"

            # 检查是否是 git/path 依赖（以冒号结尾，没有版本号，允许尾随空格）
            local trimmed="${line%"${line##*[![:space:]]}"}"
            if [[ "$trimmed" =~ :$ ]]; then
                in_git_dep=true
            else
                in_git_dep=false
                current_block=""
            fi
        elif [[ "$in_git_dep" == "true" ]]; then
            # 继续收集 git 依赖的子行
            current_block="${current_block}"$'\n'"$line"
        fi
    done < <(sed -n '/^dependencies:/,/^[a-z_-]*:/p' "$source_pubspec" | grep -v "^dependencies:" | grep -v "^[a-z_-]*:")

    # 处理最后一个 git 依赖
    if [[ "$in_git_dep" == "true" ]] && [[ -n "$current_block" ]]; then
        if [[ "$current_dep" != "flutter" ]] && [[ "$current_dep" != "flutter_localizations" ]]; then
            if ! grep -q "^  ${current_dep}:" "$target_pubspec"; then
                echo "$current_block" >> "$temp_git_deps"
            fi
        fi
    fi

    # 合并普通依赖和 git 依赖
    local deps_count
    deps_count=$(wc -l < "$temp_deps_filtered" | tr -d ' ')
    local git_deps_count
    git_deps_count=$(grep -c "^  [a-z]" "$temp_git_deps" 2>/dev/null || true)
    git_deps_count=$(echo "$git_deps_count" | tail -n 1 | tr -d '[:space:]')
    if [[ -z "$git_deps_count" ]]; then
        git_deps_count=0
    fi

    local total_deps=$((deps_count + git_deps_count))

    if [[ "$total_deps" -gt 0 ]]; then
        log_info "将添加 $total_deps 个新依赖"

        # 读取目标文件，在 dev_dependencies: 前插入
        {
            while IFS= read -r line; do
                if [[ "$line" == "dev_dependencies:"* ]]; then
                    echo ""
                    echo "  # === 次要模块依赖 (自动添加 from $PROJECT_NAME) ==="
                    cat "$temp_deps_filtered" 2>/dev/null || true
                    cat "$temp_git_deps" 2>/dev/null || true
                    echo ""
                fi
                echo "$line"
            done < "$target_pubspec"
        } > "${target_pubspec}.tmp"

        mv "${target_pubspec}.tmp" "$target_pubspec"
        log_success "已添加 $total_deps 个依赖"
    else
        log_info "无新依赖需要添加"
    fi

    # 添加 assets 声明
    log_info "添加 assets 声明..."

    # 提取源项目的 assets 列表
    local temp_assets="/tmp/secondary_assets_$$.txt"
    sed -n '/^  assets:/,/^  [a-z]/p' "$source_pubspec" | \
        grep "^    -" | \
        sed 's|assets/|assets/secondary/|g' > "$temp_assets" || true

    local assets_count
    assets_count=$(wc -l < "$temp_assets" | tr -d ' ')

    if [[ "$assets_count" -gt 0 ]]; then
        echo "将添加 $assets_count 个 assets 目录"

        # 检查目标是否已有 assets 部分
        if grep -q "^  assets:" "$target_pubspec"; then
            log_info "目标已有 assets 部分，追加内容"
            # 在 assets: 行后追加
            {
                local found_assets=false
                while IFS= read -r line; do
                    echo "$line"
                    if [[ "$line" == "  assets:"* ]] && [[ "$found_assets" == "false" ]]; then
                        found_assets=true
                        echo "    # === 次要模块 assets (自动添加) ==="
                        cat "$temp_assets"
                    fi
                done < "$target_pubspec"
            } > "${target_pubspec}.tmp"
            mv "${target_pubspec}.tmp" "$target_pubspec"
        else
            log_info "目标无 assets 部分，在 flutter: 后添加"
            # 在 uses-material-design: 后添加
            {
                while IFS= read -r line; do
                    echo "$line"
                    if [[ "$line" == "  uses-material-design:"* ]]; then
                        echo ""
                        echo "  assets:"
                        echo "    # === 次要模块 assets (自动添加) ==="
                        cat "$temp_assets"
                    fi
                done < "$target_pubspec"
            } > "${target_pubspec}.tmp"
            mv "${target_pubspec}.tmp" "$target_pubspec"
        fi

        log_info "已添加 $assets_count 个 assets 目录"
    fi

    # --- 合并 dependency_overrides ---
    # 某些 B 面在 dependency_overrides 里含 path/git 多行条目，必须整块合并；
    # 旧逻辑只取 «  xx: » 单行会生成「空约束」，pub 会去 pub.dev 拉 any（如 oaid_info_plugin）并解析失败。
    local temp_overrides_blocks="/tmp/secondary_overrides_blocks_$$.yaml"
    local temp_overrides_filtered="/tmp/secondary_overrides_filtered_$$.yaml"
    > "$temp_overrides_filtered"

    if grep -q "^dependency_overrides:" "$source_pubspec" 2>/dev/null; then
        _collect_override_blocks_from_pubspec "$source_pubspec" "$temp_overrides_blocks"

        local override_count=0
        if [[ -s "$temp_overrides_blocks" ]]; then
            local block=""
            while IFS= read -r line || [[ -n "${line:-}" ]]; do
                if [[ -z "$line" ]]; then
                    if [[ -n "$block" ]]; then
                        local dep_name
                        dep_name=$(echo "$block" | head -1 | sed 's/^  //' | sed 's/:.*$//' | tr -d ' ')
                        if [[ "$dep_name" != "flutter" && "$dep_name" != "flutter_localizations" ]] \
                            && ! _override_exists_in_target "$target_pubspec" "$dep_name"; then
                            local prepared_block=""
                            prepared_block=$(_prepare_override_block_for_shell "$block") || true
                            if [[ -n "$prepared_block" ]]; then
                                printf '%s\n' "$prepared_block" >> "$temp_overrides_filtered"
                                echo "" >> "$temp_overrides_filtered"
                                override_count=$((override_count + 1))
                            fi
                        fi
                        block=""
                    fi
                    continue
                fi
                if [[ -n "$block" ]]; then
                    block+=$'\n'"$line"
                else
                    block="$line"
                fi
            done < "$temp_overrides_blocks"
            if [[ -n "$block" ]]; then
                local dep_name_flush
                dep_name_flush=$(echo "$block" | head -1 | sed 's/^  //' | sed 's/:.*$//' | tr -d ' ')
                if [[ "$dep_name_flush" != "flutter" && "$dep_name_flush" != "flutter_localizations" ]] \
                    && ! _override_exists_in_target "$target_pubspec" "$dep_name_flush"; then
                    local prepared_flush=""
                    prepared_flush=$(_prepare_override_block_for_shell "$block") || true
                    if [[ -n "$prepared_flush" ]]; then
                        printf '%s\n' "$prepared_flush" >> "$temp_overrides_filtered"
                        echo "" >> "$temp_overrides_filtered"
                        override_count=$((override_count + 1))
                    fi
                fi
            fi

            if [[ "$override_count" -gt 0 ]]; then
                # 写入 dependency_overrides 段到目标 pubspec
                if grep -q "^dependency_overrides:" "$target_pubspec"; then
                    # 已有 dependency_overrides 段，追加到其末尾
                    local override_section_end
                    override_section_end=$(awk '/^dependency_overrides:/{found=NR} found && /^[a-z]/ && NR>found{print NR; exit}' "$target_pubspec")
                    if [[ -z "$override_section_end" ]]; then
                        # dependency_overrides 是文件最后一个段，直接追加
                        cat "$temp_overrides_filtered" >> "$target_pubspec"
                    else
                        # 在段尾前插入
                        local insert_line=$((override_section_end - 1))
                        sed -i '' "${insert_line}r ${temp_overrides_filtered}" "$target_pubspec"
                    fi
                else
                    # 没有 dependency_overrides 段，在文件适当位置新建
                    # 在 dev_dependencies: 前插入
                    {
                        local inserted=false
                        while IFS= read -r line; do
                            if [[ "$line" == "dev_dependencies:"* ]] && [[ "$inserted" == "false" ]]; then
                                echo ""
                                echo "dependency_overrides:"
                                cat "$temp_overrides_filtered"
                                echo ""
                                inserted=true
                            fi
                            echo "$line"
                        done < "$target_pubspec"
                        if [[ "$inserted" == "false" ]]; then
                            echo ""
                            echo "dependency_overrides:"
                            cat "$temp_overrides_filtered"
                        fi
                    } > "${target_pubspec}.tmp"
                    mv "${target_pubspec}.tmp" "$target_pubspec"
                fi
                log_info "已合并 $override_count 条 dependency_overrides（含 path/git 多行）"
            fi
            rm -f "$temp_overrides_filtered"
        fi
    fi
    rm -f "$temp_overrides_blocks"

    # 清理临时文件
    rm -f "$temp_deps" "$temp_deps_filtered" "$temp_git_deps" "$temp_assets"

    # --- 后处理：SDK 依赖和版本冲突修复 ---

    # 自动添加 flutter_localizations（如果源项目使用）
    if grep -q "flutter_localizations:" "$source_pubspec" 2>/dev/null; then
        if ! grep -q "flutter_localizations:" "$target_pubspec" 2>/dev/null; then
            log_info "添加 flutter_localizations SDK 依赖..."
            # 在 "sdk: flutter" 行后插入
            local sdk_line=$(grep -n "sdk: flutter$" "$target_pubspec" | head -1 | cut -d: -f1)
            if [[ -n "$sdk_line" ]]; then
                sed -i '' "${sdk_line}a\\
\  flutter_localizations:\\
\    sdk: flutter
" "$target_pubspec"
                log_info "  已添加 flutter_localizations"
            fi
        fi
    fi

    # 自动升级 image 版本（3.x 与 connectivity_plus/webcrypto 有 ffi/xml 冲突）
    if grep -qE '^  image: [23]\.' "$target_pubspec" 2>/dev/null; then
        log_info "检测到 image 版本 < 4.0，升级以避免依赖冲突..."
        sed -i '' -E 's/^(  image:) [23]\.[0-9]+\.[0-9]+/\1 ^4.8.0/' "$target_pubspec"
        log_info "  已升级 image 到 ^4.8.0"
    fi

    log_success "pubspec.yaml 简化合并完成"
}

add_swift_file_to_xcode_project() {
    local pbxproj="$1"
    local filename="$2"
    local filename_no_ext="${filename%.swift}"

    # 检查文件是否已存在于项目中
    if grep -q "$filename" "$pbxproj" 2>/dev/null; then
        log_info "  $filename 已存在于 Xcode 项目中"
        return
    fi

    log_info "  将 $filename 添加到 Xcode 项目..."

    # 生成唯一的 UUID（简化版，使用文件名哈希）
    local uuid_base=$(echo -n "$filename" | md5 | cut -c1-24 | tr '[:lower:]' '[:upper:]')
    local file_ref_uuid="${uuid_base}DEF"
    local build_file_uuid="${uuid_base}ABC"

    # 1. 添加 PBXBuildFile 条目
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|/\* Begin PBXBuildFile section \*/|/* Begin PBXBuildFile section */\\
		${build_file_uuid} /* ${filename} in Sources */ = {isa = PBXBuildFile; fileRef = ${file_ref_uuid} /* ${filename} */; };|" "$pbxproj"
    else
        sed -i "s|/\* Begin PBXBuildFile section \*/|/* Begin PBXBuildFile section */\n\t\t${build_file_uuid} /* ${filename} in Sources */ = {isa = PBXBuildFile; fileRef = ${file_ref_uuid} /* ${filename} */; };|" "$pbxproj"
    fi

    # 2. 添加 PBXFileReference 条目
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|74858FAE1ED2DC5600515810 /\* AppDelegate.swift \*/ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = \"<group>\"; };|74858FAE1ED2DC5600515810 /* AppDelegate.swift */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = \"<group>\"; };\\
		${file_ref_uuid} /* ${filename} */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = ${filename}; sourceTree = \"<group>\"; };|" "$pbxproj"
    else
        sed -i "s|74858FAE1ED2DC5600515810 /\* AppDelegate.swift \*/ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = \"<group>\"; };|74858FAE1ED2DC5600515810 /* AppDelegate.swift */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = \"<group>\"; };\n\t\t${file_ref_uuid} /* ${filename} */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = ${filename}; sourceTree = \"<group>\"; };|" "$pbxproj"
    fi

    # 3. 添加到 Runner group 的 children
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|74858FAE1ED2DC5600515810 /\* AppDelegate.swift \*/,|74858FAE1ED2DC5600515810 /* AppDelegate.swift */,\\
				${file_ref_uuid} /* ${filename} */,|" "$pbxproj"
    else
        sed -i "s|74858FAE1ED2DC5600515810 /\* AppDelegate.swift \*/,|74858FAE1ED2DC5600515810 /* AppDelegate.swift */,\n\t\t\t\t${file_ref_uuid} /* ${filename} */,|" "$pbxproj"
    fi

    # 4. 添加到 Sources build phase
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|74858FAF1ED2DC5600515810 /\* AppDelegate.swift in Sources \*/,|74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */,\\
				${build_file_uuid} /* ${filename} in Sources */,|" "$pbxproj"
    else
        sed -i "s|74858FAF1ED2DC5600515810 /\* AppDelegate.swift in Sources \*/,|74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */,\n\t\t\t\t${build_file_uuid} /* ${filename} in Sources */,|" "$pbxproj"
    fi

    log_info "  $filename 已添加到 Xcode 项目"
}

show_summary() {
    echo ""
    echo "=============================================="
    echo "              同步摘要"
    echo "=============================================="
    echo ""
    echo "源项目: $PROJECT_NAME ($SOURCE_PATH)"
    echo "源包名: $SOURCE_PACKAGE"
    if [[ -n "$SOURCE_GIT_BRANCH" ]]; then
        echo "源 Git 分支: $SOURCE_GIT_BRANCH"
    fi
    if [[ -n "$SOURCE_GIT_UPSTREAM" ]]; then
        echo "源 Git 上游: $SOURCE_GIT_UPSTREAM"
    fi
    if [[ -n "$SOURCE_GIT_COMMIT" ]]; then
        echo "源 Git 提交: $SOURCE_GIT_COMMIT"
    fi
    echo "源 Git 工作区脏状态: $SOURCE_GIT_DIRTY"
    echo "混淆种子: (自动使用 iOS bundle id)"
    echo "目标位置:"
    echo "  - lib:      $TARGET_SIDE_B_DIR"
    echo "  - assets:   $TARGET_ASSETS_DIR"
    echo "  - iOS 配置: $TARGET_INFO_PLIST"

    if [[ -d "$SOURCE_PATH/plugins" ]]; then
        echo "  - plugins:  $TARGET_PLUGINS_DIR"
    fi

    if [[ -d "$SOURCE_PATH/flutter_base" ]]; then
        echo "  - flutter_base: $PROJECT_ROOT/flutter_base"
    fi

    echo ""

    # 统计文件数量
    if [[ -d "$TARGET_SIDE_B_DIR" ]] && [[ "$DRY_RUN" != "true" ]]; then
        local dart_count
        dart_count=$(find "$TARGET_SIDE_B_DIR" -name "*.dart" 2>/dev/null | wc -l | tr -d ' ')
        echo "Dart 文件数量: $dart_count"
    fi

    echo ""
}

# 记录当前项目配置到 ab_config.yaml（供后续脚本识别）
write_current_project() {
    if [[ "$DRY_RUN" == "true" ]]; then
        return
    fi

    local config_file="$PROJECT_ROOT/ab_config.yaml"
    local sync_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 生成 yaml 配置文件
    cat > "$config_file" << EOF
# AB包配置文件 - 由 sync_secondary.sh 自动生成
# 请勿手动修改，除非你知道自己在做什么

# 当前B面项目标识 (dq, lgt)
project: $PROJECT_NAME

# 源项目路径
source_path: $SOURCE_PATH

# 源项目包名
source_package: $SOURCE_PACKAGE

# 源项目 Git 信息（用于问题追踪）
source_git_branch: "$SOURCE_GIT_BRANCH"
source_git_upstream: "$SOURCE_GIT_UPSTREAM"
source_git_commit: "$SOURCE_GIT_COMMIT"
source_git_commit_short: "$SOURCE_GIT_COMMIT_SHORT"
source_git_commit_time: "$SOURCE_GIT_COMMIT_TIME"
source_git_dirty: $SOURCE_GIT_DIRTY

# 混淆种子（用于资源文件名混淆）
# 优先级: iOS bundle id > 项目名

# 同步时间
sync_time: "$sync_time"
EOF

    log_info "已更新配置文件: ab_config.yaml"
}

# 写入同步日志
write_sync_log() {
    if [[ "$DRY_RUN" == "true" ]]; then
        return
    fi

    local log_file="$PROJECT_ROOT/sync_secondary.log"
    local sync_time=$(date '+%Y-%m-%d %H:%M:%S')
    local dart_count=0

    if [[ -d "$TARGET_SIDE_B_DIR" ]]; then
        dart_count=$(find "$TARGET_SIDE_B_DIR" -name "*.dart" 2>/dev/null | wc -l | tr -d ' ')
    fi

    # 追加日志
    {
        echo "=============================================="
        echo "同步时间: $sync_time"
        echo "=============================================="
        echo "源项目: $PROJECT_NAME"
        echo "源路径: $SOURCE_PATH"
        echo "源包名: $SOURCE_PACKAGE"
        echo "源 Git 分支: $SOURCE_GIT_BRANCH"
        echo "源 Git 上游: $SOURCE_GIT_UPSTREAM"
        echo "源 Git 提交: $SOURCE_GIT_COMMIT"
        echo "源 Git 短提交: $SOURCE_GIT_COMMIT_SHORT"
        echo "源 Git 提交时间: $SOURCE_GIT_COMMIT_TIME"
        echo "源 Git 工作区脏状态: $SOURCE_GIT_DIRTY"
        echo "混淆种子: 自动(iOS bundle id)"
        echo ""
        echo "目标位置:"
        echo "  - lib:    $TARGET_SIDE_B_DIR"
        echo "  - assets: $TARGET_ASSETS_DIR"
        if [[ -d "$SOURCE_PATH/plugins" ]]; then
            echo "  - plugins: $TARGET_PLUGINS_DIR"
        fi
        if [[ -d "$SOURCE_PATH/flutter_base" ]]; then
            echo "  - flutter_base: $PROJECT_ROOT/flutter_base"
        fi
        echo ""
        echo "统计:"
        echo "  - Dart 文件数量: $dart_count"
        echo ""
        echo ""
    } >> "$log_file"

    log_success "同步日志已写入: $log_file"
}

# 清理并重装 CocoaPods，解决 Module not found 问题
run_pub_get() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将运行 fvm flutter pub get"
        return
    fi

    log_step "运行 fvm flutter pub get..."

    cd "$PROJECT_ROOT"
    if fvm flutter pub get 2>/dev/null; then
        log_success "依赖更新完成"
    else
        log_warning "fvm flutter pub get 失败，请手动运行"
    fi
}

# 清理 Flutter iOS 构建缓存
# 场景：同步后依赖图、插件链路、native assets 可能发生变化，
# 仅运行 pub get 不足以让 objective_c 等动态库重新正确打包进 Runner.app。
invalidate_flutter_ios_build_cache() {
    local paths_to_clear=(
        "$PROJECT_ROOT/.dart_tool/flutter_build"
        "$PROJECT_ROOT/.dart_tool/hooks_runner"
        "$PROJECT_ROOT/build/ios"
        "$PROJECT_ROOT/ios/Flutter/ephemeral"
        "$PROJECT_ROOT/ios/.symlinks"
    )
    local removed_count=0
    local path=""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将清理 Flutter iOS 构建缓存"
        for path in "${paths_to_clear[@]}"; do
            if [[ -e "$path" ]]; then
                log_info "  [DRY-RUN] 删除: ${path#$PROJECT_ROOT/}"
            fi
        done
        return
    fi

    log_step "清理 Flutter iOS 构建缓存..."

    for path in "${paths_to_clear[@]}"; do
        if [[ -e "$path" ]]; then
            rm -rf "$path"
            removed_count=$((removed_count + 1))
            log_info "  已删除: ${path#$PROJECT_ROOT/}"
        fi
    done

    if [[ "$removed_count" -gt 0 ]]; then
        log_success "已清理 $removed_count 个缓存目录"
    else
        log_info "未发现需要清理的 Flutter iOS 构建缓存"
    fi
}

# =============================================
# fijkplayer（IJK 播放器，BIJKPlayer pod）专项处理
# 适用项目：B 面以本地 fork plugins/fijkplayer 提供播放器的工程（如 dq 斗球/直播）。
#   dq 的 B 面无 flutter_base；fijkplayer 位于 plugins/fijkplayer，源 pubspec 在
#   dependencies 中以 `fijkplayer: path: ./plugins/fijkplayer/` 声明。
# 背景：原生插件必须落在 dependencies（而非仅 dependency_overrides），否则不会写入
#       GeneratedPluginRegistrant → MissingPluginException；且合并链路有时会把它降级成
#       dependency_overrides 里的空条目（无 path）导致解析失败。这里强制把 fijkplayer
#       规整到 dependencies 且 path 指向本地 plugins/fijkplayer，并校验 Dart/ObjC 的
#       MethodChannel/EventChannel（befovy.com/fijk*）保持一致，否则播放器静默失效。
# =============================================
project_needs_fijkplayer_override() {
    local project="$1"
    [[ "$project" == "dq" ]]
}

# 规整 pubspec 的 fijkplayer：确保位于 dependencies 且 path 指向本地 plugins/fijkplayer
ensure_fijkplayer_local_override() {
    project_needs_fijkplayer_override "$PROJECT_NAME" || return 0

    local target_pubspec="$PROJECT_ROOT/pubspec.yaml"
    local fijk_dir="$PROJECT_ROOT/plugins/fijkplayer"

    [[ -f "$target_pubspec" ]] || return 0

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将确保 fijkplayer 位于 dependencies 且 path: plugins/fijkplayer"
        return 0
    fi

    if [[ ! -d "$fijk_dir" ]]; then
        log_warning "plugins/fijkplayer 不存在，无法规整 fijkplayer 本地依赖"
        return 0
    fi

    python3 - "$target_pubspec" <<'PY'
from pathlib import Path
import re
import sys

pubspec = Path(sys.argv[1])
lines = pubspec.read_text().splitlines()

def section_bounds(name):
    start = None
    for idx, line in enumerate(lines):
        if line.rstrip() == f"{name}:" and not line.startswith(" "):
            start = idx
            break
    if start is None:
        return None, None
    end = len(lines)
    for idx in range(start + 1, len(lines)):
        ln = lines[idx]
        if ln and not ln.startswith(" ") and re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:", ln):
            end = idx
            break
    return start, end

def remove_dep(section, dep):
    start, end = section_bounds(section)
    if start is None:
        return
    block = lines[start + 1:end]
    new_block = []
    j = 0
    while j < len(block):
        ln = block[j]
        stripped = ln.lstrip(" ")
        indent = len(ln) - len(stripped)
        name = stripped.split(":", 1)[0]
        if indent == 2 and name == dep:
            j += 1
            # 吞掉其下的嵌套行（缩进 > 2 的非空行），保留空行/下一条依赖
            while j < len(block):
                nx = block[j]
                if nx.strip() == "":
                    break
                nxi = len(nx) - len(nx.lstrip(" "))
                if nxi <= 2:
                    break
                j += 1
            continue
        new_block.append(ln)
        j += 1
    lines[start + 1:end] = new_block

# 1) 清掉任何位置（dependency_overrides / dependencies）的旧 fijkplayer 条目
remove_dep("dependency_overrides", "fijkplayer")
remove_dep("dependencies", "fijkplayer")

# 2) 重新写入 dependencies，path 指向本地 plugins/fijkplayer
start, end = section_bounds("dependencies")
if start is None:
    raise SystemExit("pubspec.yaml 缺少 dependencies 段")

seg = lines[start + 1:end]
while seg and seg[-1].strip() == "":
    seg.pop()
seg.extend([
    "  fijkplayer:",
    "    path: plugins/fijkplayer",
])
lines[start + 1:end] = seg

pubspec.write_text("\n".join(lines).rstrip() + "\n")
PY

    log_success "已确保 fijkplayer 位于 dependencies 且 path: plugins/fijkplayer"
}

# 从 Podfile.lock 找出仍引用 BIJKPlayer 的旧 fijkplayer pod 名（若已是本地 fijkplayer 则返回空）
get_stale_fijkplayer_pod_name() {
    local pod_lock="$PROJECT_ROOT/ios/Podfile.lock"
    [[ -f "$pod_lock" ]] || return 0

    if grep -qE '(^  - fijkplayer \(|\.symlinks/plugins/fijkplayer/ios)' "$pod_lock"; then
        return 0
    fi

    if grep -q 'BIJKPlayer' "$pod_lock"; then
        awk '
            /^  - [A-Za-z0-9_.-]+ \(/ {
                pod = $2
                sub(/\(.*/, "", pod)
            }
            /BIJKPlayer/ && pod != "" {
                print pod
                exit
            }
        ' "$pod_lock"
    fi
}

# 若 Podfile.lock 仍是旧的 BIJKPlayer pod，则刷新 iOS Pods
refresh_fijkplayer_ios_pods_if_needed() {
    project_needs_fijkplayer_override "$PROJECT_NAME" || return 0

    local stale_pod
    stale_pod=$(get_stale_fijkplayer_pod_name)
    [[ -n "$stale_pod" ]] || return 0

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Podfile.lock 仍包含旧 fijkplayer Pod: ${stale_pod}，将运行 pod install 刷新 iOS Pods"
        return 0
    fi

    if [[ ! -d "$PROJECT_ROOT/ios" ]]; then
        log_warning "iOS 目录不存在，无法刷新 fijkplayer Pods"
        return 0
    fi

    if ! command -v pod >/dev/null 2>&1; then
        log_warning "pod 命令不可用，请手动运行: cd ios && pod install"
        return 0
    fi

    log_step "刷新 fijkplayer iOS Pods（旧 Pod: $stale_pod）..."
    if (cd "$PROJECT_ROOT/ios" && pod install >/dev/null 2>&1); then
        log_success "fijkplayer iOS Pods 已刷新"
    else
        log_warning "pod install 失败，请手动运行: cd ios && pod install"
    fi
}

# 校验 fijkplayer 的 Dart/ObjC channel 文件、iOS 插件路径与 Podfile.lock
verify_fijkplayer_channel() {
    project_needs_fijkplayer_override "$PROJECT_NAME" || return 0

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将校验 fijkplayer Dart/ObjC channel 文件、iOS 插件路径与 Podfile.lock"
        return 0
    fi

    local fijk_dir="$PROJECT_ROOT/plugins/fijkplayer"
    if [[ ! -d "$fijk_dir" ]]; then
        log_warning "fijkplayer 校验跳过: plugins/fijkplayer 不存在"
        return 0
    fi

    local dart_plugin="$fijk_dir/lib/core/fijkplugin.dart"
    local dart_player="$fijk_dir/lib/core/fijkplayer.dart"
    local objc_plugin="$fijk_dir/ios/Classes/FijkPlugin.m"
    local objc_player="$fijk_dir/ios/Classes/FijkPlayer.m"
    local ok=true

    if [[ ! -f "$dart_plugin" || ! -f "$dart_player" ]]; then
        log_warning "fijkplayer 校验: Dart channel 文件不完整"
        ok=false
    fi
    if [[ ! -f "$objc_plugin" || ! -f "$objc_player" ]]; then
        log_warning "fijkplayer 校验: iOS ObjC channel 文件不完整"
        ok=false
    fi

    if [[ -f "$dart_plugin" ]] && ! grep -q 'befovy.com/fijk' "$dart_plugin"; then
        log_warning "fijkplayer 校验: Dart 插件 channel 字符串缺失"
        ok=false
    fi
    if [[ -f "$dart_player" ]] && ! grep -q 'befovy.com/fijkplayer/' "$dart_player"; then
        log_warning "fijkplayer 校验: Dart player channel 字符串缺失"
        ok=false
    fi
    if [[ -f "$objc_plugin" ]] && ! grep -q 'befovy.com/fijk' "$objc_plugin"; then
        log_warning "fijkplayer 校验: ObjC 插件 channel 字符串缺失"
        ok=false
    fi
    if [[ -f "$objc_player" ]] && ! grep -q 'befovy.com/fijkplayer/' "$objc_player"; then
        log_warning "fijkplayer 校验: ObjC player channel 字符串缺失"
        ok=false
    fi

    local plugins_file="$PROJECT_ROOT/.flutter-plugins-dependencies"
    if [[ -f "$plugins_file" ]]; then
        local plugin_path
        plugin_path=$(python3 - "$plugins_file" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for plugin in data.get("plugins", {}).get("ios", []):
    if plugin.get("name") == "fijkplayer":
        print(plugin.get("path") or "")
        break
PY
)
        if [[ "$plugin_path" == "$PROJECT_ROOT/plugins/fijkplayer/" || "$plugin_path" == "$PROJECT_ROOT/plugins/fijkplayer" ]]; then
            log_success "fijkplayer iOS 插件路径已指向 plugins/fijkplayer"
        else
            log_warning "fijkplayer iOS 插件路径异常: ${plugin_path:-未找到}，预期 plugins/fijkplayer"
            ok=false
        fi
    else
        log_warning ".flutter-plugins-dependencies 不存在，无法校验 fijkplayer iOS 插件路径"
        ok=false
    fi

    local pod_lock="$PROJECT_ROOT/ios/Podfile.lock"
    if [[ -f "$pod_lock" ]]; then
        if grep -qE '(^  - fijkplayer \(|\.symlinks/plugins/fijkplayer/ios)' "$pod_lock"; then
            log_success "Podfile.lock 已包含 fijkplayer Pod"
        elif grep -q 'BIJKPlayer' "$pod_lock"; then
            local stale_pod
            stale_pod=$(get_stale_fijkplayer_pod_name)
            log_warning "Podfile.lock 未包含 fijkplayer，但仍包含 BIJKPlayer（可能来自旧 Pod: ${stale_pod:-未知}）；请刷新 iOS Pods，否则 Dart/ObjC 可能实际来自不同插件"
            ok=false
        fi
    else
        log_info "Podfile.lock 不存在，首次 pod install / iOS 构建时会生成"
    fi

    if [[ "$ok" == "true" ]]; then
        log_success "fijkplayer channel 校验通过（Dart 与 iOS ObjC 均已迁移）"
    fi
}

# 主函数
main() {
    echo "=============================================="
    echo "       次要模块代码同步脚本"
    echo "=============================================="
    echo ""

    # 先加载配置文件
    load_config

    parse_args "$@"
    if [[ "$KEEP_SECONDARY_IMAGES" == "true" ]]; then
        DELETE_SECONDARY_IMAGES=false
    fi
    source_compat_file

    # 启动日志记录
    setup_log "$PROJECT_NAME"

    log_info "壳工程根目录 (PROJECT_ROOT): $PROJECT_ROOT"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "模拟运行模式，不会实际修改文件"
        echo ""
    fi

    validate_source
    update_source_repo
    backup_current
    sync_lib
    replace_package_imports       # 核心：替换包名
    fix_absolute_path_imports     # 修复绝对路径导入（以 / 开头）
    fix_existing_relative_imports # 修复已有的相对路径
    update_assets_paths           # 更新 assets 路径
    sync_assets
    # 源项目含 flutter_base 包时，Base64 支持 Dart 需要同时写入该包内
    sync_flutter_base
    #optimize_secondary_images     # 压缩优化图片资源（减小包体积）
    # 暂时禁用：资源文件名混淆（避免 obfuscate_asset_filenames 出现误替换/误改字符串的问题）
    # 典型问题：不应影响 Dart 代码里的 JSON key，如 json["share"]。
    log_warning "已跳过资源文件名混淆（obfuscate_asset_filenames 已暂时禁用）"
    # 项目专用：base64 图谱生成【前】中和敏感命名的栅格图（须早于 map 生成，
    # 保证 map key 用中性名哈希，运行时引用改写后仍能命中）。
    local pre_b64_func="pre_base64_${PROJECT_NAME}"
    if type -t "$pre_b64_func" &>/dev/null; then
        log_step "运行 base64 前置中和（$pre_b64_func）..."
        "$pre_b64_func" "$TARGET_SIDE_B_DIR" || true
    fi
    generate_secondary_base64_map # 生成图片 Base64 映射（默认开启）
    ensure_base64_support_darts   # 按需写入 base_hh_image / secondary_image_base64_ext
    patch_secondary_my_asset_image_to_base64 # MyAssetImage 优先走 Base64 映射（避免删图后 bundle 读不到）
    replace_image_asset_entries   # 批量替换图片入口组件（可选）
    replace_asset_image_providers # 批量替换 AssetImage/ExactAssetImage（Base64 下的 DecorationImage 等场景）
    type -t create_md_assets_symlinks &>/dev/null && create_md_assets_symlinks
    sync_plugins                  # 须在 merge_pubspec 前完成，供 path override 解析 plugins/
    sync_ios_permissions          # 同步 iOS 权限配置
    sync_ios_podfile              # 同步 iOS Podfile 配置（解决 iOS 18.5 libswiftWebKit 问题）
    generate_entry_file
    fix_flutter_api_compatibility # 修复 Flutter API 兼容性问题
    # 项目专用兼容修复（由 compat_*.sh 定义）
    local compat_func="fix_${PROJECT_NAME}_compatibility"
    if type -t "$compat_func" &>/dev/null; then
        log_step "运行项目专用兼容修复..."
        "$compat_func" "$TARGET_SIDE_B_DIR" "$TARGET_PLUGINS_DIR" || true
    fi
    init_pubspec_from_template    # 从模板初始化 pubspec.yaml
    merge_pubspec                 # 自动合并 pubspec.yaml
    sync_sdk_version              # 同步 SDK 和 lints 版本（需在模板重置后执行，避免被覆盖）
    type -t add_flutter_base_dependency &>/dev/null && add_flutter_base_dependency
    type -t add_md_assets_paths_to_pubspec &>/dev/null && add_md_assets_paths_to_pubspec
    local compat_pubspec_func="apply_${PROJECT_NAME}_pubspec_overrides"
    if type -t "$compat_pubspec_func" &>/dev/null; then
        log_step "写入项目专用 pubspec 覆盖..."
        "$compat_pubspec_func" "$PROJECT_ROOT/pubspec.yaml" || true
    fi
    ensure_fijkplayer_local_override          # 规整 fijkplayer 到 dependencies 且 path: plugins/fijkplayer（须在 pub get 前）
    trim_pubspec_trailing_whitespace "$PROJECT_ROOT/pubspec.yaml"  # 合并自 zeus 上游：清理 pubspec 行尾空白
    show_summary
    write_current_project         # 记录当前项目名
    write_sync_log                # 写入同步日志

    run_pub_get
    local compat_post_pub_get_func="post_pub_get_${PROJECT_NAME}_compatibility"
    if type -t "$compat_post_pub_get_func" &>/dev/null; then
        log_step "运行 pub get 后项目专用修复..."
        "$compat_post_pub_get_func" || true
    fi
    refresh_fijkplayer_ios_pods_if_needed     # 若 Podfile.lock 仍是旧 BIJKPlayer pod 则刷新
    verify_fijkplayer_channel                 # 校验 Dart/ObjC channel 与插件路径一致（plugins/fijkplayer）
    invalidate_flutter_ios_build_cache
    type -t clean_and_reinstall_pods &>/dev/null && clean_and_reinstall_pods

    delete_secondary_image_files
    ensure_asset_dir_placeholders             # 给清空后的资源目录补 .gitkeep（避免全新 clone/CI 报 unable to find directory entry）

    echo ""
    log_success "========================================"
    log_success "同步完成！"
    log_success "========================================"
    echo ""
    echo "后续步骤:"
    echo "  1. 检查 lib/modules/secondary/module_entry.dart 入口文件"
    echo "  2. 检查 pubspec.yaml 合并结果"
    echo "  3. 检查 ios/Runner/Info.plist 权限配置"
    echo "  4. 运行 fvm flutter run"
    echo "  5. 运行 fvm flutter analyze 检查错误"
    echo "  6. 运行 fvm flutter build ios 测试构建"

    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        echo ""
        log_info "日志已保存: $LOG_FILE"
    fi
}

main "$@"
