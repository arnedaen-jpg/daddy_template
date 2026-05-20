# 适配新 B 面项目 — 完整清单

本文档记录将一个新的 B 面（次要模块）项目接入壳工程并完成 framework 混淆的全部步骤。
以 **md** 项目的适配过程为参考模板。

---

## 一、同步 B 面代码

```bash
# 1. 同步 B 面代码到壳工程
./scripts/sync_secondary.sh -p <project> -s /path/to/source

# 2. 检查同步结果
ls lib/modules/secondary/     # B 面 Dart 代码
ls assets/secondary/          # B 面资源文件
cat ab_config.yaml            # 确认项目标识、源路径
cat pubspec.yaml              # 确认依赖已添加（"# === 次要模块依赖" 标记后）
```

### 检查项

- [ ] `ab_config.yaml` 中 `project:` 字段正确
- [ ] `pubspec.yaml` 中 B 面依赖在 `# === 次要模块依赖` 标记之后
- [ ] 如果项目有本地子包（如 md 的 `flutter_base/`），确认已拷贝并在 pubspec 中通过 `path:` 引用
- [ ] 如果项目有自定义 iOS 原生文件（AppDelegate.swift 等），确认已同步到 `ios/Runner/`

---

## 二、创建项目清单 (project_manifests)

**文件**: `scripts/project_manifests/<project>.conf`

清单定义了每个 iOS 原生依赖的混淆级别。

### 步骤

```bash
# 1. 列出所有可混淆的 iOS 原生插件
./scripts/obfuscate_frameworks.sh list -p <project>

# 2. 查看自动检测的 iOS 平台包（传递依赖）
cd <project_root> && fvm flutter pub deps 2>/dev/null | \
  grep -E '_(ios|apple|foundation|avfoundation|darwin|wkwebview) ' | \
  grep -E '├── |└── ' | sed 's/.*[├└]── //' | sort -u

# 3. 检查哪些平台包已有 framework_profiles
ls scripts/framework_profiles/remote/
ls scripts/framework_profiles/local/

# 4. 创建清单文件（参考 template.conf）
cp scripts/project_manifests/template.conf scripts/project_manifests/<project>.conf
vim scripts/project_manifests/<project>.conf
```

### 清单格式

```
# type:name:version:level
#
# type:    remote (pub.dev) | local (plugins/ 或 flutter_base/)
# level:   L0 = 仅注入  |  L1 = + 符号重命名  |  L2 = + 方法打乱  |  L3 = + 死分支  |  disabled = 跳过
#
# 规则:
# - 有 framework_profiles/ 匹配的 profile → 可设 L1+
# - 无 profile → 只能 L0
# - 不确定 → 先 L0，测试通过后再提升

# === 可重命名的直接依赖 ===
remote:connectivity_plus:7.0.0:L0

# === 传递依赖（不可重命名，仅变异） ===
remote:image_picker_ios:0.8.13+3:L1       # 有 profile

# === 本地子包 ===
local:fijkplayer::L0
```

### 依赖分类

| 类型 | 来源 | 能否重命名 | 说明 |
|------|------|-----------|------|
| B 面直接依赖 | pubspec.yaml `# === 次要模块依赖` 后 | ✅ 可重命名 | 复制到 `plugins/` 并改名 |
| iOS 平台包 | 传递依赖（`_ios`/`_apple` 等后缀） | ❌ 不可重命名 | 通过 `dependency_overrides` 本地化后变异 |
| flutter_base 子模块 | `flutter_base/` 目录 | ✅ 可重命名 | 仅 md 等使用 flutter_base 的项目 |
| 第三方 CocoaPods | podspec 引入（AFNetworking 等） | ❌ 不可处理 | 由 Flutter 插件的 podspec 依赖，当前不在处理范围 |

---

### 补充：依赖字符串清单 (dep_strings_manifests)

除了 `project_manifests/<project>.conf`，新项目还需要准备依赖字符串混淆清单：

```bash
vim scripts/dep_strings_manifests/<project>.conf
```

格式：

```
# plugin_name: dart,swift,objc
basic_library: dart
gallery_saver_plus: dart,swift,objc
flutter_udid: dart,swift
```

规则：

- 共享插件优先写到 `scripts/dep_strings_manifests/_shared.conf`
- 项目专属插件写到 `scripts/dep_strings_manifests/<project>.conf`
- 已重命名的插件可以继续写原始包名，脚本会自动回查 `plugin_rename_mapping.conf`
- 如果项目有 `third_party/` 这类本地 `path:` 依赖，也要纳入清单；当前脚本会自动扫描 root `pubspec.yaml` 中的本地 `path:` 包
- `swift` / `objc` 只在插件存在对应源码时填写；纯 Dart 包只写 `dart`

验证：

```bash
./scripts/obfuscate_frameworks.sh dep-strings -p <project> -d -v
```

---

