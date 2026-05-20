# Daddy Template - Flutter AB 包模板工程

用于生成 Flutter AB 包的模板工程，支持 iOS 平台上架。

## 项目结构

```
lib/
├── main.dart                    # 应用入口
├── config/
│   ├── app_config.dart          # 应用配置
│   └── env_config.dart          # 环境配置
├── services/
│   └── ab_switch_service.dart   # AB 切换服务
├── router/
│   └── app_router.dart          # 动态路由管理
├── modules/
│   ├── side_a/                  # A 面（审核面）
│   │   └── pages/
│   │       └── home_page_a.dart
│   └── side_b/                  # B 面（业务面）
│       ├── side_b_entry.dart    # B 面入口（模板文件，同步后会被覆盖）
│       └── ...                  # 同步的 B 面代码（git 忽略）
├── widgets/                     # 公共组件
├── utils/                       # 工具类
└── core/                        # 核心模块

scripts/
├── sync_secondary.sh              # B 面代码同步脚本
├── sync_secondary.conf            # 同步脚本配置文件（git 忽略）
├── init_pubspec.sh             # pubspec.yaml 初始化脚本
└── create_ab_project.sh        # 项目创建脚本

pubspec.yaml.template           # pubspec.yaml 模板（git 管理）
pubspec.yaml                    # 生成的 pubspec.yaml（git 忽略）
```

## 工作原理

### AB 面切换

1. 应用启动时，`ABSwitchService` 从远程接口获取配置
2. 根据配置决定显示 A 面还是 B 面
3. 定时轮询远程接口，实现动态切换

### 远程接口格式

```json
{
  "show_side_b": true,
  "version": "1.0.0",
  "extra": {}
}
```

- `show_side_b`: `true` 显示 B 面，`false` 显示 A 面

## 快速开始

### 1. 初始化项目

```bash
./scripts/create_ab_project.sh -n my_app -b com.mycompany.myapp -d "My App"
```

### 2. 配置远程接口

编辑 `lib/config/app_config.dart`：

```dart
static const String remoteConfigUrl = 'https://your-api.com/api/config';
```

编辑 `lib/config/env_config.dart` 配置各环境 API 地址。

### 3. 开发 A 面

在 `lib/modules/side_a/` 目录下开发审核面功能。

### 4. 配置同步脚本

```bash
# 生成配置文件模板
./scripts/sync_secondary.sh --init-config

# 编辑配置文件，设置 B 面项目本地路径
vim scripts/sync_secondary.conf
```

### 5. 同步 B 面代码

```bash
# 使用配置文件中的路径同步
./scripts/sync_secondary.sh -p ph      # Sync pornhub_app project
./scripts/sync_secondary.sh -p hjsq    # Sync hjsq project
./scripts/sync_secondary.sh -p md      # Sync md project

# 或从命令行指定路径
./scripts/sync_secondary.sh -p ph -s /path/to/pornhub_app

# 或指定B包路徑跟包名
./scripts/sync_secondary.sh -s ~/b_51pc -n chaguaner2023
```

### 6. 构建发布

```bash
fvm flutter build ios --release
```

## 脚本使用

### sync_secondary.sh - B 面代码同步

从本地 B 面项目同步代码到模板工程。脚本会自动处理：
- 复制代码文件
- 替换包名导入为相对路径
- 同步 assets 资源
- 从模板初始化 pubspec.yaml
- 合并 pubspec.yaml 依赖
- 同步 SDK 版本（解决 Dart 3.7+ wildcard 变量兼容性问题）
- 写入同步日志

#### 首次使用

```bash
# 生成配置文件模板
./scripts/sync_secondary.sh --init-config

# 编辑配置文件，设置项目本地路径
vim scripts/sync_secondary.conf
```

配置文件示例 (`scripts/sync_secondary.conf`)：

```bash
# 项目路径配置
PROJECT_HJSQ="/path/to/hjsq"
PROJECT_MD="/path/to/md-android-client"
PROJECT_PH="/path/to/pornhub_app"

# 项目包名配置（通常不需要修改）
PACKAGE_HJSQ="hjsq"
PACKAGE_MD="mdgetx_client"
PACKAGE_PH="pornhub_app"
```

#### 使用配置文件同步

```bash
# 同步 pornhub_app 项目
./scripts/sync_secondary.sh -p ph

# 同步 hjsq 项目
./scripts/sync_secondary.sh -p hjsq

# 同步 md-android-client 项目
./scripts/sync_secondary.sh -p md

# 查看所有预设项目状态
./scripts/sync_secondary.sh -l
```

