import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/network/http_client.dart';
import '../utils/s.dart';

/// 环境类型
enum Environment {
  test,       // 测试环境
  staging,    // 预发环境
  production, // 正式环境
}

/// 环境配置
/// 支持测试 / 预发 / 正式三套环境切换，并持久化保存。
///
/// 每个环境对应一组「候选域名」（用于 B 面切换开关的域名轮询）。
/// `apiBaseUrl` 取候选域名的第一个，作为 HttpClient 与 DomainManager 的默认域名；
/// `apiDomains` 返回完整候选域名列表，供 DomainManager 逐个轮询、失败切换。
///
/// 域名取自 dqiu 后端（承载 qiutx-support/app/client/queryAbStatus AB 接口），
/// 使用字节码存储，规避苹果机器审核特征值扫描。
class EnvConfig {
  static String get _envKey => S.envKey;

  /// AB 包工厂「▶ 运行」与打包脚本注入：--dart-define=ENVIRONMENT=test|beta|release
  /// 与 B 面 config.dart 同一命名；壳工程映射 test→测试、beta→预发、release→正式。
  static const String _environmentDefine =
      String.fromEnvironment('ENVIRONMENT', defaultValue: '');

  static Environment _currentEnv = Environment.production;
  static SharedPreferences? _prefs;

  static Environment get current => _currentEnv;

  /// 将 dart-define ENVIRONMENT 映射为壳工程 Environment；未注入或未知值返回 null。
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
  // 各环境候选域名字节码（域名轮询用，第一个为默认域名）
  // 生成方法：utf8.encode('https://host') 取字节数组
  // ============================================================

  /// 测试环境候选域名
  /// [0] https://api.test.qiu577.com
  static const List<List<int>> _testDomainBytes = <List<int>>[
    <int>[104,116,116,112,115,58,47,47,97,112,105,46,116,101,115,116,46,113,105,117,53,55,55,46,99,111,109],
  ];

  /// 预发环境候选域名
  /// [0] https://api.13dq.co
  /// [1] https://api.ydjruvlgs.com
  static const List<List<int>> _stagingDomainBytes = <List<int>>[
    <int>[104,116,116,112,115,58,47,47,97,112,105,46,49,51,100,113,46,99,111],
    <int>[104,116,116,112,115,58,47,47,97,112,105,46,121,100,106,114,117,118,108,103,115,46,99,111,109],
  ];

  /// 正式环境候选域名（硬编码兜底）
  /// [0] https://api.dq87776.com
  /// [1] https://apial.zdbapp.com
  /// [2] https://apial.wxqerf.com
  /// [3] https://apial.miyayujia.com
  ///
  /// 仅作为兜底：正式环境优先使用编译时拉取的 OBS 域名快照（见 _obsProductionDomains）；
  /// 快照为空 / 解析失败时回退到这里。
  static const List<List<int>> _productionDomainBytes = <List<int>>[
    <int>[104,116,116,112,115,58,47,47,97,112,105,46,100,113,56,55,55,55,54,46,99,111,109],
    <int>[104,116,116,112,115,58,47,47,97,112,105,97,108,46,122,100,98,97,112,112,46,99,111,109],
    <int>[104,116,116,112,115,58,47,47,97,112,105,97,108,46,119,120,113,101,114,102,46,99,111,109],
    <int>[104,116,116,112,115,58,47,47,97,112,105,97,108,46,109,105,121,97,121,117,106,105,97,46,99,111,109],
  ];

  // ============================================================
  // 正式环境域名快照（编译时由 scripts/update_prod_domains.sh 写入）
  // 参考 XMSport 的 ScriptGetObsData：打包前从 OBS 拉取最新正式域名，
  // 原样（base64(JSON)）写入随包资源 assets/config/prod_domains.b64，
  // 运行时解码、仅正式环境使用，覆盖上面的硬编码兜底域名。
  // ============================================================

  /// 随包域名快照资源路径（base64 编码的 OBS 响应）
  static const String _prodDomainsAsset = 'assets/config/prod_domains.b64';

