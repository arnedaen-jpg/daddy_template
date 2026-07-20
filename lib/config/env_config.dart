import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_config.dart';
import '../services/domain/domain_entity.dart';
import '../services/network/http_client.dart';
import '../utils/s.dart';

/// 环境类型
enum Environment {
  test, // 测试环境
  staging, // 预发环境
  production, // 正式环境
}

/// 环境配置
/// 支持测试 / 预发 / 正式三套环境切换，并持久化保存。
///
/// 每个环境对应一组「候选域名」（完整 DomainEntity，含 CDN token / openFlag）。
/// `apiBaseUrl` 取候选域名的第一个；
/// `apiDomainEntities` 供 DomainManager 做权重轮询与 CDN 加签。
class EnvConfig {
  static String get _envKey => S.envKey;

  /// AB 包工厂「▶ 运行」与打包脚本注入：--dart-define=ENVIRONMENT=test|beta|release
  static const String _environmentDefine =
      String.fromEnvironment('ENVIRONMENT', defaultValue: '');

  static Environment _currentEnv = Environment.production;
  static SharedPreferences? _prefs;

  static Environment get current => _currentEnv;

  static Environment? _environmentFromDefine() {
    switch (_environmentDefine.trim().toLowerCase()) {
      case 'test':
        return Environment.test;
      case 'beta':
        return Environment.staging;
      case 'release':
        return Environment.production;
      default:
        return null;
    }
  }

  // ============================================================
  // 各环境候选域名字节码（快照失败时的硬编码兜底，仅 URL）
  // ============================================================

  /// base64 映射解码
  static String _db64(String b64) => utf8.decode(base64.decode(b64));

  /// 测试环境候选域名（base64 映射）
  /// [0] https://api.test.qiu577.com
  static const List<String> _testDomainB64 = <String>[
    'aHR0cHM6Ly9hcGkudGVzdC5xaXU1NzcuY29t',
  ];

  /// 预发环境候选域名（base64 映射）
  /// [0] https://api.13dq.co
  /// [1] https://api.ydjruvlgs.com
  static const List<String> _stagingDomainB64 = <String>[
    'aHR0cHM6Ly9hcGkuMTNkcS5jbw==',
    'aHR0cHM6Ly9hcGkueWRqcnV2bGdzLmNvbQ==',
  ];

  /// 正式环境候选域名（base64 映射硬编码兜底）
  /// [0] https://api.dq87776.com
  /// [1] https://apial.zdbapp.com
  /// [2] https://apial.wxqerf.com
  /// [3] https://apial.miyayujia.com
  static const List<String> _productionDomainB64 = <String>[
    'aHR0cHM6Ly9hcGkuZHE4Nzc3Ni5jb20=',
    'aHR0cHM6Ly9hcGlhbC56ZGJhcHAuY29t',
    'aHR0cHM6Ly9hcGlhbC53eHFlcmYuY29t',
    'aHR0cHM6Ly9hcGlhbC5taXlheXVqaWEuY29t',
  ];

  static const String _testDomainsAsset = 'assets/config/test_domains.b64';
  static const String _stagingDomainsAsset = 'assets/config/staging_domains.b64';
  static const String _prodDomainsAsset = 'assets/config/prod_domains.b64';

  static List<DomainEntity> _obsTestDomains = const <DomainEntity>[];
  static List<DomainEntity> _obsStagingDomains = const <DomainEntity>[];
  static List<DomainEntity> _obsProductionDomains = const <DomainEntity>[];

  /// 从 base64(JSON) 快照解析完整域名实体（按 weight 降序）。
  /// 不按 openFlag 过滤（与 XMSport/dqiu 一致：openFlag 只控制 CDN 加签）。
  static List<DomainEntity> parseDomainSnapshotB64(String b64Raw) {
    try {
      final b64 = b64Raw.replaceAll(RegExp(r'\s'), '');
      if (b64.isEmpty) return const <DomainEntity>[];

      final jsonStr = utf8.decode(base64.decode(b64));
      return parseDomainJson(jsonStr);
    } catch (_) {
      return const <DomainEntity>[];
    }
  }

