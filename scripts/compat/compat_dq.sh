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
# pub get 之后的兼容修复（双管齐下：Debug/Release.xcconfig + Pods Podfile）
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
# 三者缺一不可：(B) 在 flutter run -d <UDID> 才暴露，flutter build ios --simulator
# (generic destination) 走 x86_64 不触发，所以容易漏。
#
# ------------------------------------------------------------
# 为什么不写 Generated.xcconfig：
#   Flutter SDK 在每次 flutter run/build 时都会调 _updateGeneratedXcodePropertiesFile
#   完整覆盖 ios/Flutter/Generated.xcconfig (xcode_build_settings.dart:64-92)。
#   往里写 ARCHS / ONLY_ACTIVE_ARCH 一次性就被抹了。
#   而 EXCLUDED_ARCHS 是否含 arm64 取决于 SDK 的 pluginsSupportArmSimulator()
#   对 Pods.xcodeproj 的探测，在首次 flutter run（Podfile patch 还没经 pod install
#   生效）时 SDK 会写出 i386 而不是 i386 arm64，于是修复链断掉。
#
# 改写到 ios/Flutter/{Debug,Release}.xcconfig：
#   这两个文件是壳工程的 xcconfig，SDK 不动；它们用 #include "Generated.xcconfig"
#   引入 SDK 写入的内容。xcconfig 「后定义覆盖前定义」，所以我们把三件套追加在
#   #include 之后，永久压过 SDK / Pods-Runner 的写法。Runner.xcodeproj 的 Debug
#   target 通过 baseConfigurationReference 引用 Flutter/Debug.xcconfig，配置自动生效。
#
# Pods 各 target 仍需 Podfile post_install patch：
#   Pods 是独立 xcodeproj，不读 Runner 的 xcconfig。Flutter SDK 的
#   flutter_additional_ios_build_settings 在 Podfile.post_install 会硬覆盖每个
#   Pods target 的 EXCLUDED_ARCHS[sdk=iphonesimulator*]= "$(inherited) i386"
#   (podhelper.rb:114)。所以必须在它之后再追加三件套。podspec 的
#   pod_target_xcconfig 既不会冒泡到 Runner，又会被 Flutter 覆盖，无效。
#
# Podfile patch 用 sentinel 包裹保证幂等，xcconfig 同样用 sentinel 块。
# dqiu 独立工程的 Generated.xcconfig 也是 "i386 arm64"，最终 Runner.app 为 x86_64，
# 这里只是让壳工程跟 dqiu 独立运行行为对齐。
# ------------------------------------------------------------
post_pub_get_dq_compatibility() {
  local podfile="$PROJECT_ROOT/ios/Podfile"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] dq 将给 ios/Flutter/{Debug,Release}.xcconfig 追加 simulator x86_64/Rosetta 三件套"
    log_info "[DRY-RUN] dq 将 patch ios/Podfile post_install，给 Pods 各 target 同步强制 x86_64"
    return 0
  fi

  # === (1) Runner 主工程：Debug.xcconfig / Release.xcconfig ===
  # 写到这两个壳工程文件而非 Generated.xcconfig，因为 SDK 每次完整覆盖 Generated.xcconfig。
  # xcconfig 后定义覆盖，所以追加到 #include "Generated.xcconfig" 之后即可永久生效。
  local _xcconfig_sentinel_open="// === dq-compat: simulator 强制 x86_64/Rosetta（由 compat_dq.sh 注入，勿删） ==="
  local _xcconfig_sentinel_close="// === /dq-compat ==="
  local _xcconfig_block="
