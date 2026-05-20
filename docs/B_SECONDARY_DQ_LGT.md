# B 面项目代号（dq / lgt）

本模板**仅维护**两条 B 面同步与混淆线：

| 代号 | 业务 | 源工程示例 | 同步/兼容基线 | 说明 |
|------|------|------------|---------------|------|
| **dq** | 斗球 / 直播 | `xty`（如 `/Users/t-yh/dqiu/xty`） | 原 **tx**（主入口 + 请求 + 加解密）+ xty 实际 `main.dart` | `scripts/compat/compat_dq.sh` 生成入口；Framework/dep 字符串清单见 `project_manifests/dq.conf`、`dep_strings_manifests/dq.conf`（内容来自原 hjsq 媒体向） |
| **lgt** | 聊个天 / IM | 本地路径自行配置 | 原 **tx** 壳工程入口（GsUtil 多容器）+ 原 **acfun** 级 API/服务调用栈覆盖 | `compat_lgt.sh`；清单 `lgt.conf` 来自原 **tx** |

## 命令示例

```bash
./scripts/sync_secondary.sh --init-config   # 生成 sync_secondary.conf（含 dq 默认路径）
./scripts/sync_secondary.sh -p dq -s /Users/t-yh/dqiu/xty
./scripts/obfuscate_code.sh -p dq --all
./scripts/obfuscate_frameworks.sh run -p dq
```

`ab_config.yaml` 中 `project` 字段应为 `dq` 或 `lgt`（同步脚本写入）。
