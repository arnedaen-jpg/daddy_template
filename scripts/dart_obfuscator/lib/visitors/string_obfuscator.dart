import 'dart:io';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as path;

import '../config.dart';
import '../utils/logger.dart';
import '../utils/encoders.dart';

/// 字符串混淆器
///
/// 使用 AST 分析精确识别可混淆的字符串字面量
class StringObfuscator {
  final ObfuscatorConfig config;
  final Logger logger;

  StringObfuscator(this.config, this.logger);

  Future<void> process(
      List<String> files, AnalysisContextCollection collection) async {
    logger.step('字符串混淆 (方法: ${config.stringMethod})...');

    var totalFiles = 0;
    var totalStrings = 0;
    final report = StringBuffer();
    final skipReasonCounts = <String, int>{};
    var totalSkipped = 0;
    var skippedFiles = <String>[];

    for (final file in files) {
      final fileName = path.basename(file);
      if (_shouldSkipFile(fileName) || _shouldSkipPath(file)) {
        skippedFiles.add(fileName);
        continue;
      }

      try {
        final context = collection.contextFor(file);
        final result = await context.currentSession.getResolvedUnit(file);

        if (result is! ResolvedUnitResult) {
          continue;
        }

        final visitor = _StringCollector(config);
        result.unit.accept(visitor);

        final lineInfo = result.lineInfo;
        final relPath = _relativePath(file);

        // 记录跳过的字符串
        for (final s in visitor.skippedStrings) {
          skipReasonCounts[s.reason] = (skipReasonCounts[s.reason] ?? 0) + 1;
        }
        totalSkipped += visitor.skippedStrings.length;

        if (visitor.sensitiveStrings.isEmpty &&
            visitor.skippedStrings.isEmpty) {
          continue;
        }

        // 写入报告 —— 按文件分组
        if (visitor.sensitiveStrings.isNotEmpty ||
            visitor.skippedStrings.isNotEmpty) {
          report.writeln('\n## $relPath');
          report.writeln(
              '  混淆: ${visitor.sensitiveStrings.length}  跳过: ${visitor.skippedStrings.length}');

          for (final s in visitor.sensitiveStrings) {
            final line = lineInfo.getLocation(s.offset).lineNumber;
            final display = _truncate(s.value, 60);
            report.writeln('  [混淆] L$line: $display');
          }
          for (final s in visitor.skippedStrings) {
            final line = lineInfo.getLocation(s.offset).lineNumber;
            final display = _truncate(s.value, 60);
            report.writeln('  [跳过:${s.reason}] L$line: $display');
          }
        }

        if (visitor.sensitiveStrings.isEmpty) {
          continue;
        }

        if (config.dryRun) {
          totalFiles++;
          totalStrings += visitor.sensitiveStrings.length;
          continue;
        }

        // 执行替换 - 按 offset 倒序处理
        final content = File(file).readAsStringSync();
        var newContent = content;

        final sortedStrings = [...visitor.sensitiveStrings]
          ..sort((a, b) => b.offset.compareTo(a.offset));

        for (final stringInfo in sortedStrings) {
          if (stringInfo.isRawString) {
            continue;
          }

          final obfuscated = StringEncoders.generateObfuscatedCode(
            stringInfo.value,
            config.stringMethod,
            xorKey: config.xorKey,
          );

          final commentValue = stringInfo.value
              .replaceAll('/*', '/\\*')
              .replaceAll('*/', '*\\/')
              .replaceAll('\n', '\\n');
          final replacement = '$obfuscated /* $commentValue */';

          final originalLength = stringInfo.lexemeLength;
          final startOffset = stringInfo.offset;
          final endOffset = startOffset + originalLength;

          if (startOffset >= 0 && endOffset <= newContent.length) {
            newContent = newContent.substring(0, startOffset) +
                replacement +
                newContent.substring(endOffset);
          }
        }

        if (newContent != content) {
          File(file).writeAsStringSync(newContent);
          totalFiles++;
          totalStrings += visitor.sensitiveStrings.length;
          logger.debug(
              '混淆 ${visitor.sensitiveStrings.length} 个字符串: ${path.basename(file)}');
        }
      } catch (e) {
        logger.debug('跳过文件 ${path.basename(file)}: $e');
      }
    }

    if (config.dryRun) {
      logger.info('[DRY-RUN] 将处理 $totalFiles 个文件，$totalStrings 个字符串');
    } else {
      logger.success('字符串混淆完成: $totalFiles 个文件, $totalStrings 个字符串');
    }

    // 写入报告文件
    _writeReport(report, totalFiles, totalStrings, totalSkipped,
        skipReasonCounts, skippedFiles, files.length);
  }

