import 'dart:io';
import 'dart:math';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:path/path.dart' as path;

import '../config.dart';
import '../utils/logger.dart';
import '../utils/name_generator.dart';

/// 文件膨胀混淆器（4.3(a) 差异化）
///
/// 在 B 面注入项目专属的冗余代码，使不同项目的二进制结构差异化，
/// 降低多包相似度，缓解 4.3(a) 拒审。
///
/// seed 策略：优先 sha1(bundleId+version) 稳定 seed（同版本同包一致，利于 Crashlytics 符号映射），
/// 否则 projectName + timestamp 实现包间差异化。
class BloatInflator {
  BloatInflator(this.config, this.logger);

  final ObfuscatorConfig config;
  final Logger logger;

  static const _internalDir = '_internal';
  static const _reviewIntensiveProjects = {'dq'};

  bool get _usesReviewIntensiveBloat =>
      _reviewIntensiveProjects.contains(config.projectName);

  // 结构维度：review-intensive 项目下由 seed 派生区间随机，让不同包（不同 bundleId/version）
  // 的膨胀骨架规模不同，降低 4.3(a) 结构相似度；非 review 项目保持固定小规模。
  // 由 _deriveDimensions(seed) 在 process() 内、seed 确定后初始化。
  late final int _fileCount;
  late final int _classesPerFile;
  late final int _methodsPerClass;
  late final int _runtimeTouchCount;

  // 方法体模板的 seed 派生排列：同一个 variant 值在不同包里映射到不同模板，
  // 使两包的模板分布/顺序不同（而非都覆盖同样 12 种同样顺序）。
  late final List<int> _templatePermutation;

  // Runner 骨架的 seed 派生变体索引，避免 PreloadRunner 逐字节一致。
  late final int _mainVariant;

  bool get _retainAllMethods => _usesReviewIntensiveBloat;
  bool get _enableCrossRefs => !_usesReviewIntensiveBloat;

  /// 从稳定 seed 派生结构维度与模板排列（同包同版本可复现）。
  void _deriveDimensions(String seed) {
    // 模板排列与主骨架变体：所有项目都随 seed 变化。
    final permRng = Random('${seed}_tpl'.hashCode);
    _templatePermutation = List<int>.generate(12, (i) => i)..shuffle(permRng);
    _mainVariant = Random('${seed}_main'.hashCode).nextInt(3);

    if (!_usesReviewIntensiveBloat) {
      _fileCount = 50;
      _classesPerFile = 25;
      _methodsPerClass = 10;
      _runtimeTouchCount = _fileCount;
      return;
    }

    final dimRng = Random('${seed}_dims'.hashCode);
    _fileCount = 420 + dimRng.nextInt(221); // 420..640
    _classesPerFile = 18 + dimRng.nextInt(15); // 18..32
    _methodsPerClass = 7 + dimRng.nextInt(8); // 7..14
    _runtimeTouchCount = 40 + dimRng.nextInt(41); // 40..80
  }

  /// 获取膨胀入口文件（优先 module_entry，排除 _internal 子目录）
  String _getBloatEntryFile(List<String> files) {
    final inInternalDir =
        (String f) => path.split(f).any((s) => s == _internalDir);
    final candidates = files
        .where(
            (f) => path.basename(f) == 'module_entry.dart' && !inInternalDir(f))
        .toList();
    if (candidates.isNotEmpty) return candidates.first;
    final rootFiles = files.where((f) => !inInternalDir(f)).toList();
    return rootFiles.isNotEmpty ? rootFiles.first : '';
  }

