import 'package:crypto/crypto.dart';
import 'dart:convert';

/// 方法名/变量名生成器
class NameGenerator {
  static const _prefixes = [
    'process', 'validate', 'prepare', 'check', 'init',
    'load', 'fetch', 'parse', 'handle', 'resolve'
  ];
  
  static const _middles = [
    'data', 'config', 'state', 'cache', 'buffer',
    'context', 'params', 'options', 'settings', 'result'
  ];
  
  static const _suffixes = [
    'async', 'sync', 'internal', 'helper', 'util',
    'core', 'base', 'impl', 'wrapper', 'proxy'
  ];
  
  /// 生成确定性的方法名
  static String generateMethodName(String seed) {
    final hash = _hash(seed);
    
    final pIdx = hash[0] % _prefixes.length;
    final mIdx = hash[1] % _middles.length;
    final sIdx = hash[2] % _suffixes.length;
    final useSuffix = hash[3] % 2 == 1;
    
    final middle = _capitalize(_middles[mIdx]);
    
    if (useSuffix) {
      final suffix = _capitalize(_suffixes[sIdx]);
      return '_${_prefixes[pIdx]}$middle$suffix';
    } else {
      return '_${_prefixes[pIdx]}$middle';
    }
  }
  
  /// 生成确定性的类名
  static String generateClassName(String seed) {
    final hash = _hash(seed);
    
    final pIdx = hash[0] % _prefixes.length;
    final mIdx = hash[1] % _middles.length;
    final sIdx = hash[2] % _suffixes.length;
    
    final prefix = _capitalize(_prefixes[pIdx]);
    final middle = _capitalize(_middles[mIdx]);
    final suffix = _capitalize(_suffixes[sIdx]);
    
    return '_$prefix${middle}$suffix';
  }
  
  /// 生成确定性的路由哈希
  static String generateRouteHash(String seed, {int length = 10}) {
    final bytes = utf8.encode(seed);
    final digest = md5.convert(bytes);
    return '/${digest.toString().substring(0, length)}';
  }
  
  /// 基于密度决定是否应该注入
  static bool shouldInject(String seed, double density) {
    final hash = _hash(seed);
    final value = hash[0] / 256.0;
    return value < density;
  }
  
  static List<int> _hash(String input) {
    final bytes = utf8.encode(input);
    final digest = md5.convert(bytes);
    return digest.bytes;
  }
  
  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
