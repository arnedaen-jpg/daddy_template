import 'dart:io';
import 'package:path/path.dart' as path;

import '../config.dart';
import '../utils/logger.dart';
import '../utils/name_generator.dart';

/// 符号扭曲器
///
/// 生成 extension、generic、mixin 等高级 Dart 构造，
/// 增加二进制结构复杂度与包间差异化。
class SymbolDistorter {
  SymbolDistorter(this.config, this.logger);

  final ObfuscatorConfig config;
  final Logger logger;

  Future<void> process(
    List<String> files,
    dynamic collection,
  ) async {
    logger.step('符号扭曲 (extension / generic / mixin)...');

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
    final seedBase = config.seedBase;
    final seed = seedBase != null ? '${project}_symbol_$seedBase' : '${project}_symbol_${DateTime.now().millisecondsSinceEpoch}';

    if (config.dryRun) {
      logger.info('[DRY-RUN] 将生成 extension/generic/mixin 代码');
      return;
    }

    const internalDir = '_internal';
    final dir = Directory(path.join(config.targetDir, internalDir));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final filePath = path.join(dir.path, 'part_extensions.dart');
    final content = _generateSymbolBloat(seed);
    File(filePath).writeAsStringSync(content);

    logger.info('生成: part_extensions.dart');

    final mainPath = path.join(dir.path, 'preload.dart');
    if (File(mainPath).existsSync()) {
      var mainContent = File(mainPath).readAsStringSync();
      mainContent = _normalizePreloadAccumulator(mainContent);
      if (!mainContent.contains('part_extensions')) {
        final importMatch = RegExp(r"^(import '[^']+';)", multiLine: true).firstMatch(mainContent);
        if (importMatch != null) {
          mainContent = mainContent.replaceFirst(
            importMatch.group(0)!,
            "${importMatch.group(0)}\nimport 'part_extensions.dart';",
          );
        } else {
          mainContent = "import 'part_extensions.dart';\n$mainContent";
        }
      }
      if (!mainContent.contains('ExtRunner.run()')) {
        mainContent = mainContent.replaceFirst(
          '    if (preloadScore < 0) {}',
          '    preloadScore += ExtRunner.run();\n    if (preloadScore < 0) {}',
        );
      }
      File(mainPath).writeAsStringSync(mainContent);
      logger.info('已接入 PreloadRunner');
    }

    logger.success('符号扭曲完成');
  }

  String _generateSymbolBloat(String seed) {
    final buffer = StringBuffer();
    buffer.writeln('// Generated. Seed: $seed');
    buffer.writeln('');

    // Extension
    final extName = NameGenerator.generateClassName('${seed}_Ext');
    buffer.writeln('extension $extName on int {');
    buffer.writeln('  int get doubled => this * 2;');
    buffer.writeln('  int add(int x) => this + x;');
    buffer.writeln('}');
    buffer.writeln('');

    final extName2 = NameGenerator.generateClassName('${seed}_ExtStr');
    buffer.writeln('extension $extName2 on String {');
    buffer.writeln('  String get reversed => split(\'\').reversed.join();');
    buffer.writeln('}');
    buffer.writeln('');

    // Generic
    final genName = NameGenerator.generateClassName('${seed}_Gen');
    buffer.writeln('class $genName<T> {');
    buffer.writeln('  final T value;');
    buffer.writeln('  $genName(this.value);');
    buffer.writeln('  T get v => value;');
    buffer.writeln('  $genName<R> map<R>(R Function(T) f) => $genName<R>(f(value));');
    buffer.writeln('}');
    buffer.writeln('');

    final genName2 = NameGenerator.generateClassName('${seed}_Pair');
    buffer.writeln('class $genName2<K, V> {');
    buffer.writeln('  final K key;');
    buffer.writeln('  final V val;');
    buffer.writeln('  $genName2(this.key, this.val);');
    buffer.writeln('  K get k => key;');
    buffer.writeln('  V get v => val;');
    buffer.writeln('}');
    buffer.writeln('');

    // Mixin
    final mixName = NameGenerator.generateClassName('${seed}_Mixin');
    buffer.writeln('mixin $mixName {');
    buffer.writeln('  int _counter = 0;');
    buffer.writeln('  int get count => _counter;');
    buffer.writeln('  void inc() => _counter++;');
    buffer.writeln('}');
    buffer.writeln('');

    final mixName2 = NameGenerator.generateClassName('${seed}_Mixin2');
    buffer.writeln('mixin $mixName2 {');
    buffer.writeln('  int get mixinVal => 42;');
    buffer.writeln('}');
    buffer.writeln('');

    final implName = NameGenerator.generateClassName('${seed}_Impl');
    buffer.writeln('class $implName with $mixName, $mixName2 { }');
    buffer.writeln('');

    buffer.writeln('class ExtRunner {');
    buffer.writeln('  static num run() {');
    buffer.writeln('    final a = 1.doubled;');
    buffer.writeln('    final b = \'ab\'.reversed;');
    buffer.writeln('    final c = $genName<int>(2).map((x) => x + 1).v;');
    buffer.writeln('    final d = $genName2<int, String>(3, \'x\');');
    buffer.writeln('    final e = $implName()..inc()..inc();');
    buffer.writeln('    return a + b.length + c + d.k + e.count + e.mixinVal;');
    buffer.writeln('  }');
    buffer.writeln('}');

    return buffer.toString();
  }

  String _normalizePreloadAccumulator(String content) {
    return content
        .replaceAll('    var _ = 0.0;', '    var preloadScore = 0.0;')
        .replaceAll('    _ += Part', '    preloadScore += Part')
        .replaceAll(
          '    _ += ExtRunner.run();',
          '    preloadScore += ExtRunner.run();',
        )
        .replaceAll('    if (_ < 0) {}', '    if (preloadScore < 0) {}');
  }
}
