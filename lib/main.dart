import 'package:flutter/material.dart';
import 'app_binding.dart';
import 'config/app_config.dart';
import 'config/env_config.dart';
import 'modules/primary/pages/home_page.dart';
import 'modules/secondary/module_entry.dart';
import 'router/app_router.dart';
import 'services/config_service.dart';
import 'services/domain_manager.dart';
import 'services/network/http_client.dart';
import 'services/network/network_permission_service.dart';
import 'widgets/env_switcher.dart';

/// 全局 Navigator Key，用于壳工程（A 面）页面内导航
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  AppBinding.ensureInitialized();
  runApp(const AbRootHost());
}

/// AB 根宿主
///
/// 关键：B 面（次要模块）自身是一个完整的 MaterialApp/GetMaterialApp。
/// 若把它当作子路由 push 进「壳工程」的 MaterialApp，会形成 MaterialApp 嵌套，
/// 导致 B 面用 root overlay 弹出的弹窗落在壳层 overlay（无 Material 祖先），
/// 触发 “No Material widget found” 以及布局溢出。
///
/// 因此这里按当前模式在「根部」挂载：
///   - 主要模式 / 启动页 → 壳工程 MaterialApp（_ShellApp）
///   - 次要模式 → 直接挂载 B 面（ModuleEntry.getHomePage()），让 B 面自己的
///     MaterialApp 成为唯一顶层 App，弹窗 / 导航 / 主题上下文均正确解析。
class AbRootHost extends StatefulWidget {
  const AbRootHost({super.key});

  @override
  State<AbRootHost> createState() => _AbRootHostState();
}

class _AbRootHostState extends State<AbRootHost> {
  final ConfigService _configService = ConfigService();
  bool _bootstrapped = false;
  bool _secondaryReady = false;
  Future<void>? _secondaryPrepareFuture;
  int _modeToken = 0;

  @override
  void initState() {
    super.initState();
    _configService.addListener(_handleConfigChanged);
    _configService.onModeChanged = (_) => _handleConfigChanged();
    _bootstrap();
  }

  @override
  void dispose() {
    _configService.removeListener(_handleConfigChanged);
    _configService.onModeChanged = null;
    super.dispose();
  }

  Future<void> _bootstrap() async {
    // 1. 初始化环境配置
    await EnvConfig.initialize();

    // 2. 初始化网络权限服务（触发 iOS 网络权限弹窗）
    await NetworkPermissionService().initialize();

    // 3. 初始化域名管理（本地/快照 → ping → Service/OBS/npm 降级链）
    await DomainManager().initialize();

    // 4. 初始化网络客户端（依赖域名池做 CDN 加签）
    await HttpClient().initialize();
    HttpClient().updateBaseUrl();

    // 5. 初始化配置服务
    await _configService.initialize();

    // 6. 如为次要模式，确保次要模块已初始化（决定首帧挂载哪个根）
    await _prepareCurrentMode();

    // 延迟一下显示启动画面
    await Future.delayed(const Duration(milliseconds: 500));

    if (mounted) {
      setState(() => _bootstrapped = true);
    }
  }

  void _handleConfigChanged() {
    if (!_bootstrapped) return;

    _prepareCurrentMode();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _prepareCurrentMode() async {
    final token = ++_modeToken;

    if (!_configService.isSecondaryMode) {
      _secondaryPrepareFuture = null;
      if (mounted && _secondaryReady) {
        setState(() => _secondaryReady = false);
      }
      return;
    }

    if (_secondaryReady) return;

    _secondaryPrepareFuture ??= ModuleEntry.initialize();
    await _secondaryPrepareFuture;
    if (!mounted || token != _modeToken) return;

    _secondaryPrepareFuture = null;
    setState(() => _secondaryReady = true);
  }

  @override
  Widget build(BuildContext context) {
    final Widget root;
    if (!_bootstrapped ||
        (_configService.isSecondaryMode && !_secondaryReady)) {
      root = const _ShellApp(home: SplashPage());
    } else if (_configService.isSecondaryMode) {
      // B 面以根级 App 直接挂载，避免与壳工程 MaterialApp 嵌套
      root = KeyedSubtree(
        key: const ValueKey('secondary-root'),
        child: ModuleEntry.getHomePage(),
      );
    } else {
      root = const _ShellApp(home: HomePage());
    }

    // 开发者悬浮按钮置于根部（位于 MaterialApp 之上），自带 Directionality/Material，
    // 因此在 A 面壳工程与 B 面独立 App 两种根下都能正常显示。
    return EnvFloatingIndicator(child: root);
  }
}

/// 壳工程 App（A 面 / 启动页）
class _ShellApp extends StatelessWidget {
  final Widget home;

  const _ShellApp({required this.home});

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
      // 壳工程内部命名路由仍走动态路由
      onGenerateRoute: AppRouter.generateRoute,
      home: home,
    );
  }
}
