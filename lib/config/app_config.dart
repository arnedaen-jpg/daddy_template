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

  /// 域名降级链（Service→OBS→unpkg→npm）全部失败且域名池仍空时，
  /// 是否再尝试旧版「CDN 文章隐写 + 硬编码」兜底。默认关闭；主路径已对齐 XMSport/dqiu。
  static const bool useConfigDomainFallback = false;

  /// 是否启用 EnvConfig 内硬编码候选域名（`_test/_staging/_productionDomainBytes`）。
  /// 临时关掉以便单独验证 OBS/unpkg 快照与运行时 OBS 拉源；验证完再改回 true。
  static const bool useHardcodedDomainFallback = true;

  /// 是否在 AB 状态查询请求中附带 `X-Config-Token`。
  /// 旧 supabase / Worker 接口需要；现接口（qiutx-support/app/client/queryAbStatus）
  /// 改用 bundleid / language / phoneType header，不再需要该 token，故默认关闭。
  static const bool useConfigApiAuth = false;

}
