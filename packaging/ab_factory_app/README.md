# AB 包工厂桌面应用

macOS 原生 UI：`AB包工厂.app`，与 `~/daddy_template` 脚本链配合使用。

## 更新 app.py

模板内维护副本路径（工厂启动时会尝试从模板覆盖自身）：

```
packaging/ab_factory_app/app.py
```

将修改后的 `app.py` 复制到上述路径并提交 `daddy_template`；在工厂里点「对齐脚本 / 更新模板」或重启工厂后生效。

也可直接替换：

```
AB包工厂.app/Contents/Resources/app.py
```

## 运行项目 · 高级侧栏（v6.10+）

「运行项目」区主界面保留：项目路径、设备、运行/停止/热更新等常用操作。

以下功能收进右侧滑出栏，点 **「高级」** 展开，再点 **「收起」** 或侧栏内 **「收起」** 关闭：

- 运行模式（Debug / Release）
- 修复模型（Cursor Agent 模型选择）
- **截屏修Bug** / **一键修Bug**
- 自动探查（模拟器巡检）
- 多图说明 / 截一张 / 多图提交修 Bug
- **修正导入** / **还原**（pubspec 与混淆 import 修复，使用步骤 2 目标工程路径）

## 指纹浏览器 · 防跟踪隔离（v6.9+）

步骤区新增 **「指纹浏览器 · 防跟踪隔离」**（基于 Camoufox）：

- 每个**身份**绑定独立 SOCKS5 代理 + 固化浏览器指纹，互不关联
- **添加身份**：名称 + 系统伪装（macOS/Windows/Linux）+ 语言 + 代理
- **打开浏览器**：手动操作窗口，关闭即结束会话；cookies 持久化
- **核验 IP/指纹**：无头检查出口 IP、时区、UA、屏幕等是否符合预期
- **换新指纹**：为当前身份重新生成一套指纹
- **安装依赖**（首次）：在 `~/Library/Application Support/ABFactory/camoufox-venv` 创建专用 venv 并下载 Camoufox（约 300MB）

数据目录：`~/Library/Application Support/ABFactory/fingerprint-browsers/`

实现文件：

- `packaging/ab_factory_app/fpbrowser/` — 指纹/代理/启动逻辑
- `packaging/ab_factory_app/fpbrowser_runner.py` — venv 与子进程封装

## 一键混淆（v6.8+）

对应脚本 `scripts/full_obfuscate.sh`（sync → obfuscate_code --all → obfuscate_frameworks run），拆成两个按钮：

- **步骤 2 · 「一键同步+混淆」**：完整链路 = 同步 B 面 → 工厂 pubspec 修复 → 代码混淆(--all) → Framework 混淆(run)。
  比直接跑 `full_obfuscate.sh` 多了工厂的 pubspec 修复，避免污染导致后续混淆失败。任一步失败即中止。
- **步骤 4 · 「一键混淆」**：只串联代码混淆(--all) → Framework 混淆(run)，不重新同步。适合 B 面已同步、只想重跑混淆。

两者均按当前所选「项目代号」显式传 `-p`，串行执行、输出实时写日志。

## 步骤 5 · 成品包混淆

v6.7+ 在「步骤 5 · 打包 IPA」内增加独立区块：

- **IPA 路径**：工厂打包产物或任意外部 `.ipa`
- **混淆 IPA**：调用工程/模板内 `scripts/harden_ipa_standalone.sh`
- **Mach-O**：可选勾选
- 与 **打包 IPA** 分离；打包不再自动做成品包加固

依赖脚本（需在工程或 `daddy_template/scripts/` 内）：

- `harden_ipa_standalone.sh`
- `obfuscate_ipa.sh`
- `macho_symbol_obfuscator.py`
- `ipa_hardening_lib.sh`
