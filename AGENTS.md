# AGENTS.md

本文件面向在本仓库中工作的 Codex / AI 代理，目标是让代理基于当前代码现状而不是旧模板印象来行动。

## 仓库定位

这是一个用于制作 iOS AB 包的 Flutter 壳工程，仓库由两部分组成：

- Flutter 壳工程：负责 A 面、AB 切换、网络与域名兜底、iOS 审核期控制。
- 脚本工具链：负责迁移 B 面代码、同步依赖与资源、混淆 Dart / Framework / 依赖字符串、打包 IPA、上传 IPA。

当前工程不是单纯的 App 业务仓库，而是「A 面壳 + B 面迁移 + 混淆打包流水线」的组合体。

## 当前仓库状态

- **只保留两个 B 面代号：`dq`（斗球/直播）与 `lgt`（聊个天/IM）**，说明见 `docs/B_SECONDARY_DQ_LGT.md`。
- `ab_config.yaml` 由 `sync_secondary.sh` 生成，`project` 为 `dq` 或 `lgt`。
- 适配文件：`scripts/compat/compat_dq.sh`、`scripts/compat/compat_lgt.sh`；旧代号脚本已删除。
- 默认同步 **dq** 时可在 `sync_secondary.conf` 中把路径设为 `/Users/t-yh/dqiu/xty`（`--init-config` 已带示例）。

## 目录与边界

- `lib/modules/primary/`：A 面（审核面）代码，允许自由开发。
- `lib/modules/secondary/`：B 面同步结果，默认视为生成物，不要手改，除非任务明确是修同步/混淆逻辑。
- `assets/secondary/`：B 面资源同步结果，默认视为生成物。
- `plugins/`：B 面插件及本地化依赖，同步/Framework 混淆后生成。
- `flutter_base/`：老模板中曾用于 `md`/`yms`；当前 dq/lgt 不依赖则可为空。
- `third_party/generated_deps/`：历史 B 面可能生成 path 覆盖；当前以 dq/lgt 与 `compat_*.sh` 为准。
- `scripts/compat/compat_*.sh`：各 B 面项目的专项兼容修复入口。
- `scripts/project_manifests/*.conf`：Framework / Pod 混淆清单。
- `scripts/framework_profiles/`：Framework / Pod 的 profile 规则。
- `ab_config.yaml`：`sync_secondary.sh` 自动生成，后续混淆脚本会依赖它识别当前项目。
- `sync_secondary.log`：最近一次 B 面同步记录。

如果任务只是开发 A 面或修壳层逻辑，不要直接改 `lib/modules/secondary/`、`assets/secondary/`、`plugins/`、`flutter_base/`、`third_party/generated_deps/`。

## 开发约定

- 统一使用 `fvm flutter`，`.fvmrc` 当前指定 Flutter `3.38.3`。
- 先看 `ab_config.yaml`，再判断当前同步的是哪个 B 面项目。
- 先看 `docs/AB_MAKE.md`，再决定当前任务位于迁移、混淆、打包还是上传阶段。
- 如果需要适配新 B 面项目，重点看 `docs/ADAPT_NEW_PROJECT.md`、`scripts/compat/`、`scripts/project_manifests/`。
- `test/widget_test.dart` 仍是 Flutter 模板测试，不代表当前壳工程真实行为；不要把它当作可靠回归测试。

## 常用命令

```bash
# 安装依赖
fvm flutter pub get

# 本地运行
fvm flutter run

# 静态分析
fvm flutter analyze

# 测试
fvm flutter test

# iOS release 构建
fvm flutter build ios --release
```

## 创建新壳工程

```bash
# 复制当前模板，生成新的 AB 壳工程
./scripts/create_ab_project.sh -n my_app -b com.example.myapp -d "My App"
```

注意：

- `create_ab_project.sh` 使用 `-b/--bundle`，不是 `-p`。
- 新工程会复制当前模板、更新 Bundle ID / 显示名称、初始化新 git 仓库。
- 该脚本会在新工程里放开部分 `.gitignore`，方便提交同步后的 B 面代码和资源。

## B 面同步

```bash
# 初始化同步配置
./scripts/sync_secondary.sh --init-config

# 列出已配置的项目路径
./scripts/sync_secondary.sh -l

# 从预设路径同步
./scripts/sync_secondary.sh -p dq

# 显式指定源路径同步
./scripts/sync_secondary.sh -p dq -s /Users/t-yh/dqiu/xty

# 预览模式
./scripts/sync_secondary.sh -p dq -d
```

