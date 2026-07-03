# AB 包制作操作指引

本文档包含 AB 包制作的所有相关事项，每位提包人员都要仔细阅读。

## 一. AB 包制作流程
AB 包制作流程大致分为 3 条线，分别是开发者账号、 APP 开发、提审，前 2 条线可并行，最后提审。

### 开发者账号
1. 登录开发者账号 -> 创建 bundle id -> 使用 `gen_csr.sh` 脚本创建 CSR -> 创建 appstore 发布证书并下载 -> 创建 appstore 描述文件并下载。
2. 进入 appstore connect 后台 -> 生成 api key，得到 Issuer ID、KEY ID、p8 文件（下载）。

### APP 开发
1. 产生需要开发的 APP idea、相关功能列表等。（app icon 制作可以在这个步骤之后就进行）
2. 使用 `create_ab_project.sh` 脚本创建新项目(这里需要 bundle id，可以使用已有或预先创建，最终和开发者账号保持一致即可) -> 使用 `sync_secondary.sh` 脚本迁移 B 面代码 -> 运行成功&提交 git。
3. A 面开发 -> 运行成功&提交 git。
4. 在提包管理后台（https://admin.gzgshay3.com），添加 APP 配置，验证 AB 切换是否正常。
5. 使用 `obfuscate_frameworks.sh` 脚本混淆 -> git 查看混淆变化 -> 运行成功&验证功能完整。(目前在试用阶段，使用后要检查 b 面的兼容)
6. 使用 `obfuscate_code.sh -p <项目> --all` 脚本混淆（含文件膨胀等）-> git 查看混淆变化 -> 运行成功&验证功能完整。

### 提审
1. 在 appstore connect 后台填写 app 信息（类目、title、keywords、description、截图等等）。
2. 使用 `build_flutter_ipa.sh` 脚本打包 ipa（或在 AB 包工厂步骤 5 点「打包 IPA」）。
3. 在 AB 包工厂步骤 5 点 **「混淆 IPA」**（或 CLI `harden_ipa_standalone.sh`），对工厂产物或外部 IPA 做资源指纹差异化；可选 Mach-O。
4. 重签&真机验证（可选；混淆时若已填描述文件则已重签）。
5. 使用 `upload_ipa.sh` 脚本上传 ipa。
6. 所有信息 ready，提交审核。
7. 在提包管理后台将该 APP 配置置为已提审状态。

## 二. 开发者账号
### 账号分配
每个 APP 使用一个独立的开发者账号。
1. 提包人员需要开发者账号，提前找阿汤 TG 申请。
2. 账号分配后，可以在提包管理平台->开发者账号，看到最新分配的开发者账号。

### 账号使用
提包人员拿到苹果开发者账号后，在指纹浏览器（AdsPower）环境中登录使用。
- 开发者账号都是网页号，除了指纹浏览器，不要在任何其它地方登录，可能触发风控。
- 在环境中打开 https://developer.apple.com/ 登录分配的苹果开发者账号。分配的账号信息会有配套的接码链接，发送code后，打开链接即可接码。
- 登录账号成功后，查看 Membership details 是否正常（一般都是开通的），同时将 Team ID复制出来（打包需要）。
- 大多数情况，一个开发者账号分配下来，接码有效期内（大于1个月），足以上架一个 app。
- 在 app 上架成功后，验证切换 ab 正常、B 面运行正常、后续不再更新 app，提包人员手动将该该进行归档，后续不再接码续费。

注意：使用拿到的账号登录时，可能会碰到被苹果锁定，申请解锁第 2 天即可使用；有较低概率碰到账号被封，提示信息为 "Need assistance with accessing your developer account?"，反馈给阿汤并再申请一个账号。

### 指纹浏览器
每个提包人员都会分配到一个指纹浏览器账号，该账号也是提包管理后台的账号。
- 未被标签的环境都可以使用，使用后标签上自己的花名，防混用。
- 每个环境都已配置好了默认的动态代理，不要使用 vpn 代理。
- 开发者账号使用的指纹浏览器环境，ip 应该与账号注册地保持一致。比如开发者账号是土区的，那么当前指纹浏览器环境ip配置动态代理的国家/地区选择土耳其，需要手动修改。
- 打开环境后，页面显示出正确的ip地区，表示动态ip分配正常。
- 在 AdsPower 里面，碰到 ip 刷不出来，可以使用 http://next.ipfoxy.io/ 来刷新代理。
- AB 包过审后不再更新，且开发者账号归档。后面可以复用该环境，重置掉指纹，修改浏览器内核等。

