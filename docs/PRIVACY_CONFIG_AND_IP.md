# 远程配置与 IP 处理说明（自建 Worker）

## 目的

- 通过 `GET /client/api/config` 获取 A/B 展示策略（`data.config` 为 `A` 或 `B`）。
- 在服务端记录请求来源与大致归属，用于运维与风控分析（非广告画像用途时亦建议在隐私政策中披露）。

## 客户端发送的数据

应用会在该请求的 **Query** 中附带应用版本、iOS 版本、屏幕分辨率、`identifierForVendor` 等参数；在 **HTTP Header** 中附带 **Bundle ID**（`X-Bundle-Id`）、版本、机型等（见 `DeviceInfoManager`），并在启用 `AppConfig.useConfigApiAuth` 时附带 **`X-Config-Token`**（与 Cloudflare Worker 密钥一致）。

客户端 **不会**在请求体中主动拼接本机局域网 IP；公网 IP 由服务端在建立 TLS 连接时可见。

## 服务端（Cloudflare Worker）

- **IP**：优先使用 `CF-Connecting-IP`，否则 `X-Forwarded-For` 首段。
- **归属**：使用 Cloudflare 边缘提供的 `request.cf` 字段（如国家、城市、区域、ASN 组织名等），无需在客户端集成第三方 GeoIP SDK。
- **存储**：可选写入 **D1** 表 `access_logs`；控制台 **Logs** 中亦可检索结构化日志。
- **鉴权**：生产环境应设置 `wrangler secret put CONFIG_AUTH_TOKEN`，并在 Cloudflare 控制台配置 **WAF / Rate limiting**，降低接口被滥用的风险。

## 保留期限与合规

- D1 与 Workers 日志的默认保留策略以 Cloudflare 当前产品文档为准；若需更短保留期，应通过定期清理或迁移策略实现。
- 在面向最终用户的 **隐私政策** 中说明：收集 IP 与大致位置/运营商类信息的目的、范围、保存期限与用户权利；若适用 GDPR、个人信息保护法等，请由法务确认合法性基础与跨境传输安排。

## 修改密钥与 API 根地址

- 密钥：修改 `lib/utils/s.dart` 中 `configAuthToken` 对应字节数组，并同步 `wrangler secret put CONFIG_AUTH_TOKEN`。
- API 根 URL：修改 `lib/config/env_config.dart` 中 `_testApiBytes` / `_productionApiBytes`（无尾部 `/`），与 `cloudflare-ab-config` 部署得到的 Worker 域名一致。

## 从旧 API 域名迁移

若本地曾持久化「工作域名」（`DomainManager` 缓存），可能仍会先请求旧主机。请在调试面板中清除缓存域名（或调用 `DomainManager().clearCachedDomain()`），必要时重装应用。
