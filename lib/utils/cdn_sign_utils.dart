import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// CDN URL 加签（对齐 XMSport XMTmapCDNDomainTool / dqiu StringUtils）
class CdnSignUtils {
  CdnSignUtils._();

  static String generateRandomString(int length) {
    const charset =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(charset[random.nextInt(charset.length)]);
    }
    return buffer.toString();
  }

  /// typeValue: 1 阿里, 2 腾讯, 3 华为
  static String signTypeA(String urlS, String token, int typeValue) {
    var urlStr = urlS;
    var keyStr = '';

    if (typeValue == 1) {
      keyStr = 'auth_key';
    } else if (typeValue == 2) {
      keyStr = 'sign';
    } else if (typeValue == 3) {
      keyStr = 'auth_key';
    }

    if (keyStr.isEmpty || urlStr.contains('$keyStr=')) {
      return urlStr;
    }

    String uriPath;
    if (urlStr.contains(':')) {
      final uri = Uri.parse(urlStr);
      if (uri.host.isEmpty) return urlStr;
      final hostUrl = '${uri.scheme}://${uri.host}';
      uriPath = urlStr.substring(hostUrl.length);
    } else {
      uriPath = urlStr;
    }

    var uriPathShort = uriPath;
    if (uriPath.contains('?')) {
      uriPathShort = uriPath.split('?').first;
    }

    var randomStr = '0';
    if (typeValue != 1) {
      randomStr = generateRandomString(20).toLowerCase();
    }

    var timeInterval = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (typeValue != 3) {
      timeInterval += 3600;
    }

    final uriPathNew = '$uriPathShort-$timeInterval-$randomStr-0-$token';
    final md5Str = md5.convert(utf8.encode(uriPathNew)).toString();

    if (urlStr.contains('?')) {
      return '$urlStr&$keyStr=$timeInterval-$randomStr-0-$md5Str';
    }
    return '$urlStr?$keyStr=$timeInterval-$randomStr-0-$md5Str';
  }

  static String signTypeB(String urlS, String token, int typeValue) {
    final urlStr = _processUrl202(urlS);

    String uriPath;
    var hostUrl = '';
    if (urlStr.contains(':')) {
      final url = Uri.parse(urlStr);
      if (url.host.isEmpty) return urlStr;
      hostUrl = '${url.scheme}://${url.host}';
      uriPath = urlStr.substring(hostUrl.length);
    } else {
      uriPath = urlStr;
    }

    var uriPathShort = uriPath;
    if (uriPath.contains('?')) {
      uriPathShort = uriPath.split('?').first;
    }

    final date = DateTime.now().subtract(const Duration(minutes: 10));
    final dateStr = _cdnDateStr(date);

    final uriPathNew = token + dateStr + uriPathShort;
    final md5Str = md5.convert(utf8.encode(uriPathNew)).toString();

    if (urlStr.isNotEmpty) {
      return '$hostUrl/$dateStr/$md5Str$uriPath';
    }
    return '$dateStr/$md5Str$uriPath';
  }

  /// 对完整 URL 按域名实体加签；方能或 openFlag=false 时原样返回
  static String maybeSignUrl(String url, {
    required int domainType,
    required bool openFlag,
    required String token,
    required String signType,
  }) {
    if (domainType <= 0 || !openFlag || token.isEmpty) {
      return url;
    }
    if (signType == 'B') {
      return signTypeB(url, token, domainType);
    }
    return signTypeA(url, token, domainType);
  }

  static String _cdnDateStr(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}${two(date.month)}${two(date.day)}'
        '${two(date.hour)}${two(date.minute)}';
  }

  static String _processUrl202(String urlStr) {
    var newSr = urlStr;
    final array = urlStr.split('/');
    if (urlStr.contains('/202') && array.length > 4) {
      final lastDateString = array[3];
      final lastMD5String = array[4];
      final temp = '/$lastDateString/$lastMD5String';
      newSr = urlStr.replaceAll(temp, '');
    }
    return newSr;
  }
}