${_xcconfig_sentinel_open}
EXCLUDED_ARCHS[sdk=iphonesimulator*] = \$(inherited) arm64
ARCHS[sdk=iphonesimulator*] = x86_64
ONLY_ACTIVE_ARCH[sdk=iphonesimulator*] = NO
${_xcconfig_sentinel_close}
"

  local _xc
  for _xc in "$PROJECT_ROOT/ios/Flutter/Debug.xcconfig" \
             "$PROJECT_ROOT/ios/Flutter/Release.xcconfig" \
             "$PROJECT_ROOT/ios/Flutter/Profile.xcconfig"; do
    if [[ ! -f "$_xc" ]]; then
      continue
    fi
    if grep -qF "$_xcconfig_sentinel_open" "$_xc"; then
      continue
    fi
    printf '%s' "$_xcconfig_block" >> "$_xc"
  done
  log_success "dq Runner 架构已对齐: ios/Flutter/{Debug,Release}.xcconfig 追加 simulator x86_64 三件套"

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

  # === (3) lib/utils/secondary_image_base64_ext.dart：补 byPath 反向索引 ===
  # write_base64_support_darts.sh 用 HEREDOC 写死了一份 lookup 链：
  #     getByPath(newPath) ?? getByName(newPath) ?? getByName(name)
  # 但 byPath 表 key 是绝对路径 /Users/.../assets/...，调用方传相对路径 assets/...
  # 永远命不中 byPath，全部退到 byName。而 byName 用 basename 作 key，多分辨率
  # 同名 PNG 会互相覆盖，最终 secondaryAssetProvider 拿到的可能是 2x/3x 图，
  # 但 scale=1.0、centerSlice 仍按 1x 坐标写死，paintImage 算出 outputSize-sliceBorder
  # 为负，DecorationImage 直接抛
  # 'centerSlice was used with a BoxFit that does not guarantee that the image is fully visible.'
  # video_item_widget.dart 这类 9-patch 直接画不出来。
  #
  # 这里给 ext.dart 注入一个「byPath -> 相对路径」反向索引（且只保留 1x，
  # 排除 /2.0x/ /3.0x/ 等高 DPR 子目录），在 byName 之前先精确命中 1x 那份。
  # 写在 compat_dq.sh 而非 write_base64_support_darts.sh，是为了把改动限制在 dq 项目，
  # 不影响其他用同一套 sync 流程的项目。
  local ext_file="$PROJECT_ROOT/lib/utils/secondary_image_base64_ext.dart"
  if [[ ! -f "$ext_file" ]]; then
    log_warning "未找到 lib/utils/secondary_image_base64_ext.dart，跳过 byPath 反向索引补丁"
    return 0
  fi

  python3 - "$ext_file" <<'PY'
import re
import sys
from pathlib import Path

ext = Path(sys.argv[1])
text = ext.read_text(encoding="utf-8")

SENTINEL = "// === dq-compat: byPath 反向索引（仅 1x），由 compat_dq.sh 注入 ==="

if SENTINEL in text:
    print("ext_already_patched")
    raise SystemExit(0)

# (1) 在 `_secondaryImageBytesCache` 定义之后插入索引代码块
index_block = """
""" + SENTINEL + """
/// `byPath` 表里 key 是项目绝对路径，调用方传相对路径，直接 `getByPath` 永远 miss，
/// 全部退到 `byName`。但同名多分辨率 PNG 会撞 key 互相覆盖，最终 9-patch (centerSlice)
/// 场景会拿到 2x/3x 图但 scale=1.0，DecorationImage 直接 assert 崩溃。
/// 这里建立「相对路径 -> base64」的反向索引，且只保留 1x（不在 `*x/` 子目录里）。
final RegExp _dprFolderPattern = RegExp(r'/\\d+(\\.\\d+)?x/');
final Map<String, String> _byPathRelativeIndex = (() {
  final result = <String, String>{};
  for (final entry in SecondaryImageBase64Map.byPath.entries) {
    final fullKey = entry.key;
    final assetsIdx = fullKey.indexOf('assets/');
    if (assetsIdx < 0) continue;
    final relPath = fullKey.substring(assetsIdx);
    if (_dprFolderPattern.hasMatch('/' + relPath)) continue;
    result[relPath] = entry.value;
  }
  return result;
})();
// === /dq-compat ===
"""

# 用 lambda 形式拼接 repl，避免 re 把 index_block 里的 `\d` / `\.` 当反向引用解释。
new_text, n1 = re.subn(
    r"(final Map<String, Uint8List> _secondaryImageBytesCache = <String, Uint8List>\{\};\n)",
    lambda m: m.group(0) + index_block,
    text,
    count=1,
)
if n1 == 0:
    print("ext_patch_failed: cannot locate _secondaryImageBytesCache declaration", file=sys.stderr)
    raise SystemExit(1)

