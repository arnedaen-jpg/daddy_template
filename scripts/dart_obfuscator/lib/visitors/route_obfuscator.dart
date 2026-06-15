import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as path;

import '../config.dart';
import '../utils/logger.dart';
import '../utils/name_generator.dart';

/// 路由/路径常量混淆器
///
/// 目标：
/// 1. 只改动路由相关文件，避免误伤 API 字符串
/// 2. 保留动态参数段（如 `:id`），避免路由模式失效
/// 3. 在混淆完成后做一次安全校验，发现异常立即失败
class RouteObfuscator {
  final ObfuscatorConfig config;
  final Logger logger;

  /// 路由映射表: 原始路径 -> 混淆路径
  final Map<String, String> routeMapping = {};

  RouteObfuscator(this.config, this.logger);

  /// 获取项目特定的路由/API路径文件模式
  List<String> _getRouteFilePatterns() {
    switch (config.projectName) {
      case 'ph':
        return ['routes/routes.dart'];
      case 'hjsq':
        return ['router/paths.dart'];
      case '51pc':
        return ['routes/routes.dart'];
      case 'hlw':
        return ['util/go_routers.dart'];
      case 'tiktok':
        return ['public/routes.dart'];
      case '91cg':
        return ['util/go_routers.dart'];
      case '51cg':
        return ['util/go_routers.dart'];
      case 'mrds':
        return ['util/go_routers.dart'];
      case 'yms':
        return ['common/local_router/router_map.dart'];
      case 'oio':
        return ['common/local_router/router_map.dart'];
      case 'bili':
        return ['common/local_router/router_map.dart'];
      case '91porn':
        return ['routers/router_map.dart'];
      case '91porn2':
        return ['public/routes.dart'];
      case 'txpjb':
        return ['route/route_config.dart'];
      case 'xjpjb':
        return ['route/route_config.dart'];
      case 'hlbdy':
        return ['util/go_routers.dart'];
      case 'acfun':
        return ['features/routes/app_routes.dart'];
      case 'nnrj':
        return ['routes/routes.dart'];
      case 'tx':
        return [
          'core/routers.dart',
          'modules/splash/splash_view.dart',
        ];
      case 'dq':
        // xty / 斗球：GetX 路由多在 config / main
        return [
          'config/app_pages.dart',
          'config/config.dart',
        ];
      case 'lgt':
        // 与 acfun 同：集中路由表
        return ['features/routes/app_routes.dart'];
      case 'douyin':
        return [
          'router.dart',
          'router/home.dart',
          'router/library.dart',
          'router/follow.dart',
          'router/play.dart',
          'router/mine.dart',
          'router/profile.dart',
          'router/pay.dart',
          'router/webview.dart',
          'router/chat.dart',
          'router/search.dart',
          'router/common.dart',
          'router/movie.dart',
          'router/post.dart',
        ];
      default:
        return [
          'routes/routes.dart',
          'router/paths.dart',
          'features/routes/app_routes.dart',
        ];
    }
  }