当前支持项目代号：

- `dq`
- `lgt`

（历史代号已移除：hjsq、md、ph、51pc、hlw、tiktok、91cg、yms、acfun、tx）

`sync_secondary.sh` 的真实行为很重要：

- 默认会开启 `--base64-map`。
- 默认会批量将 `Image.asset(...)` 替换为 `BaseHHImage.image(...)`。
- 默认会在同步结束后删除 `assets/secondary/` 下的图片文件，仅保留非图片资源；如需保留图片，要显式传 `--keep-secondary-images`。
- 当前脚本会处理 Base64 图片映射，但已经临时跳过 `obfuscate_asset_filenames`，不要假设资源文件名一定会被重命名。
- 会重置 `pubspec.yaml` 为 `pubspec.yaml.template`，再合并 B 面依赖与 assets。
- 会写入 `ab_config.yaml`、`sync_secondary.log`，并尝试执行 `fvm flutter pub get`。
- `dq` / `lgt` 的专项逻辑在 `compat_dq.sh`、`compat_lgt.sh` 中；资源/Base64/依赖合并仍由 `sync_secondary.sh` 主流程处理。

除非任务明确是修同步链路，否则不要直接手改同步结果，优先修 `scripts/sync_secondary.sh` 或 `scripts/compat/compat_*.sh`。

## 混淆与资源处理

### Dart / B 面代码混淆

```bash
# 全量 Dart AST 混淆
./scripts/obfuscate_code.sh -p dq --all

# 仅字符串混淆
./scripts/obfuscate_code.sh -p dq --string

# 仅文件膨胀（4.3a 差异化）
./scripts/obfuscate_code.sh -p dq --bloat

# 预览模式
./scripts/obfuscate_code.sh -p dq --all -d
```

说明：

- `obfuscate_code.sh` 会优先从 `ab_config.yaml` 自动检测当前项目，但建议显式传 `-p`。
- `--all` 当前包含 `string`、`callstack`、`bloat`、`noise`、`mutation`、`symbols`。
- 文件膨胀细节见 `docs/OBFUSCATION_BLOAT.md`。
- 真正执行 AST 混淆的工具在 `scripts/dart_obfuscator/`。

### Framework / Pod / 依赖字符串混淆

```bash
# 一键执行 rename -> mutate -> build -> pod mutate -> dep-strings
./scripts/obfuscate_frameworks.sh run -p dq

# 仅列出当前 B 面可混淆 iOS 原生插件
./scripts/obfuscate_frameworks.sh list -p dq

# 仅生成 rename mapping
./scripts/obfuscate_frameworks.sh -g -p dq

# 仅执行原生代码变异
./scripts/obfuscate_frameworks.sh mutate -p dq

# 仅执行依赖字符串混淆
./scripts/obfuscate_frameworks.sh dep-strings -p dq
```

说明：

- `run` 默认包含依赖字符串混淆；如需跳过，传 `--no-dep-strings`。
- **cocoapods-mangle** 默认关；与 Pod 源码变异/闭源 SDK 可能冲突，仅在需要时 `ZT_POD_MANGLE=1 ./scripts/obfuscate_frameworks.sh run -p dq`。
- 混淆范围只针对 `pubspec.yaml` 中 `# === 次要模块依赖` 标记后的 B 面依赖。
- 规则来自 `scripts/project_manifests/*.conf` 与 `scripts/framework_profiles/`。
- 新项目适配流程见 `docs/ADAPT_NEW_PROJECT.md`。

## 打包与上传

```bash
# 生成 CSR / 私钥
./scripts/gen_csr.sh /path/to/work_dir

# 基于工作目录打包 IPA
./scripts/build_flutter_ipa.sh /path/to/work_dir --silent=3

# 上传 IPA
./scripts/upload_ipa.sh /path/to/work_dir

# 可选：对现成 IPA 重签
./scripts/resign_ipa.sh /path/to/app.ipa
```

说明：

