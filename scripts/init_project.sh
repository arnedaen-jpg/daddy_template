#!/bin/bash

# ============================================================
# 项目初始化脚本
# 用于初始化新的 AB 包项目
# ============================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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

# 显示帮助
show_help() {
    echo "使用方法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -n, --name NAME          应用名称"
    echo "  -p, --package PACKAGE    包名 (如: com.example.app)"
    echo "  -d, --display NAME       显示名称 (iOS/Android 显示的名称)"
    echo "  -h, --help               显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 -n my_app -p com.mycompany.myapp -d \"My App\""
}

# 主函数
main() {
    local app_name=""
    local package_name=""
    local display_name=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)
                app_name="$2"
                shift 2
                ;;
            -p|--package)
                package_name="$2"
                shift 2
                ;;
            -d|--display)
                display_name="$2"
                shift 2
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

    if [[ -z "$app_name" || -z "$package_name" ]]; then
        log_error "必须提供应用名称和包名"
        show_help
        exit 1
    fi

    if [[ -z "$display_name" ]]; then
        display_name="$app_name"
    fi

    log_info "初始化项目..."
    log_info "应用名称: $app_name"
    log_info "包名: $package_name"
    log_info "显示名称: $display_name"

    # 更新 pubspec.yaml
    log_info "更新 pubspec.yaml..."
    sed -i '' "s/^name: .*/name: $app_name/" "$PROJECT_ROOT/pubspec.yaml"

    # 更新 app_config.dart
    log_info "更新应用配置..."
    sed -i '' "s/static const String appName = .*/static const String appName = '$display_name';/" \
        "$PROJECT_ROOT/lib/config/app_config.dart"

    log_success "项目初始化完成！"
    echo ""
    echo "后续步骤:"
    echo "  1. 修改 iOS Bundle Identifier: 打开 ios/Runner.xcodeproj"
    echo "  2. 修改 Android applicationId: 编辑 android/app/build.gradle"
    echo "  3. 配置远程 API 地址: 编辑 lib/config/app_config.dart"
    echo "  4. 开发 A 面功能: 编辑 lib/modules/side_a/"
    echo "  5. 运行 flutter pub get"
}

main "$@"