  Future<void> process(
    List<String> files,
    AnalysisContextCollection collection,
  ) async {
    logger.step('文件膨胀 (4.3a 差异化)...');

    if (config.targetDir.isEmpty) {
      logger.warning('目标目录为空，跳过文件膨胀');
      return;
    }

    final targetDir = Directory(config.targetDir);
    if (!targetDir.existsSync()) {
      logger.warning('目标目录不存在: ${config.targetDir}');
      return;
    }

    final project = config.projectName ?? 'default';
    final seed = config.seedBase != null
        ? '${project}_${config.seedBase}'
        : '${project}_${DateTime.now().millisecondsSinceEpoch}';

    _deriveDimensions(seed);

    if (config.dryRun) {
      logger.info(
          '[DRY-RUN] 将生成膨胀代码 (seed: $seed, 规模: $_fileCount×$_classesPerFile×$_methodsPerClass)');
      return;
    }

    // 1. 创建 _internal 目录（移除旧的 _bloat 以统一命名）
    final internalDir = Directory(path.join(config.targetDir, _internalDir));
    final oldBloatDir = Directory(path.join(config.targetDir, '_bloat'));
    if (oldBloatDir.existsSync()) {
      oldBloatDir.deleteSync(recursive: true);
      logger.info('已移除旧目录 _bloat');
    }
    if (internalDir.existsSync()) {
      internalDir.deleteSync(recursive: true);
      logger.info('已清理旧 _internal 目录');
    }
    internalDir.createSync(recursive: true);

    logger.info(
      '膨胀规模: $_fileCount 文件 × $_classesPerFile 类 × $_methodsPerClass 方法'
      '${_usesReviewIntensiveBloat ? " (审核强化，运行时轻量触达)" : ""}',
    );

    // 2. 生成膨胀代码
    final generatedPaths = _generateBloatFiles(internalDir.path, seed);
    for (final f in generatedPaths) {
      logger.info('生成: ${path.basename(f)}');
    }

    // 3. 注入入口调用（从项目文件列表找 module_entry，非生成的文件列表）
    final entryFile = _getBloatEntryFile(files);
    if (entryFile.isEmpty) {
      logger.warning('未找到入口文件，膨胀代码可能被 tree-shaking 移除');
      logger.info('建议在 module_entry.dart 中手动调用 PreloadRunner.run()');
      return;
    }

    var entryContent = File(entryFile).readAsStringSync();
    if (entryContent.contains('preload.dart') ||
        entryContent.contains('_internal/preload')) {
      logger.debug('入口文件已包含 preload 引用，跳过注入');
      return;
    }
    // 迁移旧命名到中性命名
    if (entryContent.contains('BloatEntry') ||
        entryContent.contains('bloat_generated')) {
      entryContent = entryContent
          .replaceAll("import '_bloat/bloat_generated.dart';",
              "import '$_internalDir/preload.dart';")
          .replaceAll('BloatEntry.run()', 'PreloadRunner.run()')
          .replaceAll('_bloatInit', '_preloadInit');
      File(entryFile).writeAsStringSync(entryContent);
      logger.info('已迁移旧引用');
      logger.success('文件膨胀完成');
      return;
    }

    var newContent = _injectBloatImport(entryContent);
    if (newContent == null) return;

    final withCall = _injectBloatCall(newContent);
    if (withCall != null) {
      newContent = withCall;
      logger.info('已注入 preload 调用到 getHomePage(): ${path.basename(entryFile)}');
    } else {
      newContent = _injectBloatTopLevel(newContent);
      logger.info('已注入 preload 顶层初始化: ${path.basename(entryFile)}');
    }

    File(entryFile).writeAsStringSync(newContent);

    logger.success('文件膨胀完成');
  }

