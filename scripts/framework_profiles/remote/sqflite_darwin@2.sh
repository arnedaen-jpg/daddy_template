#!/bin/bash
# =============================================
#   Profile: sqflite_darwin (远程依赖)
#   版本: 2.4.x  (纯 ObjC, SPM 结构)
#   iOS/macOS 源文件:
#     darwin/sqflite_darwin/Sources/sqflite_darwin/
#       SqflitePlugin.{h,m}            ← 主入口 + Flutter Plugin 注册
#       SqfliteDatabase.{h,m}
#       SqfliteCursor.{h,m}
#       SqfliteOperation.{h,m}         ← 4 个 @implementation
#       SqfliteDarwinDatabase.{h,m}
#       SqfliteDarwinResultSet.{h,m}
#       SqfliteDarwinDatabaseAdditions.{h,m}
#       SqfliteDarwinDatabaseQueue.h
#       SqfliteImport.h
#       SqfliteDarwinDB.h
#       include/sqflite_darwin/SqflitePluginPublic.h
#       include/sqflite_darwin/SqfliteImportPublic.h
#
#   Status: draft
#   说明: SqflitePlugin 暴露 Flutter MethodChannel；所有 Sqflite* 公开类的
#         实例方法是动态调度入口，不可改名。L1 只动 static 函数。
#         考虑到 sqflite 是数据库底层，方法顺序打乱(L2) 有风险（涉及多个 @implementation 块），
#         保守起见 L2/L3 仅做"温和"打乱并配合死分支注入。
# =============================================

PROFILE_NAME="sqflite_darwin"
PROFILE_VERSION="2.4"
PROFILE_STATUS="draft"

# 公开类 / Flutter 注册 / 跨文件互调的关键名 — 不允许重命名
PROFILE_PROTECTED=(
    "SqflitePlugin"
    "SqfliteDatabase"
    "SqfliteCursor"
    "SqfliteOperation"
    "SqfliteBatchOperation"
    "SqfliteMethodCallOperation"
    "SqfliteQueuedOperation"
    "SqfliteDarwinDatabase"
    "SqfliteDarwinResultSet"
    "SqfliteDarwinDatabaseAdditions"
    "SqfliteDarwinDatabaseQueue"
    "SqfliteDarwinDB"
    "SqfliteDarwinStatement"
    "register"
    "registerWithRegistrar"
    "handle"
    "handleMethodCall"
    "toSqlValue"
    "databaseWithPath"
    "databaseWithURL"
    "_channelName"
)

PROFILE_SKIP_FILES=()

profile_apply() {
    local plugin_dir="$1"
    local level="$2"

    local src_dir
    src_dir=$(bt_find_src_dir "$plugin_dir" "sqflite_darwin")
    [[ -z "$src_dir" ]] && return 1

    bt_inject_classes "$src_dir" "$PROFILE_NAME" 6

    if [[ "$level" == "L1" || "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_rename_static_functions "$f" "${PROFILE_PROTECTED[@]}"
        done
    fi

    if [[ "$level" == "L2" || "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_reorder_objc_methods "$f"
        done
    fi

    if [[ "$level" == "L3" ]]; then
        for f in "$src_dir"/*.m; do
            [[ -f "$f" ]] && bt_inject_dead_branches "$f"
        done
    fi
}
