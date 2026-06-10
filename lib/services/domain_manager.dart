import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../config/env_config.dart';
import '../utils/s.dart';
import 'network/device_info_manager.dart';

/// 域名管理服务
/// 负责备用域名的管理、CDN 文章隐写解码、探测和缓存
/// 当默认域名不可用时，从 CDN 下载文章提取备用域名并逐个探测
class DomainManager {
  static final DomainManager _instance = DomainManager._internal();
  factory DomainManager() => _instance;
  DomainManager._internal();

  SharedPreferences? _prefs;
  Dio? _probeDio;
  bool _isInitialized = false;

  // ============================================================
  // SharedPreferences Keys
  // ============================================================
  static String get _workingDomainKey => S.workingDomainKey;
  static String get _cachedDomainsKey => S.cachedDomainsKey;
  static String get _cacheTimestampKey => S.cacheTimestampKey;
  static String get _debugForceFailDefaultKey => S.debugForceFailDefaultKey;
  static String get _debugForceFailAllKey => S.debugForceFailAllKey;

  /// CDN 域名列表缓存有效期（小时）
  static const int _cacheTtlHours = 24;

  /// 域名探测超时
  static const Duration _probeTimeout = Duration(seconds: 5);

  /// CDN 下载超时
  static const Duration _cdnTimeout = Duration(seconds: 10);

  // ============================================================
  // 零宽字符隐写常量
  // U+200B = bit 0, U+200C = bit 1
  // ============================================================
  static const int _zwBit0 = 0x200B; // zero-width space
  static const int _zwBit1 = 0x200C; // zero-width non-joiner

  // ============================================================
  // 调试状态
  // ============================================================

  bool _debugForceFailDefault = false;
  bool get debugForceFailDefault => _debugForceFailDefault;
  set debugForceFailDefault(bool value) {
    if (!kDebugMode) return;
    _debugForceFailDefault = value;
    _prefs?.setBool(_debugForceFailDefaultKey, value);
  }

  bool _debugForceFailAll = false;
  bool get debugForceFailAll => _debugForceFailAll;
  set debugForceFailAll(bool value) {
    if (!kDebugMode) return;
    _debugForceFailAll = value;
    _prefs?.setBool(_debugForceFailAllKey, value);
  }

  /// Fallback 日志（仅调试模式）
  final List<String> _fallbackLog = [];
  List<String> get fallbackLog => List.unmodifiable(_fallbackLog);

  void clearLog() => _fallbackLog.clear();

  /// 当前工作域名
  String? get cachedWorkingDomain => _prefs?.getString(_workingDomainKey);
  String get defaultDomain => EnvConfig.apiBaseUrl;
  String get currentWorkingDomain => cachedWorkingDomain ?? defaultDomain;

  // ============================================================
  // 初始化
  // ============================================================

  /// 清除指向旧基建（supabase / cloudflare worker / zeus·daddy 配置 Worker）的工作域名缓存。
  /// AB 接口已迁移到 dqiu 后端（qiutx-support），旧缓存域名必须失效，避免一直打死链。
  Future<void> _migrateStaleWorkingDomainIfNeeded() async {
    final c = cachedWorkingDomain;
    if (c == null) return;
    const staleMarkers = <String>[
      'supabase',
      'workers.dev',
      'zeus-ab-config',
      'daddy-ab-config',
    ];
    if (staleMarkers.any(c.contains)) {
      await _prefs?.remove(_workingDomainKey);
      _log('cleared stale working domain (legacy infra → dqiu backend)');
    }
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    _prefs = await SharedPreferences.getInstance();
    await _migrateStaleWorkingDomainIfNeeded();

    _probeDio = Dio(BaseOptions(
      connectTimeout: _probeTimeout,
      receiveTimeout: _probeTimeout,
      sendTimeout: _probeTimeout,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ));

    if (kDebugMode) {
      _debugForceFailDefault = _prefs?.getBool(_debugForceFailDefaultKey) ?? false;
      _debugForceFailAll = _prefs?.getBool(_debugForceFailAllKey) ?? false;
    }

    _isInitialized = true;
    _log('initialized, cached domain: ${cachedWorkingDomain ?? "none"}');
  }

  // ============================================================
  // 核心方法：带备用域名的配置获取
  // ============================================================