  Future<void> process(
      List<String> files, AnalysisContextCollection collection) async {
    final projectName = config.projectName ?? 'default';
    logger.step('路由/API路径常量混淆 (项目: $projectName)...');

    if (_shouldSkipRouteObfuscation(projectName)) {
      logger.warning('项目 $projectName 使用完整路径跳转，跳过路由 path 哈希混淆');
      return;
    }

    final patterns = _getRouteFilePatterns();
    final pathFiles = <String>[];
    for (final pattern in patterns) {
      final matched = files.where((f) => f.endsWith(pattern)).toList();
      pathFiles.addAll(matched);
    }

    if (pathFiles.isEmpty) {
      if (config.projectName == 'ph' ||
          config.projectName == 'hjsq' ||
          config.projectName == '51pc' ||
          config.projectName == 'hlw' ||
          config.projectName == 'tiktok' ||
          config.projectName == '91cg' ||
          config.projectName == '51cg' ||
          config.projectName == 'mrds' ||
          config.projectName == 'yms' ||
          config.projectName == 'oio' ||
          config.projectName == 'bili' ||
          config.projectName == '91porn' ||
          config.projectName == '91porn2' ||
          config.projectName == 'txpjb' ||
          config.projectName == 'xjpjb' ||
          config.projectName == 'hlbdy' ||
          config.projectName == 'acfun' ||
          config.projectName == 'nnrj' ||
          config.projectName == 'tx' ||
          config.projectName == 'dq' ||
          config.projectName == 'lgt' ||
          config.projectName == 'douyin') {
        logger.warning('未找到路径常量文件: ${patterns.join(" 或 ")}');
      } else {
        logger.info('项目 $projectName 无路径混淆配置，跳过');
      }
      return;
    }

    logger.info(
        '找到 ${pathFiles.length} 个路径常量文件: ${pathFiles.map((f) => path.basename(f)).join(", ")}');

    final allRoutes = <String>[];
    for (final pathFile in pathFiles) {
      final context = collection.contextFor(pathFile);
      final result = await context.currentSession.getResolvedUnit(pathFile);

      if (result is! ResolvedUnitResult) {
        logger.warning('无法解析文件: ${path.basename(pathFile)}');
        continue;
      }

      final visitor = _RouteCollector();
      result.unit.accept(visitor);

      final collectedRoutes = visitor.routes.toSet();
      final commentedRoutes = _extractCommentedOriginalRoutes(pathFile);
      if (commentedRoutes.isNotEmpty) {
        collectedRoutes.removeWhere(_looksObfuscatedRoute);
        collectedRoutes.addAll(commentedRoutes);
      }

      if (collectedRoutes.isNotEmpty) {
        logger.info(
            '  ${path.basename(pathFile)}: ${collectedRoutes.length} 个路径');
        allRoutes.addAll(collectedRoutes);
      }
    }

    if (allRoutes.isEmpty) {
      logger.info('未找到可混淆的路径常量');
      return;
    }

    logger.info('共找到 ${allRoutes.length} 个路径常量');

    final routeRewrites = <_RouteRewrite>[];
    final skippedRoutes = <String, String>{};
    final seed = projectName;

    for (final route in allRoutes.toSet()) {
      final routeParts = _RoutePatternParts.parse(route);
      if (!routeParts.isSupported) {
        skippedRoutes[route] = routeParts.unsupportedReason ?? '未知原因';
        continue;
      }

      final obfuscatedBase =
          NameGenerator.generateRouteHash('${seed}_${routeParts.route}');
      final rewrite = _RouteRewrite(
        originalPattern: routeParts.route,
        obfuscatedPattern: routeParts.dynamicSuffix.isEmpty
            ? obfuscatedBase
            : '$obfuscatedBase${routeParts.dynamicSuffix}',
        originalLocationPrefix: routeParts.hasDynamicSegments
            ? '${routeParts.staticPrefix}/'
            : routeParts.route,
        obfuscatedLocationPrefix:
            routeParts.hasDynamicSegments ? '$obfuscatedBase/' : obfuscatedBase,
        hasDynamicSegments: routeParts.hasDynamicSegments,
      );

      routeRewrites.add(rewrite);
      routeMapping[route] = rewrite.obfuscatedPattern;
    }

    if (skippedRoutes.isNotEmpty) {
      for (final entry in skippedRoutes.entries) {
        logger.warning('跳过路径 ${entry.key}: ${entry.value}');
      }
    }

    if (routeRewrites.isEmpty) {
      logger.info('未找到可安全混淆的路径常量');
      return;
    }

    if (config.dryRun) {
      logger.info('[DRY-RUN] 将混淆 ${routeRewrites.length} 个路径常量');
      for (final rewrite in routeRewrites.take(5)) {
        logger.debug(
            '  ${rewrite.originalPattern} -> ${rewrite.obfuscatedPattern}');
      }
      if (routeRewrites.length > 5) {
        logger.debug('  ... 等 ${routeRewrites.length - 5} 个');
      }
      return;
    }

    final allDartFiles = await _collectAllDartFiles(config.targetDir);
    final repairedApiFiles = _repairLeakedApiRoutes(
      allDartFiles: allDartFiles,
      routeRewrites: routeRewrites,
    );
    if (repairedApiFiles > 0) {
      logger.warning('已修复 $repairedApiFiles 个 API/网络文件中的路由哈希泄漏');
    }

    final routeAwareFiles = _findRouteAwareFiles(
      allDartFiles,
      pathFiles.toSet(),
      routeRewrites,
    );

    logger.info('将更新 ${routeAwareFiles.length} 个路由相关文件');

    var replacedCount = 0;
    final pathFileSet = pathFiles.toSet();
    final sortedRewrites = [...routeRewrites]..sort(
        (a, b) => b.originalPattern.length.compareTo(a.originalPattern.length));

    for (final file in routeAwareFiles) {
      final content = File(file).readAsStringSync();
      final newContent = _rewriteContent(
        content,
        sortedRewrites,
        annotateExactMatches: pathFileSet.contains(file),
      );

      if (newContent != content) {
        File(file).writeAsStringSync(newContent);
        replacedCount++;
        logger.debug('替换路径: ${path.relative(file, from: config.targetDir)}');
      }
    }

    final validation = _validateRouteSafety(
      allDartFiles: allDartFiles,
      routeAwareFiles: routeAwareFiles,
      routeRewrites: routeRewrites,
      skippedRoutes: skippedRoutes,
      projectName: seed,
      pathFiles: pathFiles,
    );

    final mappingFile = File('build/route_mapping_$seed.txt');
    mappingFile.parent.createSync(recursive: true);
    final buffer = StringBuffer();
    buffer.writeln('# 路径常量映射表 (项目: $seed)');
    buffer.writeln('# 生成时间: ${DateTime.now()}');
    buffer.writeln(
        '# 路径文件: ${pathFiles.map((f) => path.basename(f)).join(", ")}');
    buffer.writeln(
        '# 路由相关文件: ${routeAwareFiles.map((f) => path.relative(f, from: config.targetDir)).join(", ")}');
    buffer.writeln('# 校验结果: ${validation.issues.isEmpty ? "PASS" : "FAIL"}');
    buffer.writeln('');

    if (skippedRoutes.isNotEmpty) {
      buffer.writeln('[跳过的路径]');
      for (final entry in skippedRoutes.entries) {
        buffer.writeln('${entry.key} -> ${entry.value}');
      }
      buffer.writeln('');
    }

    for (final entry in routeMapping.entries) {
      buffer.writeln('${entry.key} -> ${entry.value}');
    }
    mappingFile.writeAsStringSync(buffer.toString());

    logger.success('路径混淆完成: ${routeRewrites.length} 个路径, $replacedCount 个文件');
    logger.info('映射表保存至: ${mappingFile.path}');
    logger.info('校验报告保存至: ${validation.reportPath}');

    if (validation.issues.isNotEmpty) {
      throw StateError('路由混淆校验失败，请先修复校验报告中的问题');
    }
  }

