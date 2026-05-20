import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:dart_obfuscator/obfuscator.dart';
import 'package:dart_obfuscator/config.dart';

/// B面代码混淆工具 CLI
void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('target',
        abbr: 't', help: '目标目录', defaultsTo: 'lib/modules/secondary')
    ..addOption('project',
        abbr: 'p',
        help: '项目代码 (dq, lgt；其它代号已弃用)')
    ..addOption('method',
        abbr: 'm',
        help: '字符串混淆方法 (bytes, base64, xor, concat)',
        defaultsTo: 'bytes')
    ..addOption('xor-key', abbr: 'k', help: 'XOR 密钥', defaultsTo: '42')
    ..addOption('depth', help: '调用栈深度 (1-5)', defaultsTo: '3')
    ..addFlag('string', help: '启用字符串混淆', defaultsTo: false)
    ..addFlag('callstack', help: '启用调用栈混淆（针对核心类方法）', defaultsTo: false)
    ..addFlag('bloat', help: '启用文件膨胀（4.3a 差异化，每项目不同冗余代码）', defaultsTo: false)
    ..addFlag('noise',
        help: '启用业务噪音注入（build/initState/getHomePage）', defaultsTo: false)
    ..addFlag('mutation', help: '启用AST变异（方法体插入dummy代码）', defaultsTo: false)
    ..addFlag('symbols',
        help: '启用符号扭曲（extension/generic/mixin）', defaultsTo: false)
    ..addFlag('all', help: '启用所有混淆', defaultsTo: false)
    ..addOption('bundle-id',
        abbr: 'b', help: 'Bundle ID / 包名（稳定 seed，同版本同包生成一致）')
    ..addOption('version', abbr: 'V', help: '版本号（稳定 seed，用于 Crashlytics 符号映射）')
    ..addFlag('dry-run', abbr: 'd', help: '模拟运行', defaultsTo: false)
    ..addFlag('verbose', abbr: 'v', help: '详细输出', defaultsTo: false)
    ..addFlag('help', abbr: 'h', help: '显示帮助', negatable: false);

  try {
    final results = parser.parse(arguments);

    if (results['help'] as bool) {
      _printUsage(parser);
      return;
    }

    // 检查是否至少选择了一个混淆功能
    final enableAll = results['all'] as bool;
    final enableString = enableAll || results['string'] as bool;
    final enableCallstack = enableAll || results['callstack'] as bool;
    final enableBloat = enableAll || results['bloat'] as bool;
    final enableNoise = enableAll || results['noise'] as bool;
    final enableMutation = enableAll || results['mutation'] as bool;
    final enableSymbolDistort = enableAll || results['symbols'] as bool;

    if (!enableString &&
        !enableCallstack &&
        !enableBloat &&
        !enableNoise &&
        !enableMutation &&
        !enableSymbolDistort) {
      stderr.writeln('错误: 请至少选择一个混淆功能');
      stderr.writeln(
          '可用选项: --string, --callstack, --bloat, --noise, --mutation, --symbols, --all');
      exit(1);
    }

    // 解析 bundleId / version（优先 CLI，否则从 pubspec 读取，用于稳定 seed）
    var bundleId = results['bundle-id'] as String?;
    var version = results['version'] as String?;
    if (bundleId == null || version == null) {
      final fromPubspec =
          _readPubspec(path.absolute(results['target'] as String));
      bundleId ??= fromPubspec.$1;
      version ??= fromPubspec.$2;
    }

    // 构建配置
    final config = ObfuscatorConfig(
      targetDir: results['target'] as String,
      projectName: results['project'] as String?,
      bundleId: bundleId,
      version: version,
      stringMethod: results['method'] as String,
      xorKey: int.parse(results['xor-key'] as String),
      callStackDepth: int.parse(results['depth'] as String),
      enableString: enableString,
      enableCallstack: enableCallstack,
      enableBloat: enableBloat,
      enableNoise: enableNoise,
      enableMutation: enableMutation,
      enableSymbolDistort: enableSymbolDistort,
      dryRun: results['dry-run'] as bool,
      verbose: results['verbose'] as bool,
    );

    // 验证目标目录
    final targetDir = Directory(config.targetDir);
    if (!targetDir.existsSync()) {
      stderr.writeln('错误: 目标目录不存在: ${config.targetDir}');
      stderr.writeln('请先运行 sync_secondary.sh 同步 B 面代码');
      exit(1);
    }

    // 运行混淆器
    final obfuscator = Obfuscator(config);
    await obfuscator.run();
  } on FormatException catch (e) {
    stderr.writeln('参数错误: ${e.message}');
    _printUsage(parser);
    exit(1);
  } catch (e, stack) {
    stderr.writeln('错误: $e');
    if (arguments.contains('-v') || arguments.contains('--verbose')) {
      stderr.writeln(stack);
    }
    exit(1);
  }
}

/// 从项目根目录的 pubspec.yaml 读取 name、version
(String?, String?) _readPubspec(String targetDirPath) {
  var dir = Directory(targetDirPath);
  if (!dir.existsSync()) return (null, null);
  var current = path.absolute(targetDirPath);
  for (var i = 0; i < 10; i++) {
    final pubspec = File(path.join(current, 'pubspec.yaml'));
    if (pubspec.existsSync()) {
      String? name, ver;
      for (final line in pubspec.readAsStringSync().split('\n')) {
        final t = line.trim();
        if (t.startsWith('name:')) {
          name = t.substring(5).trim().split('#').first.trim();
        } else if (t.startsWith('version:')) {
          ver = t.substring(8).trim().split('#').first.trim();
        }
        if (name != null && ver != null) break;
      }
      return (name, ver);
    }
    final parent = path.dirname(current);
    if (parent == current) break;
    current = parent;
  }
  return (null, null);
}

void _printUsage(ArgParser parser) {
  print('''
B面代码混淆工具

用法: dart run bin/obfuscate.dart [选项]

${parser.usage}

混淆功能说明:
  --string     字符串混淆：将敏感字符串（API路径、中文文本等）转为 String.fromCharCodes()
  --callstack  调用栈混淆：在核心类方法中注入包装调用，增加调用深度（针对项目定制）
  --bloat      文件膨胀：注入项目专属冗余代码，降低多包相似度（4.3a 差异化）
  --noise      业务噪音：在 build/initState/getHomePage 中随机插入 Noise.run()
  --mutation   AST 变异：在方法体中插入 dummy 代码
  --symbols    符号扭曲：生成 extension/generic/mixin 结构

核心文件（--callstack 针对的文件，每个项目不同）:
  dq:     与 tx 相同（主入口/请求/加解密/WS）
  lgt:    与 acfun 相同（全量 API/服务/路由，偏 IM 社区向）
  （历史 alias ph/hjsq/tx 等已收敛，见仓库文档）

示例:
  dart run bin/obfuscate.dart -p ph --string              # ph 项目字符串混淆
  dart run bin/obfuscate.dart -p ph --callstack           # ph 项目调用栈混淆
  dart run bin/obfuscate.dart -p ph --bloat               # ph 项目文件膨胀（4.3a）
  dart run bin/obfuscate.dart -p ph --noise              # 业务噪音注入
  dart run bin/obfuscate.dart -p ph --all                 # 所有混淆
  dart run bin/obfuscate.dart --string -d                 # 模拟运行（不实际修改）
''');
}