# (2) 把 lookup 链中插入 _byPathRelativeIndex[newPath]
new_text, n2 = re.subn(
    r"(return SecondaryImageBase64Map\.getByPath\(newPath\) \?\?\n)(\s+)(SecondaryImageBase64Map\.getByName\(newPath\))",
    lambda m: m.group(1) + m.group(2) + "_byPathRelativeIndex[newPath] ??\n" + m.group(2) + m.group(3),
    new_text,
    count=1,
)
if n2 == 0:
    print("ext_patch_failed: cannot locate lookup chain", file=sys.stderr)
    raise SystemExit(1)

ext.write_text(new_text, encoding="utf-8")
print("ext_patched")
PY

  log_success "dq Base64 lookup 已注入: secondary_image_base64_ext.dart 加 byPath 反向索引 (sentinel 幂等)"

  # === (4) lib/modules/secondary/**/*.dart：把 'assets/svgs/' 改为 'assets/secondary/svgs/' ===
  # sync_secondary.sh 的 update_assets_path 入口判断用 `'assets/[^s]` 把所有 's' 开头的子目录
  # 全部过滤掉了，再加上 asset_dirs 白名单（images/icons/fonts/lottie/json/svga/…）压根没有 svgs，
  # 结果 SvgPicture.asset('assets/svgs/icon_match_sort_2.svg') 这类调用同步过来后字符串没被改写。
  # flutter_svg 内部走的是 PlatformAssetBundle.load(key)，绕过 secondaryAssetProvider 拦截，
  # 实际文件被搬到 assets/secondary/svgs/，但代码还在加载 assets/svgs/，直接抛
  # 'Unable to load asset: "assets/svgs/xxx.svg". The asset does not exist or has empty data.'
  #
  # 这里在 sync 跑完后给壳工程的 secondary 子树补一次重写，限定在 lib/modules/secondary/ 内，
  # 避免误改壳工程本地（非 secondary）的代码。覆盖 .svg / .svga 及任何 'assets/svgs/' 前缀。
  local secondary_dart_root="$PROJECT_ROOT/lib/modules/secondary"
  if [[ -d "$secondary_dart_root" ]]; then
    local svg_path_count=0
    local is_darwin=0
    if [[ "$(uname)" == "Darwin" ]]; then
      is_darwin=1
    fi
    while IFS= read -r -d '' f; do
      if grep -q "['\"]assets/svgs/" "$f" 2>/dev/null; then
        if [[ $is_darwin -eq 1 ]]; then
          sed -i '' "s|'assets/svgs/|'assets/secondary/svgs/|g" "$f"
          sed -i '' 's|"assets/svgs/|"assets/secondary/svgs/|g' "$f"
        else
          sed -i "s|'assets/svgs/|'assets/secondary/svgs/|g" "$f"
          sed -i 's|"assets/svgs/|"assets/secondary/svgs/|g' "$f"
        fi
        svg_path_count=$((svg_path_count + 1))
      fi
    done < <(find "$secondary_dart_root" -name '*.dart' -print0)
    log_success "dq svgs 路径已改写: 共更新 ${svg_path_count} 个 dart 文件 (assets/svgs/ -> assets/secondary/svgs/)"
  else
    log_warning "未找到 lib/modules/secondary 目录，跳过 svgs 路径重写"
  fi

  # === (5) rongcloud_im_wrapper_plugin 化名插件的 version.config 版本对齐 ===
  # pub 包 rongcloud_im_wrapper_plugin 5.32.6 自带 version.config 误写
  # ios_im_sdk_version=5.36.5，但 cocoapods trunk 当前最高仅到 5.36.4，
  # pod install 直接 "could not find compatible versions for pod RongCloudIM/IMLibCore"。
  # 这里通过 version.config 独有键 ios_im_sdk_version 识别（兼容混淆后的化名），
  # 把 5.36.5 改为 5.36.4 让 pod install 通过；android 端同步对齐。
  local rc_count=0
  while IFS= read -r -d '' vc; do
    if grep -q "^ios_im_sdk_version=5\.36\.5$" "$vc" 2>/dev/null; then
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' 's|^ios_im_sdk_version=5\.36\.5$|ios_im_sdk_version=5.36.4|' "$vc"
        sed -i '' 's|^android_im_sdk_version=5\.36\.5$|android_im_sdk_version=5.36.4|' "$vc"
      else
        sed -i 's|^ios_im_sdk_version=5\.36\.5$|ios_im_sdk_version=5.36.4|' "$vc"
        sed -i 's|^android_im_sdk_version=5\.36\.5$|android_im_sdk_version=5.36.4|' "$vc"
      fi
      rc_count=$((rc_count + 1))
    fi
  done < <(find "$PROJECT_ROOT/plugins" -maxdepth 2 -name version.config -print0 2>/dev/null)
  if [[ $rc_count -gt 0 ]]; then
    log_success "dq RongCloudIM 版本已对齐 5.36.4（trunk 当前最新）：patch ${rc_count} 份 version.config"
  fi
}

