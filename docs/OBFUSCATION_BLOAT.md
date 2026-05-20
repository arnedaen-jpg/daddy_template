# 文件膨胀说明

B 面混淆体系中的**文件膨胀**功能，用于缓解 App Store 4.3(a) 多包相似度拒审。

---

## 一、适用场景

| 场景 | 问题 | 解决方案 |
|------|------|----------|
| **4.3(a) 多包相似** | 多个 AB 包共用同一 B 面，提审时被判定「大部分代码都一样」 | 为每个项目注入**不同的**膨胀代码，降低包间二进制相似度 |
| **B 面占比大** | B 面 60M、A 面 5M | 文件膨胀**无法直接解决**；应给 **A 面**加资源稀释占比 |

**本功能面向 4.3(a) 场景**：通过为 ph / hjsq / md / 51pc 等项目分别生成差异化的冗余代码，使审核端在二进制比对时判定相似度降低。

---

## 二、原理

在 B 面 `lib/modules/secondary/` 中注入**项目专属**的冗余 Dart 代码：

- **差异化来源**：优先 `sha1(bundleId+version)` 稳定 seed（同版本同包生成一致，利于 Crashlytics/Sentry 符号映射）；否则 `projectName + timestamp`
- **存活保证**：在 `module_entry.dart` 的 `getHomePage()` 开头调用 `PreloadRunner.run()`，确保代码被实际执行，不被 tree-shaking 移除
- **生成内容**：8 个子文件 × 16 类 × 6 方法 ≈ 768 个方法；真实代码（条件、循环、List/Map、JSON），子模块间交叉调用

---

## 三、目录结构

```
lib/modules/secondary/
├── module_entry.dart          # 注入 PreloadRunner.run() 调用
├── _internal/                 # 中性命名，避免敏感词
│   ├── part_cache.dart       # 子模块（16 类 × 6 方法，含 List/Map/JSON）
│   ├── part_config.dart      # 交叉调用下一模块
│   ├── part_state.dart
│   ├── part_util.dart
│   ├── part_helper.dart
│   ├── part_data.dart
│   ├── part_handler.dart
│   ├── part_parser.dart
│   ├── part_extensions.dart   # extension/generic/mixin（符号扭曲）
│   ├── part_runtime.dart      # 业务噪音（RuntimeInit.run）
│   └── preload.dart          # 主入口
└── ... 其他 B 面文件
```

---

## 四、生成逻辑

```text
seed = sha1(bundleId+version) ?? projectName + timestamp
  # bundleId/version 从 pubspec 或 -b/-V 读取；同版本同包稳定，利于 Crash 符号映射

对每个子文件 f in 0..7 (cache, config, state, util, helper, data, handler, parser):
  生成 part_${name}.dart:
    - import dart:convert
    - List/Map/JSON 类：_toListMap(n)、_toJson(list)、jsonEncode
    - 交叉调用：import part_${next}.dart，run() 中调用 Part${next}.run()
    对每个类 c in 0..15:
      className = generateClassName(seed)_C${c}  # 唯一后缀防哈希冲突
      for 每个方法 m in 0..5:
        三种模式：条件/循环、List.fold、Map 运算
    Part${f}.run() 调用本文件内 ListMap 类 + 各类的首个方法 + 下一 Part

preload.dart:
  导入 8 个子模块 + part_extensions
  PreloadRunner.run() 依次调用 Part0..7.run() + ExtRunner.run()
```

---

## 五、注入逻辑

1. **优先**：在 `getHomePage()` 方法体开头插入 `PreloadRunner.run();`
2. **后备**：若未找到 `getHomePage()`，在文件顶层添加 `final _preloadInit = () { PreloadRunner.run(); return 0; }();`，在库加载时执行

---

## 六、差异化保证

| 项目 | seed 策略 | 结果 |
|------|-----------|------|
| ph + 稳定 seed | `sha1(bundleId+version)` | 同版本同包一致，利于 Crashlytics 符号映射 |
| ph + 未指定 version | `projectName + timestamp` | 每次不同，包间差异化 |
| hjsq / md | 同上 | 不同项目因 projectName/bundleId 不同，结构差异大 |

---

## 七、使用方式

文件膨胀已并入 `obfuscate_code.sh`，统一入口、多种组合：

```bash
# 执行膨胀（默认仅 --bloat）
./scripts/obfuscate_code.sh -p ph --bloat

# 膨胀 + 业务噪音 + AST 变异 + 符号扭曲
./scripts/obfuscate_code.sh -p ph --bloat --noise --mutation --symbols

# 模拟运行
./scripts/obfuscate_code.sh -p ph --bloat -d

# 指定目标目录
./scripts/obfuscate_code.sh -p ph --bloat -t lib/modules/secondary

# 稳定 seed（同版本同包一致，利于 Crashlytics 符号映射）
./scripts/obfuscate_code.sh -p ph --bloat -b com.example.app -V 1.0.0 --noise --mutation --symbols

# 所有混淆（含 string/callstack/bloat/noise/mutation/symbols）
./scripts/obfuscate_code.sh -p ph --all
```

或直接使用 Dart CLI：

```bash
cd scripts/dart_obfuscator
dart run bin/obfuscate.dart -p ph --bloat --noise --mutation --symbols
```

---

## 八、与其它混淆的关系

