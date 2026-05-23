#!/usr/bin/env bash
# compat_dq.sh - dq（斗球 / 直播，源工程示例: xty）专用适配
# 方案沿用原 tx / yc001 体系：自包含入口（不引用壳工程 lib/shell/）、iOS 部署目标对齐、
#   pubspec 覆盖、本地播放器 plugin podspec 修补。
# 由 sync_secondary.sh 自动 source。

# dq 源工程 ios/Podfile 与 Runner.xcodeproj 当前 deployment_target = 13.0
DQ_MIN_IOS_DEPLOYMENT_TARGET="${DQ_MIN_IOS_DEPLOYMENT_TARGET:-13.0}"

# ------------------------------------------------------------
# 入口文件生成：完全自包含
#   - 不引用 ../../shell/ 等跨 secondary 边界的路径
#   - 把 dqiu/lib/main.dart 「允许联网」分支的初始化逻辑直接内嵌
#   - 所有 import 走 secondary 内部相对路径（沿用 compat_tx.sh / compat_lgt.sh 风格）
# ------------------------------------------------------------
generate_dq_entry_file() {
  local entry_file="$1"
  cat > "$entry_file" << 'EOF'
import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'indicator/x_footer.dart';
import 'indicator/x_qiu_header.dart';
import 'main.dart' show MainApp;
import 'main/appLog/log_manager.dart';
import 'main/config/app_data_manager.dart';
import 'main/domain/xx_domain_manager.dart';
import 'main/im/im_manager.dart';
import 'modules/global_logic.dart';

/// 次要模块入口 - dq（斗球）
///
/// 源项目为独立 App 时 main() 会处理权限弹窗 / 退出等；嵌入壳工程时应避免 exit(0)。
/// 此处复刻 dqiu/lib/main.dart 「允许联网」分支的最小初始化序列。
class ModuleEntry {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    WidgetsFlutterBinding.ensureInitialized();
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    await GetStorage.init();
    await GetStorage.init('view_config');

    final pkg = await PackageInfo.fromPlatform();
    AppDataManager.instance.version = pkg.version;
    AppDataManager.instance.appName = pkg.appName;

    await initializeDateFormatting();

    EasyLoading().indicatorType = EasyLoadingIndicatorType.ring;

    Get.put(LogManager());

    // === B 面运行所需的最小核心环境（与 dqiu 独立运行允许联网分支一致） ===
    if (!Get.isRegistered<GlobalLogic>()) {
      Get.put(GlobalLogic());
      XXDomainManager.instance.requestDomain();
      AppDataManager.instance.initData();
      IMManager.instance.initClient();
      IMManager.instance.initSDKAndConnect();
    }

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
        dragText: '上拉加载',
        armedText: '准备加载',
        readyText: '正在加载',
        processingText: '正在加载',
        processedText: '加载成功',
        showMessage: false,
        noMoreText: '没有更多',
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

# ------------------------------------------------------------
# pubspec 覆盖：移除 OHOS fork 的 connectivity_plus git override
#   xty 的 dependency_overrides 里 connectivity_plus 指向 OHOS fork，iOS 无原生实现
#   → MissingPluginException(dev.fluttercommunity.plus/connectivity_status)。
#   删 git override，并保证 dependencies 里使用 pub.dev 版。
# ------------------------------------------------------------
apply_dq_pubspec_overrides() {
  local pubspec="${1:-}"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] dq 将清理 connectivity_plus OHOS git override，确保 pub.dev 版"
    return 0
  fi
  if [[ -z "$pubspec" || ! -f "$pubspec" ]]; then
    log_warning "未找到 pubspec.yaml，跳过 dq 依赖版本对齐"
    return 0
  fi
  python3 - "$pubspec" << 'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

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
  log_success "dq 依赖已对齐: connectivity_plus 走 pub.dev"
}

# ------------------------------------------------------------
# pub get 之后的兼容修复
#
# 让壳工程 ios/Flutter/Generated.xcconfig 的 EXCLUDED_ARCHS[sdk=iphonesimulator*]
# 追加 arm64，使 Apple Silicon Mac 上的模拟器构建走 x86_64 + Rosetta。
#
# 背景：dq 依赖 BIJKPlayer 老 fat framework，没有 arm64-simulator slice。Xcode 15+ 在
# Apple Silicon 上原生跑模拟器是 arm64-simulator，平台不匹配会链接失败：
#   "Building for iOS-simulator, but linking in object file …
#    /IJKMediaPlayer[arm64](ijksdl_log.o) built for iOS"
#
# 为什么必须改 Runner 主工程的 xcconfig 而不是 fijkplayer 自己的 podspec：
#   Runner 主工程读的是 Generated.xcconfig + Pods-Runner.<config>.xcconfig，
#   而 Flutter 的 flutter_additional_ios_build_settings 在 Podfile.post_install
#   阶段会硬覆盖 Pods 各 target 的 EXCLUDED_ARCHS = "$(inherited) i386"。
#   podspec 的 pod_target_xcconfig / user_target_xcconfig 既不会冒泡到 Runner，
#   又会被 Flutter 覆盖，唯一稳定的注入点就是 Generated.xcconfig。
#
# Flutter `pub get` 会保留 Generated.xcconfig 中已有的 EXCLUDED_ARCHS 行（已实测验证），
# 所以一次注入持久。dqiu 独立工程的 Generated.xcconfig 历史上也是 "i386 arm64"，
# 这里只是让壳工程和 dqiu 独立运行行为对齐。
# ------------------------------------------------------------
post_pub_get_dq_compatibility() {
  local cfg="$PROJECT_ROOT/ios/Flutter/Generated.xcconfig"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] dq 将追加 arm64 到 ios/Flutter/Generated.xcconfig 的 EXCLUDED_ARCHS[sdk=iphonesimulator*]"
    return 0
  fi

  if [[ ! -f "$cfg" ]]; then
    log_warning "未找到 ios/Flutter/Generated.xcconfig，跳过模拟器架构排除"
    return 0
  fi

  python3 - "$cfg" <<'PY'
import sys
from pathlib import Path

cfg = Path(sys.argv[1])
lines = cfg.read_text(encoding="utf-8").splitlines()
key = "EXCLUDED_ARCHS[sdk=iphonesimulator*]"
prefix = key + "="

found = False
changed = False
out = []
for ln in lines:
    if ln.startswith(prefix):
        # 注意：key 本身含 '='，不能用 ln.split('=', 1)，必须按 prefix 长度切。
        # 旧版用 split('=', 1) 会把 'EXCLUDED_ARCHS[sdk=iphonesimulator*]=i386'
        # 错切成 ['EXCLUDED_ARCHS[sdk', 'iphonesimulator*]=i386']，最终写出
        # 畸形行 '...=iphonesimulator*]=i386 arm64'，被 Xcode 解析为无效设置。
        found = True
        cur = ln[len(prefix):].strip()
        toks = cur.split()
        if "arm64" not in toks:
            toks.append("arm64")
            ln = f"{prefix}{' '.join(toks)}"
            changed = True
    out.append(ln)

if not found:
    out.append(f"{prefix}i386 arm64")
    changed = True

if changed:
    cfg.write_text("\n".join(out) + "\n", encoding="utf-8")
    print("changed")
else:
    print("unchanged")
PY

  log_success "dq 模拟器架构排除已对齐: EXCLUDED_ARCHS[sdk=iphonesimulator*] 含 arm64（与 dqiu 独立运行一致）"
}

