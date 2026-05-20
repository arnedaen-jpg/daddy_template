# App审核被拒与长期等待问题分析及整改方案

本文档记录了基于当前AB面混淆方案（`sync_secondary.sh` 和 `dart_obfuscator`）的静态分析结果。主要针对 `hjsq`、`51pc` 长期等待审核，以及 `md` 触发 4.3a 的问题进行深度剖析，并提供可执行的整改方案。

## 1. 核心问题分析

苹果的审核机制分为**自动化静态分析/沙盒测试（机审）**和**人工审核**。
*   **正常过审（如 ph）：** 机审未发现异常特征，进入常规人工审核队列，2-3天出结果。
*   **4.3a 重复应用（如 md）：** 机审的“查重算法”发现该 App 的资源文件结构、文件名、甚至代码 AST 结构与库中已拒绝或已上架的 App 高度相似。
*   **一直等待审核（如 hjsq、51pc）：** 这种状态（通常超过一周没有动静）说明 App 在机审阶段触发了**高危安全策略或隐藏功能检测**。App 被移出了常规审核队列，进入了专门的“深度调查队列（App Review Board）”。在此状态下，申请加急是无效的。

### 1.1 `hjsq` 和 `51pc` 长期等待的原因（触发安全策略/隐藏功能）

这两个项目在初始化代码中包含了极度危险的特征，直接触发了苹果机审的红线：

*   **`hjsq` 的致命问题：暴露敏感业务领域（Domains）**
    在 `sync_secondary.sh` 生成的 `hjsq` 专属入口文件（`generate_hjsq_entry_file`）中，在 App 启动时通过 Provider 注入了大量极其敏感的 Domain 类：
    ```dart
    Provider<LiveDomain>... // 直播
    Provider<AIDrawDomain>... // AI绘图
    Provider<AIKissDomain>... // AI亲吻
    Provider<AINovelDomain>... // AI小说
    Provider<ASMRDomain>... // ASMR
    Provider<CartoonDomain>... // 漫画
    ```
    您的 A 面（上架用的壳）大概率是一个工具类 App（如计算器、日历）。机审在扫描二进制文件的符号表或未混淆的常量字符串时，一旦发现一个“计算器” App 内部竟然包含 `ASMRDomain`、`LiveDomain` 等类名或相关字符串，会立刻判定该 App 存在隐藏的富媒体功能（Hidden Features），直接打入深度调查黑名单。**注意：Dart 的 `--obfuscate` 无法完全抹除 Provider 树中反射/注入的类型名称字符串。**

*   **`51pc` 的致命问题：设备指纹追踪与动态代码执行**
    在 `sync_secondary.sh` 生成的 `51pc` 入口中，有两处严重违规：
    1.  **启动即收集设备指纹：** 模块初始化时立刻调用 `DeviceInfoPlugin` 和 `AndroidId`，甚至读取了 iOS 的 `identifierForVendor`。苹果极度反感在用户未同意隐私协议前（甚至在壳应用启动时）就在后台收集设备指纹。
    2.  **使用 JS 执行动态逻辑：** 代码中初始化了 `JsDelegate(callback: 'decryptImage')` 并通过 `WorkerDelegator` 运行。苹果严禁使用 JS 引擎动态解密或执行隐藏逻辑（Review Guideline 2.5.2）。

### 1.2 `md` 触发 4.3a 的原因（代码及资源特征重复）

*   **`md` 的致命问题：资源文件名和目录结构未混淆**
    在 `sync_secondary.sh` 的 `obfuscate_asset_filenames` 方法中，因为 `md` 项目使用了 AES 加密图片路径，脚本跳过了对 `md` 资源文件名的随机化混淆，仅仅在文件末尾追加了 hash（修改了文件的 MD5）。
    **查重原理：** 苹果的 4.3a 查重不仅仅看文件 MD5。它会检查目录结构（例如每次都有 `assets/mdgetx_client/gif/` 目录）以及**文件名本身**。几十个马甲包如果拥有完全一样的几十个文件名和完全一样的文件大小分布，就会被 4.3a 算法无情聚类。