## 三. AB 包壳工程
当前 flutter 代码工程就是壳工程。使用 `create_ab_project.sh` 脚本生成新的 AB 代码工程，与当前代码一致，包括所有脚本。

### 创建 AB 代码工程

1. 调用 daddy_template 中的 `create_ab_project.sh` 生成 A 面 app 新工程，比如 `./scripts/create_ab_project.sh -n myapp_aiagent -b com.myapp.aiagent -d "AIAgent"`。编译运行成功，进入下一步。
2. 在新的 myapp_aiagent 代码工程，根据业务，调用 `sync_secondary.sh` 迁移 B 面，例如 `dq`（斗球/xty）或 `lgt`（聊个天）：`./scripts/sync_secondary.sh -p dq -s /Users/t-yh/dqiu/xty`。编译运行成功，可手动切换到 B 面成功，进入下一步。

需要隐藏 B 面图片时使用 `--base64-map`，例如 `./scripts/sync_secondary.sh -p dq -s /Users/t-yh/dqiu/xty --base64-map`。

  注：当前 B 面仅保留两个代号 **`dq`**、**`lgt`**（详见 `docs/B_SECONDARY_DQ_LGT.md`）。在 `sync_secondary.conf` 中配置 `PROJECT_LGT` 后再同步 `lgt`。
3. 制作 A 面，核心代码写在 `modules/primary` 中。已有的 B 面代码入口为 `lib/modules/secondary/module_entry.dart`。

### 开发者面板
壳工程 APP 运行后有个开发者面板，用于 AB 面调试。
- 默认 debug 模式下会显示开发面板，用于一些测试开发。
- 在面板里可以切换 AB 配置下发网络环境、切换 AB 面、跳过静默期。
- 打包后的 ipa 运行，不会显示该开发者面板。

静默期机制
- APP 提交审核，为了规避机审对网络请求的特征扫描，壳工程内置了静默期机制。
- 默认 3 天内，APP 不会进行 AB 配置请求，3 天后才会触发。
- 可以在开发者面板进跳过这个机制，进行开发调试。
  
注意：如果打包使用第三方混淆工具，提包者在混淆前，需要手动执行 `./scripts/update_silent_period.sh`，更新代码中的静默期。

## 四. 混淆
混淆是当前提包业务必须要执行的步骤，混淆工分为 4 部分。

### 图片资源混淆
前面使用 `sync_secondary.sh` 进行 B 面代码同步时，会对图片资源进行提前处理（与 `--base64-map` 等组合有关；具体以 `sync_secondary.sh` 与 compat 逻辑为准）。

### framework 混淆（试用阶段）
使用 `./scripts/obfuscate_frameworks.sh run` 命令对 b 面部分（有些不能重命令）frameworks 进行重命名。

### 代码混淆
使用 `./scripts/obfuscate_code.sh -p <项目> --all` 命令对 B 面代码进行混淆（含字符串、调用栈、文件膨胀、业务噪音、AST 变异、符号扭曲）。也可按需组合 `--string`、`--callstack`、`--bloat` 等。

**重要**：必须指定 `-p` 为 **`dq` 或 `lgt`**，否则无法保证多包间差异化，尤其影响 4.3a 应对效果。脚本会尝试从 `ab_config.yaml` 或 `sync_secondary.log` 自动检测项目，但建议显式指定。

#### 文件膨胀（4.3a 差异化）
文件膨胀用于缓解 App Store 4.3(a) 多包相似度拒审：多个 AB 包共用同一 B 面时，审核端可能判定「大部分代码都一样」。通过为 **dq 与 lgt 各自**注入**不同的**冗余代码，降低包间二进制相似度。

- **默认已包含**：`obfuscate_code.sh -p <项目> --all` 已包含 `--bloat`，无需单独执行。
- **单独执行**：`./scripts/obfuscate_code.sh -p dq --bloat` 仅做文件膨胀；可组合 `--noise`、`--mutation`、`--symbols` 等（`lgt` 时换 `-p lgt`）。
- **稳定 seed**（可选）：若需 Crashlytics 符号映射稳定，可加 `-b <bundleId> -V <version>`。

详见 [OBFUSCATION_BLOAT.md](OBFUSCATION_BLOAT.md)。