  Future<List<String>> _collectAllDartFiles(String targetDir) async {
    final files = <String>[];
    final dir = Directory(targetDir);

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        files.add(entity.path);
      }
    }

    return files;
  }

  Set<String> _findRouteAwareFiles(
    List<String> allDartFiles,
    Set<String> pathFiles,
    List<_RouteRewrite> routeRewrites,
  ) {
    final routeAwareFiles = <String>{...pathFiles};

    for (final file in allDartFiles) {
      if (routeAwareFiles.contains(file)) {
        continue;
      }

      final content = File(file).readAsStringSync();
      if (!_containsAnyRouteLiteral(content, routeRewrites)) {
        continue;
      }

      if (_containsRouteDefinitionMarkers(content) ||
          _containsNavigationMarkers(content)) {
        routeAwareFiles.add(file);
      }
    }

    return routeAwareFiles;
  }

  bool _containsAnyRouteLiteral(
      String content, List<_RouteRewrite> routeRewrites) {
    for (final rewrite in routeRewrites) {
      if (content.contains(rewrite.originalPattern) ||
          (rewrite.hasDynamicSegments &&
              content.contains(rewrite.originalLocationPrefix))) {
        return true;
      }
    }
    return false;
  }

  bool _containsRouteDefinitionMarkers(String content) {
    return content.contains('@TypedGoRoute') ||
        content.contains(r'GoRouteData.$route') ||
        content.contains(r'GoRouteData.$location') ||
        content.contains('GoRoute(') ||
        content.contains('RouteModel(') ||
        content.contains('initialLocation:');
  }

  bool _containsNavigationMarkers(String content) {
    return content.contains('context.go(') ||
        content.contains('context.push(') ||
        content.contains('context.replace(') ||
        content.contains('context.pushReplacement(');
  }

  String _rewriteContent(
    String content,
    List<_RouteRewrite> routeRewrites, {
    required bool annotateExactMatches,
  }) {
    var newContent = content;

    for (final rewrite in routeRewrites) {
      final singleQuotedReplacement = annotateExactMatches
          ? "'${rewrite.obfuscatedPattern}' /* ${rewrite.originalPattern} */"
          : "'${rewrite.obfuscatedPattern}'";
      final doubleQuotedReplacement = annotateExactMatches
          ? '"${rewrite.obfuscatedPattern}" /* ${rewrite.originalPattern} */'
          : '"${rewrite.obfuscatedPattern}"';

      newContent = newContent.replaceAll(
        "'${rewrite.originalPattern}'",
        singleQuotedReplacement,
      );
      newContent = newContent.replaceAll(
        '"${rewrite.originalPattern}"',
        doubleQuotedReplacement,
      );

      if (rewrite.hasDynamicSegments) {
        newContent = newContent.replaceAll(
          "'${rewrite.originalLocationPrefix}\${",
          "'${rewrite.obfuscatedLocationPrefix}\${",
        );
        newContent = newContent.replaceAll(
          '"${rewrite.originalLocationPrefix}\${',
          '"${rewrite.obfuscatedLocationPrefix}\${',
        );
      }

      if (annotateExactMatches) {
        final originalPattern = RegExp.escape(rewrite.originalPattern);
        final normalizedSingleQuoted = RegExp(
          "'/[^']+'(?:\\s*/\\*[^*]*\\*/)*\\s*/\\*\\s*$originalPattern\\s*\\*/(?:\\s*/\\*[^*]*\\*/)*",
        );
        final normalizedDoubleQuoted = RegExp(
          '"/[^"]+"(?:\\s*/\\*[^*]*\\*/)*\\s*/\\*\\s*$originalPattern\\s*\\*/(?:\\s*/\\*[^*]*\\*/)*',
        );

        newContent = newContent.replaceAll(
          normalizedSingleQuoted,
          "'${rewrite.obfuscatedPattern}' /* ${rewrite.originalPattern} */",
        );
        newContent = newContent.replaceAll(
          normalizedDoubleQuoted,
          '"${rewrite.obfuscatedPattern}" /* ${rewrite.originalPattern} */',
        );
      }
    }

    return newContent;
  }

  _RouteValidationResult _validateRouteSafety({
    required List<String> allDartFiles,
    required Set<String> routeAwareFiles,
    required List<_RouteRewrite> routeRewrites,
    required Map<String, String> skippedRoutes,
    required String projectName,
    required List<String> pathFiles,
  }) {
    final issues = <String>[];

    for (final file in routeAwareFiles) {
      final content = File(file).readAsStringSync();
      final relPath = path.relative(file, from: config.targetDir);

      for (final rewrite in routeRewrites) {
        if (content.contains("'${rewrite.originalPattern}'") ||
            content.contains('"${rewrite.originalPattern}"')) {
          issues.add('路由相关文件仍保留原始路径: $relPath -> ${rewrite.originalPattern}');
        }

        if (rewrite.hasDynamicSegments &&
            (content.contains("'${rewrite.originalLocationPrefix}\${") ||
                content.contains('"${rewrite.originalLocationPrefix}\${'))) {
          issues.add(
              '路由相关文件仍保留动态路径前缀: $relPath -> ${rewrite.originalLocationPrefix}');
        }
      }
    }

    for (final file in allDartFiles) {
      if (routeAwareFiles.contains(file) || !_looksLikeApiFile(file)) {
        continue;
      }

      final content = File(file).readAsStringSync();
      final relPath = path.relative(file, from: config.targetDir);

      for (final rewrite in routeRewrites) {
        final leaked = content.contains("'${rewrite.obfuscatedPattern}'") ||
            content.contains('"${rewrite.obfuscatedPattern}"') ||
            content.contains('/* ${rewrite.obfuscatedPattern} */') ||
            (rewrite.hasDynamicSegments &&
                (content.contains("'${rewrite.obfuscatedLocationPrefix}") ||
                    content.contains('"${rewrite.obfuscatedLocationPrefix}') ||
                    content
                        .contains('/* ${rewrite.obfuscatedLocationPrefix}')));
        if (leaked) {
          issues.add(
              '疑似路由哈希泄漏到 API/网络文件: $relPath -> ${rewrite.obfuscatedPattern}');
        }
      }
    }

    final reportFile = File('build/route_validation_$projectName.txt');
    reportFile.parent.createSync(recursive: true);
    final buffer = StringBuffer();
    buffer.writeln('# 路由混淆校验报告 (项目: $projectName)');
    buffer.writeln('# 时间: ${DateTime.now()}');
    buffer.writeln(
        '# 路径文件: ${pathFiles.map((f) => path.relative(f, from: config.targetDir)).join(", ")}');
    buffer.writeln(
        '# 路由相关文件: ${routeAwareFiles.map((f) => path.relative(f, from: config.targetDir)).join(", ")}');
    buffer.writeln('# 校验结果: ${issues.isEmpty ? "PASS" : "FAIL"}');
    buffer.writeln('');

    if (skippedRoutes.isNotEmpty) {
      buffer.writeln('[跳过的路径]');
      for (final entry in skippedRoutes.entries) {
        buffer.writeln('${entry.key} -> ${entry.value}');
      }
      buffer.writeln('');
    }

    if (issues.isEmpty) {
      buffer.writeln('未发现路由混淆泄漏或残留问题。');
    } else {
      buffer.writeln('[发现的问题]');
      for (final issue in issues) {
        buffer.writeln('- $issue');
      }
    }
    reportFile.writeAsStringSync(buffer.toString());

    if (issues.isEmpty) {
      logger.success('路由混淆校验通过');
    } else {
      logger.error('路由混淆校验失败，发现 ${issues.length} 个问题');
    }

    return _RouteValidationResult(
      issues: issues,
      reportPath: reportFile.path,
    );
  }

  bool _looksLikeApiFile(String filePath) {
    final normalized = filePath.replaceAll('\\', '/').toLowerCase();
    const keywords = [
      '/data_layer/',
      '/data_source/',
      '/remote/',
      '/network/',
      '/http/',
      '/service/',
      '/services/',
      '/api/',
      '/repo/',
      '/repository/',
    ];

    return keywords.any(normalized.contains);
  }

  int _repairLeakedApiRoutes({
    required List<String> allDartFiles,
    required List<_RouteRewrite> routeRewrites,
  }) {
    var repairedFiles = 0;

    for (final file in allDartFiles) {
      if (!_looksLikeApiFile(file)) {
        continue;
      }

      final content = File(file).readAsStringSync();
      var newContent = content;

      for (final rewrite in routeRewrites) {
        newContent = newContent.replaceAll(
          "'${rewrite.obfuscatedPattern}'",
          "'${rewrite.originalPattern}'",
        );
        newContent = newContent.replaceAll(
          '"${rewrite.obfuscatedPattern}"',
          '"${rewrite.originalPattern}"',
        );
        newContent = newContent.replaceAll(
          "'${rewrite.obfuscatedPattern}' /* ${rewrite.originalPattern} */",
          "'${rewrite.originalPattern}'",
        );
        newContent = newContent.replaceAll(
          '"${rewrite.obfuscatedPattern}" /* ${rewrite.originalPattern} */',
          '"${rewrite.originalPattern}"',
        );

        final escapedObfuscated = RegExp.escape(rewrite.obfuscatedPattern);
        final escapedOriginal = RegExp.escape(rewrite.originalPattern);
        final bytesLeakPattern = RegExp(
          r'String\.fromCharCodes\([^)]*\)\s*/\*\s*' +
              escapedObfuscated +
              r'\s*\*/\s*/\*\s*' +
              escapedOriginal +
              r'\s*\*/',
        );
        newContent = newContent.replaceAll(
          bytesLeakPattern,
          "'${rewrite.originalPattern}'",
        );
      }

      if (newContent != content) {
        File(file).writeAsStringSync(newContent);
        repairedFiles++;
      }
    }

    return repairedFiles;
  }

  Set<String> _extractCommentedOriginalRoutes(String filePath) {
    final content = File(filePath).readAsStringSync();
    final matches = RegExp(r'/\*\s*(/[^*\n]+)\s*\*/').allMatches(content);
    final routes = <String>{};

    for (final match in matches) {
      final route = match.group(1);
      if (route != null &&
          route.startsWith('/') &&
          !route.contains(r'$') &&
          RegExp(r'[a-zA-Z]').hasMatch(route)) {
        routes.add(route.trim());
      }
    }

    return routes;
  }

  bool _looksObfuscatedRoute(String route) {
    return RegExp(r'^/[0-9a-f]{10}(?:/:[A-Za-z0-9_]+)*$').hasMatch(route);
  }

  bool _shouldSkipRouteObfuscation(String projectName) {
    // douyin 的 GoRoute 定义使用分段 path，但 Go.push 调用使用完整路径。
    // 只改 GoRoute.path 会让注册路径和跳转路径不一致，例如:
    // /home/movie/detailVSearchId -> /<hash>/<hash>/detailVSearchId。
    return projectName == 'douyin';
  }
}