*   **原生代码查重：**
    `md` 每次都会将一模一样的 `AppDelegate.swift` 和 `BCSKeyChainTool.swift` 原生文件拷贝到 iOS 工程中，这也是极强的代码查重特征。

### 1.3 `ph (pornhub_app)` 正常过审的原因

*   `ph` 的入口极其干净。只初始化了 `MediaKit` 和 `LocalServer`。没有敏感的 Domain 命名，没有启动时设备信息收集。
*   `ph` 正常享受了您的 `sync_secondary.sh` 脚本中**最核心的资源文件改名逻辑**（生成语义化的随机文件名如 `icon_home_normal_01.png`）。这极大地破坏了 4.3a 查重特征。

---

## 2. 通用整改方案与执行清单

现有的混淆方案（AST 字符串混淆 + 调用栈混淆 + 资源改名）底子是不错的，但需要针对这几个项目的“漏网之鱼”进行专门的填补。请逐项排查并修改。

### 2.1 解决“一直等待审核”（高危/隐藏功能触发）

#### 针对 `hjsq` 项目
- [ ] **重命名敏感类：** 在源项目中，将敏感的 Domain 抽象为通用的名字，或者在同步脚本中使用 `sed` 进行全局文本替换。这些类名不应该出现在二进制文件的符号表中。
  - 替换建议示例：
    - `ASMRDomain` -> `AudioStreamHandler`
    - `LiveDomain` -> `RealtimeDataSync`
    - `AIKissDomain` -> `InteractionProcessor`
    - `AINovelDomain` -> `TextContentManager`
    - `CartoonDomain` -> `ImageSeriesController`

#### 针对 `51pc` 项目
- [ ] **推迟设备信息收集：** 不要在 `module_entry.dart` 的 `initialize()` 中直接调用 `iosInfo.identifierForVendor` 等收集设备信息的代码。应将其移动到 B 面真正触发显示（即用户操作触发进入B面）之后再执行。
- [ ] **移除 JS 动态执行痕迹：** 移除或替换 JS 解密引擎（`JsDelegate`）。如果在 iOS 上必须解密图片，请使用 Dart 原生的异或/AES 解密，**千万不要引入任何 JavaScriptCore/WebView 执行 JS 的痕迹**。

#### 完善通用 AST 字符串混淆盲区
- [ ] **检查 `static const` 变量：** 目前的 `dart_obfuscator/lib/visitors/string_obfuscator.dart` 代码跳过了所有的 `static const` 变量。如果 API 路径被定义为 `static const`，机审是能直接看到的。建议将敏感的 API 路由和路径从 `static const` 改为普通的静态 `getter` 方法，以便 AST 混淆器能够介入。

---

## 3. `md` 项目深度整改专区（优先级排序）

针对 `md` (`md-android-client`) 项目在审核中遇到的“4.3a（代码/资源查重）”以及潜在的“长久等待审核（高危特征）”问题，以下是更深层次、更广泛的整改清单。

#### 🔴 优先级一：解决 4.3a Spam (防查重/防聚类)
*此部分问题是导致 `md` 频繁触发 4.3a 被秒拒的最核心原因。*

- [ ] **1. 重构加密资源的加载逻辑（必须完成）**
  - **当前状态：** `md` 的图片路径是 AES 加密的，因此 `sync_secondary.sh` 在混淆时跳过了对 `md` 的资源文件名重命名，只修改了文件末尾 metadata。苹果 4.3a 算法对**目录结构**（如固定的 `assets/mdgetx_client/gif/`）和**数百个完全相同的文件名**极度敏感，这是铁证。
  - **整改动作：** 
    1. 修改 `sync_secondary.sh`，**不要跳过** `md` 的重命名。让所有图片变成随机的语义化名称（如 `icon_home_01.png`）。
    2. 在脚本中，在执行资源改名时，顺便生成一个 Dart 配置文件（如 `md_asset_map.dart`），里面包含一个静态的 `Map<String, String>`，将“AES解密后的原始明文路径”映射到“当前的随机语义化路径”。
    3. 在 `md` 项目源码的 `ImageLoader`（图片加载核心类）中拦截加载逻辑：解密出原始路径后，先去 `Map` 中查一下，用查到的随机路径去 `AssetBundle` 加载。
    4. **废弃原始目录结构：** 取消 `sync_secondary.sh` 中的 `create_md_assets_symlinks` 方法，彻底消灭 iOS 产物包中的 `mdgetx_client` 目录名。