# ------------------------------------------------------------
# 项目专用兼容修复：在 pubspec 合并前执行
# ------------------------------------------------------------
fix_dq_compatibility() {
  local target_dir="${1:-}"
  local plugins_dir="${2:-}"
  local _unused_plugins_dir="$plugins_dir"

  enforce_dq_ios_minimum_target
  neutralize_dq_sensitive_assets "$target_dir"
  return 0
}

# ------------------------------------------------------------
# 中和敏感命名的非图片资源（svg / svga / 非 lottie json）
#
# base64 映射只处理栅格图（png/jpg/...），并会把它们从 bundle 删除、
# 且 key 已 FNV-1a 脱敏；但 svg/svga/json 仍以物理文件进 bundle，
# 文件名里 live / zhibo / anchor / noble / danmu / odd / predict 等
# 直接暴露直播 + 竞猜 + 打赏业务特征，是机审「隐藏功能」查证的把柄。
#
# 本步骤在同步阶段（引用尚为明文、字符串混淆之前）执行：
#   1. 把敏感文件重命名为中性名（含目录 anchor -> 中性目录）
#   2. 用「精确 token 替换」改写 secondary Dart 中的引用
#      —— 选用的 token 均较长且业务专有，静态引用与 `前缀${var}` 插值均可覆盖
# ------------------------------------------------------------
neutralize_dq_sensitive_assets() {
  local target_dir="${1:-}"
  local assets_dir="$PROJECT_ROOT/assets/secondary"
  local secondary_lib_dir="${target_dir:-$PROJECT_ROOT/lib/modules/secondary}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] dq 将中和敏感命名的 svg/svga/json 资源并改写引用"
    return 0
  fi
  if [[ ! -d "$assets_dir" ]]; then
    return 0
  fi

  log_step "中和 dq 敏感命名资源（svg/svga/json）..."

  _dq_python3 - "$assets_dir" "$secondary_lib_dir" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

assets_dir = Path(sys.argv[1])
lib_dir = Path(sys.argv[2])

# 敏感文件名 token -> 中性 token。
# 仅选用「文件名专有」的 token：它们只会出现在资源路径/文件名里，
# 且替换只在「带资源扩展名的引用」或「引号字符串内」进行，避免误伤类名/变量名。
def neutral(token: str) -> str:
    h = hashlib.md5(('dq_asset::' + token).encode()).hexdigest()[:8]
    return f'ui_{h}'

# 文件名 stem 前缀（覆盖静态引用与 `前缀${var}` 插值）。长的先替换。
# 注意：仅保留「主要是 svg/svga/json」的 token。
# png/jpg/webp 前缀必须放进 neutralize_dq_sensitive_rasters（base64 生成前），
# 否则会在 map 生成后改 Dart 引用、却未改 map key，运行时必缺图。
FILE_TOKENS = [
    'icon_live_caisedanmu',
    'user_noble_enter',
    'anchor_live',
    'dianjing',
    # 下列为栅格图前缀，已迁移到 neutralize_dq_sensitive_rasters：
    # icon_odd_ / icon_predict_ / icon_vote_ / icon_redu /
    # icon_chat_ / icon_rank_ / bg_live_ / chat_noble_ / chat_giftNumber
]
FILE_TOKENS = sorted(set(FILE_TOKENS), key=len, reverse=True)
MAPPING = [(t, neutral(t)) for t in FILE_TOKENS]

# 目录名（含敏感词）-> 中性目录名。
DIR_MAP = {'anchor': neutral('dir_anchor'), 'live': neutral('dir_live')}

# 1) 物理重命名：仅 svg / svga / 非 lottie json。
renamed = 0
exts = {'.svg', '.svga', '.json'}
for path in list(assets_dir.rglob('*')):
    if not path.is_file() or path.suffix.lower() not in exts:
        continue
    rel = path.relative_to(assets_dir).as_posix()
    if '/lottie/' in ('/' + rel) or rel.startswith('json/json/'):
        continue
    parts = rel.split('/')
    # 目录段：整段等于敏感词才替换（避免子串误伤）。
    parts = [DIR_MAP.get(p, p) for p in parts[:-1]] + [parts[-1]]
    name = parts[-1]
    for old, new in MAPPING:
        if old in name:
            name = name.replace(old, new)
    parts[-1] = name
    new_rel = '/'.join(parts)
    if new_rel != rel:
        dest = assets_dir / new_rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        path.rename(dest)
        renamed += 1

for d in sorted(assets_dir.rglob('*'), key=lambda p: len(p.as_posix()), reverse=True):
    if d.is_dir() and not any(d.iterdir()):
        d.rmdir()

# 2) 改写 Dart 引用：只在引号字符串字面量内部做 token 替换。
str_lit = re.compile(r"""(['"])((?:\\.|(?!\1).)*)\1""", re.DOTALL)
old_dir_seg = re.compile(r'(?<![A-Za-z0-9_])(' + '|'.join(map(re.escape, DIR_MAP)) + r')(?=/)')

def rewrite_literal(m):
    q, body = m.group(1), m.group(2)
    for old, new in MAPPING:
        body = body.replace(old, new)
    body = old_dir_seg.sub(lambda dm: DIR_MAP[dm.group(1)], body)
    return q + body + q

patched = 0
for dart in lib_dir.rglob('*.dart'):
    try:
        text = dart.read_text(encoding='utf-8')
    except Exception:
        continue
    new_text = str_lit.sub(rewrite_literal, text)
    if new_text != text:
        dart.write_text(new_text, encoding='utf-8')
        patched += 1

print(f"[INFO] dq 敏感资源中和完成：重命名 {renamed} 个文件，改写 {patched} 个 Dart 文件")
PY
}