class _RouteValidationResult {
  final List<String> issues;
  final String reportPath;

  const _RouteValidationResult({
    required this.issues,
    required this.reportPath,
  });
}

class _RouteRewrite {
  final String originalPattern;
  final String obfuscatedPattern;
  final String originalLocationPrefix;
  final String obfuscatedLocationPrefix;
  final bool hasDynamicSegments;

  const _RouteRewrite({
    required this.originalPattern,
    required this.obfuscatedPattern,
    required this.originalLocationPrefix,
    required this.obfuscatedLocationPrefix,
    required this.hasDynamicSegments,
  });
}

class _RoutePatternParts {
  final String route;
  final String staticPrefix;
  final String dynamicSuffix;
  final bool hasDynamicSegments;
  final bool isSupported;
  final String? unsupportedReason;

  const _RoutePatternParts({
    required this.route,
    required this.staticPrefix,
    required this.dynamicSuffix,
    required this.hasDynamicSegments,
    required this.isSupported,
    this.unsupportedReason,
  });

  factory _RoutePatternParts.parse(String route) {
    final segments = route.split('/').skip(1).toList();
    if (segments.isEmpty) {
      return _RoutePatternParts(
        route: route,
        staticPrefix: '/',
        dynamicSuffix: '',
        hasDynamicSegments: false,
        isSupported: false,
        unsupportedReason: '根路径无需混淆',
      );
    }

    final firstDynamicIndex = segments.indexWhere(_isDynamicSegment);
    if (firstDynamicIndex == -1) {
      return _RoutePatternParts(
        route: route,
        staticPrefix: route,
        dynamicSuffix: '',
        hasDynamicSegments: false,
        isSupported: true,
      );
    }

    final hasStaticAfterDynamic = segments
        .skip(firstDynamicIndex)
        .any((segment) => !_isDynamicSegment(segment));
    if (hasStaticAfterDynamic) {
      return _RoutePatternParts(
        route: route,
        staticPrefix: route,
        dynamicSuffix: '',
        hasDynamicSegments: true,
        isSupported: false,
        unsupportedReason: '动态参数后仍包含静态段，当前策略无法安全改写',
      );
    }

    final staticSegments = segments.take(firstDynamicIndex).toList();
    if (staticSegments.isEmpty) {
      return _RoutePatternParts(
        route: route,
        staticPrefix: '/',
        dynamicSuffix: '/${segments.skip(firstDynamicIndex).join('/')}',
        hasDynamicSegments: true,
        isSupported: false,
        unsupportedReason: '路径没有可混淆的静态段',
      );
    }

    return _RoutePatternParts(
      route: route,
      staticPrefix: '/${staticSegments.join('/')}',
      dynamicSuffix: '/${segments.skip(firstDynamicIndex).join('/')}',
      hasDynamicSegments: true,
      isSupported: true,
    );
  }