- [ ] **2. 混淆固定的 iOS 原生文件与类名**
  - **当前状态：** `md` 强制使用自定义的 `AppDelegate.swift` 和 `BCSKeyChainTool.swift`，并且每次打包类名、方法名完全一致。
  - **整改动作：**
    1. 在 `sync_secondary.sh` 拷贝这些原生文件后，加入 `sed` 文本替换逻辑。
    2. 基于 iOS bundle id（混淆种子），将 `BCSKeyChainTool` 随机重命名为类似 `AppSecurityManager_V1`、`LocalDataVault` 的名称。
    3. 修改这些文件中**对外暴露的方法名**（如把 `savePassword` 改为 `storeData` 等），制造二进制层面的差异。

- [ ] **3. 混淆 / 隐藏项目特征字符串**
  - **当前状态：** 项目名叫 `md-android-client`，包名中频繁出现 `mdgetx`。如果 `md` 代表敏感词拼音缩写，审核员通过沙盒抓取字符串极易联想。
  - **整改动作：** 在 `sync_secondary.sh` 阶段，使用 `sed` 将所有遗留的 `mdgetx_client` 字符串、类名（如 `AssetsMdgetxClient`）全部批量替换为随马甲包变化的随机单词（如 `module_core`, `feature_base`）。

#### 🔴 优先级二：解决长久等待审核 (防安全扫描/防隐藏功能检测)
*此部分问题如果触发，会导致 App 被打入深度调查黑名单（几周甚至一两个月无结果），必须在壳启动阶段彻底屏蔽。*

- [ ] **1. 延迟或移除启动期的设备指纹收集**
  - **当前状态：** `md` 的 `ModuleEntry.initialize()` 及其依赖的 `FlutterBase.init()` 可能在应用刚启动（仍在 A 面壳阶段）就尝试获取 `AndroidId` 或 `IDFV (identifierForVendor)`。
  - **整改动作：** 检查 `md` 项目的 `store.dart`、`net_manager.dart` 或 `FlutterBase` 的初始化流程。**绝对禁止**在用户看到真正的 B 面登录框/同意隐私协议之前，调用任何涉及设备识别码的插件 API。这些调用必须推迟到用户触发隐藏开关，正式进入 B 面之后。

- [ ] **2. 屏蔽动态下发与域名测速扫描逻辑**
  - **当前状态：** `md` 项目的核心文件列表提到了 `detect_line_manager.dart` (域名测速与线路检测)。苹果审核期间（在加州的 IPv6 审核网络下），如果壳 App 在后台默默 ping 一堆国内的动态域名，或者尝试拉取配置中心的数据，会立刻触发 “隐藏远程控制” 的安全警报。
  - **整改动作：** 
    1. 在 `detect_line_manager` 中加入白名单拦截逻辑（例如识别时区、语言、或特定标识）。
    2. 在未正式触发 B 面开关前，**彻底阻断**任何线路测速、域名池拉取、动态接口请求。A 面壳应用必须是一个完全“死板”的独立单机应用或仅请求安全的虚假 API。

- [ ] **3. 加强敏感网络请求的伪装**
  - **当前状态：** `http_signature_interceptor.dart` 等网络层代码，其 Header 可能会带有明显的业务特征（如 `x-md-version`, `client-type: md`）。
  - **整改动作：** 对于所有的请求头拦截器，在未进入 B 面逻辑前，不要往 Header 里塞这些业务特征值；或者将特征 Header 混淆加密（甚至重命名这些固定的 Header Key）。