  /// 解析域名 JSON（明文或已 base64 decode）
  static List<DomainEntity> parseDomainJson(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return const <DomainEntity>[];
      final data = decoded['data'];
      if (data is! List) return const <DomainEntity>[];

      final entities = <DomainEntity>[];
      final seen = <String>{};
      for (final item in data) {
        if (item is! Map) continue;
        final entity = DomainEntity.fromJson(Map<String, dynamic>.from(item));
        if (!entity.domain.startsWith('http')) continue;
        if (seen.contains(entity.domain)) continue;
        seen.add(entity.domain);
        entities.add(entity);
      }

      entities.sort((a, b) => b.weight.compareTo(a.weight));
      return entities;
    } catch (_) {
      return const <DomainEntity>[];
    }
  }

  static Future<List<DomainEntity>> _loadSnapshotAsset(String assetPath) async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      return parseDomainSnapshotB64(raw);
    } catch (_) {
      return const <DomainEntity>[];
    }
  }

  static Future<void> _loadObsDomainSnapshots() async {
    final test = await _loadSnapshotAsset(_testDomainsAsset);
    if (test.isNotEmpty) _obsTestDomains = List<DomainEntity>.unmodifiable(test);

    final staging = await _loadSnapshotAsset(_stagingDomainsAsset);
    if (staging.isNotEmpty) {
      _obsStagingDomains = List<DomainEntity>.unmodifiable(staging);
    }

    final prod = await _loadSnapshotAsset(_prodDomainsAsset);
    if (prod.isNotEmpty) {
      _obsProductionDomains = List<DomainEntity>.unmodifiable(prod);
    }
  }

  static List<DomainEntity> get _obsDomainsForCurrentEnv {
    switch (_currentEnv) {
      case Environment.test:
        return _obsTestDomains;
      case Environment.staging:
        return _obsStagingDomains;
      case Environment.production:
        return _obsProductionDomains;
    }
  }

  static Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadObsDomainSnapshots();

    final fromDefine = _environmentFromDefine();
    if (fromDefine != null) {
      _currentEnv = fromDefine;
      await _prefs?.setString(_envKey, fromDefine.name);
      return;
    }

    final savedEnv = _prefs?.getString(_envKey);
    if (savedEnv != null) {
      _currentEnv = Environment.values.firstWhere(
        (e) => e.name == savedEnv,
        orElse: () => Environment.production,
      );
    }
  }

  static Future<void> setEnvironment(Environment env) async {
    if (_currentEnv == env) return;

    _currentEnv = env;
    await _prefs?.setString(_envKey, env.name);

    HttpClient().updateBaseUrl();
  }

  static Future<void> switchToTest() async {
    await setEnvironment(Environment.test);
  }

  static Future<void> switchToStaging() async {
    await setEnvironment(Environment.staging);
  }

  static Future<void> switchToProduction() async {
    await setEnvironment(Environment.production);
  }

  static List<String> get _currentDomainB64 {
    switch (_currentEnv) {
      case Environment.test:
        return _testDomainB64;
      case Environment.staging:
        return _stagingDomainB64;
      case Environment.production:
        return _productionDomainB64;
    }
  }

  /// 当前环境完整域名实体（优先 OBS/unpkg 快照；快照空时可选硬编码兜底）
  static List<DomainEntity> get apiDomainEntities {
    final obs = _obsDomainsForCurrentEnv;
    if (obs.isNotEmpty) {
      return obs.map((e) => DomainEntity.fromJson(e.toJson())).toList();
    }
    // 验证 OBS 时关闭硬编码，强制走 DomainManager 运行时 OBS/npm 拉源
    if (!AppConfig.useHardcodedDomainFallback) {
      return const <DomainEntity>[];
    }
    return _currentDomainB64
        .map((b64) => DomainEntity.urlOnly(_db64(b64)))
        .toList();
  }

  /// 当前环境候选域名 URL 列表
  static List<String> get apiDomains =>
      apiDomainEntities.map((e) => e.domain).toList();

  static String get apiBaseUrl {
    final list = apiDomains;
    return list.isNotEmpty ? list.first : '';
  }

  /// 与 dqiu `_envSuffix` / XMSport 包后缀对齐：test / beta / prod
  static String get domainPullEnvSuffix {
    switch (_currentEnv) {
      case Environment.test:
        return 'test';
      case Environment.staging:
        return 'beta';
      case Environment.production:
        return 'prod';
    }
  }

  static bool get isTest => _currentEnv == Environment.test;
  static bool get isStaging => _currentEnv == Environment.staging;
  static bool get isProduction => _currentEnv == Environment.production;

  static String get envDisplayName {
    switch (_currentEnv) {
      case Environment.test:
        return '测试环境';
      case Environment.staging:
        return '预发环境';
      case Environment.production:
        return '正式环境';
    }
  }
}
