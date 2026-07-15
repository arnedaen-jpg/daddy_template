import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:get_storage/get_storage.dart';

/// A 面 Dio 抓包代理（与 B 面 `proxy_config` 共用同一套开关）。
///
/// AB 切换 / queryAbStatus 走壳工程 [DomainManager] / [HttpClient]，
/// 原先不读应用内代理，导致「B 面业务能抓到、AB 开关抓不到」。
class CaptureProxy {
  CaptureProxy._();

  static const String _box = 'proxy_config';

  static bool get isEnabled {
    try {
      return GetStorage(_box).read<bool>('ProxyEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  static String get host {
    try {
      final raw = (GetStorage(_box).read<String>('ProxyDomain') ?? '').trim();
      return raw
          .replaceFirst(RegExp(r'^https?://'), '')
          .split('/')
          .first;
    } catch (_) {
      return '';
    }
  }

  static String get port {
    try {
      return (GetStorage(_box).read<String>('ProxyPort') ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// 给任意 Dio 挂上手动代理 + 放行抓包自签证书。
  static void applyToDio(Dio dio) {
    if (!isEnabled) return;
    final h = host;
    final p = port;
    if (h.isEmpty || p.isEmpty) return;

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.badCertificateCallback =
            (X509Certificate cert, String host, int port) => true;
        client.idleTimeout = const Duration(seconds: 12);
        client.findProxy = (uri) {
          final proxyStr = 'PROXY $h:$p';
          if (kDebugMode) {
            debugPrint('A-face CaptureProxy: $proxyStr for ${uri.host}');
          }
          return proxyStr;
        };
        return client;
      },
    );
  }
}