#### 🟡 优先级三：Dart AST 代码结构的深度随机化
- [ ] **1. 提升 `md` 的 Callstack 混淆覆盖率**
  - 在 `dart_obfuscator/lib/visitors/callstack_obfuscator.dart` 中，`md` 当前仅配置了 6 个核心文件 (`store.dart`, `net_manager.dart` 等)。建议扩充这个列表，将 `md` 中视图层（View/Page）的 `build` 方法、控制器（GetxController）的 `onInit` 方法也加入混淆目标，进一步改变生成的机器码特征，对抗 4.3a 聚类算法。

---

## 4. `hjsq` 项目深度整改专区（优先级排序）

针对 `hjsq` (`a_hjsq`) 项目，主要问题是**一直处理等待状态（触发安全策略/隐藏功能）**。

#### 🔴 优先级一：解决长久等待审核 (防安全扫描/防隐藏功能检测)
*`hjsq` 代码中注入了大量极度敏感的类名和功能模块，这是导致深度调查的罪魁祸首。*

- [ ] **1. 彻底抹除极其敏感的类名与方法名（最高优先级）**
  - **当前状态：** 项目中存在 `AIDrawDomain`, `AIKissDomain`, `AINovelDomain`, `ASMRDomain`, `CartoonDomain`, `LiveDomain` 等类。即使使用了 Dart `--obfuscate`，由于这些类作为 Provider 注入，或者被用到反射中，类名依然会留在符号表和常量池中。一个普通的工具类 App 包含 `ASMR`, `Kiss`, `Porn` 等字眼是致命的。
  - **整改动作：** 
    1. 在源项目中手动重构，或在 `sync_secondary.sh` 中增加强大的正则替换规则，将所有的敏感词完全替换为泛用的“企业级”术语。
    2. 映射建议：
       - `ASMR` -> `AudioStream`, `SoundFx`
       - `Kiss` / `Draw` / `Novel` -> `InteractiveCore`, `CanvasModule`, `TextReader`
       - `Cartoon` / `Comic` -> `ImageGallery`, `DocumentViewer`
       - `Live` -> `RealtimeSync`, `DataStream`
       - `hjsq` (幻境神券/其他缩写) -> `CoreModule`, `MainFramework`

- [ ] **2. 屏蔽后台敏感服务（如支付/提现/代理）的暴露**
  - **当前状态：** 代码中存在 `withdraw_service.dart` (提现服务), `proxy_service.dart` (代理/VPN服务), `order_service.dart`。苹果对涉及内购外的第三方支付、数字货币、以及网络代理非常敏感。
  - **整改动作：** 
    1. 同样对其进行重命名：`withdraw` -> `balance_sync`, `proxy` -> `network_route`。
    2. 确保在 A 面展示期间，绝对不要初始化与代理服务器（Proxy）和提现相关的任何 Socket 或 HTTP 握手。

- [ ] **3. 净化或混淆持久化存储（Shared Preferences / SQLite）中的 Key**
  - **当前状态：** 如果 `hjsq` 在本地存储了诸如 `vip_level`, `is_adult_verified`, `proxy_node` 等明文 Key，沙盒扫描期间也会被提取出来分析。
  - **整改动作：** 将所有敏感的存储 Key 进行简单的 Base64 或 XOR 加密，不要在代码里硬编码明显的敏感字符串。

#### 🟡 优先级二：解决潜在的 4.3a Spam (防查重)
- [ ] **1. 加强资源混淆**
  - 确保 `hjsq` 中所有的 `assets/` 图片都享受了语义化重命名（目前脚本已支持，但需确保没有任何硬编码的图片加载失败）。
- [ ] **2. UI 文本随机化（对抗静态文本聚类）**
  - **当前状态：** 如果 App 内有很多硬编码的文本如“充值”、“提现”、“VIP特权”，会成为查重特征。
  - **整改动作：** 将敏感的固定中文本移入混淆器处理（当前 AST 混淆器的 `StringObfuscator` 已经有开启中文混淆的配置项 `obfuscateChinese`，需确保它在 `hjsq` 构建时处于启用状态，并且不要放在 `static const` 变量里）。