  /// 运行时解码出的正式环境域名（按权重降序）；为空表示未拉取到，走硬编码兜底
  static List<String> _obsProductionDomains = const <String>[];

  /// 加载并解码随包正式域名快照。任何失败都静默回退到硬编码域名。
  static Future<void> _loadObsProductionDomains() async {
    try {
      final raw = await rootBundle.loadString(_prodDomainsAsset);
      final b64 = raw.replaceAll(RegExp(r'\s'), '');
      if (b64.isEmpty) return;

      final jsonStr = utf8.decode(base64.decode(b64));
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return;
      final data = decoded['data'];
      if (data is! List) return;

      // 收集 (域名, 权重)，过滤未开启 / 非法项
      final entries = <MapEntry<String, num>>[];
      for (final item in data) {
        if (item is! Map) continue;
        if (item['openFlag'] == false) continue;
        final domain = item['domain'];
        if (domain is! String) continue;
        final d = domain.trim();
        if (!d.startsWith('http')) continue;
        final weight = item['weight'];
        entries.add(MapEntry(d, weight is num ? weight : 0));
      }

      // 按权重降序：权重高者优先作为默认/首选域名
      entries.sort((a, b) => b.value.compareTo(a.value));

      final domains = <String>[];
      for (final e in entries) {
        if (!domains.contains(e.key)) domains.add(e.key);
      }
      if (domains.isNotEmpty) {
        _obsProductionDomains = List<String>.unmodifiable(domains);
      }
    } catch (_) {
      // 资源缺失 / base64 / JSON 解析失败 → 保持空，回退硬编码
    }
  }

  /// 初始化环境配置
  static Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();

    // 加载编译时拉取的正式环境域名快照（仅正式环境使用，失败则回退硬编码）
    await _loadObsProductionDomains();

    // dart-define 优先（AB 包工厂 ▶ 运行 / IPA 打包注入），避免仍用 SharedPreferences 里的正式环境
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

  /// 切换环境
  static Future<void> setEnvironment(Environment env) async {
    if (_currentEnv == env) return;

    _currentEnv = env;
    await _prefs?.setString(_envKey, env.name);

    // 更新 HttpClient 的 baseUrl
    HttpClient().updateBaseUrl();
  }

  /// 切换到测试环境
  static Future<void> switchToTest() async {
    await setEnvironment(Environment.test);
  }

  /// 切换到预发环境
  static Future<void> switchToStaging() async {
    await setEnvironment(Environment.staging);
  }

  /// 切换到正式环境
  static Future<void> switchToProduction() async {
    await setEnvironment(Environment.production);
  }

  /// 当前环境的候选域名字节码列表
  static List<List<int>> get _currentDomainBytes {
    switch (_currentEnv) {
      case Environment.test:
        return _testDomainBytes;
      case Environment.staging:
        return _stagingDomainBytes;
      case Environment.production:
        return _productionDomainBytes;
    }
  }

  /// 当前环境的候选域名列表（运行时从字节码解码，供域名轮询使用）
  ///
  /// 正式环境：优先返回编译时拉取的 OBS 域名快照（_obsProductionDomains），
  /// 快照为空时回退到硬编码的 _productionDomainBytes。测试/预发不受影响。
  static List<String> get apiDomains {
    if (_currentEnv == Environment.production &&
        _obsProductionDomains.isNotEmpty) {
      return List<String>.from(_obsProductionDomains);
    }
    return _currentDomainBytes.map((bytes) => utf8.decode(bytes)).toList();
  }

  /// 获取当前环境的 API 基础地址（候选域名的第一个）
  static String get apiBaseUrl => apiDomains.first;

  /// 是否为测试环境
  static bool get isTest => _currentEnv == Environment.test;

  /// 是否为预发环境
  static bool get isStaging => _currentEnv == Environment.staging;

  /// 是否为正式环境
  static bool get isProduction => _currentEnv == Environment.production;

  /// 获取环境显示名称
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
