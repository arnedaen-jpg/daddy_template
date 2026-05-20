import 'dart:convert';

/// 字符串编码工具
class StringEncoders {
  /// Base64 编码
  static String encodeBase64(String input) {
    return base64.encode(utf8.encode(input));
  }
  
  /// XOR 编码
  static String encodeXor(String input, int key) {
    final bytes = utf8.encode(input);
    final xored = bytes.map((b) => b ^ key).toList();
    return xored.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  
  /// Unicode 码点数组编码
  /// 注意：String.fromCharCodes 需要的是 Unicode 码点，不是 UTF-8 字节
  static String encodeBytes(String input) {
    // 使用 runes 获取 Unicode 码点，而不是 utf8.encode 获取的字节
    final codePoints = input.runes.toList();
    return '[${codePoints.join(', ')}]';
  }
  
  /// 字符串拼接编码
  static String encodeConcat(String input, {int chunkSize = 3}) {
    final chunks = <String>[];
    for (var i = 0; i < input.length; i += chunkSize) {
      final end = (i + chunkSize < input.length) ? i + chunkSize : input.length;
      chunks.add("'${input.substring(i, end)}'");
    }
    return '[${chunks.join(', ')}].join()';
  }
  
  /// 根据方法名生成混淆代码
  static String generateObfuscatedCode(String original, String method, {int xorKey = 42}) {
    switch (method) {
      case 'base64':
        final encoded = encodeBase64(original);
        return "StringDecoder.base64('$encoded')";
      case 'xor':
        final encoded = encodeXor(original, xorKey);
        return "StringDecoder.xorHex('$encoded', $xorKey)";
      case 'bytes':
        final encoded = encodeBytes(original);
        return "String.fromCharCodes($encoded)";
      case 'concat':
        return encodeConcat(original);
      default:
        return "String.fromCharCodes(${encodeBytes(original)})";
    }
  }
}
