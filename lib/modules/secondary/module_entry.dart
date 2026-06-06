import 'package:flutter/material.dart';

/// 次要模块入口
/// 此文件为模板占位文件，同步代码后会被覆盖
class ModuleEntry {
  static bool _initialized = false;

  /// 初始化模块
  static Future<void> initialize() async {
    if (_initialized) return;
    // 模块初始化逻辑（同步后自动生成）
    _initialized = true;
  }

  /// 获取首页
  static Widget getHomePage() {
    return const Scaffold(
      body: Center(
        child: Text(
          '模块未配置\n请运行 sync_secondary.sh 同步代码',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// 获取路由
  static Map<String, WidgetBuilder> getRoutes() {
    return {};
  }
}
