import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';

/// 对齐 XMSport / AFNetworking 默认 User-Agent。
///
/// AFNetworking 格式：
/// `Executable/Version (UIDevice.model; iOS systemVersion; Scale/x.xx)`
/// 例：`XMSport/3.0.0 (iPhone; iOS 17.0; Scale/3.00)`
///
/// App 名取自 `CFBundleExecutable`，缺省用 `CFBundleIdentifier`；
/// Flutter 默认 executable 为 `Runner` 时改用 `CFBundleName`（如 watchsport / xty）。
class UserAgentUtils {
  UserAgentUtils._();

  static const _channel = MethodChannel('xm.ua/bundle_info');

  /// 解析 UA 前缀 App 名（对齐 AFNetworking）
  static Future<String> resolveAppToken({
    required String fallbackAppName,
    required String fallbackPackageName,
  }) async {
    if (Platform.isIOS) {
      try {
        final token = await _channel.invokeMethod<String>('userAgentAppToken');
        final cleaned = sanitize(token ?? '');
        if (cleaned.isNotEmpty) return cleaned;
      } catch (_) {}
    }

    final fromDisplay = sanitize(fallbackAppName);
    if (fromDisplay.isNotEmpty) return fromDisplay;

    final parts = fallbackPackageName.split('.');
    final last = parts.isNotEmpty ? sanitize(parts.last) : '';
    if (last.isNotEmpty) return last;

    return 'App';
  }

  /// 组装完整 UA
  static String build({
    required String appToken,
    required String version,
    required String model,
    required String iosVersion,
    double? scale,
  }) {
    final name = sanitize(appToken).isEmpty ? 'App' : sanitize(appToken);
    final ver = sanitize(version);
    final cleanModel =
        sanitize(model).isEmpty ? 'iPhone' : sanitize(model);
    final cleanIos = sanitize(iosVersion);
    final pixelRatio = scale ??
        (PlatformDispatcher.instance.views.isNotEmpty
            ? PlatformDispatcher.instance.views.first.devicePixelRatio
            : 3.0);
    return '$name/$ver ($cleanModel; iOS $cleanIos; Scale/${pixelRatio.toStringAsFixed(2)})';
  }

  static String sanitize(String value) {
    if (value.isEmpty) return value;
    return value.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
  }
}
