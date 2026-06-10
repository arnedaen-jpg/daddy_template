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

  /// 设备机型标识（phoneType header）——对齐 XMSport 的 `[UIDevice deviceTypeName]`：
  /// 真机返回 utsname.machine 这种硬件 identifier（如 "iPhone15,2"），
  /// 模拟器返回 "<model> SimuLator"。注意这是设备类型，不是 "ios"。
  String get phoneType {
    final info = _iosDeviceInfo;
    if (info == null) return '';
    if (!isPhysicalDevice) {
      final model = info.model.trim();
      return '${model.isNotEmpty ? model : 'iPhone'} SimuLator';
    }
    final machine = info.utsname.machine.trim();
    return machine.isNotEmpty ? machine : info.model.trim();
  }

  /// 当前语言（如 zh-CN），用于 AB 状态查询接口的 language header
  String get language {
    final locale = PlatformDispatcher.instance.locale;
    final code = locale.languageCode;
    final country = locale.countryCode;
    if (country != null && country.isNotEmpty) {
      return '$code-$country';
    }
    return code;
  }

  /// 渠道号：构建时可用 --dart-define=APP_CHANNEL=xxx 覆盖，缺省走默认渠道
  String get appChannel {
    const fromDefine = String.fromEnvironment('APP_CHANNEL', defaultValue: '');
    return fromDefine.isNotEmpty ? fromDefine : S.defaultChannel;
  }

  /// AB 状态查询接口（qiutx-support/app/client/queryAbStatus）的请求头。
  /// 与 dqiu 客户端 getHeader 对齐：version / client-type / source / channel /
  /// client-tag / channelApp / deviceId / Authorization / x-user-header，
  /// 外加接口文档要求的 bundleid / language / phoneType。
  ///
  /// 注: sign / t / r 为业务接口防篡改签名（依赖 signMD5 密钥与登录态），
  /// 该状态查询接口不需要，故不同步。未登录态统一用 Basic 默认凭证。
  Map<String, String> getAbQueryHeaders() {
    final channel = appChannel;
    return {
      S.hVersion: _sanitizeHeaderValue(appVersion),
      S.hClientType: S.vClientTypeIos,
      S.hSource: channel,
      S.hChannel: channel,
      S.hClientTag: S.vClientTag,
      S.hChannelApp: channel,
      S.hDeviceIdLower: _sanitizeHeaderValue(deviceId),
      S.hAuthorization: S.vBasicAuth,
      S.hXUserHeader: S.vAnonUserHeader,
      S.hBundleIdLower: _sanitizeHeaderValue(bundleId),
      S.hLanguage: _sanitizeHeaderValue(language),
      S.hPhoneType: _sanitizeHeaderValue(phoneType),
    };
  }

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
