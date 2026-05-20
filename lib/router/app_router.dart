import 'package:flutter/material.dart';
import '../config/env_config.dart';
import '../services/config_service.dart';
import '../services/domain_manager.dart';
import '../services/network/http_client.dart';
import '../services/network/network_permission_service.dart';
import '../modules/primary/pages/home_page.dart';
import '../modules/secondary/module_entry.dart';
import '../utils/s.dart';

/// 路由名称常量
class AppRoutes {
  static const String splash = '/';
  static String get home => S.homeRoute;
  static String get primaryHome => S.primaryHomeRoute;
  static String get secondaryHome => S.secondaryHomeRoute;
}

/// 动态路由管理器
/// 根据配置动态切换路由
class AppRouter {
  static final ConfigService _configService = ConfigService();

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
      return _buildRoute(ModuleEntry.getHomePage(), settings);
    } else {
      return _buildRoute(_getHomePage(), settings);
    }
  }

  /// 根据配置获取首页
  static Widget _getHomePage() {
    if (_configService.isSecondaryMode) {
      return ModuleEntry.getHomePage();
    }
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
  static PageRouteBuilder _buildRouteNoAnimation(Widget page, RouteSettings settings) {
    return PageRouteBuilder(
      pageBuilder: (_, __, ___) => page,
      settings: settings,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
  }

  /// 导航到首页（根据当前配置，无动画）
  static void navigateToHome(BuildContext context) {
    final page = _getHomePage();
    Navigator.of(context).pushAndRemoveUntil(
      _buildRouteNoAnimation(page, RouteSettings(name: AppRoutes.home)),
      (route) => false,
    );
  }

  /// 导航到指定模式的首页（无动画）
  static void navigateToMode(BuildContext context, FeatureMode mode) {
    final page = mode == FeatureMode.primary 
        ? const HomePage() 
        : ModuleEntry.getHomePage();
    
    Navigator.of(context).pushAndRemoveUntil(
      _buildRouteNoAnimation(page, RouteSettings(
        name: mode == FeatureMode.primary ? AppRoutes.primaryHome : AppRoutes.secondaryHome,
      )),
      (route) => false,
    );
  }
}

/// 启动页
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // 1. 初始化环境配置
    await EnvConfig.initialize();

    // 2. 初始化网络权限服务（触发 iOS 网络权限弹窗）
    // 这一步会请求 apple.com 来触发系统的网络权限弹窗
    // 并监听网络状态变化
    await NetworkPermissionService().initialize();

    // 3. 初始化网络客户端
    await HttpClient().initialize();

    // 4. 初始化域名管理服务
    await DomainManager().initialize();

    // 5. 初始化配置服务
    // ConfigService 会检查 NetworkPermissionService.networkEnabled
    // 如果网络不可用，会注册回调等待网络可用后再获取配置
    await ConfigService().initialize();

    // 6. 如果需要显示次要模式，确保次要模块已初始化
    await ConfigService().ensureSecondaryInitialized();

    // 延迟一下显示启动画面
    await Future.delayed(const Duration(milliseconds: 500));

    if (mounted) {
      // 导航到首页
      AppRouter.navigateToHome(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
