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
