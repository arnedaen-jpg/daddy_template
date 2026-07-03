import 'dart:io';
import 'dart:math';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as path;

import '../config.dart';
import '../utils/logger.dart';
import '../utils/name_generator.dart';

/// 调用栈混淆器
///
/// 在核心类的方法体中注入包装调用，增加调用栈深度
/// 这样代码会实际被执行，不会被 tree shaking 移除
class CallstackObfuscator {
  final ObfuscatorConfig config;
  final Logger logger;
  late final Random _random;

  CallstackObfuscator(this.config, this.logger) {
    // 使用时间戳作为随机种子，确保每次运行结果不同
    _random = Random(DateTime.now().millisecondsSinceEpoch);
  }

  /// 获取项目特定的核心文件列表（全量）
  List<String> _getAllCoreFiles(String projectName) {
    switch (projectName) {
      case 'dq':
        // 斗球 xty：与源工程 /Users/t-yh/dqiu/lib 实际结构对齐（只按 basename 匹配）。
        // 覆盖全部基础设施层：网络/API/Service/Manager/加密/IM/路由/缓存/域名/启动。
        // 故意排除海量 UI（*_page/_widget/_dialog）、纯数据 *_entity/_response 与 *_logic
        // GetX 控制器——callstack 包装注入会增加调用深度，仅对基础设施层安全且有价值。
        return [
          // --- 启动 / 路由 / 入口 ---
          'module_entry.dart',
          'main.dart',
          'splash_page.dart',
          'app_pages.dart',
          'app_routes.dart',
          'config.dart',
          'view_config.dart',
          'bface_core_init.dart',
          // --- 网络 / HTTP ---
          'http_manager.dart',
          'http_utils.dart',
          'http_result_entity.dart',
          'mock_interceptor.dart',
          // --- API 层 ---
          'app_data_api.dart',
          'chat_api.dart',
          'collection_api.dart',
          'common_api.dart',
          'community_api.dart',
          'hw_api.dart',
          'im_api.dart',
          'login_api.dart',
          'match_api.dart',
          'match_data_api.dart',
          'match_detail_api.dart',
          'match_detail_esport_api.dart',
          'match_dj_api.dart',
          'match_esport_api.dart',
          'match_filter_api.dart',
          'material_api.dart',
          'mine_api.dart',
          'news_api.dart',
          'search_api.dart',
          'video_api.dart',
          'video_detail_api.dart',
          'video_gift_api.dart',
          // --- Service 层 ---
          'app_data_service.dart',
          'banner_service.dart',
          'chat_service.dart',
          'collection_service.dart',
          'common_service.dart',
          'community_service.dart',
          'hw_service.dart',
          'im_service.dart',
          'login_service.dart',
          'match_data_service.dart',
          'match_detail_esport_service.dart',
          'match_detail_service.dart',
          'match_dj_service.dart',
          'match_esport_service.dart',
          'match_filter_service.dart',
          'match_service.dart',
          'material_service.dart',
          'mine_service.dart',
          'news_service.dart',
          'news_video_service.dart',
          'search_service.dart',
          'video_detail_service.dart',
          'video_gift_service.dart',
          'video_service.dart',
          // --- Manager 层（数据/基础设施）---
          'app_data_manager.dart',
          'baseball_data_manager.dart',
          'basket_data_manager.dart',
          'esport_data_manager.dart',
          'foot_data_manager.dart',
          'tennis_data_manager.dart',
          'audio_manager.dart',
          'im_manager.dart',
          'log_manager.dart',
          'match_push_manager.dart',
          'player_set_manager.dart',
          'view_config_manager.dart',
          'event_bus_manager.dart',
          'xx_user_manager.dart',
          'xx_domain_manager.dart',
          'json_cache_manager.dart',
          // --- IM / socket ---
          'im_client.dart',
          'rongcloud_im_client.dart',
          'global_heart_beat.dart',
          // --- 加密 ---
          'encryption_utils.dart',
          'encrypt_strings.dart',
          'domain_encrypt_utils.dart',
          // --- 域名 / 全局 / 日志 / 缓存 / 存储 ---
          'global_logic.dart',
          'common_log.dart',
          'app_cache_utils.dart',
          'match_cache.dart',
          'material_cache_util.dart',
          'storage_keys.dart',
          'ServiceDataStorage.dart',
        ];
      case 'lgt':
        // 聊个天/IM：服务层 + API 全量 + 路由
        return [
          // 入口与初始化
          'module_entry.dart',
          'app_prepare.dart',
          'main.dart',

          // 服务层 - 全量
          'app_service.dart',
          'user_service.dart',
          'storage_service.dart',
          'im_service.dart',
          'im_quota_service.dart',

          // HTTP 服务层
          'api_settings.dart',
          'api_encrypt.dart',
          'api_crypto.dart',
          'api_code.dart',

          // API 接口 - 全量
          'api.dart',
          'api_sys.dart',
          'api_home.dart',
          'api_user.dart',
          'api_search.dart',
          'api_video.dart',
          'api_comic.dart',
          'api_novel.dart',
          'api_community.dart',
          'api_coterie.dart',
          'api_welfare.dart',
          'api_ai.dart',
          'api_ad.dart',
          'api_mine.dart',
          'api_file.dart',
          'api_cdn.dart',
          'api_information.dart',
          'api_activity.dart',
          'api_fixed.dart',
          'api_adult_game.dart',
          'api_news.dart',
          'api_region.dart',
          'api_bookshelf.dart',
          'api_im.dart',
          'api_dynamic.dart',
          'api_blogger.dart',

          // 路由 - 全量
          'app_pages.dart',
          'app_routes.dart',
          'app_routes_jump.dart',
          'route_model.dart',
          'route_stack_tracker.dart',
          'internal_jump_routes.dart',
          'routes_pages_anime.dart',
          'routes_pages_common.dart',
          'routes_pages_community.dart',
          'routes_pages_mine.dart',
          'routes_pages_novel.dart',
          'routes_pages_video.dart',

          // 配置
          'app_config.dart',
          'proxy_config.dart',
          'app_build_config.dart',

          // 公共工具
          'payment_utils.dart',
          'report_utils.dart',
          'app_utils.dart',
          'novel_text_decrypt.dart',
          'ad_jump.dart',
          'upload_utils.dart',
        ];
      default:
        return [
          'api_service.dart',
          'user_service.dart',
        ];
    }
  }

