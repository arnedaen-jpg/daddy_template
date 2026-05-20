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

/// 业务噪音注入器
///
/// 扫描 AST，找到 build()、initState()、getHomePage()，
/// 随机插入 Noise.run() 调用，增加运行时分支与混淆效果。
class BusinessNoiseInjector {
  BusinessNoiseInjector(this.config, this.logger);

  final ObfuscatorConfig config;
  final Logger logger;
  late final Random _random;

  static const _targetMethodNames = ['build', 'initState', 'getHomePage'];

  /// 注入概率 (0.6 ~ 0.85)
  static const _minInjectionRate = 0.6;
  static const _maxInjectionRate = 0.85;

  Future<void> process(
    List<String> files,
    AnalysisContextCollection collection,
  ) async {
    logger.step('业务噪音注入 (build/initState/getHomePage)...');

    final seedBase = config.seedBase;
    _random = Random(seedBase != null ? seedBase.hashCode : (DateTime.now().millisecondsSinceEpoch + (config.projectName?.hashCode ?? 0)));

    if (config.targetDir.isEmpty) {
      logger.warning('目标目录为空，跳过');
      return;
    }

    final targetDir = Directory(config.targetDir);
    if (!targetDir.existsSync()) {
      logger.warning('目标目录不存在: ${config.targetDir}');
      return;
    }

    final project = config.projectName ?? 'default';
    final seed = seedBase != null ? '${project}_noise_$seedBase' : '${project}_noise_${DateTime.now().millisecondsSinceEpoch}';

    if (config.dryRun) {
      logger.info('[DRY-RUN] 将生成 Noise 并注入到目标方法');
      return;
    }

    const internalDir = '_internal';
    final dir = Directory(path.join(config.targetDir, internalDir));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final runtimePath = path.join(dir.path, 'part_runtime.dart');
    final runtimeContent = _generateRuntimeClass(seed);
    File(runtimePath).writeAsStringSync(runtimeContent);
    logger.info('生成: part_runtime.dart');

    // 2. 扫描文件，收集目标方法
    final toInject = <_InjectionTarget>[];
    for (final file in files) {
      if (_shouldSkipFile(file)) continue;

      try {
        final context = collection.contextFor(file);
        final result = await context.currentSession.getResolvedUnit(file);

        if (result is! ResolvedUnitResult) continue;

        final visitor = _NoiseMethodCollector();
        result.unit.accept(visitor);

        for (final m in visitor.methods) {
          if (_targetMethodNames.contains(m.name)) {
            final rate =
                _minInjectionRate + _random.nextDouble() * (_maxInjectionRate - _minInjectionRate);
            if (NameGenerator.shouldInject('${seed}_${path.basename(file)}_${m.name}', rate)) {
              toInject.add(_InjectionTarget(
                filePath: file,
                methodName: m.name,
                bodyOffset: m.bodyOffset,
                bodyEnd: m.bodyEnd,
              ));
            }
          }
        }
      } catch (e) {
        logger.debug('跳过 ${path.basename(file)}: $e');
      }
    }

    if (toInject.isEmpty) {
      logger.warning('未找到可注入的目标方法');
      return;
    }

    // 3. 按文件分组，添加 import 并注入
    final byFile = <String, List<_InjectionTarget>>{};
    for (final t in toInject) {
      byFile.putIfAbsent(t.filePath, () => []).add(t);
    }

    for (final entry in byFile.entries) {
      var content = File(entry.key).readAsStringSync();

      // Skip part-of files (cannot have import directives)
      if (RegExp(r'^\s*part\s+of\s+', multiLine: true).hasMatch(content)) {
        logger.debug('跳过 part 文件: ${path.basename(entry.key)}');
        continue;
      }

      // 确保有 noise 的 import，并记录插入导致的偏移量
      final originalLength = content.length;
      content = _ensureRuntimeImport(content, entry.key);
      final importShift = content.length - originalLength;

      // 按 bodyOffset 倒序注入，避免偏移变化
      final sorted = [...entry.value]..sort((a, b) => b.bodyOffset.compareTo(a.bodyOffset));

      for (final t in sorted) {
        content = _injectRuntimeCall(
          content,
          t.bodyOffset + importShift,
          t.methodName,
          bodyEnd: t.bodyEnd != null ? t.bodyEnd! + importShift : null,
        );
      }

      File(entry.key).writeAsStringSync(content);
      logger.debug('注入 ${entry.value.length} 处: ${path.basename(entry.key)}');
    }

    logger.success('业务噪音注入完成: ${toInject.length} 处');
  }

