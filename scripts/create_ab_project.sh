#!/bin/bash

# ============================================================
# AB 包项目创建脚本
# 一键复制 daddy_template 到新项目并配置 name 和 bundle id
# ============================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$TEMPLATE_DIR")"

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
    echo "  -n, --name NAME          项目名称 (如: my_app, 用于文件夹名和 Flutter 项目名)"
    echo "  -b, --bundle BUNDLE_ID   iOS Bundle Identifier (如: com.example.myapp)"
    echo "  -d, --display NAME       显示名称 (iOS 桌面显示的名称，可选，默认使用项目名称)"
    echo "  -o, --output DIR         输出目录 (可选，默认为模板的同级目录)"
    echo "  -h, --help               显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 -n my_app -b com.mycompany.myapp"
    echo "  $0 -n my_app -b com.mycompany.myapp -d \"My App\""
    echo "  $0 -n my_app -b com.mycompany.myapp -o /path/to/output"
    echo ""
    echo "说明:"
    echo "  此脚本会将 daddy_template 复制到同级目录，并自动完成以下配置："
    echo "  1. 重命名项目文件夹"
    echo "  2. 更新 pubspec.yaml 中的项目名称"
    echo "  3. 更新 iOS Bundle Identifier"
    echo "  4. 更新 iOS 显示名称"
    echo "  5. 更新应用配置文件"
    echo "  6. 清理 git 历史和构建缓存"
}

# 验证项目名称格式 (小写字母、数字、下划线)
validate_project_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z][a-z0-9_]*$ ]]; then
        log_error "项目名称格式无效: $name"
        log_error "项目名称必须以小写字母开头，只能包含小写字母、数字和下划线"
        exit 1
    fi
}

# 与 pub.dev 包名或 Flutter 工具链冲突的名称（会导致 flutter run 失败，如 No application found for TargetPlatform.ios）
validate_reserved_project_name() {
    local name="$1"
    case "$name" in
        test|flutter|flutter_test|dart|example|sample|version|pub|meta|collection|async)
            log_error "项目名称不能使用保留或易冲突名称: $name"
            log_error "请改用例如 my_app、test_app、demo_one 等"
            exit 1
            ;;
    esac
}

# 验证 Bundle ID 格式
validate_bundle_id() {
    local bundle_id="$1"
    if [[ ! "$bundle_id" =~ ^[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z][a-zA-Z0-9]*)+$ ]]; then
        log_error "Bundle ID 格式无效: $bundle_id"
        log_error "Bundle ID 格式示例: com.example.myapp"
        exit 1
    fi
}

