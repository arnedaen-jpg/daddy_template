# 成品包层混淆（IPA / Mach-O / Pod）

面向 App Store **4.3(a) 相似度**，在「不改 A 面源码」的前提下，从**成品二进制与资源**层再做一层差异化。
这是马甲包实践里反复推荐的三类手段，本仓库已把它们脚本化：

| 手段 | 脚本 | 阶段 | 风险 | 默认 |
|------|------|------|------|------|
| 1. 资源指纹差异化 | `scripts/obfuscate_ipa.sh --resources` | 构建后、重签名前 | 低 | 开 |
| 2. Mach-O 符号混淆 | `scripts/obfuscate_ipa.sh --macho`（内部调 `macho_symbol_obfuscator.py`） | 构建后、重签名前 | 中高 | 关 |
| 3. cocoapods-mangle | `scripts/enable_pod_mangle.sh` | `pod install` 编译期 | 中 | **关**（仅 `ZT_POD_MANGLE=1` 时开） |

> ⚠️ 任何二进制/资源改写都会使已有代码签名失效。后处理发生在**重签名之前**；
> 步骤 5「混淆 IPA」或 `harden_ipa_standalone.sh` 会在加固后自动重签。不要对已上架且不再重签的 IPA 使用。

---

## 1. 资源指纹差异化（低风险，推荐默认开）

`obfuscate_ipa.sh --resources` 做两件事，都不重命名文件（避免破坏 Dart / nib 里的按名引用，
这正是 `sync_secondary.sh` 里 `obfuscate_asset_filenames` 被禁用的原因）：

- 给散图（png/jpg/webp/gif，跳过 `Assets.car`）尾部追加 **seed 派生字节** → 改 MD5，不改可见内容。
- 向 `.app` 根与每个 `.bundle` 注入 seed 派生的惰性资源文件 `.zt_<hash>.dat` → 改包内文件集合指纹。

同一 seed（默认 = Bundle ID）可复现；不同包 seed 不同 → 指纹不同。

## 2. Mach-O 符号混淆（中高风险，需真机回归）

`macho_symbol_obfuscator.py` 直接解析 fat/thin Mach-O，**就地等长**改写
`__TEXT,__objc_classname` / `__TEXT,__objc_methname` 里的字符串：

- 等长、NUL 结尾保留 → 不动 string table / load command / section 偏移，指针引用仍有效，
  调用点 selref 与方法定义共享同一字符串，改后仍一致，运行时可正常派发。
- **整包 `apply-app`（推荐）**：先对 `.app` 内所有 Mach-O **收集全局映射**，再统一写入。
- **`--macho` 默认（L2.6）**：`RCIMIW`/`RCIMWrapper`/`IRCIMIW` 类名
  + SDK 方法（selector）+ `--sync-cstring` + `--patch-methtype`
  + 从 `App.framework` `__const` 采集 Dart 枚举/类型名并等长同步。
  **不要**裸前缀 `RC`。
- **禁止对 `App.framework`（Dart AOT）做 channel/`engine_cb` scrub**：就地改字面量会破坏
  编译期 string switch hash；只 scrub 原生、留下 Dart 也会因双边不一致闪退。
  检测到 `App.framework` 时脚本会**自动关闭** scrub。
- **正确做法**：用 `scripts/rongcloud_channel_obfuscate.py` 在 **源码/Framework 混淆阶段**
  同步改 Dart + ObjC(+Java) 的 MethodChannel / `engine:` / `engine_cb:`（seed 派生，可 restore）。
  `obfuscate_frameworks.sh run` 已接入 apply + verify。
- **注意**：终端里残留的 `ZT_MACHO_SCRUB_CSTRING=1` 等会覆盖脚本默认值；调试后请 `unset ZT_MACHO_*`。

| 环境变量 | 默认 | 说明 |
|----------|------|------|
| `ZT_MACHO_SDK_PREFIXES` | `RCIMIW,RCIMWrapper,IRCIMIW` | 类名前缀白名单 |
| `ZT_MACHO_SYNC_CSTRING` | `1` | 同步 `__cstring` 与类名映射 |
| `ZT_MACHO_PATCH_METHTYPE` | `1`（L2.5+） | 补丁 `__objc_methtype` 嵌入类名 |
| `ZT_MACHO_SDK_CLASSES_ONLY` | `1` | 只改 SDK 前缀类 |
| `ZT_MACHO_SCRUB_CSTRING` | `0` | channel/`engine_cb` 擦除（勿对 Dart AOT） |
| `ZT_MACHO_SDK_METHODS` | `1`（L2.6） | SDK selector 改名 |
| `ZT_MACHO_SYMBOL_ALIASES` | `0` | LINKEDIT ObjC 符号别名 |
| `ZT_RENAME_FW` | `1`（standalone） | 重命名融云等 framework |
| `ZT_NEUTRALIZE_PATHS` / `ZT_NEUTRALIZE_ENUMS` | `1` | 抹构建路径 / 枚举名 |

### 单独试跑