# ------------------------------------------------------------
# 项目专用兼容修复：在 pubspec 合并前执行
# ------------------------------------------------------------
fix_dq_compatibility() {
  local target_dir="${1:-}"
  local plugins_dir="${2:-}"
  local _unused_target_dir="$target_dir"
  local _unused_plugins_dir="$plugins_dir"

  enforce_dq_ios_minimum_target
  return 0
}

_dq_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "未找到 python3，无法执行 dq 兼容修复"
    return 1
  fi
  python3 "$@"
}

# ------------------------------------------------------------
# 对齐 iOS 最低部署版本（沿用 compat_lgt.sh / compat_tx.sh 的实现）
# ------------------------------------------------------------
enforce_dq_ios_minimum_target() {
  local minimum_target="${1:-$DQ_MIN_IOS_DEPLOYMENT_TARGET}"
  local podfile="$PROJECT_ROOT/ios/Podfile"
  local pbxproj="$PROJECT_ROOT/ios/Runner.xcodeproj/project.pbxproj"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] dq 将确保当前工程 iOS 最低版本不低于 $minimum_target"
    return 0
  fi

  if [[ ! -f "$podfile" || ! -f "$pbxproj" ]]; then
    log_warning "dq iOS 工程文件不完整，跳过 deployment target 对齐"
    return 0
  fi

  local changed
  if ! changed=$(_dq_python3 - "$minimum_target" "$podfile" "$pbxproj" <<'PY'
from pathlib import Path
import re
import sys

minimum = sys.argv[1]
podfile = Path(sys.argv[2])
pbxproj = Path(sys.argv[3])

def version_lt(lhs: str, rhs: str) -> bool:
    def parse(value: str):
        return tuple(int(part) for part in value.split('.'))
    left = parse(lhs)
    right = parse(rhs)
    max_len = max(len(left), len(right))
    left += (0,) * (max_len - len(left))
    right += (0,) * (max_len - len(right))
    return left < right

changed = False

podfile_text = podfile.read_text()
platform_pattern = re.compile(r"^(platform\s*:ios,\s*')([^']+)('.*)$", re.MULTILINE)
platform_match = platform_pattern.search(podfile_text)
if platform_match and version_lt(platform_match.group(2), minimum):
    podfile_text = platform_pattern.sub(rf"\g<1>{minimum}\g<3>", podfile_text, count=1)
    changed = True
    podfile.write_text(podfile_text)

pbxproj_text = pbxproj.read_text()
deployment_pattern = re.compile(r"(IPHONEOS_DEPLOYMENT_TARGET = )([0-9]+(?:\.[0-9]+)*)(;)")

def replace_target(match):
    current = match.group(2)
    if version_lt(current, minimum):
        return f"{match.group(1)}{minimum}{match.group(3)}"
    return match.group(0)

updated_pbxproj = deployment_pattern.sub(replace_target, pbxproj_text)
if updated_pbxproj != pbxproj_text:
    changed = True
    pbxproj.write_text(updated_pbxproj)

print("changed" if changed else "unchanged")
PY
  ); then
    log_warning "dq iOS 最低版本对齐失败，请手动检查 Podfile 和 project.pbxproj"
    return 0
  fi

  if [[ "$changed" == "changed" ]]; then
    log_success "dq iOS 最低版本已对齐到 $minimum_target"
  else
    log_info "dq iOS 最低版本已满足 >= $minimum_target"
  fi
}
