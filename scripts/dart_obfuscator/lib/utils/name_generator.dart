import 'package:crypto/crypto.dart';
import 'dart:convert';

/// 方法名/变量名生成器
class NameGenerator {
  static const _prefixes = [
    'process',
    'validate',
    'prepare',
    'check',
    'init',
    'load',
    'fetch',
    'parse',
    'handle',
    'resolve',
    'compute',
    'dispatch',
    'transform',
    'acquire',
    'compose',
    'evaluate',
    'normalize',
    'serialize',
    'aggregate',
    'delegate',
  ];

  static const _middles = [
    'data',
    'config',
    'state',
    'cache',
    'buffer',
    'context',
    'params',
    'options',
    'settings',
    'result',
    'token',
    'stream',
    'record',
    'signal',
    'metric',
    'entity',
    'schema',
    'payload',
    'segment',
    'channel',
  ];

  static const _suffixes = [
    'async',
    'sync',
    'internal',
    'helper',
    'util',
    'core',
    'base',
    'impl',
    'wrapper',
    'proxy',
    'node',
    'bridge',
    'adapter',
    'guard',
    'handler',
    'layer',
    'scope',
    'chain',
    'pipe',
    'relay',
  ];

  static final List<String> _prefixPool = _expandWords(_prefixes);
  static final List<String> _middlePool = _expandWords(_middles);
  static final List<String> _suffixPool = _expandWords(_suffixes);

  /// 生成确定性的方法名
  static String generateMethodName(String seed) {
    final hash = _hash(seed);

    final pIdx = hash[0] % _prefixPool.length;
    final mIdx = hash[1] % _middlePool.length;
    final sIdx = hash[2] % _suffixPool.length;
    final useSuffix = hash[3] % 2 == 1;

    final middle = _capitalize(_middlePool[mIdx]);

    if (useSuffix) {
      final suffix = _capitalize(_suffixPool[sIdx]);
      return '_${_prefixPool[pIdx]}$middle$suffix';
    } else {
      return '_${_prefixPool[pIdx]}$middle';
    }
  }

  /// 生成确定性的类名
  static String generateClassName(String seed) {
    final hash = _hash(seed);

    final pIdx = hash[0] % _prefixPool.length;
    final mIdx = hash[1] % _middlePool.length;
    final sIdx = hash[2] % _suffixPool.length;
    // Use extra hash bytes to optionally append a numeric disambiguator
    final numSuffix = ((hash[3] & 0xFF) << 8 | (hash[4] & 0xFF)) % 997;
    final useNum = hash[5] % 3 == 0;

    final prefix = _capitalize(_prefixPool[pIdx]);
    final middle = _capitalize(_middlePool[mIdx]);
    final suffix = _capitalize(_suffixPool[sIdx]);

    if (useNum) {
      return '_$prefix$middle$suffix$numSuffix';
    }
    return '_$prefix$middle$suffix';
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

  static List<String> _expandWords(List<String> baseWords) {
    const qualifiers = ['core', 'native', 'runtime', 'adaptive'];
    final out = <String>[];
    final seen = <String>{};

    void add(String word) {
      final normalized = word.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
      if (normalized.isEmpty || normalized.startsWith(RegExp(r'[0-9]'))) {
        return;
      }
      if (seen.add(normalized)) out.add(normalized);
    }

    for (final word in baseWords) {
      add(word);
    }
    for (final qualifier in qualifiers) {
      for (final word in baseWords) {
        add('$qualifier${_capitalize(word)}');
      }
    }
    return out;
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
