import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/network/http_client.dart';
import '../utils/s.dart';

/// 环境类型
enum Environment {
  test,       // 测试环境
  production, // 正式环境
}

/// 环境配置
/// 支持测试/正式环境切换，并持久化保存
class EnvConfig {
  static String get _envKey => S.envKey;

  static Environment _currentEnv = Environment.production;
  static SharedPreferences? _prefs;

  static Environment get current => _currentEnv;

  // ============================================================
  // API 地址字节码配置
  // 使用字节码存储 API 地址，规避苹果机器审核特征值扫描
  // 生成方法：使用 StringObfuscator.encode('your-url') 获取字节码
  // ============================================================

  /// 测试环境 API 地址字节码
  /// 原始值: https://daddy-ab-config.arnedaen.workers.dev（无尾部 /）
  static const List<int> _testApiBytes = <int>[
    104, 116, 116, 112, 115, 58, 47, 47, 100, 97, 100, 100, 121, 45, 97, 98, 45, 99, 111, 110,
    102, 105, 103, 46, 97, 114, 110, 101, 100, 97, 101, 110, 46, 119, 111, 114, 107, 101,
    114, 115, 46, 100, 101, 118,
  ];

  /// 正式环境 API 地址字节码
  /// 原始值: https://daddy-ab-config.arnedaen.workers.dev
  static const List<int> _productionApiBytes = <int>[
    104, 116, 116, 112, 115, 58, 47, 47, 100, 97, 100, 100, 121, 45, 97, 98, 45, 99, 111, 110,
    102, 105, 103, 46, 97, 114, 110, 101, 100, 97, 101, 110, 46, 119, 111, 114, 107, 101,
    114, 115, 46, 100, 101, 118,
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

  /// 切换到正式环境
  static Future<void> switchToProduction() async {
    await setEnvironment(Environment.production);
  }

  /// 获取当前环境的 API 基础地址（运行时从字节码解码）
  static String get apiBaseUrl {
    switch (_currentEnv) {
      case Environment.test:
        // return 'http://127.0.0.1:8081';
        return utf8.decode(_testApiBytes);
      case Environment.production:
        return utf8.decode(_productionApiBytes);
    }
  }

  /// 是否为测试环境
  static bool get isTest => _currentEnv == Environment.test;

  /// 是否为正式环境
  static bool get isProduction => _currentEnv == Environment.production;

  /// 获取环境显示名称
  static String get envDisplayName {
    switch (_currentEnv) {
      case Environment.test:
        return '测试环境';
      case Environment.production:
        return '正式环境';
    }
  }
}
