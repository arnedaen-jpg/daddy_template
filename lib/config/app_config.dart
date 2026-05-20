/// 应用配置
class AppConfig {
  /// 应用名称
  static const String appName = 'Daddy Template';

  /// 应用版本
  static const String appVersion = '1.0.0';

  /// 是否开启调试模式
  static const bool debugMode = true;

  /// 默认显示主要模式还是次要模式 (false = 主要模式, true = 次要模式)
  static const bool defaultShowSecondary = false;

  /// 静默期天数（从打包时间开始计算，N 天内强制显示主要模式）
  /// 设置为 0 表示禁用静默期
  static const int silentPeriodDays = 3;

  /// 打包时间戳（毫秒）- 打包脚本或手动更新此值
  /// 静默期从此时间开始计算，而非用户首次启动时间
  /// 格式: DateTime.now().millisecondsSinceEpoch
  static const int buildTimestamp = 1737100800000; // 2025-01-17 12:00:00 UTC

  /// 远程配置拉取是否在默认域名（及缓存域名）失败后，继续尝试 CDN 文章与硬编码备用域名。
  /// 使用自建 Cloudflare Worker 时建议为 `false`，避免仍向旧链路请求。
  static const bool useConfigDomainFallback = false;

  /// 是否在 `GET /client/api/config` 请求中附带 `X-Config-Token`（须与 Worker 密钥 `CONFIG_AUTH_TOKEN` 一致）。
  static const bool useConfigApiAuth = true;

}