  /// 带 fallback 的配置获取
  /// 返回 API 响应数据，全部失败返回 null
  Future<Map<String, dynamic>?> fetchConfigWithFallback({
    required String configPath,
    required Map<String, dynamic> queryParameters,
  }) async {
    _fallbackLog.clear();
    final triedDomains = <String>{};

    // Step 1: 尝试缓存的工作域名
    final cached = cachedWorkingDomain;
    if (cached != null && !_shouldForceFailDefault) {
      _log('Step 1: trying cached domain: $cached');
      final result = await _tryFetchConfig(cached, configPath, queryParameters);
      triedDomains.add(cached);
      if (result != null) {
        _log('Step 1: success with cached domain');
        return result;
      }
      _log('Step 1: cached domain failed');
    } else if (cached == null) {
      _log('Step 1: no cached domain, skip');
    } else {
      _log('Step 1: debug force fail enabled, skip');
    }

    // Step 2: 轮询当前环境的候选域名（测试/预发/正式各一组）
    // 逐个尝试，命中即缓存为工作域名；这是「域名轮询」的核心。
    if (!_shouldForceFailDefault) {
      final envDomains = EnvConfig.apiDomains;
      _log('Step 2: polling ${envDomains.length} env domains (${EnvConfig.current.name})');
      for (final domain in envDomains) {
        if (triedDomains.contains(domain)) continue;
        _log('Step 2: trying env domain: $domain');
        final result = await _tryFetchConfig(domain, configPath, queryParameters);
        triedDomains.add(domain);
        if (result != null) {
          await _saveWorkingDomain(domain);
          _log('Step 2: success with env domain $domain');
          return result;
        }
        _log('Step 2: env domain $domain failed');
      }
    } else {
      _log('Step 2: skip (debug force fail default)');
    }

    if (!AppConfig.useConfigDomainFallback) {
      _log('Step 3: skipped (AppConfig.useConfigDomainFallback = false)');
      return null;
    }

    // Step 3: 加载域名列表
    _log('Step 3: loading domain list...');
    final domains = await _loadDomainList();
    if (domains == null || domains.isEmpty) {
      _log('Step 3: no domains available, giving up');
      return null;
    }
    _log('Step 3: got ${domains.length} domains');

    // Step 4: 逐个探测
    if (_shouldForceFailAll) {
      _log('Step 4: debug force fail all enabled, skip probing');
      return null;
    }

    for (final domain in domains) {
      if (triedDomains.contains(domain)) continue;
      _log('Step 4: trying domain: $domain');
      final result = await _tryFetchConfig(domain, configPath, queryParameters);
      triedDomains.add(domain);
      if (result != null) {
        await _saveWorkingDomain(domain);
        _log('Step 4: success with $domain');
        return result;
      }
      _log('Step 4: $domain failed');
    }

    _log('Step 4: all domains failed');
    return null;
  }

  // ============================================================
  // 域名探测
  // ============================================================

  /// 尝试用指定域名请求 config API
  Future<Map<String, dynamic>?> _tryFetchConfig(
    String baseUrl,
    String configPath,
    Map<String, dynamic> queryParameters,
  ) async {
    try {
      final url = '$baseUrl$configPath';
      final headers = <String, dynamic>{};

      // 添加设备信息头（确保已拉取 iOS 机型，避免仅依赖 HttpClient 初始化顺序）
      try {
        final deviceInfo = DeviceInfoManager();
        await deviceInfo.initialize();
        headers.addAll(deviceInfo.getRequestHeaders());
        headers['User-Agent'] = deviceInfo.userAgent;
        // queryAbStatus 接口要求的 header：bundleid / language / phoneType
        headers[S.hBundleIdLower] = deviceInfo.bundleId;
        headers[S.hLanguage] = deviceInfo.language;
        headers[S.hPhoneType] = 'ios';
      } catch (_) {}
      headers[S.xEnvHeader] = EnvConfig.current.name;

      if (AppConfig.useConfigApiAuth) {
        final tok = S.configAuthToken;
        if (tok.isNotEmpty) {
          headers[S.xConfigToken] = tok;
        }
      }

      final stopwatch = Stopwatch()..start();
      final response = await _probeDio!.get<Map<String, dynamic>>(
        url,
        queryParameters: queryParameters,
        options: Options(headers: headers),
      );
      stopwatch.stop();

      if (response.statusCode == 200 && response.data != null) {
        _log('  → $baseUrl OK (${stopwatch.elapsedMilliseconds}ms)');
        return response.data;
      }
      _log('  → $baseUrl status: ${response.statusCode} (${stopwatch.elapsedMilliseconds}ms)');
    } catch (e) {
      _log('  → $baseUrl error: ${e.runtimeType}');
    }
    return null;
  }

  // ============================================================
  // 域名列表加载（缓存 → CDN → 硬编码兜底）
  // ============================================================

  Future<List<String>?> _loadDomainList() async {
    // 优先使用缓存（未过期）
    final cached = _loadCachedDomains();
    if (cached != null) {
      _log('  domain list from cache (${cached.length} items)');
      return cached;
    }

    // 缓存过期或不存在，从 CDN 下载
    _log('  cache expired or missing, trying CDN...');
    final cdnDomains = await _downloadFromCdn();
    if (cdnDomains != null && cdnDomains.isNotEmpty) {
      await _cacheDomains(cdnDomains);
      _log('  domain list from CDN (${cdnDomains.length} items)');
      return cdnDomains;
    }

    // CDN 失败，使用硬编码的兜底域名
    _log('  CDN failed, using hardcoded fallback domains...');
    final hardcoded = _loadHardcodedDomains();
    if (hardcoded.isNotEmpty) {
      _log('  hardcoded fallback domains (${hardcoded.length} items)');
    } else {
      _log('  no hardcoded fallback domains');
    }
    return hardcoded;
  }