  String _relativePath(String filePath) {
    final targetDir = config.targetDir;
    if (filePath.startsWith(targetDir)) {
      return filePath.substring(targetDir.length + 1);
    }
    return path.basename(filePath);
  }

  String _truncate(String value, int maxLen) {
    final escaped = value.replaceAll('\n', '\\n').replaceAll('\r', '');
    if (escaped.length <= maxLen) return escaped;
    return '${escaped.substring(0, maxLen)}...';
  }

  void _writeReport(
    StringBuffer fileDetails,
    int totalFiles,
    int totalStrings,
    int totalSkipped,
    Map<String, int> skipReasonCounts,
    List<String> skippedFiles,
    int totalFileCount,
  ) {
    final projectName = config.projectName ?? 'default';
    final reportOverride =
        Platform.environment['DART_STRING_OBFUSCATION_REPORT'];
    final reportFile = File(reportOverride != null && reportOverride.isNotEmpty
        ? reportOverride
        : 'build/string_obfuscation_report_$projectName.txt');
    reportFile.parent.createSync(recursive: true);

    final buf = StringBuffer();
    buf.writeln('# 字符串混淆报告');
    buf.writeln('# 项目: $projectName');
    buf.writeln('# 时间: ${DateTime.now()}');
    buf.writeln('# 方法: ${config.stringMethod}');
    buf.writeln('# 模式: ${config.dryRun ? "DRY-RUN" : "实际执行"}');
    buf.writeln('');
    buf.writeln('## 统计');
    buf.writeln('  扫描文件总数: $totalFileCount');
    buf.writeln('  混淆文件数:   $totalFiles');
    buf.writeln('  跳过文件数:   ${skippedFiles.length}');
    buf.writeln('  混淆字符串:   $totalStrings');
    buf.writeln('  跳过字符串:   $totalSkipped');
    buf.writeln('');
    buf.writeln('## 跳过原因统计');
    final sortedReasons = skipReasonCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sortedReasons) {
      buf.writeln('  ${e.key}: ${e.value}');
    }
    buf.writeln('');
    buf.writeln('## 跳过的文件 (文件级规则)');
    for (final f in skippedFiles) {
      buf.writeln('  $f');
    }
    buf.writeln('');
    buf.writeln('## 按文件详情');
    buf.write(fileDetails);

    reportFile.writeAsStringSync(buf.toString());
    logger.info('混淆报告: ${reportFile.path}');
  }

  bool _shouldSkipFile(String fileName) {
    // 跳过生成文件和特定配置文件
    final skipPatterns = [
      '.g.dart',
      '.freezed.dart',
      '.pb.dart',
      '.pbenum.dart',
      '.pbjson.dart',
      '.pbgrpc.dart',
      'api_const.dart',
      '_const.dart',
      '_constants.dart',
      '_enum.dart',
      'enum.dart', // 枚举定义文件
      'routes_register.dart', // 路由注册（大量 const）
      'storage_service.dart', // 存储服务（大量 const）
    ];

    if (skipPatterns.any((p) => fileName.contains(p))) {
      return true;
    }

    // 跳过 model 文件（通常使用 @Freezed/@JsonSerializable 注解）
    if (fileName.endsWith('_model.dart') || fileName.endsWith('_models.dart')) {
      return true;
    }

    // 跳过 domain/model/ 目录下的文件（Freezed 模型）
    return false;
  }

  bool _shouldSkipPath(String filePath) {
    // 跳过 domain/model/ 目录（通常全是 Freezed 模型）
    if (filePath.contains('/domain/model/')) {
      return true;
    }
    return false;
  }
}

/// 字符串信息
class _StringInfo {
  final String value;
  final int offset;
  final bool hasDoubleQuote;
  final bool isRawString;
  final int lexemeLength;

  _StringInfo(this.value, this.offset, this.hasDoubleQuote, this.lexemeLength,
      {this.isRawString = false});
}

/// 跳过的字符串信息
class _SkippedInfo {
  final String value;
  final int offset;
  final String reason;

