import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 混淆器配置
class ObfuscatorConfig {
  /// 目标目录
  final String targetDir;

  /// 项目名称 (hjsq, ph, 51pc, 51cg, hlw, tiktok, 91cg, yms, acfun, tx, douyin, mrds, oio, bili, 91porn, 91porn2, txpjb, xjpjb, hlbdy, nnrj)
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
      case 'ph':
        return [
          ...common,
          'porn',
          'adult',
          'xxx',
          'sex',
        ];
      case 'hjsq':
        return [
          ...common,
          'audio',
          'voice',
          'ai',
          'generate',
          'cartoon',
          'novel',
          'game',
          'feed',
        ];
      case 'hlw':
        return [
          ...common,
          'social',
          'community',
          'short',
          'welfare',
          'lucky',
          'sign',
          'store',
          'rank',
        ];
      case 'tiktok':
        return [
          ...common,
          'comic',
          'novel',
          'audio',
          'seed',
          'date',
          'chat',
          'game',
          'aifun',
          'live',
          'mine',
          'post',
        ];
      case '91cg':
        return [
          ...common,
          'jycg',
          'TJ-043',
          'chgapi',
          'chigua',
          'social',
          'community',
          'welfare',
          'ai',
          'strip',
          'faceoff',
          'paint',
          'novel',
          'sign',
          'growth',
          'blogger',
          'acting',
          'analytics',
          'report',
          'track',
          'trace',
          'aff',
          'attribution',
          'fingerprint',
          'session',
          'install',
          'device',
          'oauth',
          'bundleId',
          'appCode',
          'domain',
          'cdn',
          'm3u8',
          'upload',
          'invite',
        ];
      case '51cg':
        return [
          ...common,
          'cgqz',
          'social',
          'community',
          'secret',
          'welfare',
          'girl',
          'keep',
          'ai',
          'strip',
          'face',
          'paint',
          'novel',
          'sign',
          'blogger',
          'vip',
          'analytics',
          'report',
          'trace',
          'aff',
          'attribution',
          'fingerprint',
          'session',
          'install',
        ];
      case 'yms':
        return [
          ...common,
          'cartoon',
          'comic',
          'video',
          'short',
          'detect',
          'track',
          'splash',
          'gesture',
        ];
      case 'acfun':
        return [
          ...common,
          'acfun',
          'acfan',
          'comic',
          'novel',
          'video',
          'anime',
          'community',
          'coterie',
          'dynamic',
          'blogger',
          'adult',
          'game',
          'wallet',
          'blind',
          'station',
          'search',
          'favorite',
          'bookshelf',
          'im',
          'chat',
          'message',
          'conversation',
          'friend',
          'unread',
          'quota',
          'voice',
          'sound',
          'audio',
          'vibration',
          'analytics',
          'report',
          'track',
          'trace',
          'session',
          'channel',
          'attribution',
          'device',
          'udid',
          'jailbreak',
          'domain',
          'cdn',
          'm3u8',
          'upload',
          'invite',
          'appCode',
          'appNickname',
        ];
      case 'nnrj':
        return [
          ...common,
          'nnrj',
          'nan',
          'niang',
          'diary',
          'hengrui',
          'tsplay',
          'xd',
          'api',
          'domain',
          'backup',
          'line',
          'encrypt',
          'decrypt',
          'device',
          'uuid',
          'udid',
          'channel',
          'appCode',
          'appNickname',
          'inviteCode',
          'analytics',
          'report',
          'track',
          'trace',
          'session',
          'attribution',
          'install',
          'im',
          'chat',
          'message',
          'conversation',
          'notice',
          'm3u8',
          'download',
          'cache',
          'upload',
          'vip',
          'wallet',
          'coin',
          'gold',
          'recharge',
          'pay',
          'ai',
          'face',
          'pic',
          'video',
          'game',
          'hookup',
          'diary',
          'blogger',
          'community',
          'short',
          'rank',
          'search',
        ];
      case 'tx':
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
      case 'dq':
        // 斗球/直播：与 tx 相同关键词表
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
        // 聊个天：与 acfun 相同 + IM 向词汇
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
      case 'douyin':
        return [
          ...common,
          'douyin',
          'movie',
          'post',
          'follow',
          'chat',
          'search',
          'creator',
          'analytics',
          'danmaku',
          'withdraw',
          'recharge',
          'share',
          'track',
        ];
      case 'mrds':
        return [
          ...common,
          'snsds',
          'social',
          'community',
          'contest',
          'match',
          'rider',
          'broker',
          'girl',
          'ai',
          'strip',
          'face',
          'paint',
          'novel',
          'sign',
          'blogger',
          'withdraw',
          'recharge',
          'trace',
        ];
      case 'oio':
        return [
          ...common,
          'oioclient',
          'comic',
          'novel',
          'video',
          'live',
          'community',
          'post',
          'photo',
          'game',
          'wallet',
          'withdraw',
          'recharge',
          'creator',
          'agent',
          'track',
          'analytics',
          'device',
          'splash',
        ];
      case 'bili':
        return [
          ...common,
          'blxvclient',
          'bili',
          'comic',
          'comics',
          'cartoon',
          'novel',
          'video',
          'short',
          'live',
          'community',
          'post',
          'photo',
          'game',
          'wallet',
          'withdraw',
          'recharge',
          'creator',
          'agent',
          'track',
          'analytics',
          'device',
          'splash',
          'domain',
          'encrypt',
          'hmac',
        ];
      case '91porn':
        return [
          ...common,
          'jyporn',
          '91porn',
          'video',
          'short',
          'live',
          'community',
          'post',
          'cartoon',
          'novel',
          'darkweb',
          'wallet',
          'recharge',
          'withdraw',
          'pre_sale',
          'track',
          'analytics',
          'device',
          'splash',
          'domain',
          'm3u8',
          'download',
        ];
      case '91porn2':
        return [
          ...common,
          'porn',
          'pron',
          '91porn',
          'dx-092',
          'ympxbys',
          'iuoqtoqr',
          'api.php',
          'github',
          'official',
          'oauth',
          'trace',
          'aff',
          'pwa',
          'comic',
          'novel',
          'audio',
          'girl',
          'date',
          'chat',
          'live',
          'post',
          'seed',
          'wallet',
          'withdraw',
          'recharge',
          'analytics',
          'report',
          'device',
          'domain',
          'm3u8',
          'encrypt',
          'upload',
        ];
      case 'txpjb':
        return [
          ...common,
          'sf42',
          'movie',
          'comic',
          'cartoon',
          'anime',
          'drama',
          'short',
          'stream',
          'nude',
          'darknet',
          'ai',
          'lottery',
          'wallet',
          'withdraw',
          'recharge',
          'task',
          'splash',
          'analytics',
          'channel',
          'cdn',
          'native',
          'domain',
          'dynamic',
          'upload',
        ];
      case 'xjpjb':
        return [
          ...common,
          'sf81',
          'xjpjb',
          'movie',
          'comic',
          'anime',
          'short',
          'stream',
          'nude',
          'darknet',
          'melon',
          'ai',
          'chat',
          'wallet',
          'withdraw',
          'recharge',
          'task',
          'shop',
          'splash',
          'analytics',
          'channel',
          'cdn',
          'native',
          'domain',
          'dynamic',
          'upload',
          'qrcode',
          'barcode',
        ];
      case 'hlbdy':
        return [
          ...common,
          'hlbdy',
          'black',
          'sns',
          'social',
          'community',
          'topic',
          'wanted',
          'welfare',
          'short',
          'video',
          'ai',
          'faceoff',
          'paint',
          'strip',
          'novel',
          'voice',
          'sign',
          'vip',
          'gold',
          'coin',
          'wallet',
          'recharge',
          'trace',
          'aff',
          'attribution',
          'analytics',
          'fingerprint',
          'session',
          'install',
          'domain',
          'security',
          'jailbreak',
          'token',
          'hive',
          'r2',
          'multipart',
        ];
      case '51pc':
        return [
          ...common,
          'tea',
          'elegant',
          'broker',
          'adopt',
          'lottery',
          'chat',
          'mall',
          'order',
          'withdraw',
          'report',
          'intention',
          'agent',
          'ingot',
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
