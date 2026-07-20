import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../config/env_config.dart';
import '../utils/cdn_sign_utils.dart';
import '../utils/s.dart';
import 'domain/domain_entity.dart';
import 'network/device_info_manager.dart';

enum _DowngradeType { service, obs, npm }

class _DowngradeModel {
  final int rank;
  final String url;
  final _DowngradeType type;

  const _DowngradeModel({
    required this.rank,
    required this.url,
    required this.type,
  });
}

/// 域名管理服务
///
/// 对齐 XMSport `XMDomainProvider` / dqiu `XXDomainManager`：
/// 本地/缓存 → ping → 降级拉源 Service → Huawei OBS → unpkg → 多 npm 镜像；
/// 请求侧权重轮询 + CDN Type A/B 加签（受 openFlag 控制）。
class DomainManager {
  static final DomainManager _instance = DomainManager._internal();
  factory DomainManager() => _instance;
  DomainManager._internal();

  SharedPreferences? _prefs;
  Dio? _probeDio;
  bool _isInitialized = false;

  List<DomainEntity> _domainList = [];
  int _domainIdx = 0;
  bool _isMoreRequesting = false;

  // ============================================================
  // SharedPreferences Keys
  // ============================================================
  static String get _workingDomainKey =>
      '${S.workingDomainKey}_${EnvConfig.current.name}';
  static String get _cachedDomainsKey =>
      '${S.cachedDomainsKey}_${EnvConfig.current.name}';
  static String get _cacheTimestampKey =>
      '${S.cacheTimestampKey}_${EnvConfig.current.name}';
  static String get _debugForceFailDefaultKey => S.debugForceFailDefaultKey;
  static String get _debugForceFailAllKey => S.debugForceFailAllKey;

  static const int _cacheTtlHours = 24;
  static const Duration _probeTimeout = Duration(seconds: 5);
  static const Duration _cdnTimeout = Duration(seconds: 10);

  static const int _zwBit0 = 0x200B;
  static const int _zwBit1 = 0x200C;

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

  final List<String> _fallbackLog = [];
  List<String> get fallbackLog => List.unmodifiable(_fallbackLog);
  void clearLog() => _fallbackLog.clear();

  String? get cachedWorkingDomain {
    final raw = _prefs?.getString(_workingDomainKey);
    if (raw == null || raw.isEmpty) return null;
    return DomainEntity.decodeMappedUrl(raw);
  }
  String get defaultDomain => EnvConfig.apiBaseUrl;
  String get currentWorkingDomain =>
      currentDomain()?.domain ?? cachedWorkingDomain ?? defaultDomain;

  List<DomainEntity> get domains => List.unmodifiable(_domainList);

  // ============================================================
  // 初始化 / 环境切换
  // ============================================================

  Future<void> _migrateStaleWorkingDomainIfNeeded() async {
    final legacyGlobalKey = S.workingDomainKey;
    if (_prefs?.getString(legacyGlobalKey) != null) {
      await _prefs?.remove(legacyGlobalKey);
      _log('removed legacy global working domain key');
    }

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
      _log('cleared stale working domain');
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
      _debugForceFailDefault =
          _prefs?.getBool(_debugForceFailDefaultKey) ?? false;
      _debugForceFailAll = _prefs?.getBool(_debugForceFailAllKey) ?? false;
    }

    _isInitialized = true;

    // 先装载本地/缓存种子，后台再 ping + 降级拉源（不阻塞启动）
    // 验证 OBS 时跳过本地缓存与硬编码，直接走运行时 OBS 拉源
    List<DomainEntity> list;
    if (!AppConfig.useHardcodedDomainFallback) {
      list = EnvConfig.apiDomainEntities; // 仅编译期 OBS 快照；空则靠 runtime pull
      _log('hardcoded fallback OFF: seed=${list.length} (OBS snapshot only)');
    } else {
      list = _loadCachedDomainEntities();
      if (list.isEmpty) {
        list = EnvConfig.apiDomainEntities;
      }
    }
    _domainList = list;
    unawaited(_checkDomainList(List<DomainEntity>.from(list)));