  _SkippedInfo(this.value, this.offset, this.reason);
}

/// 字符串收集器
class _StringCollector extends RecursiveAstVisitor<void> {
  final ObfuscatorConfig config;
  final List<_StringInfo> sensitiveStrings = [];
  final List<_SkippedInfo> skippedStrings = [];

  bool _inConstContext = false;
  bool _classHasConstConstructor = false;

  _StringCollector(this.config);

  void _skip(SimpleStringLiteral node, String reason) {
    skippedStrings.add(_SkippedInfo(node.value, node.offset, reason));
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    // 检测类是否有 const 构造函数
    final wasHasConstConstructor = _classHasConstConstructor;
    _classHasConstConstructor = node.members
        .any((m) => m is ConstructorDeclaration && m.constKeyword != null);

    super.visitClassDeclaration(node);
    _classHasConstConstructor = wasHasConstConstructor;
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    // static const 字段完全跳过（包括列表内的字符串）
    if (node.isStatic && node.fields.isConst) {
      return; // 完全不处理 static const
    }
    // 非 static 的 const 字段也跳过
    if (node.fields.isConst) {
      return;
    }
    // 如果类有 const 构造函数，final 字段的初始化器必须是 const
    if (_classHasConstConstructor && node.fields.isFinal) {
      return;
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    // 顶层 const 变量必须是常量，跳过
    if (node.variables.isConst) {
      return;
    }
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    // 检查是否是局部 const 变量声明
    final parent = node.parent;
    if (parent is VariableDeclarationList && parent.isConst) {
      return; // 跳过所有 const 变量
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    // const 构造函数的参数默认值必须是常量
    if (node.constKeyword != null) {
      // 跳过 const 构造函数的参数
      // 只访问函数体
      node.body.accept(this);
      return;
    }
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    // 函数参数默认值必须是常量，完全跳过
    // 只访问参数本身，不访问默认值
    node.parameter.accept(this);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    // Enhanced enum values are implicitly const
    final wasInConst = _inConstContext;
    _inConstContext = true;
    super.visitEnumConstantDeclaration(node);
    _inConstContext = wasInConst;
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    // 检查是否是 const 构造函数调用
    final wasInConst = _inConstContext;
    if (node.isConst) {
      _inConstContext = true;
    }
    super.visitInstanceCreationExpression(node);
    _inConstContext = wasInConst;
  }

  @override
  void visitListLiteral(ListLiteral node) {
    // 检查是否是 const 列表
    final wasInConst = _inConstContext;
    if (node.isConst) {
      _inConstContext = true;
    }
    super.visitListLiteral(node);
    _inConstContext = wasInConst;
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    // 检查是否是 const Set/Map
    final wasInConst = _inConstContext;
    if (node.isConst) {
      _inConstContext = true;
    }
    super.visitSetOrMapLiteral(node);
    _inConstContext = wasInConst;
  }

  @override
  void visitAnnotation(Annotation node) {
    // 注解参数必须是常量
  }

  @override
  void visitImportDirective(ImportDirective node) {
    // import URI 必须是字符串字面量，不能替换为表达式
  }

  @override
  void visitExportDirective(ExportDirective node) {}

  @override
  void visitPartDirective(PartDirective node) {}

  @override
  void visitPartOfDirective(PartOfDirective node) {}

  @override
  void visitLibraryDirective(LibraryDirective node) {}

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    // 相邻字符串（如 "a" "b" "c"）完全跳过
    // 混淆其中任何一个都会导致语法错误
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    // 访问 expression
    node.expression.accept(this);
    // 访问每个 case/default 的 statements（跳过 case 标签中的常量值）
    // SwitchMember 是所有 case 类型的基类，包括:
    // - SwitchCase (传统 case)
    // - SwitchPatternCase (Dart 3.0+ pattern matching)
    // - SwitchDefault
    for (final member in node.members) {
      for (final statement in member.statements) {
        statement.accept(this);
      }
    }
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    // 访问 expression
    node.expression.accept(this);
    // 访问每个 case 的 expression（跳过 pattern）
    for (final caseClause in node.cases) {
      caseClause.expression.accept(this);
    }
  }

  @override
  void visitSwitchCase(SwitchCase node) {
    // 跳过 switch case 中的表达式（必须是 const）
    // 只访问 statements
    for (final statement in node.statements) {
      statement.accept(this);
    }
  }

  @override
  void visitSwitchPatternCase(SwitchPatternCase node) {
    // 跳过模式匹配中的表达式
    // 只访问 statements
    for (final statement in node.statements) {
      statement.accept(this);
    }
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    // 跳过常量模式（switch case 中的模式匹配）
  }

  @override
  void visitMapPatternEntry(MapPatternEntry node) {
    // Map pattern 的 key 必须是编译期常量，不能替换为表达式
    // 只访问 value pattern（可能包含嵌套 pattern）
    node.value.accept(this);
  }

  @override
  void visitPatternVariableDeclaration(PatternVariableDeclaration node) {
    // 跳过模式变量声明
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (_inConstContext) {
      _skip(node, 'const_context');
      return;
    }

    final value = node.value;
    final lexeme = node.literal.lexeme;

    final isRawString = lexeme.startsWith("r'") || lexeme.startsWith('r"');
    if (isRawString) {
      _skip(node, 'raw_string');
      return;
    }

    if (value.isEmpty || value.length < config.minStringLength) {
      _skip(node, 'too_short');
      return;
    }

    if (!_containsLetter(value) && !_containsChinese(value)) {
      _skip(node, 'no_letter_or_chinese');
      return;
    }

    if (value.contains(r'$')) {
      _skip(node, 'interpolation');
      return;
    }

    if (_isResourcePath(value)) {
      _skip(node, 'resource_path');
      return;
    }

    if (_isGenericString(value)) {
      _skip(node, 'generic');
      return;
    }

    final hasDoubleQuote = lexeme.startsWith('"');
    sensitiveStrings.add(_StringInfo(
      value,
      node.offset,
      hasDoubleQuote,
      lexeme.length,
      isRawString: isRawString,
    ));

    super.visitSimpleStringLiteral(node);
  }

  bool _containsLetter(String value) {
    return RegExp(r'[a-zA-Z]').hasMatch(value);
  }

  bool _containsChinese(String value) {
    return RegExp(r'[\u4e00-\u9fa5]').hasMatch(value);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    // 跳过字符串插值
  }

  bool _isResourcePath(String value) {
    // package: URI 作为指令跳过的双保险
    return value.startsWith('package:');
  }

  /// 通用编程字符串 —— 任何正常 app 都有的，不构成特征指纹，
  /// 保留它们让二进制字符串分布看起来自然
  bool _isGenericString(String value) {
    // 含中文一定要混淆（业务特征）
    if (_containsChinese(value)) {
      return false;
    }

    // 含 / 的路径/API格式一定要混淆
    if (value.contains('/')) {
      return false;
    }

    // HTTP 方法、标准头、MIME 类型
    const httpTerms = {
      'GET',
      'POST',
      'PUT',
      'DELETE',
      'PATCH',
      'HEAD',
      'OPTIONS',
      'Content-Type',
      'Authorization',
      'Accept',
      'User-Agent',
      'Cache-Control',
      'Connection',
      'Host',
      'Origin',
      'Referer',
      'application/json',
      'application/x-www-form-urlencoded',
      'multipart/form-data',
      'text/plain',
      'text/html',
      'utf-8',
      'UTF-8',
      'charset',
    };
    if (httpTerms.contains(value)) {
      return true;
    }

    // 通用 JSON/数据 key（任何 app 都会有的短字段名）
    const dataKeys = {
      'id',
      'type',
      'name',
      'data',
      'code',
      'msg',
      'message',
      'status',
      'result',
      'error',
      'success',
      'list',
      'info',
      'url',
      'key',
      'value',
      'title',
      'text',
      'image',
      'icon',
      'time',
      'date',
      'page',
      'size',
      'total',
      'count',
      'index',
      'true',
      'false',
      'null',
      'yes',
      'no',
      'ok',
      'OK',
    };
    if (dataKeys.contains(value)) {
      return true;
    }

    // 日期/时间格式模板
    if (RegExp(r'^[yYMdDhHmsSaEZ\s\-:/.,]+$').hasMatch(value)) {
      return true;
    }

    // 纯大写常量风格且较短（如 DEBUG, INFO, WARNING）—— 通用日志级别等
    if (value.length <= 10 && RegExp(r'^[A-Z][A-Z0-9_]+$').hasMatch(value)) {
      return true;
    }

    return false;
  }
}