  /// 语义化文件名池 — 模拟真实业务模块命名
  static const _semanticFileNames = [
    // 数据 & 缓存
    'local_cache_manager', 'memory_cache_provider', 'disk_cache_strategy',
    'data_sync_controller', 'offline_storage_helper', 'incremental_sync_task',
    'data_migration_runner', 'schema_version_checker',
    // 网络 & 请求
    'request_retry_handler', 'response_interceptor_chain', 'api_throttle_guard',
    'network_quality_monitor', 'dns_prefetch_service',
    'certificate_pin_validator',
    'connection_pool_manager', 'upload_chunk_scheduler',
    // 状态 & 生命周期
    'app_lifecycle_observer', 'session_state_machine', 'auth_token_refresher',
    'foreground_task_queue', 'background_sync_worker', 'idle_cleanup_scheduler',
    'state_snapshot_builder', 'undo_history_manager',
    // 配置 & 功能开关
    'feature_flag_evaluator', 'remote_config_fetcher', 'ab_test_resolver',
    'locale_preference_store', 'theme_variant_builder', 'accessibility_adapter',
    'dynamic_param_loader', 'config_merge_strategy',
    // 日志 & 监控
    'event_tracker_pipeline', 'crash_breadcrumb_logger', 'performance_sampler',
    'user_action_recorder', 'metric_aggregation_sink', 'log_rotation_policy',
    'error_dedup_filter', 'trace_context_propagator',
    // 安全 & 校验
    'input_sanitizer_chain', 'content_hash_verifier', 'signature_compute_util',
    'encryption_key_rotation', 'integrity_check_runner', 'rate_limit_bucket',
    // 媒体 & 资源
    'image_resize_processor', 'thumbnail_cache_policy', 'asset_preload_queue',
    'video_buffer_strategy', 'audio_fade_controller', 'resource_bundle_loader',
    // 通用
    'pagination_cursor_helper', 'deep_link_route_parser',
    'notification_channel_hub',
    'search_index_builder', 'text_measure_util', 'date_range_calculator',
    'color_palette_generator', 'animation_curve_factory',
    'layout_constraint_solver', 'gesture_conflict_resolver',
    'dependency_graph_walker', 'task_priority_comparator',
    'batch_operation_executor', 'diff_patch_applier',
  ];

  static const _semanticDomains = [
    'account',
    'activity',
    'analytics',
    'archive',
    'asset',
    'auth',
    'backup',
    'billing',
    'bookmark',
    'channel',
    'client',
    'collection',
    'comment',
    'content',
    'credential',
    'delivery',
    'device',
    'dialog',
    'download',
    'event',
    'experiment',
    'feed',
    'filter',
    'gateway',
    'gesture',
    'history',
    'identity',
    'index',
    'insight',
    'library',
    'license',
    'message',
    'metadata',
    'module',
    'notification',
    'payment',
    'pipeline',
    'policy',
    'preference',
    'profile',
    'query',
    'quota',
    'ranking',
    'recommendation',
    'report',
    'request',
    'response',
    'review',
    'schedule',
    'search',
    'security',
    'session',
    'signal',
    'stream',
    'subscription',
    'sync',
    'task',
    'timeline',
    'token',
    'upload',
    'variant',
    'viewport',
    'workflow',
  ];

  static const _semanticActions = [
    'adapter',
    'allocator',
    'analyzer',
    'applier',
    'assembler',
    'binder',
    'builder',
    'calculator',
    'checker',
    'collector',
    'composer',
    'coordinator',
    'decoder',
    'dispatcher',
    'encoder',
    'evaluator',
    'executor',
    'factory',
    'fetcher',
    'formatter',
    'generator',
    'guard',
    'handler',
    'indexer',
    'loader',
    'mapper',
    'matcher',
    'merger',
    'monitor',
    'normalizer',
    'observer',
    'optimizer',
    'parser',
    'planner',
    'processor',
    'provider',
    'reader',
    'recorder',
    'reducer',
    'renderer',
    'resolver',
    'router',
    'runner',
    'sampler',
    'scheduler',
    'serializer',
    'snapshotter',
    'sorter',
    'store',
    'tracker',
    'transformer',
    'validator',
    'writer',
  ];

  static const _semanticObjects = [
    'batch',
    'bridge',
    'bucket',
    'buffer',
    'cache',
    'catalog',
    'chain',
    'channel',
    'cluster',
    'config',
    'context',
    'cursor',
    'dataset',
    'descriptor',
    'entry',
    'graph',
    'group',
    'handle',
    'hub',
    'item',
    'layer',
    'ledger',
    'list',
    'map',
    'matrix',
    'node',
    'packet',
    'page',
    'payload',
    'queue',
    'record',
    'registry',
    'scope',
    'segment',
    'snapshot',
    'state',
    'table',
    'tree',
    'unit',
    'window',
  ];

