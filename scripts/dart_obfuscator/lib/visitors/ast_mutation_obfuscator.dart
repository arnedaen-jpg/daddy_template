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

/// AST 变异混淆器
///
/// 修改已有函数，在方法体开头插入 dummy 代码（无效但难优化），
/// 增加控制流复杂度与二进制差异。
class ASTMutationObfuscator {
  ASTMutationObfuscator(this.config, this.logger);

  final ObfuscatorConfig config;
  final Logger logger;
  late final Random _random;

  /// 注入概率 (0.3 ~ 0.6)
  static const _minRate = 0.3;
  static const _maxRate = 0.6;

  /// 随机生成 dummy 代码，避免固定 pattern（如 identical(1,1)）被 ML 识别
  String _randomDummySnippet() {
    switch (_random.nextInt(8)) {
      case 0:
        return 'try { } catch (_) { }';
      case 1:
        return 'for (var __ = DateTime.now().millisecond; __ < 0; __++) { }';
      case 2:
        return 'for (var __ = 0; __ < 0; __++) { }';
      case 3:
        switch (_random.nextInt(3)) {
          case 0:
            return 'if (DateTime.now().millisecond < 0) { }';
          case 1:
            return 'if (DateTime.now().microsecond < 0) { }';
          case 2:
            return 'if (DateTime.now().millisecondsSinceEpoch < 0) { }';
          default:
            return 'if (1 > 2) { }';
        }
      case 4:
        return 'if (1 > 2) { }';  // 原 switch 易与嵌套注入冲突破坏 case 结构
      case 5:
        return 'assert(true);';
      case 6:
        return 'do { } while (false);';
      default:
        return 'if (1 > 2) { }';
    }
  }

  Future<void> process(
    List<String> files,
    AnalysisContextCollection collection,
  ) async {
    logger.step('AST 变异 (插入 dummy 代码)...');

    final seedBase = config.seedBase;
    _random = Random(seedBase != null ? seedBase.hashCode : (DateTime.now().millisecondsSinceEpoch + (config.projectName?.hashCode ?? 0)));

    if (config.dryRun) {
      logger.info('[DRY-RUN] 将在方法体中插入 dummy 代码');
      return;
    }

    var totalFiles = 0;
    var totalInjections = 0;

    for (final file in files) {
      if (_shouldSkipFile(file)) continue;

      try {
        final context = collection.contextFor(file);
        final result = await context.currentSession.getResolvedUnit(file);

        if (result is! ResolvedUnitResult) continue;

        final visitor = _MutationMethodCollector();
        result.unit.accept(visitor);

        if (visitor.methods.isEmpty) continue;

        final rate =
            _minRate + _random.nextDouble() * (_maxRate - _minRate);
        final toMutate = visitor.methods.where((m) {
          return NameGenerator.shouldInject(
            '${config.projectName ?? "x"}_${seedBase ?? ""}_mut_${path.basename(file)}_${m.name}',
            rate,
          );
        }).toList();

        if (toMutate.isEmpty) continue;

        var content = File(file).readAsStringSync();

        // 先计算所有插入点（使用原始 content），再按 actualPos 倒序插入，
        // 避免嵌套方法时：先插入内层导致 content 偏移，外层再用旧 offset 错位（如破坏 return）
        final toApply = <({int pos, String snippet})>[];
        for (final m in toMutate) {
          int insertPos = -1;
          int braceIdx = -1;
          if (m.bodyOffset >= 0 && m.bodyOffset < content.length && content[m.bodyOffset] == '{') {
            braceIdx = m.bodyOffset;
          } else {
            braceIdx = _scanForBrace(content, m.bodyOffset.clamp(0, content.length));
          }
          if (braceIdx >= 0 &&
              !_isLikelyClassBody(content, braceIdx) &&
              !_isCollectionLiteralBrace(content, braceIdx) &&
              !_isInsideArrowExpression(content, braceIdx) &&
              !_isSwitchBlockBrace(content, braceIdx) &&
              !_isNamedParamBrace(content, braceIdx)) {
            insertPos = braceIdx + 1;
          } else {
            final pattern = _methodDeclarationPattern(m.name);
            final matches = pattern.allMatches(content).toList();
            if (matches.isEmpty) {
              logger.debug('跳过变异 ${m.name}: 无法定位方法体');
              continue;
            }
            final nearest = matches.reduce((a, b) {
              final da = (a.end - m.bodyOffset).abs();
              final db = (b.end - m.bodyOffset).abs();
              return da <= db ? a : b;
            });
            insertPos = nearest.end;
          }
          if (insertPos < 0) continue;
          final actualPos = _pickMutationInsertPosition(
            content, insertPos, m.bodyEnd, m.firstStatementEnd,
          );
          if (_wouldInjectBeforeCaseOrDefault(content, actualPos)) continue;
          final snippet = _randomDummySnippet();
          toApply.add((pos: actualPos, snippet: snippet));
        }

        // 按插入位置倒序，确保从后往前插入不改变未处理段的偏移
        toApply.sort((a, b) => b.pos.compareTo(a.pos));
        for (final e in toApply) {
          content = content.substring(0, e.pos) + '${e.snippet} ' + content.substring(e.pos);
          totalInjections++;
        }

        File(file).writeAsStringSync(content);
        totalFiles++;
        logger.debug('变异 ${toMutate.length} 个方法: ${path.basename(file)}');
      } catch (e) {
        logger.debug('跳过 ${path.basename(file)}: $e');
      }
    }

    logger.success('AST 变异完成: $totalFiles 个文件, $totalInjections 处');
  }

