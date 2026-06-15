import 'dart:io';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as path;

import 'config.dart';
import 'visitors/string_obfuscator.dart';
import 'visitors/route_obfuscator.dart';
import 'visitors/callstack_obfuscator.dart';
import 'visitors/bloat_inflator.dart';
import 'visitors/business_noise_injector.dart';
import 'visitors/ast_mutation_obfuscator.dart';
import 'visitors/symbol_distorter.dart';
import 'utils/logger.dart';

/// B面代码混淆器
///
/// 使用 Dart analyzer 进行 AST 分析，实现精确的代码混淆
class Obfuscator {
  final ObfuscatorConfig config;
  final Logger _logger;

  late AnalysisContextCollection _contextCollection;

  Obfuscator(this.config) : _logger = Logger(verbose: config.verbose);

  /// 运行混淆
  Future<void> run() async {
    _logger.banner('B面代码混淆工具');

    if (config.projectName != null) {
      _logger.info('项目: ${config.projectName}');
    }
    _logger.info('目标目录: ${config.targetDir}');
    _logger.info('');
    _logger.info('混淆功能:');
    _logger.info(
        '  字符串混淆: ${config.enableString ? "✓ 启用 (${config.stringMethod})" : "✗ 禁用"}');
    _logger.info(
        '  调用栈混淆: ${config.enableCallstack ? "✓ 启用 (深度: ${config.callStackDepth})" : "✗ 禁用"}');
    _logger.info('  文件膨胀: ${config.enableBloat ? "✓ 启用 (4.3a 差异化)" : "✗ 禁用"}');
    _logger.info('  业务噪音: ${config.enableNoise ? "✓ 启用" : "✗ 禁用"}');
    _logger.info('  AST 变异: ${config.enableMutation ? "✓ 启用" : "✗ 禁用"}');
    _logger.info('  符号扭曲: ${config.enableSymbolDistort ? "✓ 启用" : "✗ 禁用"}');
    if (config.dryRun) {
      _logger.warning('模拟运行模式');
    }
    _logger.info('');

    final stopwatch = Stopwatch()..start();

    // 初始化分析上下文
    await _initAnalysisContext();

    // 收集要处理的文件
    final dartFiles = await _collectDartFiles();
    _logger.info('找到 ${dartFiles.length} 个 Dart 文件');

    // 执行混淆（每步前重建分析上下文，确保 AST offset 与磁盘文件一致）
    if (config.enableString) {
      await _runStringObfuscation(dartFiles);
    }

    if (config.enableCallstack) {
      await _reinitAnalysisContext();
      await _runCallstackObfuscation(dartFiles);
    }

    if (config.enableBloat) {
      await _reinitAnalysisContext();
      await _runBloatInflation(dartFiles);
    }

    if (config.enableNoise) {
      await _reinitAnalysisContext();
      await _runNoiseInjection(dartFiles);
    }

    if (config.enableMutation) {
      await _reinitAnalysisContext();
      await _runASTMutation(dartFiles);
    }

    if (config.enableSymbolDistort) {
      await _reinitAnalysisContext();
      await _runSymbolDistortion(dartFiles);
    }

    stopwatch.stop();

    _logger.banner('混淆完成！耗时: ${stopwatch.elapsed.inSeconds}s');
    _logger.info('');
    _logger.info('后续步骤:');
    _logger.info('  1. 运行 fvm flutter analyze ${config.targetDir}');
    _logger.info(
        '  2. 运行 flutter build ipa --release --obfuscate --split-debug-info=build/symbols');
  }

  /// 初始化分析上下文
  Future<void> _initAnalysisContext() async {
    _logger.step('初始化 Dart 分析器...');

    final absolutePath = path.normalize(path.absolute(config.targetDir));

    _contextCollection = AnalysisContextCollection(
      includedPaths: [absolutePath],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
    );

    _logger.debug('分析上下文已创建');
  }

  /// 收集所有 Dart 文件
  Future<List<String>> _collectDartFiles() async {
    final files = <String>[];
    final dir = Directory(config.targetDir);

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        // 检查是否应该排除
        final fileName = path.basename(entity.path);
        final shouldExclude = config.excludeFilePatterns
            .any((pattern) => fileName.contains(pattern));

        if (!shouldExclude) {
          files.add(entity.path);
        }
      }
    }

    return files;
  }

  /// 运行字符串混淆（含路由混淆）
  Future<void> _runStringObfuscation(List<String> files) async {
    _logger.step('执行字符串混淆 (方法: ${config.stringMethod})...');

    // 1. 先进行路由混淆（使用简单字符串替换，不影响 AST offset）
    final routeObfuscator = RouteObfuscator(config, _logger);
    await routeObfuscator.process(files, _contextCollection);

    // 2. 路由混淆修改了文件，需要重新初始化 analyzer 上下文
    //    否则字符串混淆使用的 AST offset 会与实际文件内容不匹配
    await _reinitAnalysisContext();

    // 3. 再进行普通字符串混淆
    final stringObfuscator = StringObfuscator(config, _logger);
    await stringObfuscator.process(files, _contextCollection);

    _logger.info('');
  }

  /// 重新初始化分析上下文（清除缓存）
  Future<void> _reinitAnalysisContext() async {
    _logger.debug('重新初始化分析上下文...');

    final absolutePath = path.normalize(path.absolute(config.targetDir));

    // 创建新的 AnalysisContextCollection 会使用最新的文件内容
    _contextCollection = AnalysisContextCollection(
      includedPaths: [absolutePath],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
    );
  }

  /// 运行调用栈混淆
  Future<void> _runCallstackObfuscation(List<String> files) async {
    _logger.step('执行调用栈混淆 (深度: ${config.callStackDepth})...');

    final obfuscator = CallstackObfuscator(config, _logger);
    await obfuscator.process(files, _contextCollection);

    _logger.info('');
  }

  /// 运行文件膨胀（4.3a 差异化）
  Future<void> _runBloatInflation(List<String> files) async {
    final inflator = BloatInflator(config, _logger);
    await inflator.process(files, _contextCollection);

    _logger.info('');
  }

  /// 运行业务噪音注入
  Future<void> _runNoiseInjection(List<String> files) async {
    final injector = BusinessNoiseInjector(config, _logger);
    await injector.process(files, _contextCollection);

    _logger.info('');
  }

  /// 运行 AST 变异
  Future<void> _runASTMutation(List<String> files) async {
    final mutator = ASTMutationObfuscator(config, _logger);
    await mutator.process(files, _contextCollection);

    _logger.info('');
  }

  /// 运行符号扭曲
  Future<void> _runSymbolDistortion(List<String> files) async {
    final distorter = SymbolDistorter(config, _logger);
    await distorter.process(files, _contextCollection);

    _logger.info('');
  }
}