  /// 随机选择要处理的核心文件（增加随机性）
  List<String> _selectCoreFiles(String projectName) {
    final allFiles = _getAllCoreFiles(projectName);

    // 保证一些核心文件必须被混淆
    final requiredFiles = <String>[];
    switch (projectName) {
      case 'dq':
        requiredFiles.addAll([
          'module_entry.dart',
          'main.dart',
          'http_manager.dart',
          'global_logic.dart',
          'xx_domain_manager.dart',
        ]);
        break;
      case 'lgt':
        requiredFiles.addAll([
          'module_entry.dart', 'app_prepare.dart', 'main.dart',
          'app_service.dart', 'user_service.dart', 'storage_service.dart',
          'api_settings.dart', 'api_encrpt.dart', 'api_crypto.dart',
          'api.dart', 'api_sys.dart', 'api_home.dart', 'api_user.dart',
          'api_video.dart', 'app_pages.dart', 'app_routes.dart', 'app_config.dart',
        ]);
        break;
      default:
        requiredFiles.addAll(['api_service.dart']);
    }

    // 从剩余文件中随机选择 85%-100%
    final optionalFiles =
        allFiles.where((f) => !requiredFiles.contains(f)).toList();
    final ratio = 0.85 + _random.nextDouble() * 0.15;
    final count = (optionalFiles.length * ratio).ceil();

    final shuffled = List<String>.from(optionalFiles)..shuffle(_random);
    final selected = shuffled.take(count).toList();

    return [...requiredFiles, ...selected];
  }

