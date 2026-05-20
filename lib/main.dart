import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_binding.dart';
import 'config/app_config.dart';
import 'router/app_router.dart';
import 'services/config_service.dart';
import 'widgets/env_switcher.dart';

/// 全局 Navigator Key，用于开发者选项悬浮按钮
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  AppBinding.ensureInitialized();
  _setupModeChangeListener();
  runApp(const MyApp());
}

/// 设置模式变化监听
/// 当远程配置导致模式变化时，自动导航到对应页面
void _setupModeChangeListener() {
  ConfigService().onModeChanged = (FeatureMode newMode) {
    if (kDebugMode) {
      print('Main: Mode changed to ${newMode.name}, navigating...');
    }

    // 确保 navigator 已就绪
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      if (kDebugMode) {
        print('Main: Navigator not ready, skipping navigation');
      }
      return;
    }

    // 使用 AppRouter 导航到对应模式的页面
    final context = navigator.context;
    AppRouter.navigateToMode(context, newMode);
  };
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // 使用动态路由
      onGenerateRoute: AppRouter.generateRoute,
      initialRoute: AppRoutes.splash,
      // 在所有页面顶层添加环境切换悬浮按钮
      builder: (context, child) {
        return EnvFloatingIndicator(
          navigatorKey: navigatorKey,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
