/// B面代码混淆工具
/// 
/// 使用 Dart analyzer 进行 AST 分析，实现精确的代码混淆。
/// 
/// 功能：
/// - 字符串混淆：将敏感字符串转换为编码形式
/// - 路由混淆：将路由路径替换为随机哈希
/// - 调用栈混淆：插入无用的包装方法
/// - 死代码注入：插入无用的方法
/// 
/// 参考：https://github.com/ljmatan/obfuscator
library dart_obfuscator;

export 'config.dart';
export 'obfuscator.dart';
export 'utils/encoders.dart';
export 'utils/name_generator.dart';
export 'utils/logger.dart';
export 'visitors/string_obfuscator.dart';
export 'visitors/route_obfuscator.dart';
export 'visitors/callstack_obfuscator.dart';
export 'visitors/bloat_inflator.dart';
