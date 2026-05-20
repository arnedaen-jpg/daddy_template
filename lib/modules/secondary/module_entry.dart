import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get_storage/get_storage.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'indicator/x_footer.dart';
import 'indicator/x_qiu_header.dart';
import 'main/appLog/log_manager.dart';

import 'main.dart' show MainApp;

/// 次要模块入口 - dq（斗球）
///
/// 源项目为独立 App 时 main() 会处理权限弹窗/退出等；嵌入壳工程时应避免 exit(0)。
/// 此处只初始化 B 面运行所需的最小环境并返回 [MainApp]。
class ModuleEntry {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    WidgetsFlutterBinding.ensureInitialized();
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    await GetStorage.init();
    await GetStorage.init("view_config");
    await initializeDateFormatting();
    EasyLoading().indicatorType = EasyLoadingIndicatorType.ring;
    Get.put(LogManager());
    _initEasyRefreshDefaults();
    _initialized = true;
  }

  static void _initEasyRefreshDefaults() {
    EasyRefresh.defaultHeaderBuilder = () {
      return XQiuHeader(
        triggerOffset: 69,
        safeArea: false,
        clamping: false,
        position: IndicatorPosition.behind,
      );
    };
    EasyRefresh.defaultFooterBuilder = () {
      return const XFooter(
        iconDimension: 0,
        spacing: 0,
        triggerOffset: 50,
        dragText: "上拉加载",
        armedText: "准备加载",
        readyText: "正在加载",
        processingText: "正在加载",
        processedText: "加载成功",
        showMessage: false,
        noMoreText: "没有更多",
        textStyle: TextStyle(
          color: Color(0xFF999999),
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
      );
    };
  }

  static Widget getHomePage() {
    return const MainApp();
  }

  static Map<String, WidgetBuilder> getRoutes() {
    return {};
  }
}