  /// 生成随机化的文件名列表（从语义名称池中不重复选取）
  List<String> _generateFileNames(int count, String seed) {
    final rng = Random(seed.hashCode);
    final names = <String>{..._semanticFileNames};
    for (final domain in _semanticDomains) {
      for (final action in _semanticActions) {
        names.add('${domain}_$action');
        if (names.length >= count * 2) break;
      }
      if (names.length >= count * 2) break;
    }
    for (final domain in _semanticDomains) {
      for (final action in _semanticActions) {
        for (final object in _semanticObjects) {
          names.add('${domain}_${action}_$object');
          if (names.length >= count * 2) break;
        }
        if (names.length >= count * 2) break;
      }
      if (names.length >= count * 2) break;
    }
    var salt = 0;
    while (names.length < count) {
      names.add(
          'module_${NameGenerator.generateRouteHash('$seed$salt').substring(1)}');
      salt++;
    }
    final pool = names.toList()..shuffle(rng);
    return pool.take(count).toList();
  }

  /// 生成多个膨胀文件，返回所有文件路径
  List<String> _generateBloatFiles(String internalDirPath, String seed) {
    final classesPerFile = _classesPerFile;
    final methodsPerClass = _methodsPerClass;
    final fileCount = _fileCount;
    final fileNames = _generateFileNames(fileCount, seed);
    final generatedPaths = <String>[];

    for (var f = 0; f < fileCount; f++) {
      final fileName = '${fileNames[f]}.dart';
      final filePath = path.join(internalDirPath, fileName);
      final content = _generateBloatPart(
        seed: seed,
        fileIndex: f,
        classCount: classesPerFile,
        methodsPerClass: methodsPerClass,
        fileCount: fileCount,
        fileNames: fileNames,
        enableCrossRefs: _enableCrossRefs,
        retainAllMethods: _retainAllMethods,
      );
      File(filePath).writeAsStringSync(content);
      generatedPaths.add(filePath);
    }

    final mainPath = path.join(internalDirPath, 'preload.dart');
    final mainContent = _generateBloatMain(
      seed,
      fileCount,
      fileNames,
      runtimeTouchCount: _runtimeTouchCount,
    );
    File(mainPath).writeAsStringSync(mainContent);
    generatedPaths.add(mainPath);

    return generatedPaths;
  }