```
B 面混淆体系（统一入口 obfuscate_code.sh）
├── obfuscate_code.sh --string     字符串混淆（API、URL 等）
├── obfuscate_code.sh --callstack  调用栈混淆（控制流复杂度）
├── obfuscate_code.sh --bloat      文件膨胀（4.3a 差异化） ◀ 本文
├── obfuscate_code.sh --noise      业务噪音（build/initState/getHomePage 注入 Noise.run）
├── obfuscate_code.sh --mutation   AST 变异（方法体插入 dummy 代码）
├── obfuscate_code.sh --symbols    符号扭曲（extension/generic/mixin）
├── obfuscate_code.sh --all        全部混淆
├── obfuscate_frameworks.sh        Framework 名称混淆
└── flutter build --obfuscate     Flutter 官方符号混淆
```

---

## 九、扩展功能说明

| 功能 | 说明 |
|------|------|
| **--noise** | 业务噪音：扫描 AST 找 `build()`、`initState()`、`getHomePage()`，随机插入 `RuntimeInit.run()` 调用 |
| **--mutation** | AST 变异：在 30–60% 的方法中随机位置插入 dummy 代码（开始/中间/结束 60/20/20%），条件随机（`DateTime.now().millisecond < 0` 等，避免固定 pattern） |
| **--symbols** | 符号扭曲：生成 `part_extensions.dart`，包含 extension on int/String、泛型类、mixin，接入 PreloadRunner |

上述功能与膨胀共用 `obfuscate_code.sh`，可组合使用。

### 实现细节（RuntimeInit / Mutation 注入）

- **AST 为主**：用 `leftBracket.offset`，`content[offset]=='{'` 则注入；否则向后扫描 80 字符找 `{`
- **类体/mixin 体排除** (`_isLikelyClassBody`)：`{` 前最近非空白符为 `>` 或标识符（a-z/A-Z/_）则跳过，覆盖 `extends State<X> {`、`with Mixin {` 等
- **Map/Set 字面量排除** (`_isCollectionLiteralBrace`)：`{` 前为 `=` 或 `:` 则跳过，避免注入 `RuntimeInit.run();` 到 `Map x = { }` 导致 `Set` 赋给 `Map` 报错
- **switch 块排除** (`_isSwitchBlockBrace`)：向前回溯识别 `switch(expr) {` 的 `{`，跳过注入，避免破坏 case 结构
- **case/default 排除** (`_wouldInjectBeforeCaseOrDefault`)：插入位置后紧跟 `case`/`default` 则跳过，兜底防止 switch 内误插
- **多行 import** (`_ensureRuntimeImport`)：条件 import 等跨行语句，在完整语句（含 `;`）结束后插入 `part_runtime`，避免破坏 `import 'a' if (cond) 'b' as ui;`
- **Mutation 随机位置**：开始 60%、中间（AST `firstStatementEnd` 首个顶层语句后）20%、结束（`}` 前）20%；中间使用 AST 提供的 firstStatementEnd，避免 for 循环、无括号 if-else 内误插
- **插入顺序**：先计算所有插入点，按 actualPos 倒序插入，避免嵌套方法时先插内层导致 content 偏移、外层 offset 错位
- **Dummy 片段**：`try{}catch`、`for`、`if(DateTime.now().millisecond<0){}`、`if(1>2){}`、`assert(true)`、`do{}while(false)` 等随机；已移除 switch 相关 snippet，改用 `if(1>2){}`，避免与 switch 块内注入冲突破坏 case 结构

---

### 未来可扩展

- **CallGraphMutator**：随机生成调用图（A→B→C, B→D），进一步降低 Binary 相似度

## 十、注意事项

1. **必须指定项目**：`-p ph` 等，否则无法保证项目间差异化。
2. **稳定 seed 与 Crash 符号**：推荐 `-b <bundleId> -V <version>`（或由 pubspec 自动读取），同版本同包生成一致，Crashlytics/Sentry 符号映射稳定；不指定则用 timestamp，每次不同。
3. **膨胀代码不参与业务**：仅用于增加体积和结构差异，不影响业务逻辑。
4. **中性命名**：生成的文件/类名采用 `_internal`、`part_*`、`PreloadRunner` 等中性命名，避免敏感词（如 bloat）被静态分析识别。

---

## 十一、实现文件

| 文件 | 说明 |
|------|------|
| `scripts/obfuscate_code.sh` | 统一入口脚本（--bloat / --noise / --mutation / --symbols） |
| `scripts/dart_obfuscator/lib/visitors/bloat_inflator.dart` | 膨胀逻辑（含 List/Map/JSON、交叉调用） |
| `scripts/dart_obfuscator/lib/visitors/business_noise_injector.dart` | 业务噪音（RuntimeInit.run 注入，AST+正则） |
| `scripts/dart_obfuscator/lib/visitors/ast_mutation_obfuscator.dart` | AST 变异（dummy 代码，AST+正则） |
| `scripts/dart_obfuscator/lib/visitors/symbol_distorter.dart` | 符号扭曲（extension/generic/mixin） |
| `scripts/dart_obfuscator/lib/config.dart` | enableBloat / enableNoise / enableMutation / enableSymbolDistort |
| `scripts/dart_obfuscator/bin/obfuscate.dart` | Dart CLI（支持 --bloat --noise --mutation --symbols） |