    _log('initialized, domains=${_domainList.length}, '
        'cached=${cachedWorkingDomain ?? "none"}');
  }

  /// 环境切换后重置并重新拉源（等待完成，便于随后刷新 AB）
  Future<void> onEnvironmentChanged() async {
    _domainIdx = 0;
    _isMoreRequesting = false;
    _domainList = [];
    await requestDomain();
  }

  // ============================================================
  // 域名池：选域 / 移除 / 缓存
  // ============================================================

  DomainEntity? currentDomain() {
    if (_domainList.isEmpty) return null;
    if (_domainIdx >= _domainList.length) _domainIdx = 0;

    final domain = _domainList[_domainIdx];
    if (domain.weightCnt < domain.weight) {
      domain.weightCnt++;
    }
    if (domain.weight == 0 || domain.weightCnt == domain.weight) {
      _domainIdx++;
    }
    return domain;
  }

  DomainEntity? getDomain(String domainOrHost) {
    if (domainOrHost.isEmpty) return null;
    for (final model in _domainList) {
      if (model.domain == domainOrHost || model.host == domainOrHost) {
        return model;
      }
    }
    return null;
  }

  void removeDomain(String domain) {
    if (domain.isEmpty) return;
    final next = _domainList.where((m) => m.domain != domain).toList();
    _domainList = next;
    _cacheDomainArr(_domainList);
    if (_domainList.isEmpty) {
      forceRequestMoreDomains();
    }
  }

  Future<void> requestDomain() async {
    List<DomainEntity> list;
    if (!AppConfig.useHardcodedDomainFallback) {
      // 验证 OBS：不用本地域名缓存，避免旧硬编码污染
      list = EnvConfig.apiDomainEntities;
    } else {
      list = _loadCachedDomainEntities();
      if (list.isEmpty) {
        list = EnvConfig.apiDomainEntities;
      }
    }
    _domainList = list;
    await _checkDomainList(list);
  }

  Future<void> _checkDomainList(List<DomainEntity> domainList) async {
    if (domainList.isEmpty) {
      await requestMoreDomains();
      return;
    }

    final alive = <DomainEntity>[];
    final futures = <Future>[];
    for (final model in domainList) {
      futures.add(_ping(model).then((ok) {
        if (ok) alive.add(model);
      }));
    }
    await Future.wait(futures);

    _domainList = alive.isNotEmpty ? alive : domainList;
    if (alive.isNotEmpty) {
      _cacheDomainArr(_domainList);
      _log('ping alive=${alive.length}/${domainList.length}');
    } else {
      _log('ping all failed, keep seeds and pull more');
    }

    await requestMoreDomains();
  }

  Future<bool> _ping(DomainEntity model) async {
    try {
      var url = '${model.domain}/ping';
      url = CdnSignUtils.maybeSignUrl(
        url,
        domainType: model.domainType,
        openFlag: model.openFlag,
        token: model.token,
        signType: model.signType,
      );
      final response = await _probeDio!.get(url);
      return response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300;
    } catch (_) {
      return false;
    }
  }

  // ============================================================
  // 降级拉源链（对齐 XMSport / dqiu）
  // ============================================================

  String _envSuffix() => EnvConfig.domainPullEnvSuffix;

  String _huaweiObsUrl() {
    final env = _envSuffix();
    final tpl = env == 'prod' ? S.obsProdUrlTpl : S.obsBtdUrlTpl;
    return tpl.replaceAll('#', env);
  }

  List<_DowngradeModel> _buildDowngradeModels() {
    final env = _envSuffix();
    return [
      _DowngradeModel(
        rank: 0,
        url: S.domainPullPath,
        type: _DowngradeType.service,
      ),
      _DowngradeModel(
        rank: 100,
        url: _huaweiObsUrl(),
        type: _DowngradeType.obs,
      ),
      _DowngradeModel(
        rank: 200,
        url: S.unpkgUrlTpl.replaceAll('#', env),
        type: _DowngradeType.obs,
      ),
      _DowngradeModel(
        rank: 1000,
        url: S.cnpmUrlTpl.replaceAll('#', env),
        type: _DowngradeType.npm,
      ),
      _DowngradeModel(
        rank: 2000,
        url: S.npmUrlTpl.replaceAll('#', env),
        type: _DowngradeType.npm,
      ),
      _DowngradeModel(
        rank: 3000,
        url: S.tencentNpmUrlTpl.replaceAll('#', env),
        type: _DowngradeType.npm,
      ),
      _DowngradeModel(
        rank: 4000,
        url: S.yarnNpmUrlTpl.replaceAll('#', env),
        type: _DowngradeType.npm,
      ),
    ];
  }

  Future<void> requestMoreDomains() async {
    if (_isMoreRequesting) return;
    _isMoreRequesting = true;
    await _requestMoreDomainsWithIndex(0);
  }

  Future<void> forceRequestMoreDomains() async {
    if (_isMoreRequesting) return;
    _isMoreRequesting = true;
    await _requestMoreDomainsWithIndex(0);
  }

  Future<void> _requestMoreDomainsWithIndex(int index) async {
    final models = _buildDowngradeModels();
    if (index >= models.length) {
      _isMoreRequesting = false;
      // 可选：旧文章隐写兜底
      if (AppConfig.useConfigDomainFallback && _domainList.isEmpty) {
        await _loadArticleFallbackDomains();
      }
      _log('downgrade chain finished, domains=${_domainList.length}');
      return;
    }

    final model = models[index];
    _log('downgrade[$index] ${model.type.name} ${model.url}');
    var ok = false;
    switch (model.type) {
      case _DowngradeType.service:
        ok = await _pullFromService(model.url);
        break;
      case _DowngradeType.obs:
        ok = await _pullFromObs(model.url);
        break;
      case _DowngradeType.npm:
        ok = await _pullFromNpm(model.url);
        break;
    }

    if (ok) {
      _isMoreRequesting = false;
      return;
    }
    await _requestMoreDomainsWithIndex(index + 1);
  }

  Future<bool> _pullFromService(String apiPath) async {
    if (_domainList.isEmpty) return false;
    final base = _domainList.first;
    try {
      var url = '${base.domain}$apiPath';
      url = CdnSignUtils.maybeSignUrl(
        url,
        domainType: base.domainType,
        openFlag: base.openFlag,
        token: base.token,
        signType: base.signType,
      );
      final response = await _probeDio!.get(url);
      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data['data'];
        if (data is List && data.isNotEmpty) {
          final entities = data
              .whereType<Map>()
              .map((e) => DomainEntity.fromJson(Map<String, dynamic>.from(e)))
              .where((e) => e.domain.startsWith('http'))
              .toList();
          if (entities.isNotEmpty) {
            addDomains(entities);
            _log('service pull ok: ${entities.length}');
            return true;
          }
        }
      }
    } catch (e) {
      _log('service pull fail: ${e.runtimeType}');
    }
    return false;
  }

  Future<bool> _pullFromObs(String urlStr) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: _cdnTimeout,
        receiveTimeout: _cdnTimeout,
        responseType: ResponseType.plain,
      ));
      final response = await dio.get<String>(urlStr);
      final body = response.data;
      if (body == null || body.isEmpty) return false;
      final entities = _parseBase64DomainResponse(body);
      if (entities.isNotEmpty) {
        addDomains(entities);
        _log('obs/unpkg pull ok: ${entities.length}');
        return true;
      }
    } catch (e) {
      _log('obs pull fail: ${e.runtimeType}');
    }
    return false;
  }

  Future<bool> _pullFromNpm(String urlStr) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: _cdnTimeout,
        receiveTimeout: _cdnTimeout,
      ));
      final meta = await dio.get(urlStr);
      final data = meta.data;
      if (data is! Map) return false;
      final distTags = data['dist-tags'];
      if (distTags is! Map) return false;
      final latest = distTags['latest']?.toString() ?? '';
      final versions = data['versions'];
      if (latest.isEmpty || versions is! Map) return false;
      final versionDict = versions[latest];
      if (versionDict is! Map) return false;
      final dist = versionDict['dist'];
      final tarball = dist is Map ? dist['tarball']?.toString() ?? '' : '';
      if (tarball.isEmpty) return false;

      final tarResp = await dio.get<List<int>>(
        tarball,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = tarResp.data;
      if (bytes == null || bytes.isEmpty) return false;

      final indexContent = _extractNpmIndexJs(bytes);
      if (indexContent == null) return false;
      final entities = _parseBase64DomainResponse(indexContent);
      if (entities.isNotEmpty) {
        addDomains(entities);
        _log('npm pull ok: ${entities.length}');
        return true;
      }
    } catch (e) {
      _log('npm pull fail: ${e.runtimeType}');
    }
    return false;
  }

  String? _extractNpmIndexJs(List<int> data) {
    try {
      List<int> tarBytes;
      try {
        tarBytes = GZipDecoder().decodeBytes(data);
      } catch (_) {
        tarBytes = data;
      }
      final archive = TarDecoder().decodeBytes(tarBytes);
      for (final file in archive) {
        if (!file.isFile) continue;
        final name = file.name.replaceAll('\\', '/');
        if (name == 'index.js' || name.endsWith('/index.js')) {
          return utf8.decode(file.content as List<int>);
        }
      }
      try {
        final zip = ZipDecoder().decodeBytes(data);
        for (final file in zip) {
          if (!file.isFile) continue;
          final name = file.name.replaceAll('\\', '/');
          if (name == 'index.js' || name.endsWith('/index.js')) {
            return utf8.decode(file.content as List<int>);
          }
        }
      } catch (_) {}
    } catch (_) {}
    return null;
  }

  List<DomainEntity> _parseBase64DomainResponse(String responseString) {
    try {
      final trimmed = responseString.trim();
      String jsonStr;
      try {
        jsonStr = utf8.decode(base64.decode(trimmed));
      } catch (_) {
        // unpkg 可能包一层 JS；尝试抽取最长 base64
        final extracted = _extractEmbeddedB64(trimmed);
        if (extracted != null) {
          jsonStr = utf8.decode(base64.decode(extracted));
        } else {
          jsonStr = trimmed;
        }
      }
      return EnvConfig.parseDomainJson(jsonStr);
    } catch (_) {
      return const [];
    }
  }

  String? _extractEmbeddedB64(String raw) {
    final re = RegExp(r'[A-Za-z0-9+/]{80,}={0,2}');
    String? best;
    for (final m in re.allMatches(raw)) {
      final s = m.group(0)!;
      if (best == null || s.length > best.length) best = s;
    }
    return best;
  }

  void addDomains(List<DomainEntity> domains) {
    if (domains.isEmpty) return;
    _domainList = _mergeDomains(domains);
    _cacheDomainArr(_domainList);
  }

  List<DomainEntity> _mergeDomains(List<DomainEntity> incoming) {
    if (_domainList.isEmpty) return List.from(incoming);
    if (incoming.isEmpty) return _domainList;
    final result = List<DomainEntity>.from(incoming);
    final seen = result.map((e) => e.domain).toSet();
    for (final local in _domainList) {
      if (!seen.contains(local.domain)) {
        result.add(local);
      }
    }
    return result;
  }

  // ============================================================
  // AB 配置拉取（对外主入口，供 ConfigService）
  // ============================================================

  Future<Map<String, dynamic>?> fetchConfigWithFallback({
    required String configPath,
    required Map<String, dynamic> queryParameters,
  }) async {
    _fallbackLog.clear();
    final tried = <String>{};

    if (!_isInitialized) {
      await initialize();
    }

    // 确保至少跑过一轮种子；拉源异步进行中也可先用现有池
    if (_domainList.isEmpty) {
      await requestDomain();
    }

    // Step 1: 缓存工作域名
    final cached = cachedWorkingDomain;
    if (cached != null && !_shouldForceFailDefault) {
      _log('Step 1: trying cached domain: $cached');
      final entity = getDomain(cached) ?? DomainEntity.urlOnly(cached);
      final result =
          await _tryFetchConfig(entity, configPath, queryParameters);
      tried.add(cached);
      if (result != null) {
        _log('Step 1: success');
        return result;
      }
    }

    // Step 2: 轮询当前域名池（优先权重序）
    if (!_shouldForceFailDefault && !_shouldForceFailAll) {
      final pool = List<DomainEntity>.from(
        _domainList.isNotEmpty ? _domainList : EnvConfig.apiDomainEntities,
      );
      pool.sort((a, b) => b.weight.compareTo(a.weight));
      _log('Step 2: polling ${pool.length} domains');
      for (final entity in pool) {
        if (tried.contains(entity.domain)) continue;
        _log('Step 2: trying ${entity.domain}');
        final result =
            await _tryFetchConfig(entity, configPath, queryParameters);
        tried.add(entity.domain);
        if (result != null) {
          await _saveWorkingDomain(entity.domain);
          _log('Step 2: success ${entity.domain}');
          return result;
        }
      }
    }

    // Step 3: 强制走降级拉源后再试一轮
    _log('Step 3: force downgrade pull...');
    await forceRequestMoreDomains();
    if (_shouldForceFailAll) {
      _log('Step 3: debug force fail all');
      return null;
    }

    for (final entity in List<DomainEntity>.from(_domainList)) {
      if (tried.contains(entity.domain)) continue;
      _log('Step 3: trying ${entity.domain}');
      final result =
          await _tryFetchConfig(entity, configPath, queryParameters);
      tried.add(entity.domain);
      if (result != null) {
        await _saveWorkingDomain(entity.domain);
        _log('Step 3: success ${entity.domain}');
        return result;
      }
    }

    _log('all domains failed');
    return null;
  }

  Future<Map<String, dynamic>?> _tryFetchConfig(
    DomainEntity entity,
    String configPath,
    Map<String, dynamic> queryParameters,
  ) async {
    try {
      var url = '${entity.domain}$configPath';
      url = CdnSignUtils.maybeSignUrl(
        url,
        domainType: entity.domainType,
        openFlag: entity.openFlag,
        token: entity.token,
        signType: entity.signType,
      );

      final headers = <String, dynamic>{};
      try {
        final deviceInfo = DeviceInfoManager();
        await deviceInfo.initialize();
        headers.addAll(deviceInfo.getRequestHeaders());
        headers['User-Agent'] = deviceInfo.userAgent;
        headers.addAll(deviceInfo.getAbQueryHeaders());
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
        final code = response.data!['code'];
        // 业务层异常码：对齐 dqiu 踢域名区间
        if (code is int && code > 380 && code < 520) {
          _log('  → ${entity.domain} biz code $code, drop');
          return null;
        }
        _log('  → ${entity.domain} OK (${stopwatch.elapsedMilliseconds}ms)');
        return response.data;
      }
      _log('  → ${entity.domain} status=${response.statusCode}');
    } catch (e) {
      _log('  → ${entity.domain} error: ${e.runtimeType}');
    }
    return null;
  }

  // ============================================================
  // 可选：文章隐写兜底（旧逻辑，受 useConfigDomainFallback 控制）
  // ============================================================

  Future<void> _loadArticleFallbackDomains() async {
    final cdnDomains = await _downloadFromCdn();
    if (cdnDomains != null && cdnDomains.isNotEmpty) {
      addDomains(cdnDomains.map(DomainEntity.urlOnly).toList());
      return;
    }
    final hardcoded =
        S.fallbackDomains.map(DomainEntity.urlOnly).toList();
    if (hardcoded.isNotEmpty) {
      addDomains(hardcoded);
    }
  }

  Future<List<String>?> _downloadFromCdn() async {
    final cdnDio = Dio(BaseOptions(
      connectTimeout: _cdnTimeout,
      receiveTimeout: _cdnTimeout,
    ));

    for (var i = 0; i < S.cdnArticleUrlBytes.length; i++) {
      final url = utf8.decode(S.cdnArticleUrlBytes[i]);
      try {
        _log('  CDN article[$i]: $url');
        final response = await cdnDio.get<String>(url);
        if (response.statusCode == 200 && response.data != null) {
          final domains = _extractDomainsFromArticle(response.data!);
          if (domains != null && domains.isNotEmpty) return domains;
        }
      } catch (e) {
        _log('  CDN article[$i] fail: ${e.runtimeType}');
      }
    }
    return null;
  }

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
      return domains.isNotEmpty ? domains : null;
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // 持久化
  // ============================================================

  List<DomainEntity> _loadCachedDomainEntities() {
    final json = _prefs?.getString(_cachedDomainsKey);
    final timestamp = _prefs?.getInt(_cacheTimestampKey);
    if (json == null || timestamp == null) return [];

    final age = DateTime.now().millisecondsSinceEpoch - timestamp;
    final ttlMs = _cacheTtlHours * 60 * 60 * 1000;
    if (age > ttlMs) return [];

    try {
      final list = jsonDecode(json) as List<dynamic>;
      // 兼容旧版纯 URL / base64 字符串缓存
      if (list.isNotEmpty && list.first is String) {
        return list
            .cast<String>()
            .map(DomainEntity.urlOnly)
            .where((e) => e.domain.startsWith('http'))
            .toList();
      }
      return list
          .whereType<Map>()
          .map((e) => DomainEntity.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.domain.startsWith('http'))
          .toList();
    } catch (_) {
      return [];
    }
  }

  void _cacheDomainArr(List<DomainEntity> modelArr) {
    // toJson 内 domain 已 base64 映射，与硬编码同级处理
    final mapList = modelArr.map((e) => e.toJson()).toList();
    _prefs?.setString(_cachedDomainsKey, jsonEncode(mapList));
    _prefs?.setInt(
        _cacheTimestampKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> _saveWorkingDomain(String domain) async {
    final mapped = DomainEntity.encodeMappedUrl(domain);
    await _prefs?.setString(_workingDomainKey, mapped);
    _log('  saved working domain: ${DomainEntity.decodeMappedUrl(mapped)}');
  }

  Future<void> clearCachedDomain() async {
    await _prefs?.remove(_workingDomainKey);
    _log('cleared cached working domain');
  }

  Future<void> clearDomainListCache() async {
    await _prefs?.remove(_cachedDomainsKey);
    await _prefs?.remove(_cacheTimestampKey);
    _log('cleared domain list cache');
  }

  Future<void> debugResetAll() async {
    if (!kDebugMode) return;
    await clearCachedDomain();
    await clearDomainListCache();
    _debugForceFailDefault = false;
    _debugForceFailAll = false;
    await _prefs?.remove(_debugForceFailDefaultKey);
    await _prefs?.remove(_debugForceFailAllKey);
    _fallbackLog.clear();
    _domainList = [];
    await requestDomain();
    _log('all state reset');
  }

  bool get _shouldForceFailDefault => kDebugMode && _debugForceFailDefault;
  bool get _shouldForceFailAll => kDebugMode && _debugForceFailAll;

  String get cacheStatusDescription {
    final timestamp = _prefs?.getInt(_cacheTimestampKey);
    if (timestamp == null) {
      return '无缓存 / 域名池 ${_domainList.length}';
    }
    final age = DateTime.now().millisecondsSinceEpoch - timestamp;
    final ttlMs = _cacheTtlHours * 60 * 60 * 1000;
    if (age > ttlMs) return '已过期 / 域名池 ${_domainList.length}';
    final remainHours = ((ttlMs - age) / (60 * 60 * 1000)).toStringAsFixed(1);
    return '有效 (${remainHours}h) / 池 ${_domainList.length}';
  }

  void _log(String message) {
    if (kDebugMode) {
      final time = DateTime.now().toString().substring(11, 19);
      // ignore: avoid_print
      print('DomainManager: $message');
      _fallbackLog.add('[$time] $message');
    }
  }
}
