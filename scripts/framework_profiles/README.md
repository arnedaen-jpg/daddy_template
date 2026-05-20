# Framework 混淆适配系统

## 目录结构

```
framework_profiles/
├── base_transforms.sh                  # 基础变换函数库 (L0-L3)
├── README.md                           # 本文件
├── remote/                             # 远程依赖 (pub.dev) 的混淆 profile
│   ├── device_info_plus@11.sh          # 版本精确 profile (v11.x)
│   ├── device_info_plus@10.sh          # 版本精确 profile (v10.x)
│   ├── connectivity_plus.sh            # 通用 profile (所有版本)
│   └── ...
└── local/                              # 本地 fork 依赖的混淆 profile
    ├── video_player.sh                 # 示例
    └── ...

project_manifests/
├── template.conf              # 模板
├── hlw.conf                   # 各项目的混淆清单
├── 51pc.conf
└── ...
```

## Profile 版本匹配

不同项目可能使用同一个依赖的不同版本。Profile 按主版本号匹配：

```
查找优先级（以 device_info_plus 11.2.0 为例）:
  1. remote/device_info_plus@11.sh    ← 主版本精确匹配（优先）
  2. remote/device_info_plus.sh       ← 通用（任意版本）
```

- 如果插件的**主版本号变化**（如 v10 → v11），通常意味着文件结构/API 有变，需要独立 profile
- 如果只是次版本升级（如 11.2.0 → 11.3.0），通常共用同一 profile
- 加载后会校验 `PROFILE_VERSION` 的主版本号与实际版本是否一致，不一致时自动降级 L0

## Profile 文件格式

每个 `.sh` 文件是一个 shell 脚本，定义该依赖的安全变换：

```bash
# 基本信息
PROFILE_NAME="connectivity_plus"
PROFILE_VERSION="6.1"          # 匹配的主版本 (会与实际版本校验)
PROFILE_STATUS="verified"      # draft | verified | disabled

# 不可修改的符号（公开 API、Flutter 注册入口）
PROFILE_PROTECTED=(
    "ConnectivityPlusPlugin"
    "registerWithRegistrar"
    "handleMethodCall"
)

# 应用变换
profile_apply() {
    local plugin_dir="$1"
    # 调用 base_transforms.sh 中的函数
    bt_rename_static_functions "$plugin_dir/ios/..." "${PROFILE_PROTECTED[@]}"
    bt_inject_dead_branches "$plugin_dir/ios/..."
    bt_inject_classes "$plugin_dir/ios/..." "$PROFILE_NAME" 3
}
```

## 项目清单格式 (project_manifests/*.conf)

```conf
# 格式: type:name:version:level
# type:    remote | local
# level:   L0 (仅注入) | L1 (+ 符号重命名) | L2 (+ 方法打乱) | L3 (+ 死分支) | disabled
# version: 仅 remote 需要，local 留空

remote:connectivity_plus:6.1.3:L1
remote:device_info_plus:11.2.0:L0
local:video_player::L1
local:flutter_inappwebview::disabled
```

## 变换层次

| 层次 | 操作 | 风险 | 效果 |
|------|------|------|------|
| L0 | 注入唯一 ObjC 类 | 无 | 低 |
| L1 | + 内部符号重命名 (static/private) | 低 | 高 |
| L2 | + 方法实现顺序打乱 | 低 | 中 |
| L3 | + 死分支注入到现有方法体 | 中 | 中 |

## 工作流

1. 新增依赖时，创建 profile 文件，status 设为 `draft`
2. 在 project manifest 中设为 `L0`（最安全级别）
3. 测试通过后逐步提升：`L0` → `L1` → `L2` → `L3`
4. 全部测试通过后 status 改为 `verified`
5. 同版本远程依赖的 profile 可跨项目共用
