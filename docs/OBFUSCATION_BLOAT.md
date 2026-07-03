# 文件膨胀说明

B 面混淆体系中的**文件膨胀**功能，用于缓解 App Store 4.3(a) 多包相似度拒审。

---

## 一、适用场景

| 场景 | 问题 | 解决方案 |
|------|------|----------|
| **4.3(a) 多包相似** | 多个 AB 包共用同一 B 面，提审时被判定「大部分代码都一样」 | 为每个项目注入**不同的**膨胀代码，降低包间二进制相似度 |
| **B 面占比大** | B 面 60M、A 面 5M | 文件膨胀**无法直接解决**；应给 **A 面**加资源稀释占比 |

**本功能面向 4.3(a) 场景**：为每个项目/每个包（不同 bundleId+version）分别生成**结构差异化**的冗余代码，使审核端在二进制比对时判定相似度降低。

> **强化说明（当前实现）**：为进一步降低 4.3(a) 相似度，膨胀的**结构本身**（文件数、类数、方法数、模板分布、运行时骨架）已改为**随 seed 变化**，而不再是所有包共用一套固定骨架。详见「二、原理」与「十二、随 seed 变化的结构（4.3a 强化）」。

---

## 二、原理

在 B 面 `lib/modules/secondary/` 中注入**项目专属**的冗余 Dart 代码：

- **差异化来源**：优先 `sha1(bundleId+version)` 稳定 seed（同版本同包生成一致，利于 Crashlytics/Sentry 符号映射）；否则 `projectName + timestamp`
- **存活保证**：在 `module_entry.dart` 的 `getHomePage()` 开头调用 `PreloadRunner.run()`，确保代码被实际执行，不被 tree-shaking 移除
- **生成内容（review-intensive 项目：`yms`/`oio`/`bili`/`dq`）**：文件数、类数、方法数**由 seed 派生区间随机**（`_fileCount` 420..640、`_classesPerFile` 18..32、`_methodsPerClass` 7..14），因此不同包的膨胀规模不同；非 review 项目保持固定小规模（50×25×10）。
- **模板分布随 seed 变化**：12 种方法体模板经 seed 派生排列（`_templatePermutation`）映射，使两包即使命中同一 variant 也落到不同模板；`PreloadRunner` 运行时骨架也有 seed 派生变体（变量名/起点表达式）。

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

# review-intensive 项目由 seed 派生结构维度（_deriveDimensions）：
fileCount       = 420..640    # seed 派生
classesPerFile  = 18..32      # seed 派生
methodsPerClass = 7..14       # seed 派生
runtimeTouch    = 40..80      # seed 派生（启动期只轻量触达一部分，避免递归放大）
templatePerm    = shuffle([0..11], seed)   # 方法体模板排列
mainVariant     = seed % 3    # PreloadRunner 骨架变体

对每个子文件 f in 0..fileCount-1（语义化随机文件名）:
  生成 <semantic_name>.dart:
    - import dart:convert / dart:math
    - Util 类：buildMap(n)、encode(jsonEncode)、score(n)
    - Math 类：clamp / lerp / hash
    对每个类 c in 0..classesPerFile-1:
      className = generateClassName(seed)_<Kind><c>  # 唯一后缀防哈希冲突
      for 每个方法 m in 0..methodsPerClass-1:
        方法体 = 模板[templatePerm[variant]]（12 选 1，经 seed 排列）
    Part${f}.run() 调用本文件 Util/Math + 各类首方法（review 下 retainAllMethods 保留全部方法于恒假分支）

preload.dart:
  导入全部子模块（+ 若有 part_extensions）
  PreloadRunner.run()：runtimeTouch<fileCount 时按 seed 派生步长/起点抽样触达；否则全量调用
