import 'package:flutter/material.dart';
import '../services/config_service.dart';
import '../modules/primary/pages/home_page.dart';
import '../utils/s.dart';

/// 路由名称常量
class AppRoutes {
  static const String splash = '/';
  static String get home => S.homeRoute;
  static String get primaryHome => S.primaryHomeRoute;
  static String get secondaryHome => S.secondaryHomeRoute;
}

/// 动态路由管理器
///
/// 注意：B 面（次要模块）不再作为子路由 push，而是由 [AbRootHost] 在根部按模式挂载。
/// 因此本路由仅服务于「壳工程（A 面 / 启动页）」内部导航。
class AppRouter {
  /// 生成路由
  static Route<dynamic> generateRoute(RouteSettings settings) {
    final name = settings.name;
    if (name == AppRoutes.splash) {
      return _buildRoute(const SplashPage(), settings);
    } else if (name == AppRoutes.home) {
      return _buildRoute(_getHomePage(), settings);
    } else if (name == AppRoutes.primaryHome) {
      return _buildRoute(const HomePage(), settings);
    } else if (name == AppRoutes.secondaryHome) {
      // 次要模式由根宿主切换，壳工程内不再渲染 B 面
      return _buildRoute(const HomePage(), settings);
    } else {
      return _buildRoute(_getHomePage(), settings);
    }
  }

  /// 壳工程首页（A 面）
  static Widget _getHomePage() {
    return const HomePage();
  }

  /// 构建路由
  static MaterialPageRoute _buildRoute(Widget page, RouteSettings settings) {
    return MaterialPageRoute(
      builder: (_) => page,
      settings: settings,
    );
  }

  /// 构建无动画路由
  static PageRouteBuilder _buildRouteNoAnimation(
      Widget page, RouteSettings settings) {
    return PageRouteBuilder(
      pageBuilder: (_, __, ___) => page,
      settings: settings,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
  }

  /// 导航到首页（壳工程内，无动画）
  static void navigateToHome(BuildContext context) {
    final page = _getHomePage();
    Navigator.of(context).pushAndRemoveUntil(
      _buildRouteNoAnimation(page, RouteSettings(name: AppRoutes.home)),
      (route) => false,
    );
  }

  /// 切换到指定模式
  ///
  /// 次要模式不走 Navigator（由根宿主按模式重建），统一交给 ConfigService 切换。
  static void navigateToMode(BuildContext context, FeatureMode mode) {
    if (mode == FeatureMode.secondary) {
      ConfigService().switchToSecondary();
      return;
    }

    const page = HomePage();
    Navigator.of(context).pushAndRemoveUntil(
      _buildRouteNoAnimation(
        page,
        RouteSettings(name: AppRoutes.primaryHome),
      ),
      (route) => false,
    );
  }
}

/// 启动页
///
/// 真正的初始化序列已上移到 [AbRootHost]，此处仅作为壳工程的占位加载界面。
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