  /// 多样化的方法体模板（每类 ~6-12 行，看起来像真实业务逻辑）
  void _writeMethodBody(StringBuffer buf, String seed, int variant) {
    // 经 seed 派生排列映射，使同一 variant 在不同包里落到不同模板。
    final v = _templatePermutation[variant % 12];
    switch (v) {
      case 0:
        buf.writeln('    var a = x; var b = y;');
        buf.writeln('    if (a > 0) { a *= 1.001; } else { a *= 0.999; }');
        buf.writeln('    for (var i = 0; i < 3; i++) { b += i * 0.1; }');
        buf.writeln('    final r = a.abs() + b.abs();');
        buf.writeln('    return r > 1000 ? r % 1000 : r;');
        break;
      case 1:
        buf.writeln('    final list = <double>[];');
        buf.writeln(
            '    for (var i = 0; i < 5; i++) { list.add((x + i + y).toDouble()); }');
        buf.writeln('    list.sort();');
        buf.writeln('    final mid = list[list.length ~/ 2];');
        buf.writeln(
            '    return list.fold<num>(mid, (num a, double b) => a + b - mid * 0.1);');
        break;
      case 2:
        buf.writeln(
            '    final m = <String, num>{\'x\': x, \'y\': y, \'s\': x + y};');
        buf.writeln('    m[\'d\'] = (m[\'x\'] ?? 0) - (m[\'y\'] ?? 0);');
        buf.writeln('    m[\'p\'] = (m[\'x\'] ?? 1) * (m[\'y\'] ?? 1);');
        buf.writeln('    return m.values.fold<num>(0, (a, b) => a + b);');
        break;
      case 3:
        buf.writeln('    var acc = 0.0;');
        buf.writeln('    for (var i = 1; i <= 8; i++) {');
        buf.writeln('      acc += (x * i + y) / (i + 1);');
        buf.writeln('      if (acc > 9999) acc = acc % 1000;');
        buf.writeln('    }');
        buf.writeln('    return acc;');
        break;
      case 4:
        buf.writeln('    final buf = StringBuffer();');
        buf.writeln(
            '    for (var i = 0; i < x.toInt().abs().clamp(1, 10); i++) {');
        buf.writeln('      buf.write(i.toRadixString(16));');
        buf.writeln('    }');
        buf.writeln('    return buf.length + y.toDouble();');
        break;
      case 5:
        buf.writeln('    final matrix = <List<num>>[];');
        buf.writeln('    for (var r = 0; r < 3; r++) {');
        buf.writeln('      matrix.add([x + r, y - r, (x * y + r) % 100]);');
        buf.writeln('    }');
        buf.writeln('    var trace = 0.0;');
        buf.writeln(
            '    for (var i = 0; i < 3; i++) { trace += matrix[i][i].toDouble(); }');
        buf.writeln('    return trace;');
        break;
      case 6:
        buf.writeln('    var lo = x.toDouble(), hi = y.toDouble();');
        buf.writeln('    if (lo > hi) { final t = lo; lo = hi; hi = t; }');
        buf.writeln('    for (var i = 0; i < 6; i++) {');
        buf.writeln('      final mid = (lo + hi) / 2;');
        buf.writeln(
            '      if (mid * mid > x.abs() + y.abs()) { hi = mid; } else { lo = mid; }');
        buf.writeln('    }');
        buf.writeln('    return (lo + hi) / 2;');
        break;
      case 7:
        buf.writeln('    final set1 = <int>{};');
        buf.writeln('    final set2 = <int>{};');
        buf.writeln('    for (var i = 0; i < 7; i++) {');
        buf.writeln('      set1.add((x + i).toInt());');
        buf.writeln('      set2.add((y + i * 2).toInt());');
        buf.writeln('    }');
        buf.writeln('    final inter = set1.intersection(set2);');
        buf.writeln(
            '    return (inter.length + set1.length + set2.length).toDouble();');
        break;
      case 8:
        buf.writeln(
            '    final keys = List.generate(6, (i) => \'k\${i}_\${x.toInt()}\');');
        buf.writeln(
            '    final vals = keys.asMap().map((i, k) => MapEntry(k, y + i));');
        buf.writeln(
            '    return vals.values.reduce((a, b) => a + b).toDouble();');
        break;
      case 9:
        buf.writeln('    var fib0 = x.toDouble(), fib1 = y.toDouble();');
        buf.writeln('    for (var i = 0; i < 10; i++) {');
        buf.writeln('      final next = fib0 + fib1;');
        buf.writeln('      fib0 = fib1;');
        buf.writeln('      fib1 = next % 10000;');
        buf.writeln('    }');
        buf.writeln('    return fib1;');
        break;
      case 10:
        buf.writeln(
            '    final chars = x.toInt().abs().toRadixString(36).split(\'\');');
        buf.writeln('    chars.sort();');
        buf.writeln('    var hash = y.toDouble();');
        buf.writeln(
            '    for (final c in chars) { hash = hash * 31 + c.codeUnitAt(0); }');
        buf.writeln('    return hash % 100000;');
        break;
      case 11:
        buf.writeln('    final data = List<num>.filled(8, 0);');
        buf.writeln('    for (var i = 0; i < data.length; i++) {');
        buf.writeln(
            '      data[i] = (x + i * y) * (i % 2 == 0 ? 1.01 : 0.99);');
        buf.writeln('    }');
        buf.writeln('    data.sort();');
        buf.writeln('    return data.last - data.first;');
        break;
    }
  }

