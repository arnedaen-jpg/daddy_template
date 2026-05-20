#!/usr/bin/env bash
# compat_dq.sh - dq（斗球 / 直播，源工程示例: xty）专用适配
# 同步策略沿用原 tx/yc001 体系：GetX + main.dart 入口、网络/全局逻辑分层
# 由 sync_secondary.sh 自动 source

# 与 tx 相同：iOS 最低版本（按需在 fix_dq_compatibility 中调整）
DQ_MIN_IOS_DEPLOYMENT_TARGET="${DQ_MIN_IOS_DEPLOYMENT_TARGET:-14.0}"

generate_dq_entry_file() {
  local entry_file="$1"
  cat > "$entry_file" << 'EOF'
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'indicator/x_footer.dart';
import 'indicator/x_qiu_header.dart';
import 'main/appLog/log_manager.dart';
import 'main/config/app_data_manager.dart';

import '../../shell/bface_core_bootstrap.dart';
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
    final pkg = await PackageInfo.fromPlatform();
    AppDataManager.instance.version = pkg.version;
    AppDataManager.instance.appName = pkg.appName;
    await initializeDateFormatting();
    EasyLoading().indicatorType = EasyLoadingIndicatorType.ring;
    Get.put(LogManager());
    ensureBfaceCoreInitialized();
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
EOF
}

# 合并 B 面 pubspec 后调用：xty 的 dependency_overrides 里 connectivity_plus 指向 OHOS fork，
# iOS 无原生实现 → MissingPluginException(dev.fluttercommunity.plus/connectivity_status)。
# 删 git override，并保证 dependencies 里为 pub.dev 版。
apply_dq_pubspec_overrides() {
  local pubspec="${1:-}"
  if [[ -z "$pubspec" || ! -f "$pubspec" ]]; then
    return 0
  fi
  python3 - "$pubspec" << 'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
# 删除 dependency_overrides 中 connectivity_plus 的 git 整段
s = re.sub(
    r"(?m)^  connectivity_plus:\n(?:^    .+\n)+",
    "",
    s,
    count=1,
)
if "dependency_overrides:" in s:
    pre, post = s.split("dependency_overrides:", 1)
    suffix = "dependency_overrides:" + post
else:
    pre = s
    suffix = ""

if re.search(r"^  connectivity_plus:\s", pre, re.M) is None:
    newp = re.sub(
        r"(^  dio:.*\n)",
        r"\1  connectivity_plus: ^6.1.0\n",
        pre,
        count=1,
    )
    if newp == pre:
        newp = re.sub(
            r"(^dependencies:\n  flutter:\n    sdk: flutter\n)",
            r"\1  connectivity_plus: ^6.1.0\n",
            pre,
            count=1,
        )
    pre = newp

s = pre + suffix
p.write_text(s, encoding="utf-8")
print("[apply_dq_pubspec_overrides] connectivity_plus: 已移除 OHOS git override，并确保使用 pub 直连")
PY
}

# 占位：包名会在同步时被替换为壳工程名；此处写 xty 供首次生成，同步脚本会改 import
fix_dq_compatibility() {
  local target_dir="${1:-}"
  local plugins_dir="${2:-}"
  if [[ -z "$target_dir" ]]; then
    return 0
  fi
  # 如壳工程与 dq 的 iOS 部署版本不一致，可在此用 sed 调整 Runner 的 IPHONEOS_DEPLOYMENT_TARGET
  if [[ -n "$DQ_MIN_IOS_DEPLOYMENT_TARGET" ]] && command -v /usr/libexec/PlistBuddy &>/dev/null; then
    : # 可选：与 fix_tx_compatibility 类似，按项目再打开
  fi
  return 0
}