  /// Resolve the library key for a file.
  /// Files with `part of '...'` share their parent library's namespace.
  String _resolveLibraryKey(String filePath) {
    try {
      final lines = File(filePath).readAsLinesSync();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('//')) continue;
        final match = RegExp(r"^part\s+of\s+'([^']+)'\s*;").firstMatch(trimmed);
        if (match != null) {
          final partOfTarget = match.group(1)!;
          return path
              .normalize(path.join(path.dirname(filePath), partOfTarget));
        }
        break;
      }
    } catch (_) {}
    return path.normalize(filePath);
  }

  Future<void> process(
      List<String> files, AnalysisContextCollection collection) async {
    logger.step('调用栈混淆 (深度: ${config.callStackDepth})...');

    final projectName = config.projectName ?? 'default';

    // 随机选择核心文件（每次运行结果不同）
    final coreFiles = _selectCoreFiles(projectName);

    // 使用时间戳生成唯一种子（每次运行不同）
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final seed = '${projectName}_${timestamp % 10000}';

    var totalFiles = 0;
    var totalMethods = 0;

    // 筛选核心文件
    final targetFiles = files.where((f) {
      final fileName = path.basename(f);
      return coreFiles.any((core) => fileName == core);
    }).toList();

    if (targetFiles.isEmpty) {
      logger.warning('未找到核心文件，跳过调用栈混淆');
      logger.info('目标文件列表: ${coreFiles.join(", ")}');
      return;
    }

    logger.info('随机选择 ${coreFiles.length} 个核心文件: ${coreFiles.join(", ")}');
    logger.info('找到 ${targetFiles.length} 个匹配文件');

    // Track used class names per library to avoid duplicates in part-of files
    final usedClassNamesPerLibrary = <String, Set<String>>{};

    for (final file in targetFiles) {
      try {
        final context = collection.contextFor(file);
        final result = await context.currentSession.getResolvedUnit(file);

        if (result is! ResolvedUnitResult) {
          continue;
        }

        // 收集可混淆的方法
        final visitor = _MethodCollector();
        result.unit.accept(visitor);

        if (visitor.methods.isEmpty) {
          continue;
        }

        if (config.dryRun) {
          totalFiles++;
          totalMethods += visitor.methods.length;
          logger.debug(
              '[DRY-RUN] ${path.basename(file)}: ${visitor.methods.length} 个方法');
          continue;
        }

        // 读取文件内容
        final content = File(file).readAsStringSync();
        var newContent = content;

        // Resolve the library this file belongs to (handles part-of)
        final libraryKey = _resolveLibraryKey(file);
        final usedNames =
            usedClassNamesPerLibrary.putIfAbsent(libraryKey, () => {});

        // Generate a unique wrapper class name, retrying on collision
        String wrapperClassName;
        var attempt = 0;
        do {
          final randomSuffix = _random.nextInt(100000);
          wrapperClassName = NameGenerator.generateClassName(
              '${seed}_${path.basenameWithoutExtension(file)}_${randomSuffix}_$attempt');
          attempt++;
        } while (usedNames.contains(wrapperClassName) && attempt < 100);
        usedNames.add(wrapperClassName);

        // 随机选择方法名前缀
        final prefixes = ['wrap', 'proc', 'exec', 'run', 'call', 'invoke'];
        final prefix = prefixes[_random.nextInt(prefixes.length)];
        final asyncPrefix =
            'a${prefix.substring(0, 1).toUpperCase()}${prefix.substring(1)}';

        // 在文件末尾添加包装器类
        final wrapperClass = _generateWrapperClassWithPrefix(
            wrapperClassName, config.callStackDepth, prefix, asyncPrefix);

        // 随机选择部分方法进行混淆（避免全部混淆导致模式过于明显）
        final methodsToWrap = _selectMethodsToWrap(visitor.methods);

        // 从后向前处理，避免偏移量变化
        methodsToWrap.sort((a, b) => b.bodyOffset.compareTo(a.bodyOffset));

        for (final method in methodsToWrap) {
          // 随机选择包装深度
          final depth = _random.nextInt(config.callStackDepth) + 1;

          // 包装方法体（使用对应的前缀）
          newContent = _wrapMethodWithPrefix(
              newContent, method, wrapperClassName, prefix, asyncPrefix, depth);
        }

        // 添加包装器类
        if (methodsToWrap.isNotEmpty) {
          newContent = '$newContent\n$wrapperClass';
        }

        if (newContent != content) {
          File(file).writeAsStringSync(newContent);
          totalFiles++;
          totalMethods += methodsToWrap.length;
          logger
              .debug('混淆 ${methodsToWrap.length} 个方法: ${path.basename(file)}');
        }
      } catch (e) {
        logger.debug('跳过文件 ${path.basename(file)}: $e');
      }
    }

    if (config.dryRun) {
      logger.info('[DRY-RUN] 将处理 $totalFiles 个文件，$totalMethods 个方法');
    } else {
      logger.success('调用栈混淆完成: $totalFiles 个文件, $totalMethods 个方法');
    }
  }

  /// 生成包装器类（使用指定的方法名前缀）
  String _generateWrapperClassWithPrefix(
      String className, int depth, String prefix, String asyncPrefix) {
    final buffer = StringBuffer();

    // 随机选择注释风格
    final comments = [
      '/// Data processing helper',
      '/// Internal utility class',
      '/// State management helper',
      '/// Cache processing utility',
      '/// Event handler wrapper',
      '/// Request dispatcher utility',
      '/// Service invoker helper',
    ];
    buffer.writeln('\n${comments[_random.nextInt(comments.length)]}');
    buffer.writeln('class $className {');
    buffer.writeln('  $className._();');

    // 生成嵌套包装方法
    for (var i = 1; i <= depth; i++) {
      if (i == 1) {
        buffer.writeln('  static T $prefix$i<T>(T Function() fn) => fn();');
      } else {
        buffer.writeln(
            '  static T $prefix$i<T>(T Function() fn) => $prefix${i - 1}(fn);');
      }
    }

    // 生成异步版本
    for (var i = 1; i <= depth; i++) {
      if (i == 1) {
        buffer.writeln(
            '  static Future<T> $asyncPrefix$i<T>(Future<T> Function() fn) => fn();');
      } else {
        buffer.writeln(
            '  static Future<T> $asyncPrefix$i<T>(Future<T> Function() fn) => $asyncPrefix${i - 1}(fn);');
      }
    }

    buffer.writeln('}');
    return buffer.toString();
  }

  /// 随机选择部分方法进行混淆
  List<_MethodInfo> _selectMethodsToWrap(List<_MethodInfo> methods) {
    // 混淆 80%-100% 的方法（随 seed 抖动）
    final ratio = 0.8 + _random.nextDouble() * 0.2;
    final count = (methods.length * ratio).ceil().clamp(1, methods.length);

    final shuffled = List<_MethodInfo>.from(methods)..shuffle(_random);
    return shuffled.take(count).toList();
  }

  /// 包装方法体（使用指定的前缀）
  String _wrapMethodWithPrefix(String content, _MethodInfo method,
      String wrapperClass, String prefix, String asyncPrefix, int depth) {
    // 找到方法体的 { 位置
    final bodyStart = method.bodyOffset;
    final bodyContent = content.substring(bodyStart);

    // 查找方法体结束的 }（需要跳过字符串和注释中的大括号）
    final bodyEnd = _findMatchingBrace(bodyContent, bodyStart);

    if (bodyEnd == -1) return content;

    // 获取方法体内容（不包括 { }）
    final innerBody = content.substring(bodyStart + 1, bodyEnd).trim();

    // 如果方法体太简单（如空方法或单行），跳过
    if (innerBody.isEmpty || !innerBody.contains(';')) {
      return content;
    }

    final indentedInnerBody = _indentBlock(innerBody, '    ');

    String newBody;
    if (method.isAsync) {
      // 对于 async 方法：
      // 原: AsyncJson foo() async { ... return x; }
      //
      // 需要变成（移除 async，让包装器返回 Future）:
      // AsyncJson foo() { return wrapper.aExec<InnerType>(() async { ... return x; }); }
      //
      // method.returnType 已经是 Future 的内部类型（如 Map<String, dynamic>）

      // 移除方法签名中的 async 关键字
      final beforeBody = content.substring(0, bodyStart);

      // 查找 async 关键字（可能后面有空格）
      final asyncPattern = RegExp(r'\basync\s*$');
      final trimmedBefore = beforeBody.trimRight();
      final asyncMatch = asyncPattern.firstMatch(trimmedBefore);

      if (asyncMatch != null) {
        // 移除 async 关键字
        final beforeAsync = trimmedBefore.substring(0, asyncMatch.start);
        newBody = ' {\n'
            '  return $wrapperClass.$asyncPrefix$depth<${method.returnType}>(() async {\n'
            '$indentedInnerBody\n'
            '  });\n'
            '}';
        return beforeAsync + newBody + content.substring(bodyEnd + 1);
      } else {
        // 尝试更宽松的匹配：查找任意位置的 async
        final looseMatch = RegExp(r'\basync\b\s*').firstMatch(
            beforeBody.substring(
                beforeBody.length - 20 < 0 ? 0 : beforeBody.length - 20));
        if (looseMatch != null) {
          final searchStart =
              beforeBody.length - 20 < 0 ? 0 : beforeBody.length - 20;
          final matchStart = searchStart + looseMatch.start;
          final beforeAsync = content.substring(0, matchStart);
          final afterAsync = content.substring(
              matchStart + looseMatch.end - looseMatch.start, bodyStart);
          newBody = '{\n'
              '  return $wrapperClass.$asyncPrefix$depth<${method.returnType}>(() async {\n'
              '$indentedInnerBody\n'
              '  });\n'
              '}';
          return beforeAsync +
              afterAsync +
              newBody +
              content.substring(bodyEnd + 1);
        }
        // 无法找到 async，跳过该方法
        return content;
      }
    } else {
      newBody = '{\n'
          '  return $wrapperClass.$prefix$depth<${method.returnType}>(() {\n'
          '$indentedInnerBody\n'
          '  });\n'
          '}';
    }

    return content.substring(0, bodyStart) +
        newBody +
        content.substring(bodyEnd + 1);
  }

  String _indentBlock(String body, String indent) {
    return body
        .split('\n')
        .map((line) => line.isEmpty ? line : '$indent$line')
        .join('\n');
  }

  /// 查找匹配的右大括号，正确处理字符串和注释
  int _findMatchingBrace(String bodyContent, int bodyStart) {
    var braceCount = 0;
    var i = 0;

    while (i < bodyContent.length) {
      final char = bodyContent[i];

      // 跳过单行注释
      if (char == '/' &&
          i + 1 < bodyContent.length &&
          bodyContent[i + 1] == '/') {
        i += 2;
        while (i < bodyContent.length && bodyContent[i] != '\n') {
          i++;
        }
        continue;
      }

      // 跳过多行注释
      if (char == '/' &&
          i + 1 < bodyContent.length &&
          bodyContent[i + 1] == '*') {
        i += 2;
        while (i + 1 < bodyContent.length &&
            !(bodyContent[i] == '*' && bodyContent[i + 1] == '/')) {
          i++;
        }
        i += 2; // 跳过 */
        continue;
      }

      // 跳过原始字符串 r'...' 或 r"..."
      if (char == 'r' &&
          i + 1 < bodyContent.length &&
          (bodyContent[i + 1] == '"' || bodyContent[i + 1] == "'")) {
        final quote = bodyContent[i + 1];
        i += 2;
        while (i < bodyContent.length && bodyContent[i] != quote) {
          if (bodyContent[i] == '\\' && i + 1 < bodyContent.length) {
            i += 2; // 跳过转义
          } else {
            i++;
          }
        }
        i++; // 跳过结束引号
        continue;
      }

      // 跳过三引号字符串 ''' 或 """
      if ((char == '"' || char == "'") &&
          i + 2 < bodyContent.length &&
          bodyContent[i + 1] == char &&
          bodyContent[i + 2] == char) {
        final quote = char;
        i += 3;
        while (i + 2 < bodyContent.length &&
            !(bodyContent[i] == quote &&
                bodyContent[i + 1] == quote &&
                bodyContent[i + 2] == quote)) {
          i++;
        }
        i += 3; // 跳过结束三引号
        continue;
      }

      // 跳过普通字符串 '...' 或 "..."
      if (char == '"' || char == "'") {
        final quote = char;
        i++;
        while (i < bodyContent.length && bodyContent[i] != quote) {
          if (bodyContent[i] == '\\' && i + 1 < bodyContent.length) {
            i += 2; // 跳过转义字符
          } else {
            i++;
          }
        }
        i++; // 跳过结束引号
        continue;
      }

      // 计算大括号
      if (char == '{') braceCount++;
      if (char == '}') braceCount--;

      if (braceCount == 0) {
        return bodyStart + i;
      }

      i++;
    }

    return -1;
  }
}