```bash
python3 scripts/macho_symbol_obfuscator.py scan <path/to/App.app/App> --seed com.your.bundle \
  --classes --methods --sdk-prefixes RCIMIW,RCIMWrapper,IRCIMIW,RC \
  --sync-cstring --scrub-cstring

python3 scripts/macho_symbol_obfuscator.py apply <binary> --seed com.your.bundle \
  --classes --methods --sdk-prefixes RCIMIW,RCIMWrapper,IRCIMIW,RC \
  --sync-cstring --scrub-cstring --map-out map.json
```

无法感知的风险场景：storyboard/xib 按类名实例化、跨二进制按名字调用。**提审前必须真机回归。**

## 3. cocoapods-mangle（编译期，比改成品包安全）

给第三方 Pod 的符号加统一前缀做命名空间，改二进制指纹。编译期处理，比事后改 Mach-O 安全。

```bash
# 脚本会在首次需要时自动 gem install；也可手动预装：
gem install cocoapods-mangle
# 幂等注入到 ios/Podfile 顶部（prefix 由 seed 派生）
./scripts/enable_pod_mangle.sh --seed com.your.bundle
# 之后正常 pod install / 构建即生效；移除：
./scripts/enable_pod_mangle.sh --disable
```

---

## AB 包工厂（步骤 5 独立按钮）

在 **AB 包工厂.app → 步骤 5 · 打包 IPA** 中：

| UI | 作用 |
|----|------|
| **打包 IPA** | 仅 `build_flutter_ipa.sh`，不做成品包混淆 |
| **IPA 路径** + **混淆 IPA** | 独立步骤：资源指纹 / 可选 Mach-O；可用工厂产物或任意外部 IPA |
| **Mach-O** 勾选 | 默认关；开启前需真机回归 |

打包成功后会自动把 `工作目录/ipa/` 下最新 IPA 填入路径框。描述文件取自上方 build_config 工作目录，混淆后自动重签。

工厂 UI 源码（随模板更新）：`packaging/ab_factory_app/app.py`

Framework 混淆（步骤 4）**默认不再**自动注入 cocoapods-mangle（避免与 `run_mutate_pods` /
`differentiate_binary_pod` 重叠，并降低闭源 SDK 运行时字符串查找风险）。需要时显式：

```bash
ZT_POD_MANGLE=1 ./scripts/obfuscate_frameworks.sh run -p dq
# 或
./scripts/enable_pod_mangle.sh --seed com.your.bundle && pod install
```

---

## 命令行 / 浏览器独立工具

任意来源的 IPA 可用**本地小工具**，不依赖 `build_config.json` / `flutter build`：

```bash
# 打开浏览器界面：IPA 路径输入框 +「开始混淆」按钮
./scripts/open_ipa_hardening_tool.sh
# 默认 http://127.0.0.1:8765/ ，关终端即停
```

命令行等价：

```bash
./scripts/harden_ipa_standalone.sh --ipa /path/in.ipa \
  [--out /path/out.ipa] [--seed com.bundle] [--resources] [--macho] \
  [--profile appstore.mobileprovision]
```

| 界面 / 参数 | 说明 |
|-------------|------|
| IPA 路径 | 必填 |
| 输出路径 | 可选，默认 `原名_hardened.ipa` |
| Seed | 可选，默认从 IPA 读 Bundle ID |
| 资源差异化 | 默认开 |
| Mach-O | 默认关 |
| 描述文件 | 填则加固后重签；不填则输出未签名包 |

---

## 手动 / 环境变量门控（工厂内嵌）

`resign_ipa.sh` 与 `build_and_resign.sh` 在**重签名前**已内置可选调用，通过环境变量开启：

```bash
# 只做资源差异化（低风险）
ZT_IPA_OBFUSCATE=1 ./scripts/build_and_resign.sh <work_dir>

# 资源 + Mach-O 类名混淆（需真机回归后再进产线）
ZT_IPA_OBFUSCATE=1 ZT_IPA_MACHO=1 ZT_IPA_SEED=com.your.bundle ./scripts/resign_ipa.sh app.ipa
```

| 变量 | 含义 | 默认 |
|------|------|------|
| `ZT_IPA_OBFUSCATE` | `1` 启用 / `0` 关闭成品包混淆 | 见 build_config |
| `ZT_IPA_MACHO` | `1` 额外启用 Mach-O 类名混淆 | `0` |
| `ZT_IPA_SEED` | 差异化 seed | Bundle ID |
| `ZT_POD_MANGLE` | `1` 启用 Pod mangle（Framework 混淆 `run` 时注入 Podfile） | **关** |

## 独立处理一个 IPA

```bash
# 解包→资源差异化→重打包（未签名，需再 resign_ipa.sh）
./scripts/obfuscate_ipa.sh --ipa in.ipa --out out_unsigned.ipa --seed com.your.bundle
./scripts/resign_ipa.sh out_unsigned.ipa
```

## 建议顺序（4.3a 全链路）

1. 源码/依赖层：`obfuscate_frameworks.sh run` + `obfuscate_code.sh --all`（含 Pod 源码变异与二进制 bundle 差异化）
2. 打包：`build_flutter_ipa.sh`（仅构建，不做成品包混淆）
3. 成品包层（可选）：步骤 5「混淆 IPA」或 `harden_ipa_standalone.sh`（资源默认开，Mach-O 默认关）
4. 回测：真机冒烟 + `verify_review_simulator.sh compare` 相似度比对