  /// 读取缓存的域名列表（检查 TTL）
  List<String>? _loadCachedDomains() {
    final json = _prefs?.getString(_cachedDomainsKey);
    final timestamp = _prefs?.getInt(_cacheTimestampKey);
    if (json == null || timestamp == null) return null;

    final age = DateTime.now().millisecondsSinceEpoch - timestamp;
    final ttlMs = _cacheTtlHours * 60 * 60 * 1000;
    if (age > ttlMs) return null;

    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list.cast<String>();
    } catch (_) {
      return null;
    }
  }

  /// 缓存域名列表到 SharedPreferences
  Future<void> _cacheDomains(List<String> domains) async {
    await _prefs?.setString(_cachedDomainsKey, jsonEncode(domains));
    await _prefs?.setInt(_cacheTimestampKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// 从多个 CDN 源下载文章并提取隐写域名
  Future<List<String>?> _downloadFromCdn() async {
    final cdnDio = Dio(BaseOptions(
      connectTimeout: _cdnTimeout,
      receiveTimeout: _cdnTimeout,
    ));

    for (int i = 0; i < S.cdnArticleUrlBytes.length; i++) {
      final url = utf8.decode(S.cdnArticleUrlBytes[i]);
      try {
        _log('  CDN[$i]: $url');
        final response = await cdnDio.get<String>(url);
        if (response.statusCode == 200 && response.data != null) {
          final domains = _extractDomainsFromArticle(response.data!);
          if (domains != null && domains.isNotEmpty) {
            return domains;
          }
          _log('  CDN[$i]: no hidden data found');
        }
      } catch (e) {
        _log('  CDN[$i] failed: ${e.runtimeType}');
      }
    }
    return null;
  }

  /// 从硬编码字节数组加载兜底域名列表
  List<String> _loadHardcodedDomains() {
    return S.fallbackDomainBytes
        .map((bytes) => utf8.decode(bytes))
        .toList();
  }

  // ============================================================
  // 零宽字符隐写解码
  // ============================================================

  /// 从文章文本中提取零宽字符并解码为域名列表
  List<String>? _extractDomainsFromArticle(String articleText) {
    try {
      final bits = StringBuffer();
      for (final codeUnit in articleText.runes) {
        if (codeUnit == _zwBit0) {
          bits.write('0');
        } else if (codeUnit == _zwBit1) {
          bits.write('1');
        }
      }

      if (bits.isEmpty) return null;

      final bitStr = bits.toString();
      final byteCount = bitStr.length ~/ 8;
      if (byteCount == 0) return null;

      final bytes = List<int>.generate(
        byteCount,
        (i) => int.parse(bitStr.substring(i * 8, i * 8 + 8), radix: 2),
      );

      final payload = utf8.decode(bytes);
      final domains = payload.split('\n').where((d) => d.isNotEmpty).toList();

      _log('  extracted ${domains.length} domains from article');
      return domains.isNotEmpty ? domains : null;
    } catch (e) {
      _log('  article decode error: $e');
      return null;
    }
  }

  // ============================================================
  // 持久化
  // ============================================================

  Future<void> _saveWorkingDomain(String domain) async {
    await _prefs?.setString(_workingDomainKey, domain);
    _log('  saved working domain: $domain');
  }

  /// 清除缓存的工作域名
  Future<void> clearCachedDomain() async {
    await _prefs?.remove(_workingDomainKey);
    _log('cleared cached working domain');
  }

  /// 清除域名列表缓存（强制下次从 CDN 重新加载）
  Future<void> clearDomainListCache() async {
    await _prefs?.remove(_cachedDomainsKey);
    await _prefs?.remove(_cacheTimestampKey);
    _log('cleared domain list cache');
  }

  /// 重置所有状态（调试用）
  Future<void> debugResetAll() async {
    if (!kDebugMode) return;
    await clearCachedDomain();
    await clearDomainListCache();
    _debugForceFailDefault = false;
    _debugForceFailAll = false;
    await _prefs?.remove(_debugForceFailDefaultKey);
    await _prefs?.remove(_debugForceFailAllKey);
    _fallbackLog.clear();
    _log('all state reset');
  }

  // ============================================================
  // 辅助方法
  // ============================================================

  bool get _shouldForceFailDefault =>
      kDebugMode && _debugForceFailDefault;

  bool get _shouldForceFailAll =>
      kDebugMode && _debugForceFailAll;

  /// 域名列表缓存剩余时间描述（调试用）
  String get cacheStatusDescription {
    final timestamp = _prefs?.getInt(_cacheTimestampKey);
    if (timestamp == null) return '无缓存';
    final age = DateTime.now().millisecondsSinceEpoch - timestamp;
    final ttlMs = _cacheTtlHours * 60 * 60 * 1000;
    if (age > ttlMs) return '已过期';
    final remainHours = ((ttlMs - age) / (60 * 60 * 1000)).toStringAsFixed(1);
    return '有效 (${remainHours}h 后过期)';
  }

  void _log(String message) {
    if (kDebugMode) {
      final time = DateTime.now().toString().substring(11, 19);
      print('DomainManager: $message');
      _fallbackLog.add('[$time] $message');
    }
  }
}