/// 方法信息
class _MethodInfo {
  final String name;
  final int bodyOffset; // 方法体 { 的偏移量
  final bool isAsync; // 是否是 async 方法
  final String returnType; // 返回类型（对于 async 方法，是 Future 内部的类型）
  final String rawReturnType; // 原始返回类型

  _MethodInfo(this.name, this.bodyOffset, this.isAsync, this.returnType,
      this.rawReturnType);
}

/// 方法收集器
class _MethodCollector extends RecursiveAstVisitor<void> {
  final List<_MethodInfo> methods = [];

  // 常见的 Future 类型别名映射
  static const _futureTypeAliases = {
    'AsyncJson': 'Map<String, dynamic>',
    'AsyncResult': 'Result',
    'AsyncVoid': 'void',
  };

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    // 跳过 getter/setter
    if (node.isGetter || node.isSetter) {
      return;
    }

    // 跳过抽象方法
    if (node.isAbstract) {
      return;
    }

    final body = node.body;

    // 只处理块方法体（有 { } 的）
    if (body is! BlockFunctionBody) {
      return;
    }

    // 包装进闭包后，被重新赋值的可空参数会丧失 null promotion，跳过此类方法
    if (_hasReassignedNullableParams(node.parameters, body)) {
      return;
    }

    final isAsync = body.keyword?.lexeme == 'async';
    final rawType = _getRawReturnType(node);
    final returnType = _getInnerTypeForAsync(rawType, isAsync);