  static bool _isDynamicSegment(String segment) {
    return segment.startsWith(':') || segment.contains(r'${');
  }
}

/// 路由路径 AST 收集器
class _RouteCollector extends RecursiveAstVisitor<void> {
  final List<String> routes = [];

  bool _containsLetter(String value) {
    return RegExp(r'[a-zA-Z]').hasMatch(value);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    if (node.isStatic && node.fields.isConst) {
      for (final variable in node.fields.variables) {
        final initializer = variable.initializer;
        if (initializer is StringLiteral) {
          final value = initializer.stringValue;
          if (value != null &&
              value.startsWith('/') &&
              !value.contains(r'$') &&
              _containsLetter(value)) {
            routes.add(value);
          }
        }
      }
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final constructorName = node.constructorName.type.name2.lexeme;
    if (constructorName == 'RouteModel' &&
        node.argumentList.arguments.isNotEmpty) {
      final firstArgument = node.argumentList.arguments.first;
      final literal = switch (firstArgument) {
        SimpleStringLiteral value => value,
        NamedExpression(expression: SimpleStringLiteral value) => value,
        _ => null,
      };

      final value = literal?.value;
      if (value != null &&
          value.startsWith('/') &&
          !value.contains(r'$') &&
          _containsLetter(value)) {
        routes.add(value);
      }
    }

    if (constructorName == 'GoRoute') {
      for (final argument in node.argumentList.arguments) {
        if (argument is! NamedExpression ||
            argument.name.label.name != 'path') {
          continue;
        }

        final expression = argument.expression;
        final literal = switch (expression) {
          SimpleStringLiteral value => value,
          StringLiteral value => value,
          _ => null,
        };

        final value = literal?.stringValue;
        if (value != null &&
            value.startsWith('/') &&
            !value.contains(r'$') &&
            _containsLetter(value)) {
          routes.add(value);
        }
      }
    }

    super.visitInstanceCreationExpression(node);
  }
}
