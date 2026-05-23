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
# pub get 之后的兼容修复（双管齐下：Runner xcconfig + Pods Podfile）
#
# 目标：让 Apple Silicon Mac 上的 iOS 模拟器构建走 x86_64 (Rosetta)，
# 与 dqiu 独立工程行为完全对齐（dqiu Runner.app 实测也是 x86_64-only）。
# 绕开两个相关问题：
#   A) BIJKPlayer 老 fat framework 没有 arm64-simulator slice：
#        "Building for iOS-simulator, but linking in object file …
#         /IJKMediaPlayer[arm64](ijksdl_log.o) built for iOS"
#   B) flutter run -d <arm64-sim UDID> + ONLY_ACTIVE_ARCH=YES 时，
#      destination 的 native arch (arm64) 被 EXCLUDED_ARCHS 排除 →
#      app_tracking_transparency 等 swift module 编不出任何架构 →
#      "Module 'app_tracking_transparency' not found"
#
# 修复策略（三件套）：
#   1. EXCLUDED_ARCHS[sdk=iphonesimulator*] 含 arm64  （排除 arm64-sim）
#   2. ARCHS[sdk=iphonesimulator*] = x86_64           （强制只编 x86_64）
#   3. ONLY_ACTIVE_ARCH = NO                          （不锁 destination active arch）
# 三者缺一不可：(B) 问题在 flutter run -d <UDID> 才暴露，
# 单独跑 flutter build ios --simulator (generic) 不会触发，所以容易漏。
#
# 为什么需要两处注入：
#   (1) Runner 主工程 → ios/Flutter/Generated.xcconfig
#       Runner 读 Generated.xcconfig + Pods-Runner.<config>.xcconfig 决定自身架构。
#       flutter pub get 保留已有 EXCLUDED_ARCHS 行（实测），所以一次注入持久。
#   (2) Pods 各 target（链接 BIJKPlayer / IJKMediaPlayer.framework 的 target）
#       Pods 是独立 xcodeproj，不读 Runner 的 xcconfig。Flutter SDK 的
#       flutter_additional_ios_build_settings 在 Podfile.post_install 会硬覆盖
#       每个 Pods target 的 EXCLUDED_ARCHS[sdk=iphonesimulator*]= "$(inherited) i386"
#       (podhelper.rb:114)。所以必须在它之后再追加 arm64 / ARCHS / ONLY_ACTIVE_ARCH。
#       podspec 的 pod_target_xcconfig 既不会冒泡到 Runner，又会被 Flutter 覆盖，无效。
#
# Podfile patch 用 sentinel 包裹保证幂等，sync_secondary.sh 后续重跑都不会重复注入。
# dqiu 独立工程的 Generated.xcconfig 也是 "i386 arm64"，最终 Runner.app 为 x86_64，
# 这里只是让壳工程跟 dqiu 独立运行行为对齐。
# ------------------------------------------------------------
post_pub_get_dq_compatibility() {
  local cfg="$PROJECT_ROOT/ios/Flutter/Generated.xcconfig"
  local podfile="$PROJECT_ROOT/ios/Podfile"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] dq 将强制 ios/Flutter/Generated.xcconfig simulator 走 x86_64 (Rosetta)"
    log_info "[DRY-RUN] dq 将 patch ios/Podfile post_install，给 Pods 各 target 同步强制 x86_64"
    return 0
  fi

  # === (1) Runner 主工程：Generated.xcconfig ===
  # 写入三件套：EXCLUDED_ARCHS 含 arm64 / ARCHS=x86_64 / ONLY_ACTIVE_ARCH=NO。
  # flutter pub get 保留已有这些行（实测），所以一次注入持久。
  if [[ ! -f "$cfg" ]]; then
    log_warning "未找到 ios/Flutter/Generated.xcconfig，跳过 Runner 架构对齐"
  else
    python3 - "$cfg" <<'PY'
import sys
from pathlib import Path

cfg = Path(sys.argv[1])
lines = cfg.read_text(encoding="utf-8").splitlines()

# 需要 upsert 的设置（key 必须按 prefix 长度切，不能用 split('=',1)，因为 key 本身含 '='）。
desired = [
    # (key, default_value, merge_tokens)
    ("EXCLUDED_ARCHS[sdk=iphonesimulator*]", "i386 arm64", {"arm64"}),
    ("ARCHS[sdk=iphonesimulator*]", "x86_64", None),
    ("ONLY_ACTIVE_ARCH", "NO", None),
]

