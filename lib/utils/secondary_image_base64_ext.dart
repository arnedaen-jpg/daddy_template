import 'dart:convert';
import 'dart:typed_data';

import '../modules/secondary/generate/secondary_image_base64_map.dart';

final Map<String, String?> _secondaryImageBase64Cache = <String, String?>{};
final Map<String, Uint8List> _secondaryImageBytesCache = <String, Uint8List>{};

String _normalizeSecondaryImagePath(String path) {
  if (path.startsWith('assets/') && !path.contains('assets/secondary/')) {
    return path.replaceFirst('assets/', 'assets/secondary/');
  }
  if (path.startsWith('assetsholiday/') && !path.contains('assets/secondary/')) {
    return path.replaceFirst(
      'assetsholiday/',
      'assets/secondary/assetsholiday/',
    );
  }
  return path;
}

String? _resolveSecondaryImageBase64(String path) {
  final newPath = _normalizeSecondaryImagePath(path);
  return _secondaryImageBase64Cache.putIfAbsent(newPath, () {
    final name = newPath.split('/').isNotEmpty ? newPath.split('/').last : newPath;
    return SecondaryImageBase64Map.getByPath(newPath) ??
        SecondaryImageBase64Map.getByName(newPath) ??
        SecondaryImageBase64Map.getByName(name);
  });
}

Uint8List _resolveSecondaryImageBytes(String path) {
  final newPath = _normalizeSecondaryImagePath(path);
  return _secondaryImageBytesCache.putIfAbsent(newPath, () {
    final String? b64 = _resolveSecondaryImageBase64(newPath);
    if (b64 == null || b64.isEmpty) {
      return Uint8List(0);
    }
    return base64Decode(b64);
  });
}

extension SecondaryImageBase64Ext on String {
  /// 按路径优先、文件名回退读取 Base64，并解码成 bytes。
  Uint8List base64data() => _resolveSecondaryImageBytes(this);

  String normalizedSecondaryImagePath() => _normalizeSecondaryImagePath(this);

  String fixPath(String path) => _normalizeSecondaryImagePath(path);
}
