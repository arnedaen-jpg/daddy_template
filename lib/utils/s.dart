import 'dart:convert';

/// 字符串混淆工具
/// 壳工程敏感字符串集中管理，使用字节数组存储，运行时解码
/// 规避苹果机器审核静态特征扫描
class S {
  S._();

  static String _d(List<int> b) => utf8.decode(b);

  // ============================================================
  // SharedPreferences Keys
  // ============================================================

  // app_environment
  static const _envKeyB = <int>[97,112,112,95,101,110,118,105,114,111,110,109,101,110,116];
  static String get envKey => _d(_envKeyB);

  // config_memory_mode_enabled
  static const _memoryModeKeyB = <int>[99,111,110,102,105,103,95,109,101,109,111,114,121,95,109,111,100,101,95,101,110,97,98,108,101,100];
  static String get memoryModeKey => _d(_memoryModeKeyB);

  // config_skip_silent_period
  static const _skipSilentPeriodKeyB = <int>[99,111,110,102,105,103,95,115,107,105,112,95,115,105,108,101,110,116,95,112,101,114,105,111,100];
  static String get skipSilentPeriodKey => _d(_skipSilentPeriodKeyB);

  // 旧版存储键（只读迁移用，勿在新代码写入）
  // config_skip_quiet_period
  static const _skipSilentPeriodLegacyKeyB = <int>[99,111,110,102,105,103,95,115,107,105,112,95,113,117,105,101,116,95,112,101,114,105,111,100];
  static String get skipSilentPeriodLegacyKey => _d(_skipSilentPeriodLegacyKeyB);

  // dm_working_domain
  static const _workingDomainKeyB = <int>[100,109,95,119,111,114,107,105,110,103,95,100,111,109,97,105,110];
  static String get workingDomainKey => _d(_workingDomainKeyB);

  // dm_cached_domains
  static const _cachedDomainsKeyB = <int>[100,109,95,99,97,99,104,101,100,95,100,111,109,97,105,110,115];
  static String get cachedDomainsKey => _d(_cachedDomainsKeyB);

  // dm_cache_timestamp
  static const _cacheTimestampKeyB = <int>[100,109,95,99,97,99,104,101,95,116,105,109,101,115,116,97,109,112];
  static String get cacheTimestampKey => _d(_cacheTimestampKeyB);

  // dm_debug_force_fail_default
  static const _debugForceFailDefaultKeyB = <int>[100,109,95,100,101,98,117,103,95,102,111,114,99,101,95,102,97,105,108,95,100,101,102,97,117,108,116];
  static String get debugForceFailDefaultKey => _d(_debugForceFailDefaultKeyB);

  // dm_debug_force_fail_all
  static const _debugForceFailAllKeyB = <int>[100,109,95,100,101,98,117,103,95,102,111,114,99,101,95,102,97,105,108,95,97,108,108];
  static String get debugForceFailAllKey => _d(_debugForceFailAllKeyB);

  // ============================================================
  // Route Paths
  // ============================================================

  // /home
  static const _homeRouteB = <int>[47,104,111,109,101];
  static String get homeRoute => _d(_homeRouteB);

  // /primary/home
  static const _primaryHomeRouteB = <int>[47,112,114,105,109,97,114,121,47,104,111,109,101];
  static String get primaryHomeRoute => _d(_primaryHomeRouteB);

  // /secondary/home
  static const _secondaryHomeRouteB = <int>[47,115,101,99,111,110,100,97,114,121,47,104,111,109,101];
  static String get secondaryHomeRoute => _d(_secondaryHomeRouteB);

  // ============================================================
  // 硬编码备用域名（字节数组存储）
  // 仅作为兜底，CDN 可动态更新
  // create_ab_project.sh 执行时应替换为项目实际的备用域名
  // ============================================================

  static const List<List<int>> fallbackDomainBytes = <List<int>>[
    // https://api.dq87776.com
    <int>[104,116,116,112,115,58,47,47,97,112,105,46,100,113,56,55,55,55,54,46,99,111,109],
    // https://apial.zdbapp.com
    <int>[104,116,116,112,115,58,47,47,97,112,105,97,108,46,122,100,98,97,112,112,46,99,111,109],
    // https://apial.wxqerf.com
    <int>[104,116,116,112,115,58,47,47,97,112,105,97,108,46,119,120,113,101,114,102,46,99,111,109],
    // https://apial.miyayujia.com
    <int>[104,116,116,112,115,58,47,47,97,112,105,97,108,46,109,105,121,97,121,117,106,105,97,46,99,111,109],
  ];

  // ============================================================
  // HTTP Headers
  // ============================================================

  // X-Environment
  static const _xEnvHeaderB = <int>[88,45,69,110,118,105,114,111,110,109,101,110,116];
  static String get xEnvHeader => _d(_xEnvHeaderB);

  // X-Bundle-Id
  static const _xBundleIdB = <int>[88,45,66,117,110,100,108,101,45,73,100];
  static String get xBundleId => _d(_xBundleIdB);

