# B面代码混淆工具

使用 Dart AST 分析实现精确的代码混淆，避免 `grep`/`sed` 方案的各种边界问题。

## 参考

- [ljmatan/obfuscator](https://github.com/ljmatan/obfuscator) - Dart 源码混淆服务

## 功能

| 功能 | 说明 | 实现方式 |
|------|------|----------|
| 字符串混淆 | 将敏感字符串转换为 `String.fromCharCodes()` | AST 识别 `SimpleStringLiteral`，自动排除 const 上下文 |
| 路由混淆 | 将 Routes 路由路径替换为随机哈希 | AST 识别 `routes.dart` 中的 `static const` 字段 |
| 调用栈混淆 | 在核心类方法中注入包装调用 | AST 识别核心文件的方法，包装方法体增加调用深度 |

## 使用方式

### 通过 Shell 脚本（推荐）

```bash
# 在项目根目录执行

# 字符串混淆
./scripts/obfuscate_code.sh -p ph --string

# 调用栈混淆（针对核心文件）
./scripts/obfuscate_code.sh -p ph --callstack

# 调用栈混淆，指定深度
./scripts/obfuscate_code.sh -p ph --callstack --depth 4

# 所有混淆
./scripts/obfuscate_code.sh -p ph --all

# 模拟运行（不修改文件，查看会处理哪些）
./scripts/obfuscate_code.sh -p ph --all -d
```

### 直接使用 Dart

```bash
cd scripts/dart_obfuscator

# 安装依赖
dart pub get

# 运行
dart run bin/obfuscate.dart -p ph --string
dart run bin/obfuscate.dart --help
```

## 命令行参数

```
可选参数:
  -p, --project NAME         项目代码 (hjsq, md, ph, 51pc, hlw, tiktok, 91cg, yms, acfun, tx)
                             用于加载项目特定的敏感词和核心文件列表
  -t, --target DIR           目标目录 (默认: lib/modules/secondary)

混淆功能（至少选一个）:
  --string                   字符串混淆（API路径、URL、敏感词、中文文本）
  --callstack                调用栈混淆（针对核心类方法包装调用）
  --all                      全部启用

字符串配置:
  -m, --method METHOD        bytes, base64, xor, concat (默认: bytes)
  -k, --xor-key KEY          XOR 密钥 (默认: 42)

调用栈配置:
  --depth INT                调用栈深度 1-5 (默认: 3)

其他:
  -d, --dry-run              模拟运行，不修改文件
  -v, --verbose              详细输出
  -h, --help                 帮助
```

## 调用栈混淆说明

### 为什么要针对核心文件？

1. **避免 Tree Shaking**：Flutter release 构建会移除未使用的代码
2. **精准混淆**：只混淆 API 调用、用户服务等机审重点关注的代码
3. **减少风险**：全量混淆容易破坏代码逻辑

### 项目核心文件配置

| 项目 | 核心文件 |
|------|---------|
| **ph** | `api_service.dart`, `user_service.dart`, `app_service.dart`, `app_prepare.dart`, `login.dart`, `storage_service.dart` |
| **hjsq** | `api_service.dart`, `user_service.dart`, `app_service.dart` |
| **md** | `api_service.dart`, `user_service.dart` |
| **51pc** | `api_service.dart`, `user_service.dart` |
| **tx** | `module_entry.dart`, `request.dart`, `http_request.dart`, `app_api.dart`, `global_logic.dart`, `splash_logic.dart` |

### 混淆效果示例

**原代码：**
```dart
Future<bool> updateAPIUserInfo() async {
  final s = await httpInstance.post(url: 'user/base/info');
  _userInfo.value = s;
  return true;
}
```

**混淆后：**
```dart
Future<bool> updateAPIUserInfo() async {
  return _ProcessDataHelper.wrapAsync3<bool>(() async {
    final s = await httpInstance.post(url: 'user/base/info');
    _userInfo.value = s;
    return true;
  });
}

// 文件末尾自动生成的包装器类
class _ProcessDataHelper {
  _ProcessDataHelper._();
  static T wrap1<T>(T Function() fn) => fn();
  static T wrap2<T>(T Function() fn) => wrap1(fn);
  static T wrap3<T>(T Function() fn) => wrap2(fn);
  static Future<T> wrapAsync1<T>(Future<T> Function() fn) => fn();
  static Future<T> wrapAsync2<T>(Future<T> Function() fn) => wrapAsync1(fn);
  static Future<T> wrapAsync3<T>(Future<T> Function() fn) => wrapAsync2(fn);
}
```

## 架构

```
dart_obfuscator/
├── bin/
│   └── obfuscate.dart          # CLI 入口
├── lib/
│   ├── config.dart             # 配置类（含项目特定敏感词/核心文件）
│   ├── obfuscator.dart         # 主混淆器
│   ├── dart_obfuscator.dart    # 库入口
│   ├── visitors/               # AST 访问器
│   │   ├── string_obfuscator.dart    # 字符串混淆
│   │   ├── route_obfuscator.dart     # 路由混淆
│   │   └── callstack_obfuscator.dart # 调用栈混淆
│   └── utils/
│       ├── encoders.dart       # 编码工具
│       ├── name_generator.dart # 名称生成器
│       └── logger.dart         # 日志工具
└── pubspec.yaml
```

## AST 分析优势

相比 `grep`/`sed` 方案：

### 1. 精确识别 const 上下文

- `visitInstanceCreationExpression` 检测 `node.isConst`
- `visitListLiteral` 检测 const 列表
- `visitConstructorDeclaration` 检测 const 构造函数
- `visitDefaultFormalParameter` 检测参数默认值
- 不会破坏 `const Key('xxx')` 这样的代码

### 2. 跳过字符串插值

- `visitStringInterpolation` 直接跳过
- `visitAdjacentStrings` 跳过相邻字符串 `"a" "b" "c"`
- 不会误处理 `'$variable'` 或 `'${expression}'`

### 3. 识别注解和 switch

- `visitAnnotation` 跳过注解中的字符串
- `visitSwitchCase` / `visitSwitchExpression` 跳过 case 表达式
- 不会混淆 `@Deprecated('xxx')` 或 `case 'value':`

### 4. 精确的方法体识别

- `visitMethodDeclaration` 识别方法
- `visitBlockFunctionBody` 识别方法体
- 知道 `{` 的精确位置，可以正确包装方法体

## 输出

- 混淆后的代码直接修改原文件
- 路由映射表保存至 `build/route_mapping_<project>.txt`
- 日志输出到控制台

## 工作流程

```bash
# 1. 同步 B 面代码（包含图片混淆）
./scripts/sync_secondary.sh -p ph

# 2. 运行代码混淆
./scripts/obfuscate_code.sh -p ph --all

# 3. 验证代码
fvm flutter analyze lib/modules/secondary

# 4. 构建（启用 Flutter 官方混淆）
fvm flutter build ipa --release --obfuscate --split-debug-info=build/symbols
```

## 注意事项

1. **先备份代码**：混淆会直接修改文件，出错时运行 `sync_secondary.sh` 重新同步
2. **运行分析**：混淆后执行 `fvm flutter analyze` 验证语法正确
3. **指定项目**：使用 `-p` 参数指定项目，加载正确的敏感词和核心文件列表
4. **与官方混淆配合**：构建时使用 `--obfuscate --split-debug-info=build/symbols`
