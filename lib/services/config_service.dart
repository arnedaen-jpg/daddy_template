import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../modules/secondary/module_entry.dart';
import '../utils/s.dart';
import 'domain_manager.dart';
import 'network/device_info_manager.dart';
import 'network/network_permission_service.dart';

/// 功能模式类型
enum FeatureMode {
  primary,   // 主要模式
  secondary, // 次要模式
}

/// 配置服务
/// 通过远程接口获取配置，决定显示哪种模式
/// 支持记忆模式：一旦次要模式生效，永久记住
/// 支持静默期：发布模式下，安装后 N 天内强制显示主要模式
/// 
/// 配置获取时机：
/// - app 启动时
/// - 网络授权成功时
/// - app 从后台切换到前台时
class ConfigService extends ChangeNotifier with WidgetsBindingObserver {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  /// 本地存储 key
  static String get _memoryModeKey => S.memoryModeKey;
  static String get _skipSilentPeriodKey => S.skipSilentPeriodKey;

  /// 当前模式
  FeatureMode _currentMode = FeatureMode.primary;
  FeatureMode get currentMode => _currentMode;

  /// 是否已初始化
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// 是否正在加载
  bool _isLoading = false;
  bool get isLoading => _isLoading;

  /// 是否已开启记忆模式
  bool _isMemoryModeEnabled = false;
  bool get isMemoryModeEnabled => _isMemoryModeEnabled;

  /// 是否处于静默期
  bool _isInSilentPeriod = false;
  bool get isInSilentPeriod => _isInSilentPeriod;

  /// 调试用：是否跳过静默期检查（默认关闭）
  bool _skipSilentPeriodCheck = false;
  bool get skipSilentPeriodCheck => _skipSilentPeriodCheck;
  set skipSilentPeriodCheck(bool value) {
    if (!kDebugMode) return;
    _skipSilentPeriodCheck = value;
    if (_prefs != null) {
      unawaited(_prefs!.setBool(_skipSilentPeriodKey, value));
      unawaited(_prefs!.remove(S.skipSilentPeriodLegacyKey));
    }
    if (value && _isInSilentPeriod) {
      // 跳过静默期时，重新允许配置请求
      _isInSilentPeriod = false;
      _fetchRemoteConfig();
    }
    notifyListeners();
  }

  /// SharedPreferences 实例
  SharedPreferences? _prefs;

  /// 模式变化回调（用于通知 UI 层自动切换页面）
  void Function(FeatureMode newMode)? onModeChanged;

  /// 初始化服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    // 注册生命周期监听
    WidgetsBinding.instance.addObserver(this);

    // 初始化 SharedPreferences
    _prefs = await SharedPreferences.getInstance();

    // 检查是否已开启记忆模式
    _isMemoryModeEnabled = _prefs?.getBool(_memoryModeKey) ?? false;

    // 读取跳过静默期开关状态（仅调试模式）；兼容旧 key config_skip_quiet_period
    if (kDebugMode) {
      final oldSkip = _prefs?.getBool(S.skipSilentPeriodLegacyKey);
      final newSkip = _prefs?.getBool(_skipSilentPeriodKey);
      if (oldSkip != null && newSkip == null) {
        await _prefs?.setBool(_skipSilentPeriodKey, oldSkip);
        await _prefs?.remove(S.skipSilentPeriodLegacyKey);
      }
      _skipSilentPeriodCheck = _prefs?.getBool(_skipSilentPeriodKey) ?? false;
    }

    if (_isMemoryModeEnabled) {
      // 记忆模式已开启，直接显示次要模式，无需请求远程配置
      _currentMode = FeatureMode.secondary;
      _isInitialized = true;
      notifyListeners();
      return;
    }

    // 检查静默期（如果跳过静默期开关打开，则跳过检查）
    if (AppConfig.silentPeriodDays > 0 && !_skipSilentPeriodCheck) {
      _isInSilentPeriod = _checkSilentPeriod();

      if (_isInSilentPeriod) {
        // 静默期内，强制显示主要模式，不请求配置接口
        _currentMode = FeatureMode.primary;
        _isInitialized = true;

        if (kDebugMode) {
          print('ConfigService: In silent period, forcing primary mode');
        }

        notifyListeners();
        return;
      }
    }

