import 'dart:io';
import 'dart:ui';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../utils/s.dart';

/// 设备信息管理器
/// 用于获取设备和应用相关信息，用于 HTTP 请求头
class DeviceInfoManager {
  static final DeviceInfoManager _instance = DeviceInfoManager._internal();
  factory DeviceInfoManager() => _instance;
  DeviceInfoManager._internal();

  PackageInfo? _packageInfo;
  IosDeviceInfo? _iosDeviceInfo;
  bool _isInitialized = false;

  /// 初始化
  Future<void> initialize() async {
    if (_isInitialized) return;

    _packageInfo = await PackageInfo.fromPlatform();

    if (Platform.isIOS) {
      final deviceInfoPlugin = DeviceInfoPlugin();
      _iosDeviceInfo = await deviceInfoPlugin.iosInfo;
    }

    _isInitialized = true;
  }

  /// Bundle ID
  String get bundleId => _packageInfo?.packageName ?? '';

  /// 应用显示名称
  String get appName => _packageInfo?.appName ?? '';

  /// 应用版本号
  String get appVersion => _packageInfo?.version ?? '';

  /// Build 号
  String get buildNumber => _packageInfo?.buildNumber ?? '';

  /// iOS 系统版本
  String get iosVersion => _iosDeviceInfo?.systemVersion ?? '';

  /// 展示用机型：优先 commercial 名称（device_info_plus 12.x+ 新增的 `modelName`，
  /// 给出像 "iPhone 15 Pro" 这种真型号），其次 UIDevice.model（泛化的 "iPhone"），
  /// 再次 utsname.machine（裸 identifier 如 "iPhone16,1"）。
  ///
  /// 用 dynamic 反射拿 modelName 是为了兼容仍走 path 依赖的老版本（11.x 没这个 getter，
  /// 直接 `info.modelName` 在编译期就会报 `The getter 'modelName' isn't defined`）。
  /// 老版自动降级到 model + utsname.machine，不再阻塞编译。
  String get deviceModel {
    final info = _iosDeviceInfo;
    if (info == null) return '';
    final String modelNameOrEmpty = (() {
      try {
        final dynamic d = info;
        final v = d.modelName;
        return v is String ? v : '';
      } catch (_) {
        return '';
      }
    })();
    for (final s in <String>[
      modelNameOrEmpty.trim(),
      info.model.trim(),
      info.utsname.machine.trim(),
    ]) {
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  /// 设备名称
  String get deviceName => _iosDeviceInfo?.name ?? '';

  /// 设备唯一标识 (identifierForVendor)
  String get deviceId => _iosDeviceInfo?.identifierForVendor ?? '';

  /// 是否为物理设备
  bool get isPhysicalDevice => _iosDeviceInfo?.isPhysicalDevice ?? false;

  /// 屏幕分辨率
  String get screenResolution {
    final window = PlatformDispatcher.instance.implicitView;
    if (window != null) {
      final size = window.physicalSize;
      return '${size.width.toInt()}x${size.height.toInt()}';
    }
    return '';
  }

  /// 获取用于 HTTP 请求头的信息 Map
  Map<String, String> getRequestHeaders() {
    return {
      S.xBundleId: _sanitizeHeaderValue(bundleId),
      S.xAppName: Uri.encodeComponent(appName),
      S.xAppVersion: _sanitizeHeaderValue(appVersion),
      S.xBuildNumber: _sanitizeHeaderValue(buildNumber),
      S.xIosVersion: _sanitizeHeaderValue(iosVersion),
      S.xDeviceModel: _sanitizeHeaderValue(deviceModel),
      S.xDeviceId: _sanitizeHeaderValue(deviceId),
      S.xIsPhysicalDevice: isPhysicalDevice.toString(),
    };
  }

  /// 获取配置接口所需的查询参数
  Map<String, String> getConfigQueryParams() {
    return {
      S.qAppVersion: appVersion,
      S.qOsVersion: iosVersion,
      S.qScreenResolution: screenResolution,
      S.qDeviceId: deviceId,
      S.qDeviceModel: deviceModel,
    };
  }

  /// 获取 iOS 风格的 User-Agent
  /// 格式: AppName/Version (iOS Version; Device Model)
  String get userAgent {
    final appName = _packageInfo?.appName ?? 'App';
    final cleanAppName = _sanitizeHeaderValue(appName);
    final cleanAppVersion = _sanitizeHeaderValue(appVersion);
    final cleanIosVersion = _sanitizeHeaderValue(iosVersion);
    final cleanDeviceModel = _sanitizeHeaderValue(deviceModel);
    
    return '$cleanAppName/$cleanAppVersion (iOS $cleanIosVersion; $cleanDeviceModel)';
  }

  /// 过滤非 ASCII 字符，确保 HTTP Header 值合法
  String _sanitizeHeaderValue(String value) {
    if (value.isEmpty) return value;
    // 只保留可见的 ASCII 字符 (0x20-0x7E)
    return value.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
  }
}