#### 使用命令行路径同步

```bash
# 指定项目代码和源路径
./scripts/sync_secondary.sh -p ph -s /path/to/pornhub_app
```

#### 模拟运行

```bash
# 不实际修改文件，只显示将执行的操作
./scripts/sync_secondary.sh -p ph -d
```

#### 参数说明

| 参数 | 说明 |
|------|------|
| `-p, --project NAME` | **必需** - 项目代码 (hjsq, md, ph) |
| `-s, --source PATH` | 源项目路径（可选，覆盖配置文件） |
| `-n, --package NAME` | 源项目包名（可选，默认从 pubspec.yaml 读取） |
| `-l, --list` | 列出预设项目配置状态 |
| `-d, --dry-run` | 模拟运行，不实际复制文件 |
| `--init-config` | 生成配置文件模板 |
| `-h, --help` | 显示帮助信息 |

#### 脚本执行流程

1. **加载配置文件** - 从 `scripts/sync_secondary.conf` 加载项目路径配置
2. **验证源项目** - 检查项目路径和结构
3. **备份当前代码** - 备份到 `backups/` 目录
4. **同步 lib 代码** - 复制所有 Dart 文件
5. **替换包名导入** - 将 `package:xxx/` 替换为相对路径
6. **修复相对路径** - 修复源项目中已有的相对路径导入
7. **更新 assets 路径** - 将 `assets/` 更新为 `assets/side_b/`
8. **同步 assets 资源** - 复制资源文件
9. **同步 plugins** - 复制插件（如有）
10. **生成入口文件** - 生成 `side_b_entry.dart`
11. **同步 SDK 版本** - 从源项目同步 SDK 和 flutter_lints 版本
12. **从模板初始化 pubspec.yaml** - 先重置到模板状态
13. **合并 pubspec.yaml** - 合并依赖和 assets 声明
14. **写入同步日志** - 记录到 `sync_secondary.log`
15. **运行 fvm flutter pub get** - 更新依赖

### init_pubspec.sh - pubspec.yaml 初始化

从模板重置 pubspec.yaml（移除 B 面依赖）。

```bash
./scripts/init_pubspec.sh
```

### create_ab_project.sh - 项目初始化

初始化新项目，修改应用名称和包名。

```bash
./scripts/create_ab_project.sh -n app_name -p com.example.app -d "Display Name"
```

## B 面代码要求

B 面项目需要是标准的 Flutter 项目结构：

```
your_b_side_project/
├── lib/                     # 代码目录
│   ├── main.dart           # 入口文件
│   └── ...                 # 其他代码
├── assets/                  # 资源目录（可选）
└── pubspec.yaml            # 依赖配置
```

同步后脚本会自动生成 `side_b_entry.dart` 入口文件，提供：

```dart
class SideBEntry {
  static Widget getHomePage() => const MainApp();
  static Future<void> initialize() async { ... }
  static Map<String, WidgetBuilder> getRoutes() => { ... };
}
```

## 注意事项

1. **A 面开发**：每个 AB 包的 A 面功能都不一样，需要开发者自由发挥，以通过审核为目标
2. **B 面同步**：B 面代码通过脚本从本地项目同步，请勿直接修改 `lib/modules/side_b/` 下的代码（除 `side_b_entry.dart` 模板外）
3. **Git 忽略**：B 面代码、assets、pubspec.yaml、lock 文件、配置文件均被 git 忽略
4. **pubspec.yaml 管理**：使用 `pubspec.yaml.template` 作为基础模板，同步脚本会自动从模板初始化再合并依赖
5. **SDK 版本**：脚本会自动同步源项目的 SDK 版本，避免 Dart 3.7+ wildcard 变量兼容性问题
6. **入口文件**：`side_b_entry.dart` 由脚本自动生成，无需手动维护
7. **接口安全**：远程配置接口建议添加安全验证
8. **默认配置**：网络不可用时默认显示 A 面
9. **同步日志**：同步信息记录在 `sync_secondary.log`，可查看历史同步记录
10. **FVM**：项目使用 FVM 管理 Flutter 版本，请使用 `fvm flutter` 命令运行

## 常用命令

```bash
# 安装依赖
fvm flutter pub get

# 运行应用
fvm flutter run

# 构建 iOS
fvm flutter build ios --release

# 静态分析
fvm flutter analyze

# 运行测试
fvm flutter test
```

## 依赖

- `dio`: HTTP 请求
- `shared_preferences`: 本地存储
- `device_info_plus`: 设备信息
- `package_info_plus`: 应用包信息