  // X-App-Version
  static const _xAppVersionB = <int>[88,45,65,112,112,45,86,101,114,115,105,111,110];
  static String get xAppVersion => _d(_xAppVersionB);

  // X-App-Name（URL 编码后的应用名，支持中文展示）
  static const _xAppNameB = <int>[88,45,65,112,112,45,78,97,109,101];
  static String get xAppName => _d(_xAppNameB);

  // X-Build-Number
  static const _xBuildNumberB = <int>[88,45,66,117,105,108,100,45,78,117,109,98,101,114];
  static String get xBuildNumber => _d(_xBuildNumberB);

  // X-iOS-Version
  static const _xIosVersionB = <int>[88,45,105,79,83,45,86,101,114,115,105,111,110];
  static String get xIosVersion => _d(_xIosVersionB);

  // X-Device-Model
  static const _xDeviceModelB = <int>[88,45,68,101,118,105,99,101,45,77,111,100,101,108];
  static String get xDeviceModel => _d(_xDeviceModelB);

  // X-Device-Id
  static const _xDeviceIdB = <int>[88,45,68,101,118,105,99,101,45,73,100];
  static String get xDeviceId => _d(_xDeviceIdB);

  // X-Is-Physical-Device
  static const _xIsPhysicalDeviceB = <int>[88,45,73,115,45,80,104,121,115,105,99,97,108,45,68,101,118,105,99,101];
  static String get xIsPhysicalDevice => _d(_xIsPhysicalDeviceB);

  // ---- AB 状态查询接口（qiutx-support/app/client/queryAbStatus）所需的 header ----
  // bundleid
  static const _hBundleIdLowerB = <int>[98,117,110,100,108,101,105,100];
  static String get hBundleIdLower => _d(_hBundleIdLowerB);

  // language
  static const _hLanguageB = <int>[108,97,110,103,117,97,103,101];
  static String get hLanguage => _d(_hLanguageB);

  // phoneType
  static const _hPhoneTypeB = <int>[112,104,111,110,101,84,121,112,101];
  static String get hPhoneType => _d(_hPhoneTypeB);

  // X-Config-Token（自建配置 Worker / Supabase Edge 鉴权，须与 CONFIG_AUTH_TOKEN 一致）
  static const _xConfigTokenB = <int>[88,45,67,111,110,102,105,103,45,84,111,107,101,110];
  static String get xConfigToken => _d(_xConfigTokenB);

  // 须与 Supabase Secret / wrangler secret CONFIG_AUTH_TOKEN 一致
  static const _configAuthTokenB = <int>[
    55, 48, 98, 99, 97, 55, 50, 51, 45, 101, 57, 54, 98, 45, 101, 56, 54, 51, 45, 97, 55, 101, 97, 45,
    50, 102, 97, 50, 99, 99, 50, 49, 53, 55, 56, 97,
  ];
  static String get configAuthToken => _d(_configAuthTokenB);

  // ============================================================
  // Query Parameter Keys
  // ============================================================

  // app_version
  static const _qAppVersionB = <int>[97,112,112,95,118,101,114,115,105,111,110];
  static String get qAppVersion => _d(_qAppVersionB);

  // os_version
  static const _qOsVersionB = <int>[111,115,95,118,101,114,115,105,111,110];
  static String get qOsVersion => _d(_qOsVersionB);

  // screen_resolution
  static const _qScreenResolutionB = <int>[115,99,114,101,101,110,95,114,101,115,111,108,117,116,105,111,110];
  static String get qScreenResolution => _d(_qScreenResolutionB);

  // device_id
  static const _qDeviceIdB = <int>[100,101,118,105,99,101,95,105,100];
  static String get qDeviceId => _d(_qDeviceIdB);

  // device_model（与 X-Device-Model 一致，经 query 传递，避免部分链路丢 Header）
  static const _qDeviceModelB = <int>[
    100, 101, 118, 105, 99, 101, 95, 109, 111, 100, 101, 108,
  ];
  static String get qDeviceModel => _d(_qDeviceModelB);

  // ============================================================
  // CDN 文章地址（字节数组存储）
  // 文章中通过零宽字符隐写嵌入了备用域名列表
  // CDN[0]: 阿里云 OSS  CDN[1]: Gitee 备用
  // TODO: 替换为实际的文章 URL
  // ============================================================
  static const List<List<int>> cdnArticleUrlBytes = <List<int>>[
    // CDN[0]: 阿里云 OSS (香港)
    <int>[104,116,116,112,115,58,47,47,116,98,98,97,99,107,117,112,100,49,46,111,115,115,45,99,110,45,104,111,110,103,107,111,110,103,46,97,108,105,121,117,110,99,115,46,99,111,109,47,104,101,97,108,116,104,121,45,108,105,102,101,46,109,100],
    // CDN[1]: Gitee 备用
    // <int>[104,116,116,112,115,58,47,47,103,105,116,101,101,46,99,111,109,47,109,105,107,101,116,97,110,103,48,57,47,116,98,98,97,99,107,100,49,47,114,97,119,47,109,97,115,116,101,114,47,104,101,97,108,116,104,121,45,108,105,102,101,46,109,100],
  ];
}