- `build_flutter_ipa.sh` 仅打包，**不做**成品包 IPA 混淆；步骤 5 在 AB 包工厂里用「混淆 IPA」或 CLI `harden_ipa_standalone.sh`。
- `build_flutter_ipa.sh` 会更新 `lib/config/app_config.dart` 中的 `buildTimestamp`，并按 `--silent`（或历史兼容 `--cooldown`）写入静默期天数 `silentPeriodDays`。
- `upload_ipa.sh` 依赖 `build_config.json` 里的 `apple_api_key` 与 `proxy` 配置。
- `build_and_resign.sh` 是从源码构建并用 `cert/` 下证书重签的一体化脚本，适合本地验证。
- **独立 IPA 混淆**（非工厂包）：`./scripts/open_ipa_hardening_tool.sh` 打开本地 UI，或 `harden_ipa_standalone.sh --ipa <path>`。

## 其他实用脚本

```bash
# 用模板重置 pubspec.yaml，并执行 pub get
./scripts/init_pubspec.sh

# 手动刷新静默期起点
./scripts/update_silent_period.sh

# 加密域名兜底配置
./scripts/encrypt_domains.sh

# 从另一个 daddy_template 同步 docs/scripts
./scripts/sync_daddy_template.sh -s /path/to/daddy_template
```

高风险提醒：

- `scripts/clean_secondary.sh` 不只是删生成物，还会执行 `git checkout -- .` 回退未暂存修改。除非用户明确要求清理，否则不要运行它。

## 壳工程核心架构

### 启动流程

`lib/router/app_router.dart` 中的 `SplashPage` 启动顺序是：

1. `EnvConfig.initialize()`
2. `NetworkPermissionService.initialize()`：通过访问 `apple.com` 触发 iOS 网络权限
3. `HttpClient.initialize()`
4. `DomainManager.initialize()`
5. `ConfigService.initialize()`
6. `ConfigService.ensureSecondaryInitialized()`
7. 导航到首页

### AB 切换逻辑

- `lib/services/config_service.dart` 是 AB 切换核心。
- 远程接口响应格式是 `{code: 0, data: {config: "A" | "B" | null}}`。
- `"B"` 切到 B 面，其余情况走 A 面。
- 一旦切到 B 面，会开启 memory mode 并持久化，后续优先直接进 B 面。
- 静默期基于 `AppConfig.buildTimestamp` 和 `AppConfig.silentPeriodDays`，不是基于首次启动时间。

### 路由与模块入口

- `lib/router/app_router.dart` 负责 A / B 首页路由分发。
- A 面首页是 `lib/modules/primary/pages/home_page.dart`。
- B 面统一入口是 `lib/modules/secondary/module_entry.dart`。
- `module_entry.dart` 在模板中只是占位文件，同步 B 面后通常会被覆盖。

### 域名与网络兜底

- `lib/services/domain_manager.dart` 负责默认域名、缓存域名、CDN 文章隐写域名、硬编码兜底域名。
- `lib/config/env_config.dart` 当前只区分 `test` / `production` 两套环境。
- `lib/utils/s.dart` 存放大量字节码字符串，包括路由、header、fallback domain、CDN 文章 URL。

### 图片与 B 面运行时

- `lib/app_binding.dart` 允许 B 面在运行时替换 `ImageCache`。
- Base64 图片链路相关支持文件由同步脚本自动生成到 `lib/utils/`，必要时也会写入 `flutter_base`。

### 调试面板

- `lib/widgets/env_switcher.dart` 中的 `EnvFloatingIndicator` 只在 `kDebugMode` 下显示。
- 支持切换环境、查看 AB 状态、跳过静默期、调试域名兜底。

## 推荐工作流

大多数任务按这个顺序理解和执行：

1. 确认当前项目与阶段：看 `ab_config.yaml`、`docs/AB_MAKE.md`；`project` 应为 `dq` 或 `lgt`
2. 如果是 B 面接入：先跑 `sync_secondary.sh`
3. 如果是 A 面开发：只改 `lib/modules/primary/` 与壳层代码
4. 如果是混淆：先 `obfuscate_frameworks.sh`，再 `obfuscate_code.sh`
5. 如果是打包：准备工作目录，再跑 `build_flutter_ipa.sh`
6. 如果是上传：确认 `build_config.json` 的 API key / proxy 后跑 `upload_ipa.sh`

## 阅读顺序建议