  /// 生成随机化类名后缀
  static const _classKinds = [
    'Proc',
    'Node',
    'Ctx',
    'Op',
    'Seg',
    'Block',
    'Task',
    'Job',
    'Cell',
    'Unit',
    'Slot',
    'Item',
    'Ref',
    'Link',
    'Step',
    'Elem',
  ];

  /// 生成随机化方法名前缀
  static const _methodVerbs = [
    'calc',
    'eval',
    'apply',
    'merge',
    'fold',
    'scan',
    'map',
    'reduce',
    'filter',
    'transform',
    'convert',
    'derive',
    'compose',
    'measure',
    'aggregate',
    'normalize',
    'weight',
    'blend',
  ];

  String _generateBloatPart({
    required String seed,
    required int fileIndex,
    required int classCount,
    required int methodsPerClass,
    required int fileCount,
    required List<String> fileNames,
    required bool enableCrossRefs,
    required bool retainAllMethods,
  }) {
    final buffer = StringBuffer();
    final baseSeed = '${seed}_part$fileIndex';
    final localRng = Random(baseSeed.hashCode);

    buffer.writeln('// Generated. Seed: $baseSeed');
    buffer.writeln("import 'dart:convert';");
    buffer.writeln("import 'dart:math' as math;");
    buffer.writeln('');

    // 交叉引用随机 1-3 个后续文件（仅向前引用，避免循环依赖）。
    // 审核强化模式关闭交叉运行调用，避免 10 倍文件数带来启动期递归放大。
    final laterIndices = enableCrossRefs
        ? (List.generate(
            fileCount - fileIndex - 1,
            (i) => fileIndex + 1 + i,
          )..shuffle(localRng))
        : <int>[];
    final crossRefCount = laterIndices.isEmpty
        ? 0
        : 1 + localRng.nextInt(laterIndices.length.clamp(1, 3));
    final crossRefs = laterIndices.take(crossRefCount).toList()..sort();
    for (final idx in crossRefs) {
      buffer.writeln("import '${fileNames[idx]}.dart' as ref_p$idx;");
    }
    buffer.writeln('');

    // JSON/List 工具类（每个文件不同名称）
    final utilBase = NameGenerator.generateClassName('${baseSeed}_util');
    final utilName = '${utilBase}Util';
    buffer.writeln('class $utilName {');
    buffer.writeln('  $utilName._();');
    buffer.writeln('  static List<Map<String, dynamic>> buildMap(int n) {');
    buffer.writeln('    final out = <Map<String, dynamic>>[];');
    buffer.writeln('    for (var i = 0; i < n; i++) {');
    buffer.writeln(
        "      out.add({'k': i, 'v': i * ${1.0 + localRng.nextDouble()}, 'f': i % ${2 + localRng.nextInt(5)} == 0});");
    buffer.writeln('    }');
    buffer.writeln('    return out;');
    buffer.writeln('  }');
    buffer.writeln('  static String encode(List<Map<String, dynamic>> m) {');
    buffer
        .writeln("    try { return jsonEncode(m); } catch (_) { return ''; }");
    buffer.writeln('  }');
    buffer.writeln('  static num score(int n) {');
    buffer.writeln('    final lm = buildMap(n);');
    buffer.writeln('    final s = encode(lm);');
    buffer.writeln(
        '    return s.length + lm.length * ${localRng.nextDouble() + 0.5};');
    buffer.writeln('  }');
    buffer.writeln('}');
    buffer.writeln('');

    // math 工具类
    final mathBase = NameGenerator.generateClassName('${baseSeed}_math');
    final mathName = '${mathBase}Fn';
    buffer.writeln('class $mathName {');
    buffer.writeln('  $mathName._();');
    buffer.writeln('  static double clamp(double v, double lo, double hi) =>');
    buffer.writeln('      v < lo ? lo : (v > hi ? hi : v);');
    buffer.writeln(
        '  static double lerp(double a, double b, double t) => a + (b - a) * t;');
    buffer.writeln('  static int hash(String s) {');
    buffer.writeln('    var h = 0;');
    buffer.writeln(
        '    for (var i = 0; i < s.length; i++) { h = (h * 31 + s.codeUnitAt(i)) & 0x7FFFFFFF; }');
    buffer.writeln('    return h;');
    buffer.writeln('  }');
    buffer.writeln('}');
    buffer.writeln('');

    // className -> firstMethodName (for runner references)
    final classMethods = <String, List<String>>{};

    for (var c = 0; c < classCount; c++) {
      final kind = _classKinds[localRng.nextInt(_classKinds.length)];
      final baseName = NameGenerator.generateClassName('${baseSeed}_c$c');
      final className = '$baseName$kind$c';

      final hasState = localRng.nextBool();
      buffer.writeln('class $className {');
      if (hasState) {
        buffer.writeln('  static final _memo = <String, num>{};');
        buffer.writeln('  $className._();');
      } else {
        buffer.writeln('  $className._();');
      }

      final usedMethodNames = <String>{};
      final methodNames = <String>[];
      for (var m = 0; m < methodsPerClass; m++) {
        final verb = _methodVerbs[localRng.nextInt(_methodVerbs.length)];
        final baseMethod =
            NameGenerator.generateMethodName('${baseSeed}_c${c}m$m');
        var methodName = '${verb}_${baseMethod.substring(1)}';
        // dedup within class
        if (!usedMethodNames.add(methodName)) {
          methodName = '${methodName}_$m';
          usedMethodNames.add(methodName);
        }
        methodNames.add(methodName);
        buffer.writeln('  static num $methodName(num x, num y) {');
        _writeMethodBody(buffer, '${baseSeed}_c${c}m$m', localRng.nextInt(12));
        buffer.writeln('  }');
      }
      buffer.writeln('}');
      buffer.writeln('');

      classMethods[className] = methodNames;
    }

    // 汇总 runner — 直接引用收集到的真实名称
    buffer.writeln('class Part$fileIndex {');
    buffer.writeln('  static num run() {');
    buffer.writeln('    var sum = 0.0;');
    buffer.writeln('    sum += $utilName.score(${3 + localRng.nextInt(5)});');
    buffer.writeln("    sum += $mathName.hash('$baseSeed') * 0.001;");
    for (final entry in classMethods.entries) {
      final firstMethod = entry.value.isNotEmpty ? entry.value.first : 'run';
      buffer.writeln(
          '    sum += ${entry.key}.$firstMethod(${localRng.nextDouble().toStringAsFixed(2)}, ${localRng.nextDouble().toStringAsFixed(2)});');
    }
    if (retainAllMethods) {
      buffer.writeln('    if (DateTime.now().microsecondsSinceEpoch < 0) {');
      for (final entry in classMethods.entries) {
        for (final methodName in entry.value.skip(1)) {
          buffer.writeln(
              '      sum += ${entry.key}.$methodName(${localRng.nextDouble().toStringAsFixed(2)}, ${localRng.nextDouble().toStringAsFixed(2)});');
        }
      }
      buffer.writeln('    }');
    }
    for (final idx in crossRefs) {
      buffer.writeln('    sum += ref_p$idx.Part$idx.run();');
    }
    buffer.writeln('    return sum;');
    buffer.writeln('  }');
    buffer.writeln('}');

    return buffer.toString();
  }