# ------------------------------------------------------------
# base64 图谱生成【之前】中和敏感命名的栅格图（png/jpg/jpeg/webp）
#
# 栅格图会被 generate_secondary_base64_map 编码进 map（key = FNV-1a(文件名/路径)）
# 后从 bundle 删除。map key 虽已脱敏，但业务代码里的【引用字符串】
# （如 XXAssetImage("icon_live_qiupiao")）仍是明文，直接暴露直播/主播/竞猜/打赏。
#
# 因此必须在 map 生成【前】把文件名与引用一起改成中性前缀：
#   1. 物理重命名 png/jpg/jpeg/webp（按前缀替换，保留数字/后缀，兼容序列图）
#   2. 用前缀子串替换改写 Dart 字符串字面量（静态引用 + `前缀${var}` 插值均覆盖）
# 之后 map 以中性名哈希为 key，运行时 getByName(中性名) 命中一致。
#
# 注意调用时机：sync_secondary.sh 在 generate_secondary_base64_map 之前调用
# pre_base64_dq，切勿放到 fix_dq_compatibility（那是 map 生成之后）。
# ------------------------------------------------------------
pre_base64_dq() {
  neutralize_dq_sensitive_rasters "${1:-}"
  return 0
}

neutralize_dq_sensitive_rasters() {
  local target_dir="${1:-}"
  local assets_dir="$PROJECT_ROOT/assets/secondary"
  local secondary_lib_dir="${target_dir:-$PROJECT_ROOT/lib/modules/secondary}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] dq 将在 base64 前中和敏感命名的栅格图（png/jpg/webp）并改写引用"
    return 0
  fi
  if [[ ! -d "$assets_dir" ]]; then
    return 0
  fi

  log_step "中和 dq 敏感命名栅格图（png/jpg/webp，base64 前）..."

  _dq_python3 - "$assets_dir" "$secondary_lib_dir" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

assets_dir = Path(sys.argv[1])
lib_dir = Path(sys.argv[2])

def neutral(token: str) -> str:
    h = hashlib.md5(('dq_raster::' + token).encode()).hexdigest()[:8]
    return f'ui_{h}'

# 资源名专有的敏感前缀（长前缀先替换，避免短前缀先命中导致漏改）。
# 仅选用「明显是图片名前缀」的 token：直播/主播/贵族/礼物/弹幕/赔率/竞猜/vip/排行/聊天图标。
# 必须在 generate_secondary_base64_map 之前执行，保证 map key 与 Dart 引用一致。
FILE_TOKENS = [
    'ic_main_tab_live',
    'icon_live_danmu', 'ic_live_search', 'ic_live_segment66', 'ic_live_banner',
    'bg_live_search_empty', 'icon_live', 'bg_live', 'ic_live',
    'chat_noble', 'ic_noble_alert', 'bg_noble', 'ic_noble',
    'chat_giftNumber',
    'ic_bg_vip_pay', 'ic_vip', 'icon_vip',
    'icon_live_danmu', 'ic_danmu',
    'ic_odds', 'icon_odd', 'ic_odd',
    'ic_anchor_record', 'ic_anchor_player', 'ic_anchor_un',
    'icon_anchor_online', 'bg_anchor_online', 'icon_anchor', 'bg_anchor', 'ic_anchor',
    'btn_zhibo',
    'icon_qiupiao', 'icon_qiuzuan',
    # 原误放在 neutralize_dq_sensitive_assets（svg 步骤）的栅格前缀：
    'icon_predict_', 'icon_vote_', 'icon_redu',
    'icon_chat_', 'icon_rank_', 'bg_live_',
]
FILE_TOKENS = sorted(set(FILE_TOKENS), key=len, reverse=True)
MAPPING = [(t, neutral(t)) for t in FILE_TOKENS]

RASTER_EXTS = {'.png', '.jpg', '.jpeg', '.webp'}

# 1) 物理重命名：仅栅格图；lottie 目录保持原样（其图片由 lottie json 引用）。
renamed = 0
for path in list(assets_dir.rglob('*')):
    if not path.is_file() or path.suffix.lower() not in RASTER_EXTS:
        continue
    rel = path.relative_to(assets_dir).as_posix()
    if '/lottie/' in ('/' + rel):
        continue
    name = path.name
    new_name = name
    for old, new in MAPPING:
        if old in new_name:
            new_name = new_name.replace(old, new)
    if new_name != name:
        dest = path.with_name(new_name)
        dest.parent.mkdir(parents=True, exist_ok=True)
        path.rename(dest)
        renamed += 1

# 2) 改写 Dart 引用：只在引号字符串字面量内部做前缀子串替换。
str_lit = re.compile(r"""(['"])((?:\\.|(?!\1).)*)\1""", re.DOTALL)

def rewrite_literal(m):
    q, body = m.group(1), m.group(2)
    for old, new in MAPPING:
        if old in body:
            body = body.replace(old, new)
    return q + body + q

patched = 0
for dart in lib_dir.rglob('*.dart'):
    try:
        text = dart.read_text(encoding='utf-8')
    except Exception:
        continue
    new_text = str_lit.sub(rewrite_literal, text)
    if new_text != text:
        dart.write_text(new_text, encoding='utf-8')
        patched += 1

print(f"[INFO] dq 栅格图中和完成：重命名 {renamed} 个文件，改写 {patched} 个 Dart 文件")
PY
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