## 三、检查 framework_profiles

**目录**: `scripts/framework_profiles/remote/` 和 `scripts/framework_profiles/local/`

profile 文件用于 L1+ 级别的高级变异（符号重命名、方法打乱等）。

### 版本匹配规则

profile 文件名格式: `<package_name>@<major_version>.sh`

```
# 例: connectivity_plus 7.0.0 → 查找优先级:
#   1. remote/connectivity_plus@7.sh     ← 主版本精确匹配
#   2. remote/connectivity_plus.sh       ← 通用（版本无关）
#   3. local/connectivity_plus@7.sh      ← 本地同名
#   4. local/connectivity_plus.sh        ← 本地通用
```

### 检查项

- [ ] 清单中设为 L1+ 的依赖，必须有匹配的 profile 文件
- [ ] 版本号主版本必须匹配（`@6.sh` 不匹配 `7.x.x`）
- [ ] 如果新版本没有 profile，降级为 L0 或创建新 profile

### 已有 profile 列表（供参考）

运行 `ls scripts/framework_profiles/remote/` 查看最新列表。
常见已覆盖:
- `connectivity_plus@6` / `image_picker_ios@0` / `path_provider_foundation@2`
- `permission_handler_apple@9` / `shared_preferences_foundation@2`
- `url_launcher_ios@6` / `webview_flutter_wkwebview@3`

---

## 四、检查第三方原生 Pods

运行 `obfuscate_frameworks.sh run` 后，报告的 **"第三方原生 Pods"** 部分会列出所有由 Flutter 插件 podspec 引入的原生 CocoaPods。

这些 Pods（如 AFNetworking、SDWebImage、GoogleMLKit 等）当前不在混淆范围内。
如果审核对此有要求，需要在对应 Flutter 插件的 profile 中额外处理。

### 常见第三方 Pods 及其来源

| Pod | 引入者 | 说明 |
|-----|--------|------|
| AFNetworking | 项目内部 / 部分插件 | 网络库 |
| SDWebImage | image_pickers / ZLPhotoBrowser | 图片加载 |
| BIJKPlayer | fijkplayer (flutter_base) | IJK 播放器 |
| GoogleMLKit / MLKit* | mobile_scanner | 条码扫描 |
| OrderedSet | flutter_inappwebview | 有序集合 |

---

## 五、特殊项目适配 (compat)

如果项目有特殊逻辑（如 md 的 AES 加密资源路径、flutter_base 子包），需要在 `scripts/compat/compat_<project>.sh` 中处理。

### md 项目特殊处理

- `flutter_base/` 子包系统（fijkplayer、device_identity）
- AES 加密的资源路径（`assets_mdgetx_client.dart`）
- 自定义 iOS 原生文件（AppDelegate.swift、BCSKeyChainTool.swift）
- Google Firebase 配置（GoogleService-Info.plist）

### 检查 `project_uses_flutter_base()`

如果新项目也有类似 `flutter_base/` 的子包结构，需要在 `obfuscate_frameworks.sh` 的 `project_uses_flutter_base()` 函数中注册:

```bash
project_uses_flutter_base() {
    local project="$1"
    [[ "$project" == "md" ]]          # ← 在此添加新项目
    # [[ "$project" == "md" || "$project" == "new_project" ]]
}
```

---

## 六、执行混淆并验证

```bash
# 1. 一键执行全流程
./scripts/obfuscate_frameworks.sh run -p <project>

# 2. 检查报告
cat scripts/reports/<project>_*.txt

# 3. 验证构建
fvm flutter build ios --release

# 4. 如果构建失败，常见排查点:
#    - pubspec.yaml 依赖冲突 → 检查 dependency_overrides
#    - Pod 找不到 → cd ios && pod install --repo-update
#    - 传递依赖冲突 → 检查报告中 "跳过的插件" 部分
#    - flutter_base 子包路径错误 → 检查 flutter_base/pubspec.yaml
```

---

## 七、完整适配检查清单

### 必须

- [ ] `sync_secondary.sh` 同步成功，`ab_config.yaml` 正确
- [ ] `scripts/project_manifests/<project>.conf` 已创建
- [ ] 清单中 L1+ 的依赖有对应的 framework_profiles
- [ ] `obfuscate_frameworks.sh run` 执行成功
- [ ] `fvm flutter build ios --release` 构建成功

### 建议

- [ ] 检查报告中 "第三方原生 Pods" 部分，了解未覆盖的原生依赖
- [ ] 首次适配先全部用 L0，确认构建通过后再提升混淆级别
- [ ] 如果有 `flutter_base/` 或类似子包，确认 `project_uses_flutter_base()` 已注册
- [ ] 如果项目有自定义 iOS 原生文件，确认 `compat_<project>.sh` 中有处理逻辑
- [ ] 资源混淆（`obfuscate_code.sh`）单独处理，不在本脚本范围内