### dart 混淆
执行打包脚本 `build_flutter_ipa.sh` 时，会自动加上官方 dart 代码混淆效果。

### 成品包加固（4.3a，步骤 5 独立操作）

针对**二进制 Pod / 成品 IPA** 的差异化，在 **AB 包工厂 → 步骤 5** 中单独提供（与「打包 IPA」按钮分离）：

| 手段 | 位置 | 说明 |
|------|------|------|
| **cocoapods-mangle** | 步骤 4 Framework 混淆（可选） | 默认关；`ZT_POD_MANGLE=1` 时 `run` 注入 Podfile |
| **资源指纹 / Mach-O** | 步骤 5「混淆 IPA」 | 填 IPA 路径后点击；可处理工厂产物或外部 IPA |

- **打包**：`build_flutter_ipa.sh` **不再**自动做成品包混淆；打包成功后工厂会把 `工作目录/ipa/*.ipa` 填入「IPA 路径」。
- **混淆**：在步骤 5 点 **「混淆 IPA」**；勾选 Mach-O 为可选项（需真机回归）。使用工作目录下的描述文件自动重签。
- 命令行等价：`./scripts/harden_ipa_standalone.sh --ipa /path/in.ipa [--profile ...]`

## 五. 打包 ipa

### 信息收集
打包 ipa 和使用 App Store Connect API 上传 ipa 需要一些文件和信息，需要提前收集.
1. 提前在本机创建一个工作目录，比如 TestApp。
2. 打开 App Store Connect，进入 Users and Access -> Integrations，在 App Store Connect API 中点击 Request Access，然后点击 Generate API Key 生成 admin 权限的 key。将 Issuer ID、KEY ID 复制出来保存，并下载 key 文件（.p8），放到 TestApp 目录中的 private_keys 目录（新建）。
3. 打开 Identifiers，创建 App ID，比如 com.testapp.tibao9527。
4. 打开 Certificates，选 iOS Distribution (App Store Connect and Ad Hoc)即可，不需要开发证书。这时需要 CSR，使用壳工程中的 `gen_csr.sh` 来生成，这时会同时生成一个.key文件，后面打包会用到。然后生成发布证书（ios_distribution.cer），下载到工作目录（TestApp）。
5. 打开 Profiles，选择 Distribution 中的 App Store Connect 即可，只用于发布。生成 appstore.mobileprovision，下载到工作目录（TestApp）。


### 打包 ipa

1. 在工作目录（如 TestApp）中创建 `build_config.json`，参考 `scripts/build_config.json.example`：

```json
{
  "bundle_id": "com.testapp.tibao9527",
  "team_id": "N7K9UNDX7X",
  "profile": "appstore.mobileprovision",
  "certificate": "ios_distribution.cer",
  "private_key": "mykey.key",
  "export_dir": "ipa",
  "signing_style": "manual",
  "flutter_build_mode": "release"
}
```

2. 确保工作目录结构如下：
```
TestApp/
├── build_config.json
├── appstore.mobileprovision
├── ios_distribution.cer (可选，如已导入钥匙串)
├── mykey.key (可选，如已导入钥匙串)
└── private_keys/
    └── AuthKey_XXXXX.p8 (上传用)
```

3. 在 Flutter 代码工程根目录执行打包脚本 `./scripts/build_flutter_ipa.sh /path/to/TestApp`
4. 打包完成后，IPA 文件将生成到工作目录的 `ipa/` 文件夹。**默认**会执行成品包资源指纹差异化并重签（见上文「成品包加固」）。


### 重签
打包&混淆后的 ipa，为了验证其功能是否正常，可以将已混淆的 ipa 进行重新签名，安装到真机上体验。
- 重签使用的是正规的开发者账号，验证重签的真机，必须是未被关联审查过的。可以联系阿汤，将自己的真机 UDID 更新真机 mobileprovision。
- 执行 `./scripts/resign_ipa.sh '/Users/user/Documents/apps_info/ipa/app.ipa'` 脚本，对已有的 IPA 进行重新签名。
- 使用 Apple Configurator 工具安装重签后的 IPA，即可体验。

## 六. 上传 ipa
上传 ipa 需要 build_config 里的 apple_api_key 和 proxy 信息完整。