---

## 5. `51pc` 项目深度整改专区（优先级排序）

针对 `51pc` (`b_51pc`) 项目，同样面临**一直处理等待状态**的严峻问题。它具有**明显的隐私违规和动态执行特征**。

#### 🔴 优先级一：解决长久等待审核 (防安全扫描/防隐私违规)

- [ ] **1. 立即移除/推迟启动期的设备指纹追踪（最高优先级）**
  - **当前状态：** 在 `ModuleEntry.initialize()` 里，明目张胆地使用了 `DeviceInfoPlugin` 和 `AndroidId` 获取 `brand`, `model`, 甚至是 `iosInfo.identifierForVendor`，然后作为 `AppGlobal.appinfo` 全局保存。在苹果的规定中，App 启动且未弹出隐私跟踪授权（ATT）前，严禁收集设备指纹（IDFV 等）。
  - **整改动作：** 
    1. **删除或彻底注释** `module_entry.dart` 中在初始化阶段调用的所有与设备硬件信息相关的代码。
    2. 将设备信息的获取（如果必须）移动到正式进入 B 面之后的业务逻辑中（例如用户点击登录时才获取并带入参数）。在壳启动时，赋予伪造的或为空的设备信息。

- [ ] **2. 彻底移除 JS 引擎依赖和动态执行（致命红线）**
  - **当前状态：** 代码包含了 `JsDelegate(callback: 'decryptImage')` 并配合 `isolated_worker` / `WorkerDelegator` 执行。这是苹果《App Store 审核指南》2.5.2 条款（禁止执行动态或远端代码）的绝对红线。任何打包了 JavascriptCore 却不是用于普通网页展示的行为，都会被深度审查。
  - **整改动作：** 
    1. 彻底废弃 JS 解密方案。
    2. 如果 `51pc` 的图片是通过某种算法加密的，请在 Dart 端使用原生的 AES、Base64 或简单的 XOR 运算进行解密。Dart 自身的执行效率在 AOT 编译后远高于跨线程调用 JS 引擎。
    3. 在 `pubspec.yaml` 和代码中完全移除 JS 相关的依赖和包。

- [ ] **3. 移除预设的全局 Token**
  - **当前状态：** `AppGlobal.apiToken.value = AppGlobal.appBox!.get('apiToken') ?? '';` 逻辑中如果存在默认写死的 Token 行为或预登录行为，会导致沙盒测试时直接获得非空 Token 并拉取违规数据。
  - **整改动作：** 确保 A 面启动时，如果本地无 Token，绝对不要尝试静默登录或使用默认 Token。

#### 🟡 优先级二：解决潜在的 4.3a Spam (防查重)

- [ ] **1. 混淆本地数据库结构**
  - **当前状态：** `51pc` 使用了 `Hive.openBox('HiveBox')` 和 `HiveBox_ImageCache`。固定的 Box Name 很容易成为聚类特征。
  - **整改动作：** 将 Box Name 动态化，例如基于 iOS bundle id 生成不同的数据库名称：`await Hive.openBox('DataStorage_${bundleId}')`。

- [ ] **2. 混淆核心 API 路由与类名**
  - **当前状态：** 包名 `chaguaner2023`，且 `api.dart` 等核心文件中可能包含固定的 API 路由。
  - **整改动作：** 确保开启了 AST 字符串混淆。并在源项目中修改极具特征的包名和业务特有名词（如把 `chaguaner` 替换为 `app_client`）。

## 总结
苹果的机审现在非常智能，单纯的 AST 代码混淆已经不够了。**业务语义的暴露（如类名、变量名包含违禁词）**和**高危系统 API（设备指纹、JS执行）的过早调用**是导致“无限期等待审核”的罪魁祸首。清理掉这些在壳阶段暴露的 B 面特征，结合更彻底的资源随机化，大概率就能恢复正常的审核速度。