  String _generateBloatMain(
    String seed,
    int fileCount,
    List<String> fileNames, {
    required int runtimeTouchCount,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('// Generated. Seed: $seed');
    buffer.writeln('');

    for (var f = 0; f < fileCount; f++) {
      buffer.writeln("import '${fileNames[f]}.dart';");
    }
    buffer.writeln('');

    buffer.writeln('class PreloadRunner {');
    buffer.writeln('  static bool _run = false;');
    if (runtimeTouchCount < fileCount) {
      buffer.writeln('  static final List<num Function()> _runners = [');
      for (var f = 0; f < fileCount; f++) {
        buffer.writeln('    Part$f.run,');
      }
      buffer.writeln('  ];');
    }
    buffer.writeln('  static void run() {');
    buffer.writeln('    if (_run) return;');
    buffer.writeln('    _run = true;');
    buffer.writeln('    var preloadScore = 0.0;');
    if (runtimeTouchCount < fileCount) {
      // seed 派生的等价变体：变量名与起点表达式不同，避免 PreloadRunner 逐字节一致。
      const nameSets = [
        ['total', 'touchCount', 'step', 'index', 'touched'],
        ['count', 'picks', 'stride', 'cursor', 'done'],
        ['len', 'hits', 'gap', 'pos', 'iter'],
      ];
      const startExprs = [
        'DateTime.now().millisecondsSinceEpoch.abs()',
        'DateTime.now().microsecondsSinceEpoch.abs()',
        '(DateTime.now().millisecondsSinceEpoch.abs() ^ 0x5bd1e995)',
      ];
      final n = nameSets[_mainVariant % nameSets.length];
      final startExpr = startExprs[_mainVariant % startExprs.length];
      buffer.writeln('    final ${n[0]} = _runners.length;');
      buffer.writeln(
          '    final ${n[1]} = ${n[0]} < $runtimeTouchCount ? ${n[0]} : $runtimeTouchCount;');
      buffer.writeln('    final ${n[2]} = (${n[0]} / ${n[1]}).ceil();');
      buffer.writeln('    var ${n[3]} = $startExpr % ${n[2]};');
      buffer.writeln(
          '    for (var ${n[4]} = 0; ${n[4]} < ${n[1]} && ${n[3]} < ${n[0]}; ${n[4]}++) {');
      buffer.writeln('      preloadScore += _runners[${n[3]}]();');
      buffer.writeln('      ${n[3]} += ${n[2]};');
      buffer.writeln('    }');
    } else {
      for (var f = 0; f < fileCount; f++) {
        buffer.writeln('    preloadScore += Part$f.run();');
      }
    }
    buffer.writeln('    if (preloadScore < 0) {}');
    buffer.writeln('  }');
    buffer.writeln('}');

    return buffer.toString();
  }

  String? _injectBloatImport(String content) {
    final importLine = "import '$_internalDir/preload.dart';";
    if (content.contains('preload.dart') ||
        content.contains('_internal/preload')) return null;

    final lines = content.split('\n');
    var lastImportIdx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('import ')) {
        lastImportIdx = i;
      }
    }