  bool _shouldSkipFile(String filePath) {
    if (path.split(filePath).any((s) => s == '_internal')) return true;
    final name = path.basename(filePath);
    if (name.endsWith('.g.dart') || name.endsWith('.freezed.dart')) return true;
    return false;
  }

  /// 排除类体/mixin体 {：方法体前必为 )，类体/mixin 前为 > 或标识符
  /// 但 async/sync[*] { 是函数体，=> { 是 Set/Map 字面量，均不算类体
  bool _isLikelyClassBody(String content, int braceIdx) {
    if (braceIdx <= 0) return false;
    var i = braceIdx - 1;
    while (i >= 0 && (content[i] == ' ' || content[i] == '\t' || content[i] == '\n')) i--;
    if (i < 0) return true;
    final c = content.codeUnitAt(i);
    if (c == 0x3e) {  // '>'
      // '=>' 是箭头函数，{ 是 Set/Map 字面量，不是类体
      return !(i > 0 && content.codeUnitAt(i - 1) == 0x3d);
    }
    if (c == 0x2a) return false;  // '*' — async*/sync* 函数体
    if ((c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || c == 0x5f) {
      // 提取完整单词，排除 async/sync 关键字
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

  /// 排除 Map/Set 字面量的 {：Var x = { 中 { 前为 =，误注入会导致 Set 赋给 Map 报错
  bool _isCollectionLiteralBrace(String content, int braceIdx) {
    if (braceIdx <= 0) return false;
    var i = braceIdx - 1;
    while (i >= 0 && (content[i] == ' ' || content[i] == '\t' || content[i] == '\n')) i--;
    if (i < 0) return false;
    return content[i] == '=' || content[i] == ':';
  }

  /// 排除 => { ... } 内部嵌套的 { }：
  /// 箭头函数返回 Set/Map 字面量，内部所有 { } 都是集合上下文，不能注入语句
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

  /// 排除命名参数的 {：foo(int a, {int? b}) 中 { 前为 , 或 (
  bool _isNamedParamBrace(String content, int braceIdx) {
    if (braceIdx <= 0) return false;
    var i = braceIdx - 1;
    while (i >= 0 && (content[i] == ' ' || content[i] == '\t' || content[i] == '\n')) i--;
    if (i < 0) return false;
    return content[i] == ',' || content[i] == '(';
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

  /// 随机插入位置：开始 60%、中间 20%、结束 20%
  /// 使用 AST 的 firstStatementEnd 作为中间插入点，避免 for 循环、无括号 if-else 的语法错误
  int _pickMutationInsertPosition(String content, int bodyStart, int bodyEnd, int firstStatementEnd) {
    if (bodyEnd <= bodyStart || bodyEnd > content.length) return bodyStart;
    final len = bodyEnd - bodyStart;
    if (len < 30) return bodyStart;

    final r = _random.nextDouble();
    if (r < 0.6) return bodyStart;

    if (r < 0.8) {
      // 中间：插入到第一个「顶层语句」之后，由 AST 提供，避免误入 for/if-else 内部
      if (firstStatementEnd > bodyStart && firstStatementEnd < bodyEnd - 2) {
        var pos = firstStatementEnd;
        while (pos < content.length && pos < bodyEnd &&
            (content[pos] == ' ' || content[pos] == '\t' ||
                content[pos] == '\n' || content[pos] == '\r')) {
          pos++;
        }
        if (pos < bodyEnd) return pos;
      }
      return bodyStart;
    }

    // 结束：插入到方法体末尾 } 之前
    return bodyEnd;
  }

  /// 向后扫描找到第一个 {，bodyOffset 有时指向 async 而非 {
  int _scanForBrace(String content, int startOffset, {int maxScan = 80}) {
    final end = (startOffset + maxScan).clamp(0, content.length);
    for (var i = startOffset; i < end; i++) {
      if (content[i] == '{') return i;
    }
    return -1;
  }

  /// 严格匹配方法声明，排除 switch/if/for/while/catch/else/do/try
  /// 返回类型放宽：Future<void>, List<int>, Map<K,V> 等
  RegExp _methodDeclarationPattern(String name) {
    final esc = RegExp.escape(name);
    const prefix = r'(?:^|\n|[;}]\s*)(?:@override\s*)?\s*';
    const suffix = r'\)\s*\{';
    const typePattern = r'(?:void|dynamic|(?!switch\b|if\b|for\b|while\b|catch\b|else\b|do\b|try\b)[A-Za-z_][A-Za-z0-9_<>, \?]*)';
    return RegExp(prefix + r'\b' + typePattern + r'\s+' + esc + r'\s*\([\s\S]*?' + suffix);
  }
}

class _MutationMethodCollector extends RecursiveAstVisitor<void> {
  final List<_MutationMethodInfo> methods = [];

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.isGetter || node.isSetter || node.isAbstract) return;

    final body = node.body;
    if (body is! BlockFunctionBody) return;

    final inner = body.block.statements;
    if (inner.isEmpty) return;

    final stmts = body.block.statements;
    final firstEnd = stmts.isNotEmpty ? stmts.first.end : body.block.rightBracket.offset;
    methods.add(_MutationMethodInfo(
      node.name.lexeme,
      body.block.leftBracket.offset,
      body.block.rightBracket.offset,
      firstStatementEnd: firstEnd,
    ));
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final body = node.functionExpression.body;
    if (body is! BlockFunctionBody) return;

    if (body.block.statements.isEmpty) return;

    final stmts = body.block.statements;
    final firstEnd = stmts.isNotEmpty ? stmts.first.end : body.block.rightBracket.offset;
    methods.add(_MutationMethodInfo(
      node.name.lexeme,
      body.block.leftBracket.offset,
      body.block.rightBracket.offset,
      firstStatementEnd: firstEnd,
    ));
    super.visitFunctionDeclaration(node);
  }
}

class _MutationMethodInfo {
  final String name;
  final int bodyOffset;
  final int bodyEnd;
  final int firstStatementEnd;

  _MutationMethodInfo(this.name, this.bodyOffset, this.bodyEnd, {required this.firstStatementEnd});
}