changed = False
out = list(lines)

for key, default, merge_tokens in desired:
    prefix = key + "="
    found_idx = -1
    for i, ln in enumerate(out):
        if ln.startswith(prefix):
            found_idx = i
            break

    if found_idx == -1:
        out.append(f"{prefix}{default}")
        changed = True
        continue

    cur = out[found_idx][len(prefix):].strip()
    if merge_tokens is None:
        # 简单 upsert：值不等就覆盖
        if cur != default:
            out[found_idx] = f"{prefix}{default}"
            changed = True
    else:
        # 集合合并（用于 EXCLUDED_ARCHS）
        toks = cur.split()
        added = False
        for tok in merge_tokens:
            if tok not in toks:
                toks.append(tok)
                added = True
        if added:
            out[found_idx] = f"{prefix}{' '.join(toks)}"
            changed = True

if changed:
    cfg.write_text("\n".join(out) + "\n", encoding="utf-8")
    print("changed")
else:
    print("unchanged")
PY
    log_success "dq Runner 架构已对齐: Generated.xcconfig simulator 走 x86_64 (Rosetta)"
  fi

  # === (2) Pods 各 target：Podfile post_install ===
  # 在 flutter_additional_ios_build_settings(target) 之后追加，覆盖 podhelper.rb
  # 写入的 "$(inherited) i386"。三件套：EXCLUDED arm64 / ARCHS x86_64 / ONLY_ACTIVE NO。
  # sentinel 包裹保证幂等，不会破坏其他 post_install 自定义。
  if [[ ! -f "$podfile" ]]; then
    log_warning "未找到 ios/Podfile，跳过 Pods 架构对齐注入"
    return 0
  fi

  python3 - "$podfile" <<'PY'
import re
import sys
from pathlib import Path

podfile = Path(sys.argv[1])
text = podfile.read_text(encoding="utf-8")

SENTINEL_OPEN = "# === dq-compat: simulator 强制 x86_64/Rosetta（由 compat_dq.sh 注入，勿删） ==="
SENTINEL_CLOSE = "# === /dq-compat ==="

# 兼容历史版本：旧 sentinel 替换为新 sentinel（同一职责扩容）。
LEGACY_SENTINEL = "# === dq-compat: BIJKPlayer arm64-simulator 排除（由 compat_dq.sh 注入，勿删） ==="
if LEGACY_SENTINEL in text and SENTINEL_OPEN not in text:
    # 删除旧块，让新块重写
    pattern_legacy = re.compile(
        re.escape("    " + LEGACY_SENTINEL) + r".*?" + re.escape("    " + SENTINEL_CLOSE) + r"\n",
        re.DOTALL,
    )
    text = pattern_legacy.sub("", text)

if SENTINEL_OPEN in text:
    print("podfile_already_patched")
    raise SystemExit(0)

block = (
    "    " + SENTINEL_OPEN + "\n"
    "    target.build_configurations.each do |config|\n"
    "      excluded = (config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] || '').to_s\n"
    "      unless excluded.split.include?('arm64')\n"
    "        config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = \"#{excluded} arm64\".strip\n"
    "      end\n"
    "      config.build_settings['ARCHS[sdk=iphonesimulator*]'] = 'x86_64'\n"
    "      config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'\n"
    "    end\n"
    "    " + SENTINEL_CLOSE + "\n"
)

# 注入位置：post_install 块里 flutter_additional_ios_build_settings(target) 之后。
pattern = re.compile(
    r"(^[ \t]*flutter_additional_ios_build_settings\(target\)[ \t]*\n)",
    re.MULTILINE,
)
new_text, n = pattern.subn(lambda m: m.group(1) + block, text, count=1)

if n == 0:
    # 兜底：Podfile 没有标准 post_install/flutter_additional_ios_build_settings 时，
    # 直接在文件末尾追加一个 post_install。Flutter 标准模板都不会走到这里。
    fallback = (
        "\n"
        "post_install do |installer|\n"
        "  installer.pods_project.targets.each do |target|\n"
        + block
        + "  end\n"
        "end\n"
    )
    new_text = text.rstrip() + "\n" + fallback
    print("podfile_patched_fallback")
else:
    print("podfile_patched")

podfile.write_text(new_text, encoding="utf-8")
PY

  log_success "dq Pods 架构已注入: ios/Podfile post_install 强制 simulator 走 x86_64 (sentinel 幂等)"
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