    if (lastImportIdx >= 0) {
      lines.insert(lastImportIdx + 1, importLine);
      return lines.join('\n');
    }
    return importLine + '\n\n' + content;
  }

  String? _injectBloatCall(String content) {
    if (content.contains('PreloadRunner.run()')) return null;

    final patterns = [
      RegExp(r'(static\s+Widget\s+getHomePage\s*\([^)]*\)\s*\{)\s*'),
      RegExp(r'(static\s+Widget\s+getHomePage\s*\(\s*\)\s*\{)\s*'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(content);
      if (match != null) {
        final insertPos = match.end;
        return content.substring(0, insertPos) +
            'PreloadRunner.run();\n    ' +
            content.substring(insertPos);
      }
    }

    return null;
  }

  /// 后备：顶层初始化
  String _injectBloatTopLevel(String content) {
    const initLine =
        "final _preloadInit = () { PreloadRunner.run(); return 0; }();";
    if (content.contains('_preloadInit') ||
        content.contains('PreloadRunner.run()')) {
      return content;
    }
    final lines = content.split('\n');
    var lastImportIdx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('import ')) {
        lastImportIdx = i;
      }
    }
    if (lastImportIdx >= 0) {
      lines.insert(lastImportIdx + 1, '');
      lines.insert(lastImportIdx + 2, initLine);
      lines.insert(lastImportIdx + 3, '');
      return lines.join('\n');
    }
    return initLine + '\n\n' + content;
  }
}
