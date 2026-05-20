#!/usr/bin/env bash
# compat_lgt.sh - lgt（聊个天 / IM 类）专用适配
# 方案沿用原 tx（yc001 / flutter3_frame）：GsUtil 多容器、聊天/线路/域名分层
# 源工程未接入前，入口为模板；接入后请按实际 main/MyApp 调整 import 与 initialize
# 由 sync_secondary.sh 自动 source

LGT_MIN_IOS_DEPLOYMENT_TARGET="${LGT_MIN_IOS_DEPLOYMENT_TARGET:-14.0}"

generate_lgt_entry_file() {
  local entry_file="$1"
  cat > "$entry_file" << 'EOF'
import 'package:flustars_flutter3/flustars_flutter3.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'main.dart';
import 'utils/gs_util.dart';

/// 次要模块入口 - lgt（聊个天）
class ModuleEntry {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;

    WidgetsFlutterBinding.ensureInitialized();
    LogUtil.init(isDebug: false);
    await WakelockPlus.enable();
    await GsUtil.init();
    await GsUtil.init(containerName: 'chat_user');
    await GsUtil.init(containerName: 'search_history');
    await GsUtil.init(containerName: 'api_url');
    await GsUtil.init(containerName: 'domains');
    await GsUtil.init(containerName: 'site_url');

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: Brightness.dark,
      statusBarIconBrightness: Brightness.light,
    ));

    _initialized = true;
  }

  static Widget getHomePage() {
    return const MyApp();
  }

  static Map<String, WidgetBuilder> getRoutes() {
    return {};
  }
}
EOF
}

fix_lgt_compatibility() {
  local _target_dir="$1"
  local _plugins_dir="$2"
  enforce_lgt_ios_minimum_target
  return 0
}

_lgt_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "未找到 python3，无法执行 lgt 兼容修复"
    return 1
  fi
  python3 "$@"
}

enforce_lgt_ios_minimum_target() {
  local minimum_target="${1:-$LGT_MIN_IOS_DEPLOYMENT_TARGET}"
  local podfile="$PROJECT_ROOT/ios/Podfile"
  local pbxproj="$PROJECT_ROOT/ios/Runner.xcodeproj/project.pbxproj"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] lgt 将确保当前工程 iOS 最低版本不低于 $minimum_target"
    return 0
  fi

  if [[ ! -f "$podfile" || ! -f "$pbxproj" ]]; then
    log_warning "lgt iOS 工程文件不完整，跳过 deployment target 对齐"
    return 0
  fi

  local changed
  if ! changed=$(_lgt_python3 - "$minimum_target" "$podfile" "$pbxproj" <<'PY'
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

def replace_target(match: re.Match[str]) -> str:
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
    log_warning "lgt iOS 最低版本对齐失败，请手动检查 Podfile 和 project.pbxproj"
    return 0
  fi

  if [[ "$changed" == "changed" ]]; then
    log_success "lgt iOS 最低版本已对齐到 $minimum_target"
  else
    log_info "lgt iOS 最低版本已满足 >= $minimum_target"
  fi
}

apply_lgt_pubspec_overrides() {
  local target_pubspec="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] lgt 将对齐 package_info_plus 到 ^9.0.1"
    return 0
  fi
  if [[ ! -f "$target_pubspec" ]]; then
    log_warning "未找到 pubspec.yaml，跳过 lgt 依赖版本对齐"
    return 0
  fi
  python3 - "$target_pubspec" <<'PY'
from pathlib import Path
import re
import sys
pubspec = Path(sys.argv[1])
text = pubspec.read_text()
updated = re.sub(
    r'(^\s*package_info_plus:\s*).*$',
    r'\1^9.0.1',
    text,
    count=1,
    flags=re.MULTILINE,
)
if updated != text:
    pubspec.write_text(updated)
PY
  log_success "lgt 依赖版本已对齐: package_info_plus -> ^9.0.1"
}
