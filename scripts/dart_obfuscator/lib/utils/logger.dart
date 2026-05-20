import 'dart:io';

/// 日志工具
class Logger {
  final bool verbose;
  
  // ANSI 颜色代码
  static const _red = '\x1B[31m';
  static const _green = '\x1B[32m';
  static const _yellow = '\x1B[33m';
  static const _blue = '\x1B[34m';
  static const _cyan = '\x1B[36m';
  static const _reset = '\x1B[0m';
  
  Logger({this.verbose = false});
  
  void info(String message) {
    stdout.writeln('$_blue[INFO]$_reset $message');
  }
  
  void success(String message) {
    stdout.writeln('$_green[SUCCESS]$_reset $message');
  }
  
  void warning(String message) {
    stdout.writeln('$_yellow[WARNING]$_reset $message');
  }
  
  void error(String message) {
    stderr.writeln('$_red[ERROR]$_reset $message');
  }
  
  void step(String message) {
    stdout.writeln('$_cyan[STEP]$_reset $message');
  }
  
  void debug(String message) {
    if (verbose) {
      stdout.writeln('$_blue[DEBUG]$_reset $message');
    }
  }
  
  void banner(String message) {
    stdout.writeln('');
    stdout.writeln('==========================================');
    stdout.writeln('       $message');
    stdout.writeln('==========================================');
    stdout.writeln('');
  }
}