  bool _shouldSkipFile(String filePath) {
    if (path.split(filePath).any((s) => s == '_internal')) return true;
    final name = path.basename(filePath);
    if (name.endsWith('.g.dart') || name.endsWith('.freezed.dart')) return true;
    return false;
  }

  String _generateRuntimeClass(String seed) {
    return '''
// Generated. Seed: $seed

class RuntimeInit {
  static int _n = 0;
  static void run() {
    _n = (_n + 1) % 0x7FFFFFFF;
    if (_n < 0) _n = 0;
  }
}
''';
  }

  String _ensureRuntimeImport(String content, String filePath) {
    final importLine = _relativeImportToRuntime(filePath);
    if (content.contains('part_runtime')) return content;

    final lines = content.split('\n');
    var lastImportIdx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('import ')) {
        lastImportIdx = i;
      }
    }

    if (lastImportIdx >= 0) {
      // 多行 import（如 conditional import）需在完整语句结束后插入
      var insertAfterIdx = lastImportIdx;
      for (var i = lastImportIdx; i < lines.length; i++) {
        if (lines[i].contains(';')) {
          insertAfterIdx = i;
          break;
        }
      }
      lines.insert(insertAfterIdx + 1, importLine);
      return lines.join('\n');
    }
    return importLine + '\n\n' + content;
  }

  String _relativeImportToRuntime(String filePath) {
    final runtimePath = path.absolute(path.join(config.targetDir, '_internal', 'part_runtime.dart'));
    final fromDir = path.absolute(path.dirname(filePath));
    final rel = path.relative(runtimePath, from: fromDir).replaceAll('\\', '/');
    return "import '$rel';";
  }

  /// 向后扫描找到第一个 {
  int _scanForBrace(String content, int startOffset, {int maxScan = 80}) {
    final end = (startOffset + maxScan).clamp(0, content.length);
    for (var i = startOffset; i < end; i++) {
      if (content[i] == '{') return i;
    }
    return -1;
  }

  /// 排除类体/mixin体 {：方法体前必为 )，类体 extends X> {、mixin with X { 前为 > 或标识符
  /// 但 async/sync[*] { 是函数体，=> { 是 Set/Map 字面量，均不算类体
  bool _isLikelyClassBody(String content, int braceIdx) {
    if (braceIdx <= 0) return false;
    var i = braceIdx - 1;
    while (i >= 0 && (content[i] == ' ' || content[i] == '\t' || content[i] == '\n')) i--;
    if (i < 0) return true;
    final c = content.codeUnitAt(i);
    if (c == 0x3e) {  // '>'
      return !(i > 0 && content.codeUnitAt(i - 1) == 0x3d);  // '=>' 不是类体
    }
    if (c == 0x2a) return false;  // '*' — async*/sync* 函数体
    if ((c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || c == 0x5f) {
      final wordEnd = i + 1;
      while (i >= 0 && ((content.codeUnitAt(i) >= 0x61 && content.codeUnitAt(i) <= 0x7a) ||
                         (content.codeUnitAt(i) >= 0x41 && content.codeUnitAt(i) <= 0x5a) ||
                         content.codeUnitAt(i) == 0x5f ||
                         (content.codeUnitAt(i) >= 0x30 && content.codeUnitAt(i) <= 0x39))) {
        i--;
      }
      final word = content.substring(i + 1, wordEnd);
      return word != 'async' && word != 'sync';
    }
    return false;
  }

  /// 排除 Map/Set 字面量的 {：Var x = { 或 Map y = { 中 { 前为 =
  /// 误注入会导致 { expr; } 变为 Set，赋值给 Map 报错
  bool _isCollectionLiteralBrace(String content, int braceIdx) {
    if (braceIdx <= 0) return false;
    var i = braceIdx - 1;
    while (i >= 0 && (content[i] == ' ' || content[i] == '\t' || content[i] == '\n')) i--;
    if (i < 0) return false;
    return content[i] == '=' || content[i] == ':';  // = { 或 : { (map entry)
  }

  /// 排除 => { ... } 内部嵌套的 { }
  bool _isInsideArrowExpression(String content, int braceIdx) {
    var depth = 0;
    for (var i = braceIdx - 1; i >= 1; i--) {
      final c = content.codeUnitAt(i);
      if (c == 0x7d) {
        depth++;
      } else if (c == 0x7b) {
        if (depth == 0) {
          var j = i - 1;
          while (j >= 0 && (content[j] == ' ' || content[j] == '\t' || content[j] == '\n' || content[j] == '\r')) j--;
          return j >= 1 && content.codeUnitAt(j) == 0x3e && content.codeUnitAt(j - 1) == 0x3d;
        }
        depth--;
      }
    }
    return false;
  }

  /// 最终校验：插入位置后紧跟 case/default 说明在 switch 内，跳过
  bool _wouldInjectBeforeCaseOrDefault(String content, int pos) {
    if (pos < 0 || pos >= content.length) return false;
    var i = pos;
    while (i < content.length && (content.codeUnitAt(i) == 0x20 || content.codeUnitAt(i) == 0x09 || content.codeUnitAt(i) == 0x0a || content.codeUnitAt(i) == 0x0d)) i++;
    if (i + 5 > content.length) return false;
    return content.startsWith('case ', i) || content.startsWith('default ', i);
  }

  /// 排除 switch 块的 {：switch(expr) { 中误注入会破坏 case 结构
  bool _isSwitchBlockBrace(String content, int braceIdx) {
    if (braceIdx < 8) return false;
    var i = braceIdx - 1;
    while (i >= 0 && (content.codeUnitAt(i) == 0x20 || content.codeUnitAt(i) == 0x09 || content.codeUnitAt(i) == 0x0a || content.codeUnitAt(i) == 0x0d)) i--;
    if (i < 0 || content.codeUnitAt(i) != 0x29) return false;
    i--;
    var depth = 1;
    while (i >= 6 && depth > 0) {
      final c = content.codeUnitAt(i);
      if (c == 0x29) depth++;
      else if (c == 0x28) depth--;
      i--;
    }
    if (i < 5) return false;
    return i >= 6 && content.substring(i - 6, i) == 'switch';
  }

  /// 排除命名参数的 {：foo(int a, {int? b}) 中 { 前为 , 或 (
  bool _isNamedParamBrace(String content, int braceIdx) {
    if (braceIdx <= 0) return false;
    var i = braceIdx - 1;
    while (i >= 0 && (content[i] == ' ' || content[i] == '\t' || content[i] == '\n')) i--;
    if (i < 0) return false;
    return content[i] == ',' || content[i] == '(';
  }

  /// AST 为主、正则兜底：优先 leftBracket，失效时向后扫描找 {
  String _injectRuntimeCall(String content, int bodyOffset, String methodName, {int? bodyEnd}) {
    int braceIdx = -1;
    if (bodyOffset >= 0 && bodyOffset < content.length && content[bodyOffset] == '{') {
      braceIdx = bodyOffset;
    } else {
      braceIdx = _scanForBrace(content, bodyOffset.clamp(0, content.length));
    }
    if (braceIdx >= 0 &&
        !_isLikelyClassBody(content, braceIdx) &&
        !_isCollectionLiteralBrace(content, braceIdx) &&
        !_isInsideArrowExpression(content, braceIdx) &&
        !_isSwitchBlockBrace(content, braceIdx) &&
        !_isNamedParamBrace(content, braceIdx) &&
        !_wouldInjectBeforeCaseOrDefault(content, braceIdx + 1)) {
      final insertPos = _pickNoiseInsertPosition(
        content, braceIdx + 1, bodyEnd ?? -1,
      );
      return content.substring(0, insertPos) +
          'RuntimeInit.run(); ' +
          content.substring(insertPos);
    }
    final pattern = _methodDeclarationPattern(methodName);
    final matches = pattern.allMatches(content).toList();
    if (matches.isEmpty) return content;
    final nearest = matches.reduce((a, b) {
      final da = (a.end - bodyOffset).abs();
      final db = (b.end - bodyOffset).abs();
      return da <= db ? a : b;
    });
    final pos = nearest.end;
    if (_wouldInjectBeforeCaseOrDefault(content, pos)) return content;
    return content.substring(0, pos) + 'RuntimeInit.run(); ' + content.substring(pos);
  }

  /// 插入点：目前仅方法开头，中间/结尾需解析避免插入到字符串等，暂不实现
  int _pickNoiseInsertPosition(String content, int bodyStart, int bodyEnd) {
    return bodyStart;
  }

  /// 严格匹配方法声明，避免误插到字段/方法调用
  /// 使用 \b 词边界，防止 builder/buildSomething 等被误匹配
  RegExp _methodDeclarationPattern(String name) {
    final esc = RegExp.escape(name);
    final prefix = r'(?:^|\n|[;}]\s*)(?:@override\s*)?\s*';
    final suffix = r'\)\s*\{';
    late RegExp p;
    switch (name) {
      case 'build':
        p = RegExp(prefix + r'\bWidget\s+' + esc + r'\s*\([\s\S]*?' + suffix);
        break;
      case 'initState':
        p = RegExp(prefix + r'\bvoid\s+' + esc + r'\s*\([\s\S]*?' + suffix);
        break;
      case 'getHomePage':
        p = RegExp(prefix + r'\b(?:static\s+)?Widget\s+' + esc + r'\s*\([\s\S]*?' + suffix);
        break;
      default:
        const typePattern = r'(?:void|dynamic|(?!switch\b|if\b|for\b|while\b|catch\b|else\b|do\b|try\b)[A-Za-z_][A-Za-z0-9_<>, \?]*)';
        p = RegExp(prefix + r'\b' + typePattern + r'\s+' + esc + r'\s*\([\s\S]*?' + suffix);
    }
    return p;
  }
}

class _InjectionTarget {
  final String filePath;
  final String methodName;
  final int bodyOffset;
  final int? bodyEnd;

  _InjectionTarget({
    required this.filePath,
    required this.methodName,
    required this.bodyOffset,
    this.bodyEnd,
  });
}

class _NoiseMethodCollector extends RecursiveAstVisitor<void> {
  final List<_NoiseMethodInfo> methods = [];

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.isGetter || node.isSetter || node.isAbstract) return;

    final body = node.body;
    if (body is! BlockFunctionBody) return;

    methods.add(_NoiseMethodInfo(
      node.name.lexeme,
      body.block.leftBracket.offset,
      body.block.rightBracket.offset,
    ));
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final body = node.functionExpression.body;
    if (body is! BlockFunctionBody) return;

    methods.add(_NoiseMethodInfo(
      node.name.lexeme,
      body.block.leftBracket.offset,
      body.block.rightBracket.offset,
    ));
    super.visitFunctionDeclaration(node);
  }
}

class _NoiseMethodInfo {
  final String name;
  final int bodyOffset;
  final int bodyEnd;

  _NoiseMethodInfo(this.name, this.bodyOffset, this.bodyEnd);
}
