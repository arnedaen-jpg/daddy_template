import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 混淆器配置
class ObfuscatorConfig {
  /// 目标目录
  final String targetDir;

  /// 项目名称 (dq, lgt)
  final String? projectName;

  /// Bundle ID / 包名（用于稳定 seed，同版本同包则生成一致，利于 Crashlytics 符号映射）
  final String? bundleId;

  /// 版本号（用于稳定 seed）
  final String? version;

  /// 字符串混淆方法 (bytes, base64, xor, concat)
  final String stringMethod;

  /// XOR 加密密钥
  final int xorKey;

  /// 调用栈深度 (1-5)
  final int callStackDepth;

  /// 启用字符串混淆
  final bool enableString;

  /// 启用调用栈混淆（针对核心类方法）
  final bool enableCallstack;

  /// 启用文件膨胀（4.3a 差异化，每个项目生成不同冗余代码）
  final bool enableBloat;

  /// 启用业务噪音注入（build/initState/getHomePage 插入 Noise.run）
  final bool enableNoise;

  /// 启用 AST 变异（方法体插入 dummy 代码）
  final bool enableMutation;

  /// 启用符号扭曲（extension/generic/mixin）
  final bool enableSymbolDistort;

  /// 模拟运行（不修改文件）
  final bool dryRun;

  /// 详细输出
  final bool verbose;

  ObfuscatorConfig({
    required this.targetDir,
    this.projectName,
    this.bundleId,
    this.version,
    this.stringMethod = 'bytes',
    this.xorKey = 42,
    this.callStackDepth = 3,
    this.enableString = false,
    this.enableCallstack = false,
    this.enableBloat = false,
    this.enableNoise = false,
    this.enableMutation = false,
    this.enableSymbolDistort = false,
    this.dryRun = false,
    this.verbose = false,
  });

  /// 稳定 seed：sha1(bundleId+version)，同版本同包生成一致，利于 Crashlytics/Sentry 符号映射
  String? get seedBase {
    if (bundleId == null ||
        bundleId!.isEmpty ||
        version == null ||
        version!.isEmpty) {
      return null;
    }
    final bytes = utf8.encode('$bundleId$version');
    return sha1.convert(bytes).toString();
  }

  /// 获取项目特定的敏感词模式
  List<String> get sensitivePatterns {
    // 通用敏感词（所有项目都适用）
    final common = <String>[
      r'/api/v\d', // API 路径 /api/v1
      r'https?://', // URL
      r'^[a-zA-Z]+/[a-zA-Z]', // xxx/yyy 格式 API
      r'^/[a-zA-Z]', // /xxx 开头的 API 路径
      'video', 'player', 'live', 'download',
      'vip', 'member', 'recharge', 'pay', 'coin',
      'login', 'register', 'password', 'token',
      'user', 'account', 'email', 'code', 'bind',
      'send', 'verify', 'validate', 'check',
    ];

    switch (projectName) {
      case 'dq':
        // 斗球/直播：关键词表
        return [
          ...common,
          'movie',
          'album',
          'dating',
          'chat',
          'danmaku',
          'webrtc',
          'customer',
          'invite',
          'track',
          'channel',
          'captcha',
          'upload',
        ];
      case 'lgt':
        // 聊个天/IM：IM 向词汇
        return [
          ...common,
          'comic',
          'novel',
          'video',
          'anime',
          'community',
          'coterie',
          'wallet',
          'blind',
          'station',
          'search',
          'favorite',
          'bookshelf',
          'message',
          'im',
        ];
      default:
        return common;
    }
  }

  /// 是否混淆中文字符串
  bool get obfuscateChinese => true;

  /// 是否混淆 UI 文本（pageKey, pageName, text, titleText 等）
  bool get obfuscateUIText => true;

  /// 最小字符串长度（小于此长度的不混淆）
  int get minStringLength => 2;

  /// 排除的文件模式
  List<String> get excludeFilePatterns => [
        '.g.dart',
        '.freezed.dart',
        'api_const.dart',
      ];
}