- `docs/AB_MAKE.md`：整条提包/提审流程
- `docs/ADAPT_NEW_PROJECT.md`：新 B 面项目接入与 Framework 混淆适配
- `docs/OBFUSCATION_BLOAT.md`：4.3a 文件膨胀策略
- `scripts/sync_secondary.sh`：B 面迁移主入口
- `docs/B_SECONDARY_DQ_LGT.md`：仅 dq / lgt 的同步与清单说明
- `scripts/compat/compat_dq.sh` / `scripts/compat/compat_lgt.sh`：各自专项兼容与入口生成
- `scripts/obfuscate_frameworks.sh`：Framework / Pod / dep-strings 主入口
- `scripts/obfuscate_code.sh`：Dart AST 混淆主入口

## Cursor Cloud specific instructions

面向在 Cursor Cloud（Linux VM）中工作的后续代理。工具（FVM + Flutter `3.38.3`、Node、Deno、wrangler）已由更新脚本/快照装好；`fvm` 与 `deno` 已软链到 `/usr/local/bin`，可直接调用。更新脚本只做依赖刷新（`fvm flutter pub get` + `cloudflare-ab-config` 的 `npm install`）。

### 平台边界（重要）
- **本仓库主产物是 iOS-only Flutter 壳工程，无法在 Linux 上构建或运行**：`fvm flutter run` / `build ios` 需 macOS + Xcode + 模拟器；`ios/Podfile`（CocoaPods）与整条打包/签名/混淆/上传流水线（`build_flutter_ipa.sh`、`obfuscate_frameworks.sh`、`upload_ipa.sh` 等）及 `packaging/ab_factory_app`（PyObjC GUI）都是 macOS 专用。在 Linux 上不要尝试这些。
- Linux 上可用的是：Flutter 的 `pub get` / `analyze` / `test`（Dart VM，无需模拟器），以及后端服务 `cloudflare-ab-config`（Node + wrangler 本地模式）。

### Flutter 壳工程（lint/test）
- 全部命令用 `fvm flutter ...`（见「常用命令」）。
- `fvm flutter analyze` 会报数百个 pre-existing 问题，**并非环境问题**：主要来自 `scripts/templates/*.dart`（同步模板，引用未装依赖）与 `lib/modules/secondary/generate/*`、`lib/utils/secondary_image_base64_ext.dart`（B 面同步后才生成的文件，模板态缺失）。想看壳层代码本身用 `fvm flutter analyze lib`。
- `fvm flutter test` 目前唯一用例 `test/widget_test.dart` 引用了已不存在的 `MyApp`，会编译失败——这是已知的过期模板测试（本文件上方已说明），测试框架本身正常，不要当作回归依据、也不要为通过它而改代码。

### cloudflare-ab-config 后端（可在 Linux 端到端运行/演示）
这是 A/B 远程配置后端（App 的 `ConfigService`/`DomainManager` 请求 `GET /client/api/config`）。本地开发用 wrangler 本地模式，**无需 Cloudflare 账号**（本地 miniflare 模拟 KV + D1）。
- 首次需初始化本地 D1（`.wrangler/state` 已被 gitignore，快照可能不保留，缺表时会报错）：`cd cloudflare-ab-config && npx wrangler d1 migrations apply daddy-ab-logs --local`
- 启动：`cd cloudflare-ab-config && npx wrangler dev --port 8787 --local`（就绪后监听 `http://localhost:8787`）。
- `wrangler.toml` 默认 `ADMIN_OPEN="true"`、`DEMO_MOCK_APPLE="true"`，因此 `/admin` 无需 Token、且可用请求头 `X-Mock-Apple-ASN: 1` 模拟苹果出口（判定返回 A，仅本地/演示用）。
- 写本地 KV（dev server 运行时可另起进程写，状态共享）：`npx wrangler kv key put --binding=CONFIG_KV "ab_config_<BundleId>" "B" --local`；键规则见 `cloudflare-ab-config/README.md`。
- 冒烟验证：`curl "http://localhost:8787/client/api/config" -H "X-Bundle-Id: com.demo.app"` → `{"code":0,"data":{"config":"A"|"B"}}`；管理页浏览器打开 `http://localhost:8787/admin`。
- 该子项目无 lint/test 脚本；`npx tsc` 仅类型检查（`tsconfig.json` `noEmit`）。

### supabase（可选备用后端）
`supabase/functions/daddy-ab-config` 是与 Worker 等价的另一实现（Deno + Postgres），需 Supabase CLI + Docker，较重且非必需；Worker 已覆盖同一契约。静态管理页构建器 `deno task export-static-admin` 只需 Deno。
