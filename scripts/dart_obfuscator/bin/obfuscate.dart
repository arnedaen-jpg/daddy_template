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
        help:
            '项目代码 (dq, lgt, hjsq, ph, 51pc, 51cg, hlw, tiktok, 91cg, yms, acfun, tx, douyin, mrds, oio, bili, 91porn, 91porn2, txpjb, xjpjb, hlbdy, nnrj)')
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

    final projectName = results['project'] as String?;
    if (projectName == 'md') {
      stderr.writeln('错误: md 项目已下线，不再支持混淆');
      exit(1);
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

    final targetDirPath =
        path.normalize(path.absolute(results['target'] as String));

    // 解析 bundleId / version（优先 CLI，否则从 pubspec 读取，用于稳定 seed）
    var bundleId = results['bundle-id'] as String?;
    var version = results['version'] as String?;
    if (bundleId == null || version == null) {
      final fromPubspec = _readPubspec(targetDirPath);
      bundleId ??= fromPubspec.$1;
      version ??= fromPubspec.$2;
    }

    // 构建配置
    final config = ObfuscatorConfig(
      targetDir: targetDirPath,
      projectName: projectName,
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
  ph:     api_service.dart, user_service.dart, app_service.dart, login.dart
  hjsq:   api_service.dart, user_service.dart, app_service.dart
  tiktok: http.dart, http_config.dart, crypto_util.dart, global.dart, routes.dart
  91cg:   全量覆盖 (20+ 文件: network, request, report, cache, route, startup 层)
  51cg:   network_http.dart, request_api.dart, report_timing_interceptor.dart, cache_manager.dart
  acfun:  module_entry.dart, app_prepare.dart, user_service.dart, api_settings.dart, api_video.dart
  tx:     module_entry.dart, request.dart, http_request.dart, app_api.dart, splash_logic.dart
  douyin: router.dart, app_init.dart, http_api.dart, app_api.dart, device_util.dart
  mrds:   network_http.dart, request_api.dart, app_event_report.dart, cache_manager.dart, go_routers.dart
  oio:    client_api.dart, net_manager.dart, analytics_sdk_initializer.dart, router_map.dart, module_entry.dart
  bili:   client_api.dart, net_manager.dart, track_uploader.dart, router_map.dart, module_entry.dart
  91porn: http_manager.dart, vid_service.dart, splash_logic.dart, track_uploader.dart, router_map.dart
  91porn2: http_config.dart, http_api.dart, global.dart, routes.dart, report_monitor_event.dart
  txpjb:  module_entry.dart, route_config.dart, analytics_utils.dart, token_interceptor.dart, splash_logic.dart
  xjpjb:  module_entry.dart, route_config.dart, analytics_utils.dart, token_interceptor.dart, splash_logic.dart
  hlbdy:  module_entry.dart, network_http.dart, request_api.dart, app_event_report.dart, go_routers.dart
  nnrj:   module_entry.dart, app_prepare.dart, http_service.dart, api.dart, tracker.dart

示例:
  dart run bin/obfuscate.dart -p ph --string              # ph 项目字符串混淆
  dart run bin/obfuscate.dart -p ph --callstack           # ph 项目调用栈混淆
  dart run bin/obfuscate.dart -p ph --bloat               # ph 项目文件膨胀（4.3a）
  dart run bin/obfuscate.dart -p ph --noise              # 业务噪音注入
  dart run bin/obfuscate.dart -p ph --all                 # 所有混淆
  dart run bin/obfuscate.dart --string -d                 # 模拟运行（不实际修改）
''');
}