```

---

## 五、注入逻辑

1. **优先**：在 `getHomePage()` 方法体开头插入 `PreloadRunner.run();`
2. **后备**：若未找到 `getHomePage()`，在文件顶层添加 `final _preloadInit = () { PreloadRunner.run(); return 0; }();`，在库加载时执行

---

## 六、差异化保证

| 项目 | seed 策略 | 结果 |
|------|-----------|------|
| dq + 稳定 seed | `sha1(bundleId+version)` | 同版本同包一致，利于 Crashlytics 符号映射；不同 bundleId 结构维度不同 |
| dq + 未指定 version | `projectName + timestamp` | 每次不同，包间差异化 |
| 两个 dq 包（不同 bundleId） | 同上 | 文件/类/方法数、模板分布、运行时骨架均因 seed 不同而不同，结构相似度显著下降 |

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
| **--noise** | 业务噪音：扫描 AST 找 `build()`、`initState()`、`getHomePage()`，随机插入 `RuntimeInit.run()` 调用；注入率 **70%–95%**（随 seed 抖动） |
| **--mutation** | AST 变异：在 **45%–75%** 的方法中随机位置插入 dummy 代码（开始/中间/结束的位置权重也随 seed 抖动），条件随机（`DateTime.now().millisecond < 0` 等，避免固定 pattern） |
| **--callstack** | 调用栈包裹：每文件方法包裹率 **80%–100%**（随 seed 抖动），可选文件比例 85%–100% |
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

## 十二、随 seed 变化的结构（4.3a 强化）

为降低两个 dq 包的**结构**相似度（名字已随机但骨架曾完全相同），以下维度已改为随 seed 变化。所有取值在同一 `bundleId+version` 下可复现（稳定 seed），不同包之间不同。

### Dart 层（`obfuscate_code.sh`）

| 维度 | 取值 | 位置 |
|------|------|------|
| 膨胀文件数 `_fileCount` | 420..640（review 项目） | `dart_obfuscator/lib/visitors/bloat_inflator.dart` `_deriveDimensions` |
| 每文件类数 `_classesPerFile` | 18..32 | 同上 |
| 每类方法数 `_methodsPerClass` | 7..14 | 同上 |
| 运行时触达数 `_runtimeTouchCount` | 40..80 | 同上 |
| 方法体模板排列 `_templatePermutation` | seed 洗牌 [0..11] | `_writeMethodBody` |
| PreloadRunner 骨架变体 `_mainVariant` | seed % 3（变量名/起点表达式） | `_generateBloatMain` |
| callstack 每文件方法包裹率 | 80%–100% | `callstack_obfuscator.dart _selectMethodsToWrap` |
| noise 注入率 | 70%–95% | `business_noise_injector.dart` |
| mutation 注入率 | 45%–75% | `ast_mutation_obfuscator.dart` |
| mutation 插入位置权重 | seed 派生（`_posStartWeight`/`_posMidUpper`） | `ast_mutation_obfuscator.dart _pickMutationInsertPosition` |

### Native 层（`obfuscate_frameworks.sh`）

review-intensive 项目的 native 力度旋钮由 `randomize_review_native_knobs()` 用 SEED 派生到区间内（`seed_rand_range`），避免所有包恰好同一倍率/上限：

| 旋钮 | 区间 |
|------|------|
| `REVIEW_NATIVE_CLASS_MULTIPLIER` | 4..7 |
| `REVIEW_NATIVE_DEAD_BRANCH_MULTIPLIER` | 4..7 |
| `REVIEW_NATIVE_MAX_CLASSES_PER_SOURCE` | 100..140 |
| `REVIEW_NATIVE_MAX_EXTRA_METHODS` | 14..22 |
| `REVIEW_NATIVE_MAX_OPS` | 24..36 |
| `REVIEW_NATIVE_MAX_INFO_ENTRIES` | 22..34 |

profile 里的 `bt_inject_classes <count>` 基数会再经 `native_class_count`（× 上述倍率并封顶）放大，因此基数本身也随 seed 变化。

### 二进制 Pod 差异化（`differentiate_binary_pod`）

融云/友盟/IJK 等**闭源二进制 Pod**（`dq.conf` 中标 `disabled`）机器码不可改，是两包相似度的固定来源。策略（低风险）：

- **不碰**被签名的 `.framework`/`.xcframework` 二进制及其 `Info.plist`；
- 仅向 Pod 附带的 `.bundle` 资源包写入一个 **seed 派生的惰性资源文件**（`.zt_<hash>.dat`）；
- `.bundle` 会被 CocoaPods 拷入 `.app`，改变最终 IPA 指纹；iOS 不对资源 `.bundle` 单独签名，SDK 通常也不校验其资源包，运行不受影响；
- 无 `.bundle` 的 Pod 记录为「跳过」。

> 更激进的手段（framework/module 改名、Mach-O 二进制编辑）对带完整性自检的 SDK 风险高，当前**不启用**。

---

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
