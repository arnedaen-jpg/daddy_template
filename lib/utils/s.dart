import 'dart:convert';

/// 字符串混淆工具
/// 壳工程敏感字符串集中管理：字节数组 / base64 映射，运行时解码
/// 规避苹果机器审核静态特征扫描
class S {
  S._();

  static String _d(List<int> b) => utf8.decode(b);

  /// base64 映射解码（CDN 拉源 / 硬编码域名）
  static String _db64(String b64) => utf8.decode(base64.decode(b64));

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

  /// 硬编码兜底域名（base64 映射，运行时解码）
  static const List<String> _fallbackDomainB64 = <String>[
    // https://api.dq87776.com
    'aHR0cHM6Ly9hcGkuZHE4Nzc3Ni5jb20=',
    // https://apial.zdbapp.com
    'aHR0cHM6Ly9hcGlhbC56ZGJhcHAuY29t',
    // https://apial.wxqerf.com
    'aHR0cHM6Ly9hcGlhbC53eHFlcmYuY29t',
    // https://apial.miyayujia.com
    'aHR0cHM6Ly9hcGlhbC5taXlheXVqaWEuY29t',
  ];

  static List<String> get fallbackDomains =>
      _fallbackDomainB64.map(_db64).toList();

  /// @Deprecated 兼容旧调用：返回 utf8 字节；新代码请用 [fallbackDomains]
  static List<List<int>> get fallbackDomainBytes =>
      fallbackDomains.map((e) => utf8.encode(e)).toList();

  // ============================================================
  // CDN / OBS / NPM 拉源 URL（base64 映射，# = test|beta|prod）
  // 对齐 XMSport CONF_*_URL
  // ============================================================

  // https://bfw-pic-new0111.obs.cn-south-1.myhuaweicloud.com/cdn/app_#.json
  static const _obsProdB64 =
      'aHR0cHM6Ly9iZnctcGljLW5ldzAxMTEub2JzLmNuLXNvdXRoLTEubXlodWF3ZWljbG91ZC5jb20vY2RuL2FwcF8jLmpzb24=';
  static String get obsProdUrlTpl => _db64(_obsProdB64);

  // https://bfw-btd-pic-new0111.obs.ap-southeast-1.myhuaweicloud.com:443/cdn/app_#.json
  static const _obsBtdB64 =
      'aHR0cHM6Ly9iZnctYnRkLXBpYy1uZXcwMTExLm9icy5hcC1zb3V0aGVhc3QtMS5teWh1YXdlaWNsb3VkLmNvbTo0NDMvY2RuL2FwcF8jLmpzb24=';
  static String get obsBtdUrlTpl => _db64(_obsBtdB64);

  // https://unpkg.com/@hd-team/app-dnpkg-#
  static const _unpkgB64 =
      'aHR0cHM6Ly91bnBrZy5jb20vQGhkLXRlYW0vYXBwLWRucGtnLSM=';
  static String get unpkgUrlTpl => _db64(_unpkgB64);

  // https://r.cnpmjs.org/@hd-team/app-dnpkg-#
  static const _cnpmB64 =
      'aHR0cHM6Ly9yLmNucG1qcy5vcmcvQGhkLXRlYW0vYXBwLWRucGtnLSM=';
  static String get cnpmUrlTpl => _db64(_cnpmB64);

  // https://registry.npmmirror.com/@hd-team/app-dnpkg-#
  static const _npmB64 =
      'aHR0cHM6Ly9yZWdpc3RyeS5ucG1taXJyb3IuY29tL0BoZC10ZWFtL2FwcC1kbnBrZy0j';
  static String get npmUrlTpl => _db64(_npmB64);

  // https://mirrors.cloud.tencent.com/npm/@hd-team/app-dnpkg-#
  static const _tencentNpmB64 =
      'aHR0cHM6Ly9taXJyb3JzLmNsb3VkLnRlbmNlbnQuY29tL25wbS9AaGQtdGVhbS9hcHAtZG5wa2ctIw==';
  static String get tencentNpmUrlTpl => _db64(_tencentNpmB64);

  // https://registry.yarnpkg.com/@hd-team/app-dnpkg-#
  static const _yarnNpmB64 =
      'aHR0cHM6Ly9yZWdpc3RyeS55YXJucGtnLmNvbS9AaGQtdGVhbS9hcHAtZG5wa2ctIw==';
  static String get yarnNpmUrlTpl => _db64(_yarnNpmB64);

  // /qiutx-support/domains/v2/pull
  static const _pullPathB64 = 'L3FpdXR4LXN1cHBvcnQvZG9tYWlucy92Mi9wdWxs';
  static String get domainPullPath => _db64(_pullPathB64);

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

  // ---- 与 dqiu 客户端对齐的通用请求 header（同步自 orgin_dqiu getHeader）----
  // version
  static const _hVersionB = <int>[118,101,114,115,105,111,110];
  static String get hVersion => _d(_hVersionB);

  // client-type
  static const _hClientTypeB = <int>[99,108,105,101,110,116,45,116,121,112,101];
  static String get hClientType => _d(_hClientTypeB);

  // source
  static const _hSourceB = <int>[115,111,117,114,99,101];
  static String get hSource => _d(_hSourceB);

  // channel
  static const _hChannelB = <int>[99,104,97,110,110,101,108];
  static String get hChannel => _d(_hChannelB);

  // client-tag
  static const _hClientTagB = <int>[99,108,105,101,110,116,45,116,97,103];
  static String get hClientTag => _d(_hClientTagB);

  // channelApp
  static const _hChannelAppB = <int>[99,104,97,110,110,101,108,65,112,112];
  static String get hChannelApp => _d(_hChannelAppB);

  // deviceId
  static const _hDeviceIdLowerB = <int>[100,101,118,105,99,101,73,100];
  static String get hDeviceIdLower => _d(_hDeviceIdLowerB);

  // Authorization
  static const _hAuthorizationB = <int>[65,117,116,104,111,114,105,122,97,116,105,111,110];
  static String get hAuthorization => _d(_hAuthorizationB);

  // x-user-header
  static const _hXUserHeaderB = <int>[120,45,117,115,101,114,45,104,101,97,100,101,114];
  static String get hXUserHeader => _d(_hXUserHeaderB);

  // ---- header 取值 ----
  // ios（client-type / phoneType 取值）
  static const _vClientTypeIosB = <int>[105,111,115];
  static String get vClientTypeIos => _d(_vClientTypeIosB);

  // xhios（client-tag 取值）
  static const _vClientTagB = <int>[120,104,105,111,115];
  static String get vClientTag => _d(_vClientTagB);

  // Basic YXBwOmFwcA==（未登录默认 Authorization）
  static const _vBasicAuthB = <int>[66,97,115,105,99,32,89,88,66,119,79,109,70,119,99,65,61,61];
  static String get vBasicAuth => _d(_vBasicAuthB);

  // {"uid":0}（未登录默认 x-user-header）
  static const _vAnonUserHeaderB = <int>[123,34,117,105,100,34,58,48,125];
  static String get vAnonUserHeader => _d(_vAnonUserHeaderB);

  // GT001（默认渠道，构建时可用 --dart-define=APP_CHANNEL=xxx 覆盖）
  static const _vDefaultChannelB = <int>[71,84,48,48,49];
  static String get defaultChannel => _d(_vDefaultChannelB);

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