# 主函数
main() {
    local project_name=""
    local bundle_id=""
    local display_name=""
    local output_dir=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)
                project_name="$2"
                shift 2
                ;;
            -b|--bundle)
                bundle_id="$2"
                shift 2
                ;;
            -d|--display)
                display_name="$2"
                shift 2
                ;;
            -o|--output)
                output_dir="$2"
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

    # 验证必填参数
    if [[ -z "$project_name" || -z "$bundle_id" ]]; then
        log_error "必须提供项目名称 (-n) 和 Bundle ID (-b)"
        show_help
        exit 1
    fi

    # 验证格式
    validate_project_name "$project_name"
    validate_reserved_project_name "$project_name"
    validate_bundle_id "$bundle_id"

    # 设置默认值
    if [[ -z "$display_name" ]]; then
        display_name="$project_name"
    fi

    if [[ -z "$output_dir" ]]; then
        output_dir="$PARENT_DIR"
    fi

    local new_project_path="$output_dir/$project_name"

    # 检查目标目录是否已存在
    if [[ -d "$new_project_path" ]]; then
        log_error "目标目录已存在: $new_project_path"
        exit 1
    fi

    echo ""
    log_info "=========================================="
    log_info "创建新的 AB 包项目"
    log_info "=========================================="
    log_info "项目名称: $project_name"
    log_info "Bundle ID: $bundle_id"
    log_info "显示名称: $display_name"
    log_info "目标路径: $new_project_path"
    echo ""

    # 步骤 1: 复制模板
    log_info "[1/7] 复制模板项目..."
    cp -R "$TEMPLATE_DIR" "$new_project_path"

    # 步骤 2: 清理不需要的文件
    log_info "[2/7] 清理缓存和临时文件..."
    rm -rf "$new_project_path/.git"
    rm -rf "$new_project_path/.dart_tool"
    rm -rf "$new_project_path/.idea"
    rm -rf "$new_project_path/build"
    rm -rf "$new_project_path/ios/.symlinks"
    rm -rf "$new_project_path/ios/Pods"
    rm -rf "$new_project_path/ios/Podfile.lock"
    rm -rf "$new_project_path/pubspec.lock"
    rm -rf "$new_project_path/.DS_Store"
    rm -rf "$new_project_path/.flutter-plugins-dependencies"

    # 修改 .gitignore (注释掉 B 面相关的忽略规则，以便新项目可以提交这些代码)
    log_info "更新 .gitignore 配置..."
    if [[ -f "$new_project_path/.gitignore" ]]; then
        sed -i '' 's|^lib/modules/secondary/\*$|# lib/modules/secondary/*|' "$new_project_path/.gitignore"
        sed -i '' 's|^!lib/modules/secondary/module_entry\.dart$|# !lib/modules/secondary/module_entry.dart|' "$new_project_path/.gitignore"
        sed -i '' 's|^assets/$|# assets/|' "$new_project_path/.gitignore"
        sed -i '' 's|^plugins/$|# plugins/|' "$new_project_path/.gitignore"
    fi

    # 步骤 3: 更新 pubspec.yaml / pubspec.yaml.template
    log_info "[3/7] 更新 pubspec 配置..."
    sed -i '' "s/^name: .*/name: $project_name/" "$new_project_path/pubspec.yaml"
    sed -i '' "s/^description: .*/description: A new Flutter project/" "$new_project_path/pubspec.yaml"
    sed -i '' "s/daddy_template/$project_name/g" "$new_project_path/pubspec.yaml"
    if [[ -f "$new_project_path/pubspec.yaml.template" ]]; then
        sed -i '' "s/^name: .*/name: $project_name/" "$new_project_path/pubspec.yaml.template"
        sed -i '' "s/^description: .*/description: A new Flutter project/" "$new_project_path/pubspec.yaml.template"
        sed -i '' "s/daddy_template/$project_name/g" "$new_project_path/pubspec.yaml.template"
    fi

    # 必须与 pubspec 的 name 一致，否则 flutter run 报错（如 No application found for TargetPlatform.ios）
    for _pkg_dir in "$new_project_path/lib" "$new_project_path/test"; do
        if [[ -d "$_pkg_dir" ]]; then
            find "$_pkg_dir" -name "*.dart" -exec sed -i '' "s/package:daddy_template/package:${project_name}/g" {} +
        fi
    done

    # 步骤 4: 更新 iOS Bundle Identifier
    log_info "[4/7] 更新 iOS Bundle Identifier..."

    # 更新 project.pbxproj 中的主应用 Bundle ID
    sed -i '' "s/com.daddy.template/$bundle_id/g" "$new_project_path/ios/Runner.xcodeproj/project.pbxproj"

    # 更新测试目标的 Bundle ID
    sed -i '' "s/com.example.daddyTemplate.RunnerTests/${bundle_id}.RunnerTests/g" "$new_project_path/ios/Runner.xcodeproj/project.pbxproj"

    # 步骤 5: 更新 iOS Info.plist
    log_info "[5/7] 更新 iOS 配置 (显示名称、URL Scheme)..."
    # 更新 CFBundleDisplayName
    sed -i '' "s/<string>Daddy Template<\/string>/<string>$display_name<\/string>/" "$new_project_path/ios/Runner/Info.plist"
    # 更新 CFBundleName
    sed -i '' "s/<string>daddy_template<\/string>/<string>$project_name<\/string>/" "$new_project_path/ios/Runner/Info.plist"
    # 更新 URL Scheme 为 bundle ID
    sed -i '' "s/<string>com.daddy.template<\/string>/<string>$bundle_id<\/string>/" "$new_project_path/ios/Runner/Info.plist"

    # 步骤 6: 更新应用配置
    log_info "[6/7] 更新应用配置..."
    sed -i '' "s/static const String appName = .*/static const String appName = '$display_name';/" \
        "$new_project_path/lib/config/app_config.dart"

    # 更新 .iml 文件名
    if [[ -f "$new_project_path/daddy_template.iml" ]]; then
        mv "$new_project_path/daddy_template.iml" "$new_project_path/${project_name}.iml"
    fi

    # 步骤 7: 初始化新的 git 仓库
    log_info "[7/7] 初始化 Git 仓库..."
    cd "$new_project_path"
    git init -q
    git add .
    git commit -q -m "Initial commit from daddy_template"

    echo ""
    log_success "=========================================="
    log_success "项目创建成功！"
    log_success "=========================================="
    echo ""
    echo "项目路径: $new_project_path"
    echo ""
    echo "后续步骤:"
    echo "  1. cd $new_project_path"
    echo "  2. flutter pub get"
    echo "  3. cd ios && pod install && cd .."
    echo "  4. flutter run"
    echo ""
    echo "配置文件:"
    echo "  - 应用配置: lib/config/app_config.dart"
    echo "  - 环境配置: lib/config/env_config.dart"
    echo "  - A 面代码: lib/modules/primary/"
    echo "  - B 面代码: lib/modules/secondary/"
    echo ""
}

main "$@"