1. apple_api_key 信息在前文中有提到如何收集。
2. proxy 动态代理链接由提包人员在提包管理平台->动态代理模块生成，然后复制到 build_config 中，需要具体的国家&地区。

信息准备完毕，在当前代码工程命令行执行 `./scripts/upload_ipa.sh /path/to/TestApp`，参数是工作目录，跟前面的打包 ipa 一样。进入上传 ipa 流程，当看到 '[SUCCESS] 上传成功' 字样时，表示上传成功，过几分钟后就可以在 appsstore connect Build 中看到。

## 七. APP 提审

### 隐私和 support url
使用 https://app.freeprivacypolicy.com/ 注册生成链接。

### 检查项
1. A 面UI 必须适配 ipad，否则出现无法显示的内容和交互，审核必被拒。审核人员是使用 ipad 进行审核流程的。
2. 在提管管理平台，使用定向设备/ip下发B面，验证 AB 切换是否正常。
3. B 面运行适配是否正常。
4. 重签验证是否会 crash。（可选）

### APP 审核应对（重要）
- 提交审核后，正常是 2-3 个工作日左右进入审核。如果超过这个时间未进入审核，向苹果提交审核加急。
  - 加急后 2 天内还没有进入审核，撤下该 app，修改代码功能、app 名称 等信息，再次提交审核。
- APP 审核通过后，提包管理平台会自动更新状态。
- APP 审核被拒后，提包人员在提包管理平台->App 配置管理中，修改 APP 被拒审状态，记录被拒信息。
- 若碰到被拒审 4.3a，进入 appconnect 后台，查看审核状态变更时间记录，并反馈给阿汤。
  - 机审 4.3a（进入审核 -> 被拒时间间隔几十分钟以内），直接放弃该 app 和账号。
  - 人审 4.3a，可尝试丰富 app 的功能，再次提交申诉（有一定机率成功）。

## 八. 制作 A 面（AI 篇）
在 B 面迁移完毕，运行成功后，开始 A 面制作。产生 idea、ai coding、生成 icon、填写 appstore connect 信息等。

1. 产生 idea。与 AI（chatgpt、gemini等）进行对话，AI 可能会给你很多普通 idea，在应用商店已经非常多了，比较难上架，你需要识别。这时你需要限制 idea 范围，更容易上架成功的类目 idea。如果不满足，就让 AI 换一个。或者你可以直接排除掉不想做的一些普通 APP，比如记事本、闹钟、备忘录等等。
2. 生成 APP 功能列表。有了 idea 后，让 AI 帮你生成完整的 app 功能列表，反复对话进行调整，比如加上多语言切换、主题切换、用户引导等。最终确定 A 面功能列表。注意功能列表必须是 flutter 代码技术可实现的，并且限制开发周期（1-3天）。
3. 生成完整代码提示词。有了完整的 A 面功能列表，根据它让 AI 生成完整的代码提示词（最好英文），这时提示词的开头，应该是：你是一位专业的 flutter 开发专家，需要根据以下功能列表进行编码...。在代码提示词中，加上 flutter 技术栈、基于已有的 B 面壳工程进行开发、不要修改 B 面代码、限定代码只能在 `lib/modules/primary`中、兼容 iOS 版本等等。最终将生成的代码提示词导出 md，保存到代码工程文档中。注意，必须是完整的代码提示词，不要分段的，这样效率最高。
4. AI 编码。使用 AI 基于提示词文档在当前代码工程进行编码，解决编译错误。AI 完成功能编译后，你需要运行进行调试，解决 UI 问题、功能实现不合理问题、审核适配问题等等。
5. 生成 APP icon。使用可以画图的 AI 大模型，将功能列表丢进去，生成一张 1024*1024 的图片。在 https://www.appicon.co/#app-icon 对图片进行裁剪生成适配 iOS 项目的 icon，拖到工程资源文件夹。
6. 生成上架信息。使用 AI 基于已有的功能列表，生成符合苹果要求的上架信息，注意字段长度，不要有特殊字符。


## 九. 适配混淆改造重点
1. 尽量不要使用 const，改为 final。因为 const 不能运行时处理，只能预编译处理。能混淆的范围就比较有限，只有当字符串值无特殊意义时 hash 处理。
2. 包含在 const 结构中使用的字符串，去掉 const，比如 pb 中的 routes_register.dart。
3. 一些弹窗需要获取最外层 nav 的代码，需要改造，因为 B 面是在嵌入在壳工程中的。