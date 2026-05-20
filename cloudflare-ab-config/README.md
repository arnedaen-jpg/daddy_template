# daddy-ab-config（Cloudflare Worker）

与 `daddy_template` 中 `ConfigService` / `DomainManager` 约定的 **`GET /client/api/config`** 接口，使用 **KV** 存储当前 `A`/`B`，使用 **D1** 记录每次请求的客户端 IP 与 Cloudflare 边缘解析的归属信息。

## 前置

- [Cloudflare](https://dash.cloudflare.com) 账号；安装 Node.js 18+。
- 在项目目录执行：`npm install`

## 一次性创建资源

```bash
# KV 命名空间（记下 id）
npx wrangler kv namespace create CONFIG_KV

# D1 数据库
npx wrangler d1 create daddy-ab-logs

# 将 wrangler.toml 中 REPLACE_* 替换为上面命令输出的 id
```

应用数据库迁移（远程），**新增迁移后务必再执行一次**：

```bash
npx wrangler d1 migrations apply daddy-ab-logs --remote
```

- `0002`：为 `access_logs` 增加 `bundle_id`。
- `0003`：增加 `device_id`、`app_name`（管理页分页请求记录、按设备强制 B）。
- `0004`：增加 `remark` 列；**苹果 ASN 命中**时写入固定文案「苹果ASN」（管理页只读展示）。未执行则备注列为空（设备锁仍依赖 KV `apple_asn_lock_a_*`）。
- `0005`：增加 `ios_version`、`device_model`（来自请求头 **`X-iOS-Version`**、**`X-Device-Model`** 或 query `os_version`；与 `daddy_template` 中 `DeviceInfoManager` 一致）。管理页「设备 UUID」列第二行展示。

未执行对应迁移时，D1 写入可能报错或部分列不可用。

## 鉴权（生产必做）

默认与 Flutter `S.configAuthToken` 中字节解码后的字符串一致。部署后设置密钥（不要提交到 git）：

```bash
npx wrangler secret put CONFIG_AUTH_TOKEN
# 粘贴与客户端相同的 token，例如 daddy-shared-secret-replace-in-prod
```

若**不**设置 `CONFIG_AUTH_TOKEN`，Worker **不校验** Header（仅建议本地调试）。

## 写入默认 A/B 开关（按 Bundle ID）

客户端 **无需改模板**：`daddy_template` 里 `DomainManager._tryFetchConfig` 已通过 `DeviceInfoManager.getRequestHeaders()` 在配置请求上附带 **`X-Bundle-Id`**（即 iOS Bundle Identifier）。Worker **优先读该 Header** 选 KV；仅调试用 curl 时可传 query `bundle_id`。

- **按应用区分**：KV 键为 **`ab_config_<BundleID>`**，例如 `ab_config_com.example.myapp`，取值：`A` 或 `B`。
- **兜底**：若 Header 有 Bundle ID 但该键不存在，会再读全局键 **`ab_config`**；无 Header 时只用 **`ab_config`**。

```bash
# 某 Bundle 走 B 面
npx wrangler kv key put --binding=CONFIG_KV "ab_config_com.example.myapp" "B"

# 全局默认（无 bundle 或未配置时）
npx wrangler kv key put --binding=CONFIG_KV ab_config "A"
```

也可在 Dashboard：Workers → KV → 命名空间 → 添加键值。

**强制 B 与黑名单（与管理页一致，均存 KV）**  
判定顺序：**当前请求苹果 ASN（当次恒为 A）→ 曾命中苹果 ASN 的设备锁（`apple_asn_lock_a_<UUID>`，永久 A）→ 黑名单 → 设备强 B → Bundle 全员 B → `ab_config` / `ab_config_<BundleID>`**。

苹果网络依据 Cloudflare **`cf.asn`** 与内置兜底 ASN（714、6185、6594）及 **KV 同步结果** 的**并集**，并保留 **`cf.asOrganization` 含 “Apple”** 的兜底。管理页 **「更新苹果 ASN 列表」** 会向 [PeeringDB](https://www.peeringdb.com) 请求 **`/api/net?org_id=8418`**（Apple Inc. 在库内组织 ID），将返回的 ASN 列表写入 KV 键 **`apple_asn_fetched_json`**（JSON：`updatedAt`、`source`、`asns`）；Worker 每次判定前合并内置集与 KV（ isolate 内约 2 分钟缓存）。PeeringDB 数据由社区/运营商维护，**非苹果官方实时接口**；若拉取失败请稍后重试或继续依赖内置 + 组织名。

命中苹果 ASN 且请求带 **`X-Device-Id`**（或 query `device_id`）时写入 **`apple_asn_lock_a_<UUID>`**，该设备此后永久 A（**不再**自动写 IP 黑名单，避免同公网 IP 误伤）。若命中 ASN 但未带设备 UUID，则**仅当次**返回 A，无持久锁。

| 键前缀 | 含义 |
|--------|------|
| `apple_asn_fetched_json` | PeeringDB 同步的苹果 ASN 列表（与内置 ASN 并集后用于判定） |
| `apple_asn_lock_a_<UUID>` | 曾命中苹果 ASN 且上报过该 UUID 的设备永久 A |
| `device_force_b_<BundleID>\u001f<UUID>` | 该 Bundle 下该设备拉配置为 B（`BundleID` 为空表示未带 Bundle 的请求；分隔符为 ASCII 0x1F） |
| `bundle_force_b_<BundleID>` | 该 Bundle 下全部设备为 B（黑名单与苹果设备锁除外） |
| `ab_blocklist_device_<UUID>` | 该设备恒为 A |
| `ab_blocklist_ip_<URL编码后的IP>` | 该客户端 IP 恒为 A（与日志里 IP 列一致） |

## 部署

```bash
npx wrangler deploy
```

部署成功后得到 `https://daddy-ab-config.<子域>.workers.dev`（或自定义域）。将该根 URL（无尾部 `/`）写入 Flutter `lib/config/env_config.dart` 中测试/正式环境字节码（见仓库内 `docs/ADAPT_NEW_PROJECT.md` 或注释）。

## 管理页：`/admin`

浏览器打开（把域名换成你的 Worker）：

**`https://<你的-worker-域名>/admin`**

（旧路径 **`/admin/bundle-ab`** 会 302 重定向到 **`/admin`**。）

1. **`wrangler.toml` 中 `ADMIN_OPEN = "true"`**（默认已开）时：**无需输入 Token**，页面会提示「已开启 ADMIN_OPEN」。生产环境请删除 `[vars] ADMIN_OPEN` 或设为 `false`，并仅用 Token 访问管理接口。
2. 未开启 `ADMIN_OPEN` 时：输入 **`CONFIG_AUTH_TOKEN`**（与 `wrangler secret put`、与 App 里 `X-Config-Token` 相同）。若既未设密钥也未开 `ADMIN_OPEN`，管理接口返回 503。
3. 打开页面后会自动加载；配置请求记录分页旁可点 **「刷新」**重新拉取数据：
   - **苹果 ASN**：可点 **「更新苹果 ASN 列表」** 从 PeeringDB 拉取并写入 KV；亦可用 `POST /admin/api/apple-asn-refresh`（需与管理接口相同鉴权）、`GET /admin/api/apple-asn-status` 查看当前合并结果。
   - **配置请求记录**：D1 分页（默认每页 **20** 条）；有设备 UUID 时可 **按本行 Bundle + 设备强制 B**（同一 UUID 在不同 Bundle 下独立开关；取消请删除对应 KV 键 `device_force_b_<BundleID>\u001f<UUID>`，无 Bundle 时 `BundleID` 为空串）。**备注为「苹果ASN」或设备已存在 `apple_asn_lock_a_*` 时**，该行的「强制 B」按钮禁用，接口 `POST /admin/api/device-force-b` 对已锁设备返回 400。
   - **KV Bundle 级 A/B**：`ab_config` / `ab_config_*` 当前值。
   - **D1 中出现过的 Bundle**：可在此 **全员强制 B / 取消全员 B**（`bundle_force_b_*`）；黑名单仍为 A。

Bundle 级 A/B 仍通过 **Dashboard → KV** 或 **`wrangler kv key put`** 修改；设备强制 B 可在管理页操作，也可手动写 KV。

### 演示「命中苹果 ASN」（Mock）

在 `wrangler.toml` 中设置 **`DEMO_MOCK_APPLE = "true"`**（默认已开便于联调；**生产务必关闭**）。对配置接口附带请求头 **`X-Mock-Apple-ASN: 1`** 即视为苹果出口：返回 **A**；若同时带 **`X-Device-Id`** 则写入 **`apple_asn_lock_a_*`**；日志备注「苹果ASN」、ASN 列显示 `MOCK Apple Inc. (X-Mock-Apple-ASN)`。

```bash
curl -sS "https://<你的-worker>/client/api/config" \
  -H "X-Mock-Apple-ASN: 1" \
  -H "X-Bundle-Id: com.demo.app"
# 若启用 CONFIG_AUTH_TOKEN，再加：-H "X-Config-Token: <secret>"
```

管理页顶部在开启 Mock 时会显示可复制的一行 `curl`。

## 查询访问日志（D1）

```bash
npx wrangler d1 execute daddy-ab-logs --remote --command "SELECT * FROM access_logs ORDER BY id DESC LIMIT 20"
```

## WAF / 限流（安全）

1. **鉴权**：务必执行 `wrangler secret put CONFIG_AUTH_TOKEN`，与客户端 `S.configAuthToken` 解码值一致；未设置密钥时 Worker **不校验**（仅本地调试）。
2. **WAF**：在 Cloudflare Dashboard → Security → WAF 中对该 Worker 所在主机名或路径 `/client/api/config` 配置规则（如挑战可疑 ASN、封禁高频 IP）。
3. **Rate limiting**：Workers 或 Zone 级限流，防止 D1 / KV 被刷。

详见仓库 [`docs/PRIVACY_CONFIG_AND_IP.md`](../docs/PRIVACY_CONFIG_AND_IP.md)。