    // 跳过 dynamic 返回类型
    if (returnType == 'dynamic') {
      return;
    }

    // 对于 void：
    // - 同步 void 方法跳过（无法用 return 包装）
    // - 异步 Future<void> 可以包装（返回的是 Future）
    if (returnType == 'void' && !isAsync) {
      return;
    }

    methods.add(_MethodInfo(
      node.name.lexeme,
      body.block.leftBracket.offset,
      isAsync,
      returnType,
      rawType,
    ));

    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // 处理顶层函数（如 login()）
    final body = node.functionExpression.body;

    if (body is! BlockFunctionBody) {
      return;
    }

    // 包装进闭包后，被重新赋值的可空参数会丧失 null promotion，跳过此类方法
    if (_hasReassignedNullableParams(
        node.functionExpression.parameters, body)) {
      return;
    }

    final isAsync = body.keyword?.lexeme == 'async';
    final rawType = _getTopLevelRawReturnType(node);
    final returnType = _getInnerTypeForAsync(rawType, isAsync);

    // 跳过 dynamic 返回类型
    if (returnType == 'dynamic') {
      return;
    }

    // 对于 void：同步跳过，异步 Future<void> 可以包装
    if (returnType == 'void' && !isAsync) {
      return;
    }

    methods.add(_MethodInfo(
      node.name.lexeme,
      body.block.leftBracket.offset,
      isAsync,
      returnType,
      rawType,
    ));

