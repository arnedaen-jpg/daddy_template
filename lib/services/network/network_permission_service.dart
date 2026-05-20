import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// 网络权限服务
/// 用于监控网络权限状态，解决 iOS 首次安装时用户未授权网络导致 AB 配置请求失败的问题
/// 参考 iOS 原生 NetworkPermissionMonitor 实现
class NetworkPermissionService extends ChangeNotifier {
  static final NetworkPermissionService _instance = NetworkPermissionService._internal();
  factory NetworkPermissionService() => _instance;
  NetworkPermissionService._internal();

  /// 网络是否可用
  bool _networkEnabled = false;
  bool get networkEnabled => _networkEnabled;

  /// 是否已初始化
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// 是否正在等待网络权限
  bool _isWaitingForPermission = false;
  bool get isWaitingForPermission => _isWaitingForPermission;

  /// 连接状态订阅
  StreamSubscription<dynamic>? _connectivitySubscription;

  /// 网络可用回调列表
  final List<VoidCallback> _networkEnabledCallbacks = [];

  /// 初始化服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    if (kDebugMode) {
      print('NetworkPermissionService: Initializing...');
    }

    // 开始监听网络状态变化
    _startConnectivityMonitor();

    // 触发网络权限弹窗（通过请求 apple.com）
    await _triggerNetworkPermission();

    _isInitialized = true;
  }

  /// 开始监控网络连接状态
  void _startConnectivityMonitor() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (dynamic result) {
        final List<ConnectivityResult> results;
        if (result is List<ConnectivityResult>) {
          results = result;
        } else if (result is ConnectivityResult) {
          results = [result];
        } else {
          results = [];
        }
        _handleConnectivityChange(results);
      },
    );
  }

  /// 处理网络连接状态变化
  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final hasConnection = results.isNotEmpty && 
        !results.contains(ConnectivityResult.none);

    if (kDebugMode) {
      print('NetworkPermissionService: Connectivity changed: $results, hasConnection: $hasConnection');
    }

    // 如果从无网络变为有网络，进行实际的网络连通性测试
    if (hasConnection && !_networkEnabled) {
      _verifyNetworkConnection();
    } else if (!hasConnection) {
      _updateNetworkStatus(false);
    }
  }

  /// 触发网络权限弹窗
  /// 通过发起一个简单的 HEAD 请求到 apple.com 来触发 iOS 的网络权限弹窗
  Future<void> _triggerNetworkPermission() async {
    _isWaitingForPermission = true;
    notifyListeners();

    if (kDebugMode) {
      print('NetworkPermissionService: Triggering network permission dialog...');
    }

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      
      final request = await client.headUrl(Uri.parse('https://www.apple.com'));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Network permission trigger timeout');
        },
      );

      // 清空响应数据
      await response.drain();

      if (kDebugMode) {
        print('NetworkPermissionService: Network permission trigger completed, status: ${response.statusCode}');
      }

      // 请求成功说明网络可用
      _updateNetworkStatus(true);
    } catch (e) {
      if (kDebugMode) {
        print('NetworkPermissionService: Network permission trigger failed: $e');
      }
      // 请求失败，可能是用户拒绝了网络权限或网络不可用
      _updateNetworkStatus(false);
    } finally {
      _isWaitingForPermission = false;
      notifyListeners();
    }
  }

  /// 验证网络连接是否真正可用
  /// 通过实际发起请求来确认网络连通性
  Future<void> _verifyNetworkConnection() async {
    if (kDebugMode) {
      print('NetworkPermissionService: Verifying network connection...');
    }

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      
      final request = await client.headUrl(Uri.parse('https://www.apple.com'));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Network verification timeout');
        },
      );

      await response.drain();

      if (kDebugMode) {
        print('NetworkPermissionService: Network verification succeeded, status: ${response.statusCode}');
      }

      _updateNetworkStatus(true);
    } catch (e) {
      if (kDebugMode) {
        print('NetworkPermissionService: Network verification failed: $e');
      }
      _updateNetworkStatus(false);
    }
  }

  /// 更新网络状态
  void _updateNetworkStatus(bool enabled) {
    if (_networkEnabled == enabled) return;

    final wasDisabled = !_networkEnabled;
    _networkEnabled = enabled;

    if (kDebugMode) {
      print('NetworkPermissionService: Network status changed to: $enabled');
    }

    notifyListeners();

    // 如果从不可用变为可用，触发回调
    if (wasDisabled && enabled) {
      _triggerNetworkEnabledCallbacks();
    }
  }

  /// 触发网络可用回调
  void _triggerNetworkEnabledCallbacks() {
    if (kDebugMode) {
      print('NetworkPermissionService: Triggering ${_networkEnabledCallbacks.length} callbacks');
    }

    for (final callback in _networkEnabledCallbacks) {
      callback();
    }
    // 一次性回调，触发后清空
    _networkEnabledCallbacks.clear();
  }

  /// 注册网络可用回调（一次性）
  /// 当网络从不可用变为可用时触发
  void onNetworkEnabled(VoidCallback callback) {
    if (_networkEnabled) {
      // 如果网络已经可用，直接执行回调
      callback();
    } else {
      _networkEnabledCallbacks.add(callback);
    }
  }

  /// 等待网络可用
  /// 返回一个 Future，当网络可用时完成
  Future<void> waitForNetworkEnabled({Duration? timeout}) async {
    if (_networkEnabled) return;

    final completer = Completer<void>();
    
    onNetworkEnabled(() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    if (timeout != null) {
      return completer.future.timeout(
        timeout,
        onTimeout: () {
          if (kDebugMode) {
            print('NetworkPermissionService: Wait for network timed out');
          }
        },
      );
    }

    return completer.future;
  }

  /// 手动重试网络权限检测
  Future<void> retryNetworkPermission() async {
    await _triggerNetworkPermission();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _networkEnabledCallbacks.clear();
    super.dispose();
  }
}