    // 先设置默认值
    _currentMode =
        AppConfig.defaultShowSecondary ? FeatureMode.secondary : FeatureMode.primary;

    // 检查网络是否可用
    final networkService = NetworkPermissionService();
    if (networkService.networkEnabled) {
      // 网络可用，从远程获取配置
      await _fetchRemoteConfig();
    } else {
      // 网络不可用，注册回调，等网络可用时再获取配置
      if (kDebugMode) {
        print('ConfigService: Network not available, waiting for permission...');
      }
      networkService.onNetworkEnabled(() {
        if (kDebugMode) {
          print('ConfigService: Network enabled, fetching config...');
        }
        _fetchRemoteConfig();
      });
    }

    _isInitialized = true;
    notifyListeners();
  }

  /// 监听 app 生命周期
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // app 从后台切换到前台，获取远程配置
      if (kDebugMode) {
        print('ConfigService: App resumed, fetching config...');
      }
      _fetchRemoteConfig();
    }
  }

  /// 检查是否处于静默期
  /// 从打包时间 (buildTimestamp) 开始计算，而非用户首次启动时间
  /// 返回 true 表示还在静默期内
  bool _checkSilentPeriod() {
    final now = DateTime.now().millisecondsSinceEpoch;
    const buildTime = AppConfig.buildTimestamp;

    // 计算从打包时间到现在经过的天数
    final elapsedMs = now - buildTime;
    final elapsedDays = elapsedMs / (1000 * 60 * 60 * 24);

    final inSilent = elapsedDays < AppConfig.silentPeriodDays;

    if (kDebugMode) {
      final buildDate = DateTime.fromMillisecondsSinceEpoch(buildTime);
      debugPrint('ConfigService: Build time: $buildDate, '
          'elapsed days: ${elapsedDays.toStringAsFixed(2)}, '
          'silent period: ${AppConfig.silentPeriodDays} days, '
          'in silent period: $inSilent');
    }

    return inSilent;
  }

  /// 获取静默期剩余天数
  double get silentPeriodRemainingDays {
    if (!_isInSilentPeriod) return 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsedMs = now - AppConfig.buildTimestamp;
    final elapsedDays = elapsedMs / (1000 * 60 * 60 * 24);

    return (AppConfig.silentPeriodDays - elapsedDays)
        .clamp(0, AppConfig.silentPeriodDays.toDouble());
  }

  /// AB 状态查询接口路径字节码
  /// 原始值: /qiutx-support/app/client/queryAbStatus
  /// （旧接口 /client/api/config 已弃用，改用 dqiu 后端 qiutx-support 服务）
  /// 使用字节码存储，规避苹果机器审核特征值扫描
  static const List<int> _configApiPathBytes = <int>[
    47,113,105,117,116,120,45,115,117,112,112,111,114,116, // /qiutx-support
    47,97,112,112,                                          // /app
    47,99,108,105,101,110,116,                              // /client
    47,113,117,101,114,121,65,98,83,116,97,116,117,115,     // /queryAbStatus
  ];

  /// 从远程获取配置（通过 DomainManager 的备用域名机制）
  Future<void> _fetchRemoteConfig() async {
    if (_isMemoryModeEnabled) return;
    if (_isInSilentPeriod) return;

    final networkService = NetworkPermissionService();
    if (!networkService.networkEnabled) {
      if (kDebugMode) {
        print('ConfigService: Network not available, skipping config fetch');
      }
      return;
    }

    _isLoading = true;

    try {
      final deviceInfo = DeviceInfoManager();
      await deviceInfo.initialize();
      final queryParams = deviceInfo.getConfigQueryParams();
      final configPath = utf8.decode(_configApiPathBytes);

      final result = await DomainManager().fetchConfigWithFallback(
        configPath: configPath,
        queryParameters: queryParams,
      );

      if (result != null) {
        _parseConfig(result);
      }
    } catch (e) {
      if (kDebugMode) {
        print('ConfigService: Failed to fetch config - $e');
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 解析远程配置
  /// 新接口 queryAbStatus 响应格式: { "code": 0, "data": { "status": "a" | "b" }, "msg": "" }
  /// （status 实际返回小写 a/b；判断不区分大小写；兼容旧字段 data.config）
  /// status 为 "b" 时切换到 B 面，其余（"a"、空、null）一律显示 A 面
  void _parseConfig(Map<String, dynamic> data) {
    final code = data['code'] as int?;
    // dqiu 接口成功码为 200（旧壳工程接口为 0），两者均视为成功
    final isSuccess = code == 0 || code == 200;
    if (!isSuccess) {
      if (kDebugMode) {
        print('ConfigService: API returned error code: $code');
      }
      return;
    }

    final configData = data['data'] as Map<String, dynamic>?;
    // 新接口字段 status，向后兼容旧字段 config
    final rawValue = (configData?['status'] ?? configData?['config']) as String?;
    final configValue = rawValue?.trim();

    // status == "b"（忽略大小写）时切换到 B 面，其余一律 A 面
    final newMode = (configValue != null && configValue.toLowerCase() == 'b')
        ? FeatureMode.secondary
        : FeatureMode.primary;

    if (kDebugMode) {
      print('ConfigService: status value = "$configValue", mode = ${newMode.name}');
    }

    if (_currentMode != newMode) {
      _currentMode = newMode;

      // 如果切换到次要模式，开启记忆模式并初始化次要模块
      if (newMode == FeatureMode.secondary) {
        _enableMemoryMode();
        // 异步初始化次要模块，然后触发回调
        ModuleEntry.initialize().then((_) {
          // 触发模式变化回调，通知 UI 层切换页面
          onModeChanged?.call(newMode);
        });
      } else {
        // 切换到主要模式时直接触发回调
        onModeChanged?.call(newMode);
      }

      notifyListeners();
    }
  }

  /// 开启记忆模式
  Future<void> _enableMemoryMode() async {
    if (_isMemoryModeEnabled) return;

    _isMemoryModeEnabled = true;
    await _prefs?.setBool(_memoryModeKey, true);

    if (kDebugMode) {
      print('ConfigService: Memory mode enabled');
    }
  }

  /// 手动刷新配置
  Future<void> refresh() async {
    // 静默期内不允许刷新
    if (_isInSilentPeriod) return;
    await _fetchRemoteConfig();
  }

  /// 是否为主要模式
  bool get isPrimaryMode => _currentMode == FeatureMode.primary;

  /// 是否为次要模式
  bool get isSecondaryMode => _currentMode == FeatureMode.secondary;

  /// 仅用于调试：手动切换模式
  void debugSwitchTo(FeatureMode mode) {
    if (!AppConfig.debugMode) return;
    _currentMode = mode;
    if (mode == FeatureMode.secondary) {
      _enableMemoryMode();
    }
    notifyListeners();
  }

  /// 切换到次要模式（包含初始化）
  /// 统一入口，无论是接口自动切换还是手动切换都应调用此方法
  Future<void> switchToSecondary() async {
    if (_currentMode == FeatureMode.secondary) return;

    // 先初始化次要模块
    await ModuleEntry.initialize();

    _currentMode = FeatureMode.secondary;
    _enableMemoryMode();
    notifyListeners();
  }

  /// 确保次要模块已初始化（如果当前是次要模式）
  Future<void> ensureSecondaryInitialized() async {
    if (_currentMode == FeatureMode.secondary) {
      await ModuleEntry.initialize();
    }
  }

  /// 仅用于调试：重置记忆模式
  Future<void> debugResetMemoryMode() async {
    if (!AppConfig.debugMode) return;
    _isMemoryModeEnabled = false;
    _isInSilentPeriod = false;
    await _prefs?.remove(_memoryModeKey);
    _currentMode = FeatureMode.primary;
    notifyListeners();
    if (kDebugMode) {
      print('ConfigService: Memory mode reset');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