    super.visitFunctionDeclaration(node);
  }

  /// 检测方法是否有可空参数在方法体中被重新赋值。
  /// 闭包捕获的变量如果在闭包内被赋值，Dart 不再对其做 null promotion。
  bool _hasReassignedNullableParams(
      FormalParameterList? params, FunctionBody body) {
    if (params == null) return false;
    if (body is! BlockFunctionBody) return false;

    final nullableNames = <String>{};
    for (final param in params.parameters) {
      final typeSource = _getParamTypeSource(param);
      final name = param.name?.lexeme;
      if (typeSource != null && typeSource.endsWith('?') && name != null) {
        nullableNames.add(name);
      }
    }
    if (nullableNames.isEmpty) return false;

    final checker = _NullableParamReassignmentChecker(nullableNames);
    body.accept(checker);
    return checker.hasReassignment;
  }

  String? _getParamTypeSource(FormalParameter param) {
    if (param is DefaultFormalParameter) {
      return _getParamTypeSource(param.parameter);
    }
    if (param is SimpleFormalParameter) {
      return param.type?.toSource();
    }
    return null;
  }

  /// 获取原始返回类型字符串
  String _getRawReturnType(MethodDeclaration node) {
    final returnType = node.returnType;
    if (returnType == null) return 'dynamic';
    return returnType.toSource();
  }

  String _getTopLevelRawReturnType(FunctionDeclaration node) {
    final returnType = node.returnType;
    if (returnType == null) return 'dynamic';
    return returnType.toSource();
  }

  /// 对于 async 方法，获取 Future 内部的类型
  ///
  /// - `Future<T>` -> `T`
  /// - `AsyncJson` (typedef Future<Map<...>>) -> `Map<String, dynamic>`
  /// - `T` (非 Future) -> `T`
  String _getInnerTypeForAsync(String rawType, bool isAsync) {
    if (!isAsync) {
      return rawType;
    }

    // 处理 Future<T>
    if (rawType.startsWith('Future<') && rawType.endsWith('>')) {
      final inner = rawType.substring(7, rawType.length - 1);
      return inner.isEmpty ? 'dynamic' : inner;
    }

    // 处理常见类型别名
    if (_futureTypeAliases.containsKey(rawType)) {
      return _futureTypeAliases[rawType]!;
    }

    // 对于其他类型别名，返回 dynamic 以保证安全
    // 这些可能是 typedef Future<...> 的别名
    return 'dynamic';
  }
}

/// 检测可空参数是否在方法体内被重新赋值
class _NullableParamReassignmentChecker extends RecursiveAstVisitor<void> {
  final Set<String> nullableParamNames;
  bool hasReassignment = false;

  _NullableParamReassignmentChecker(this.nullableParamNames);

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (node.leftHandSide is SimpleIdentifier) {
      final name = (node.leftHandSide as SimpleIdentifier).name;
      if (nullableParamNames.contains(name)) {
        hasReassignment = true;
      }
    }
    super.visitAssignmentExpression(node);
  }
}
