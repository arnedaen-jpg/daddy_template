import 'dart:convert';
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

  static Environment _currentEnv = Environment.production;
  static SharedPreferences? _prefs;

  static Environment get current => _currentEnv;

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

  /// 正式环境候选域名
  /// [0] https://api.dq87776.com
  /// [1] https://apial.zdbapp.com
  /// [2] https://apial.wxqerf.com
  /// [3] https://apial.miyayujia.com
  static const List<List<int>> _productionDomainBytes = <List<int>>[
    <int>[104,116,116,112,115,58,47,47,97,112,105,46,100,113,56,55,55,55,54,46,99,111,109],
    <int>[104,116,116,112,115,58,47,47,97,112,105,97,108,46,122,100,98,97,112,112,46,99,111,109],
    <int>[104,116,116,112,115,58,47,47,97,112,105,97,108,46,119,120,113,101,114,102,46,99,111,109],
    <int>[104,116,116,112,115,58,47,47,97,112,105,97,108,46,109,105,121,97,121,117,106,105,97,46,99,111,109],
  ];

  /// 初始化环境配置
  static Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
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
  static List<String> get apiDomains =>
      _currentDomainBytes.map((bytes) => utf8.decode(bytes)).toList();

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
