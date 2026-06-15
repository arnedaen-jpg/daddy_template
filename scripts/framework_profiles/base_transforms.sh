#!/bin/bash

# ===========================================
#   Framework 混淆基础变换函数库
#
#   提供可复用的原生代码变换原语，供各 profile 调用。
#   每个函数设计为：安全、幂等、可验证。
#
#   变换层次（按风险从低到高）:
#     L0: 注入唯一类（不修改原码）
#     L1: 内部符号重命名（static 函数、私有方法）
#     L2: 方法顺序打乱（@implementation 块内）
#     L3: 死分支注入（在方法体开头插入永假分支）
# ===========================================

# 需要外部设置: SEED, DRY_RUN, VERBOSE
# 需要外部函数: hash_derive(), log_info(), log_warning()
# 由 mutate_plugin 设置: _PROFILE_SRC_DIRS[], _PROFILE_CURRENT_NAME

# =============================================
# 通用: Profile 源码目录查找
# =============================================

bt_is_non_runtime_path() {
    local path="$1"
    case "$path" in
        */Tests/*|*/RunnerTests/*|*/test/*|*/tests/*|*/example/*|*/examples/*|*/integration_test/*|*/test_driver/*|*/__tests__/*)
            return 0
            ;;
    esac
    return 1
}

# 查找 profile 的 iOS 源码目录
# 优先使用 mutate_plugin 已发现的 _PROFILE_SRC_DIRS（重命名后路径安全），
# 再尝试按 original_name 搜索，最后按 current_name 搜索
# 用法: bt_find_src_dir <plugin_dir> <original_subdir_name>
bt_find_src_dir() {
    local plugin_dir="$1"
    local original_name="$2"

    # 优先：使用 mutate_plugin 预发现的 _PROFILE_SRC_DIRS
    if [[ ${#_PROFILE_SRC_DIRS[@]} -gt 0 ]]; then
        echo "${_PROFILE_SRC_DIRS[0]}"
        return
    fi

    # 尝试按 original name
    local dir
    dir=$(find "$plugin_dir" -path "*/Sources/${original_name}" -type d \
        -not -path "*/include/*" \
        -not -path "*/Tests/*" -not -path "*/RunnerTests/*" \
        -not -path "*/test/*" -not -path "*/tests/*" \
        -not -path "*/example/*" -not -path "*/examples/*" \
        -not -path "*/integration_test/*" -not -path "*/test_driver/*" \
        2>/dev/null | head -1)
    [[ -n "$dir" ]] && echo "$dir" && return

    # 尝试按 current name
    local current
    current="${_PROFILE_CURRENT_NAME:-$(basename "$plugin_dir")}"
    dir=$(find "$plugin_dir" -path "*/Sources/${current}" -type d \
        -not -path "*/include/*" \
        -not -path "*/Tests/*" -not -path "*/RunnerTests/*" \
        -not -path "*/test/*" -not -path "*/tests/*" \
        -not -path "*/example/*" -not -path "*/examples/*" \
        -not -path "*/integration_test/*" -not -path "*/test_driver/*" \
        2>/dev/null | head -1)
    [[ -n "$dir" ]] && echo "$dir" && return

    # 最终回退：找到任何 iOS 源文件的目录
    dir=$(find "$plugin_dir" -type f \( -name "*.swift" -o -name "*.m" \) \
         -not -name "Package.swift" -not -name "${INJECT_PREFIX}*" \
         -not -path "*/Tests/*" -not -path "*/RunnerTests/*" \
         -not -path "*/test/*" -not -path "*/tests/*" \
         -not -path "*/example/*" -not -path "*/examples/*" \
         -not -path "*/integration_test/*" -not -path "*/test_driver/*" \
         \( -path "*/ios/*" -o -path "*/darwin/*" \) 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    [[ -n "$dir" ]] && echo "$dir"
}

# =============================================
# L0: 注入唯一 ObjC 类（已有功能的封装）
# =============================================

# 在指定目录注入 N 个唯一 ObjC 类文件
# 用法: bt_inject_classes <target_dir> <namespace> [count]
# count 默认 5；每个类现在包含更多属性和方法
bt_inject_classes() {
    local target_dir="$1"
    local namespace="$2"
    local count="${3:-5}"
    if declare -f native_class_count >/dev/null 2>&1; then
        count=$(native_class_count "$count")
    fi

    if declare -f generate_mutation_file_batch >/dev/null 2>&1; then
        generate_mutation_file_batch "$namespace" "$count" "$target_dir"
        return
    fi

    for (( i=0; i<count; i++ )); do
        generate_mutation_file "$namespace" "$i" "$target_dir"
    done
}

# =============================================
# L1: 内部符号重命名
# =============================================

# 重命名 ObjC 文件中的 static 函数
# 只改文件内部作用域的符号，不影响公开 API
# 用法: bt_rename_static_functions <file> [protected_pattern...]
bt_rename_static_functions() {
    local file="$1"
    shift
    local protected_patterns=("$@")

    [[ -f "$file" ]] || return 0

    local file_hash
    file_hash=$(hash_derive "${SEED}:rename:$(basename "$file")")
    local prefix="_zt${file_hash:0:6}_"

    local func_names
    func_names=$(grep -oE 'static[[:space:]]+(inline[[:space:]]+)?[[:alnum:]_]+[[:space:]]+\*?[[:alnum:]_]+[[:space:]]*\(' "$file" 2>/dev/null | \
                 sed -E 's/static[[:space:]]+(inline[[:space:]]+)?[[:alnum:]_]+[[:space:]]+\*?([[:alnum:]_]+)[[:space:]]*\(/\2/' | \
                 sort -u || true)

    [[ -z "$func_names" ]] && return 0

    local renamed=0
    local func_idx=0
    while IFS= read -r func; do
        [[ -z "$func" ]] && continue
        [[ "$func" == _zt* ]] && continue

        local skip=false
        for pat in "${protected_patterns[@]}"; do
            [[ "$func" == $pat ]] && skip=true && break
        done
        [[ "$skip" == "true" ]] && continue

        local per_func_hash
        per_func_hash=$(hash_derive "${SEED}:rename:$(basename "$file"):${func}:${func_idx}")
        local new_func="${prefix}${per_func_hash:0:4}_${func}"

        if [[ "$DRY_RUN" == "true" ]]; then
            [[ "$VERBOSE" == "true" ]] && log_info "    [L1] static: $func → $new_func" || true
        else
            sed -i '' "s/[[:<:]]${func}[[:>:]]/${new_func}/g" "$file" 2>/dev/null
        fi
        renamed=$((renamed + 1))
        func_idx=$((func_idx + 1))
    done <<< "$func_names"

    [[ "$VERBOSE" == "true" ]] && [[ $renamed -gt 0 ]] && \
        log_info "    [L1] $(basename "$file"): 重命名 $renamed 个 static 函数" || true
}

# 重命名 Swift 文件中的 private/fileprivate 函数和属性
# 安全策略:
#   - 只重命名 private func 名，不动 var/let（变量名常与参数标签重名）
#   - 跳过短名称（<8字符）和常见标识符，避免误改跨文件的参数标签
#   - 跳过也出现在非 private 函数签名中的名称
# 用法: bt_rename_swift_privates <file> [protected_pattern...]
bt_rename_swift_privates() {
    local file="$1"
    shift
    local protected_patterns=("$@")

    [[ -f "$file" ]] || return 0

    local file_hash
    file_hash=$(hash_derive "${SEED}:rename:$(basename "$file")")
    local prefix="_zt${file_hash:0:6}_"

    local func_names
    func_names=$(grep -oE '(private|fileprivate)[[:space:]]+func[[:space:]]+[[:alnum:]_]+' "$file" 2>/dev/null | \
                 sed -E 's/(private|fileprivate)[[:space:]]+func[[:space:]]+([[:alnum:]_]+)/\2/' | \
                 sort -u || true)

    [[ -z "$func_names" ]] && return 0

    local public_labels
    public_labels=$(grep -E '^\s*(public|open|internal|override|@objc|static|class)?\s*func ' "$file" 2>/dev/null | \
                    grep -v 'private\|fileprivate' | \
                    grep -oE '[[:alnum:]_]+:' | sed 's/:$//' | sort -u || true)

    local renamed=0
    local func_idx=0
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$name" == _zt* ]] && continue

        [[ ${#name} -lt 8 ]] && continue

        local skip=false
        for pat in "${protected_patterns[@]}"; do
            [[ "$name" == $pat ]] && skip=true && break
        done
        [[ "$skip" == "true" ]] && continue

        if [[ -n "$public_labels" ]]; then
            while IFS= read -r label; do
                [[ "$name" == "$label" ]] && skip=true && break
            done <<< "$public_labels"
        fi
        [[ "$skip" == "true" ]] && continue

        local per_func_hash
        per_func_hash=$(hash_derive "${SEED}:rename:$(basename "$file"):${name}:${func_idx}")
        local new_name="${prefix}${per_func_hash:0:4}_${name}"

        if [[ "$DRY_RUN" == "true" ]]; then
            [[ "$VERBOSE" == "true" ]] && log_info "    [L1] private func: $name → $new_name" || true
        else
            sed -i '' "s/[[:<:]]${name}[[:>:]]/${new_name}/g" "$file" 2>/dev/null
        fi
        renamed=$((renamed + 1))
        func_idx=$((func_idx + 1))
    done <<< "$func_names"

    [[ "$VERBOSE" == "true" ]] && [[ $renamed -gt 0 ]] && \
        log_info "    [L1] $(basename "$file"): 重命名 $renamed 个 private func" || true
}

# =============================================
# L2: 方法实现顺序打乱
# =============================================

# 打乱 ObjC @implementation 块中的方法顺序
# 用法: bt_reorder_objc_methods <file>
bt_reorder_objc_methods() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local file_hash
    file_hash=$(hash_derive "${SEED}:reorder:$(basename "$file")")

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "    [L2] $(basename "$file"): 方法顺序打乱" || true
        return 0
    fi

    # 使用 awk 解析和打乱方法顺序
    # 策略：找到 @implementation...@end 块，提取每个方法（从方法签名到下一个方法签名前），
    # 使用 seed 派生的顺序重排
    local temp_file
    temp_file=$(mktemp)
    local shuffle_seed=$(( 16#${file_hash:0:8} ))

    awk -v seed="$shuffle_seed" '
    BEGIN {
        in_impl = 0
        method_count = 0
        current_method = ""
        impl_header = ""
    }

    /^@implementation / {
        in_impl = 1
        impl_header = $0
        method_count = 0
        current_method = ""
        next
    }

    /^@end/ && in_impl {
        # 保存最后一个方法
        if (current_method != "") {
            methods[method_count++] = current_method
        }

        # 打乱顺序（Fisher-Yates with seed）
        srand(seed)
        for (i = method_count - 1; i > 0; i--) {
            j = int(rand() * (i + 1))
            tmp = methods[i]
            methods[i] = methods[j]
            methods[j] = tmp
        }

        # 输出
        print impl_header
        for (i = 0; i < method_count; i++) {
            print methods[i]
        }
        print $0  # @end

        # 重置
        in_impl = 0
        delete methods
        method_count = 0
        current_method = ""
        next
    }

    in_impl {
        # 检测方法签名: + 或 - 开头（允许前面有空白）
        if ($0 ~ /^[[:space:]]*[-+][[:space:]]*\(/) {
            if (current_method != "") {
                methods[method_count++] = current_method
            }
            current_method = $0
        } else {
            if (current_method != "") {
                current_method = current_method "\n" $0
            } else {
                # @implementation 后，第一个方法前的代码（如 pragma, 空行）
                # 归入 impl_header
                impl_header = impl_header "\n" $0
            }
        }
        next
    }

    { print }
    ' "$file" > "$temp_file"

    if [[ -s "$temp_file" ]]; then
        mv "$temp_file" "$file"
        [[ "$VERBOSE" == "true" ]] && log_info "    [L2] $(basename "$file"): 方法顺序已打乱" || true
    else
        rm -f "$temp_file"
        log_warning "    [L2] $(basename "$file"): 打乱失败，保持原样"
    fi
}

# 打乱 Swift 文件中顶层 func 的顺序
# 策略：提取顶层 func（brace_depth==1 时出现的 func），按 seed 派生的顺序重排
# 用法: bt_reorder_swift_methods <file>
bt_reorder_swift_methods() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local file_hash
    file_hash=$(hash_derive "${SEED}:reorder:$(basename "$file")")

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "    [L2] $(basename "$file"): Swift 方法顺序打乱" || true
        return 0
    fi

    local temp_file
    temp_file=$(mktemp)
    local shuffle_seed=$(( 16#${file_hash:0:8} ))

    awk -v seed="$shuffle_seed" '
    BEGIN { depth=0; in_block=0; block_count=0; current="" ; header="" ; collecting_header=1 }

    {
        # Count braces on this line
        line = $0
        opens = gsub(/{/, "{", line)
        closes = gsub(/}/, "}", line)

        if (depth == 0 && $0 ~ /^[[:space:]]*(public |open |internal |private |fileprivate )?func /) {
            collecting_header = 0
            if (current != "") {
                blocks[block_count++] = current
            }
            current = $0
            depth += opens - closes
            next
        }

        if (depth == 0 && current != "" && $0 ~ /^[[:space:]]*(public |open |internal |private |fileprivate )?(func |var |let |class |struct |enum |extension |protocol |@)/) {
            blocks[block_count++] = current
            current = $0
            depth += opens - closes
            next
        }

        if (collecting_header) {
            header = header (header == "" ? "" : "\n") $0
            depth += opens - closes
            next
        }

        if (current != "") {
            current = current "\n" $0
        } else {
            header = header "\n" $0
        }
        depth += opens - closes
        if (depth < 0) depth = 0
    }

    END {
        if (current != "") blocks[block_count++] = current

        # Fisher-Yates shuffle
        srand(seed)
        for (i = block_count - 1; i > 0; i--) {
            j = int(rand() * (i + 1))
            tmp = blocks[i]; blocks[i] = blocks[j]; blocks[j] = tmp
        }

        print header
        for (i = 0; i < block_count; i++) {
            print blocks[i]
        }
    }
    ' "$file" > "$temp_file"

    if [[ -s "$temp_file" ]]; then
        mv "$temp_file" "$file"
        [[ "$VERBOSE" == "true" ]] && log_info "    [L2] $(basename "$file"): Swift 方法顺序已打乱" || true
    else
        rm -f "$temp_file"
        log_warning "    [L2] $(basename "$file"): 打乱失败，保持原样"
    fi
}

# =============================================
# L3: 死分支注入
# =============================================

# 在 ObjC 方法体开头注入 seed 唯一的死分支
# 每个方法注入 1-3 个不同模式的死分支，条件和 payload 均由 seed 决定
# 用法: bt_inject_dead_branches <file> [max_methods]
bt_inject_dead_branches() {
    local file="$1"
    local max_methods="${2:-999}"
    [[ -f "$file" ]] || return 0

    local file_hash
    file_hash=$(hash_derive "${SEED}:deadbranch:$(basename "$file")")

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "    [L3] $(basename "$file"): 死分支注入" || true
        return 0
    fi

    local temp_file
    temp_file=$(mktemp)
    local inject_count=0
    local in_impl=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        echo "$line" >> "$temp_file"

        if [[ "$line" =~ ^@implementation ]]; then
            in_impl=1
            continue
        fi
        if [[ "$line" =~ ^@end ]] && [[ $in_impl -eq 1 ]]; then
            in_impl=0
            continue
        fi

        if [[ $in_impl -eq 1 ]] && [[ $inject_count -lt $max_methods ]]; then
            if [[ "$line" =~ ^[[:space:]]*[-+][[:space:]]*\( ]] && [[ "$line" =~ \{ ]] && [[ ! "$line" =~ \} ]]; then
                local branch_hash
                branch_hash=$(hash_derive "${SEED}:branch:$(basename "$file"):${inject_count}")
                local unique_val=$(( 16#${branch_hash:0:8} ))
                local unique_str="${branch_hash:8:16}"
                local pattern=$(( 16#${branch_hash:24:2} % 12 ))
                local branches_per=$(( (16#${branch_hash:26:2} % 4) + 3 ))
                if declare -f native_dead_branch_multiplier >/dev/null 2>&1; then
                    branches_per=$(( branches_per * $(native_dead_branch_multiplier) ))
                fi
                if [[ -n "${REVIEW_NATIVE_MAX_DEAD_BRANCHES_PER_METHOD:-}" && "$branches_per" -gt "$REVIEW_NATIVE_MAX_DEAD_BRANCHES_PER_METHOD" ]]; then
                    branches_per="$REVIEW_NATIVE_MAX_DEAD_BRANCHES_PER_METHOD"
                fi

                for (( bi=0; bi<branches_per; bi++ )); do
                    local bh
                    bh=$(hash_derive "${SEED}:branch:$(basename "$file"):${inject_count}:${bi}")
                    local bv=$(( 16#${bh:0:8} ))
                    local bs="${bh:8:12}"
                    local bp=$(( 16#${bh:20:2} % 12 ))
                    local bv2=$(( 16#${bh:24:8} ))

                    case $bp in
                        0) cat >> "$temp_file" << _BEOF
    if ([[NSProcessInfo processInfo] physicalMemory] == ${bv}UL) { NSLog(@"_zt_${bs}"); }
_BEOF
                            ;;
                        1) cat >> "$temp_file" << _BEOF
    if ([[NSProcessInfo processInfo] systemUptime] < 0.${bv}) { [[NSUserDefaults standardUserDefaults] setObject:@"${bs}" forKey:@"_zt_k_${bv}"]; }
_BEOF
                            ;;
                        2) cat >> "$temp_file" << _BEOF
    if ([[[NSBundle mainBundle] bundleIdentifier] hash] == ${bv}UL) { NSMutableArray *_a = @[@"${bs}"].mutableCopy; [_a addObject:@(${bv})]; }
_BEOF
                            ;;
                        3) cat >> "$temp_file" << _BEOF
    if ([[NSProcessInfo processInfo] processorCount] > 128) { NSData *_d = [@"_zt_${bs}" dataUsingEncoding:NSUTF8StringEncoding]; (void)_d; }
_BEOF
                            ;;
                        4) cat >> "$temp_file" << _BEOF
    if ([[NSProcessInfo processInfo] activeProcessorCount] == 0) { NSDictionary *_m = @{@"k": @(${bv}), @"s": @"${bs}"}; (void)_m; }
_BEOF
                            ;;
                        5) cat >> "$temp_file" << _BEOF
    if ([NSThread isMainThread] == NO && [NSThread isMainThread] == YES) { dispatch_async(dispatch_get_main_queue(), ^{ NSLog(@"_zt_${bs}_%lu", (unsigned long)${bv}UL); }); }
_BEOF
                            ;;
                        6) cat >> "$temp_file" << _BEOF
    if ([[NSProcessInfo processInfo] processorCount] > ${bv}) { NSString *_s = [NSString stringWithFormat:@"_zt_%@_%lu", @"${bs}", (unsigned long)${bv2}UL]; (void)_s; }
_BEOF
                            ;;
                        7) cat >> "$temp_file" << _BEOF
    if ([[NSLocale currentLocale] localeIdentifier].length > ${bv}) { NSArray *_arr = @[@(${bv}UL), @(${bv2}UL), @"${bs}"]; (void)_arr; }
_BEOF
                            ;;
                        8) cat >> "$temp_file" << _BEOF
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/_zt_${bs}_${bv}"]) { NSMutableDictionary *_d = [NSMutableDictionary new]; _d[@"v"] = @(${bv2}UL); (void)_d; }
_BEOF
                            ;;
                        9) cat >> "$temp_file" << _BEOF
    if ([[NSTimeZone systemTimeZone] secondsFromGMT] == ${bv}) { NSData *_d = [NSData dataWithBytes:"${bs}" length:12]; (void)_d; }
_BEOF
                            ;;
                        10) cat >> "$temp_file" << _BEOF
    if ([NSProcessInfo processInfo].operatingSystemVersion.majorVersion > ${bv}) { id _v = @{@"_zt_${bs}": @(${bv2}UL)}; (void)_v; }
_BEOF
                            ;;
                        11) cat >> "$temp_file" << _BEOF
    if (arc4random_uniform(1) > ${bv}) { NSSet *_s = [NSSet setWithObjects:@(${bv}UL), @"_zt_${bs}", @(${bv2}UL), nil]; (void)_s; }
_BEOF
                            ;;
                    esac
                done

                inject_count=$((inject_count + 1))
            fi
        fi
    done < "$file"

    if [[ -s "$temp_file" ]] && [[ $inject_count -gt 0 ]]; then
        mv "$temp_file" "$file"
        [[ "$VERBOSE" == "true" ]] && log_info "    [L3] $(basename "$file"): 注入 $inject_count 个方法 × 多死分支" || true
    else
        rm -f "$temp_file"
    fi
}

# 在 Swift func 体开头注入 seed 唯一的死分支
# 每个函数注入 1-3 个不同模式的死分支
# 用法: bt_inject_swift_dead_branches <file> [max_funcs]
bt_inject_swift_dead_branches() {
    local file="$1"
    local max_funcs="${2:-999}"
    [[ -f "$file" ]] || return 0

    local file_hash
    file_hash=$(hash_derive "${SEED}:deadbranch:$(basename "$file")")

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "    [L3] $(basename "$file"): Swift 死分支注入" || true
        return 0
    fi

    local temp_file
    temp_file=$(mktemp)
    local inject_count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        echo "$line" >> "$temp_file"

        if [[ $inject_count -ge $max_funcs ]]; then
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*(public\ |open\ |internal\ |private\ |fileprivate\ |override\ |static\ |class\ |@objc\ )*func\  ]] && \
           [[ "$line" =~ \{[[:space:]]*$ ]] && [[ ! "$line" =~ \} ]]; then
            local branch_hash
            branch_hash=$(hash_derive "${SEED}:swbranch:$(basename "$file"):${inject_count}")
            local branches_per=$(( (16#${branch_hash:24:2} % 4) + 3 ))
            if declare -f native_dead_branch_multiplier >/dev/null 2>&1; then
                branches_per=$(( branches_per * $(native_dead_branch_multiplier) ))
            fi
            if [[ -n "${REVIEW_NATIVE_MAX_DEAD_BRANCHES_PER_METHOD:-}" && "$branches_per" -gt "$REVIEW_NATIVE_MAX_DEAD_BRANCHES_PER_METHOD" ]]; then
                branches_per="$REVIEW_NATIVE_MAX_DEAD_BRANCHES_PER_METHOD"
            fi

            for (( bi=0; bi<branches_per; bi++ )); do
                local bh
                bh=$(hash_derive "${SEED}:swbranch:$(basename "$file"):${inject_count}:${bi}")
                local bv=$(( 16#${bh:0:8} ))
                local bs="${bh:8:12}"
                local bp=$(( 16#${bh:20:2} % 12 ))
                local bv2=$(( 16#${bh:24:8} ))

                case $bp in
                    0) cat >> "$temp_file" << _BEOF
        if ProcessInfo.processInfo.physicalMemory == ${bv} { _ = "_zt_${bs}" }
_BEOF
                        ;;
                    1) cat >> "$temp_file" << _BEOF
        if ProcessInfo.processInfo.systemUptime < 0.${bv} { UserDefaults.standard.set("_zt_${bs}", forKey: "_zt_k_${bv}") }
_BEOF
                        ;;
                    2) cat >> "$temp_file" << _BEOF
        if ProcessInfo.processInfo.processorCount > 1024 { let _a: [Any] = ["_zt_${bs}", ${bv}]; _ = _a }
_BEOF
                        ;;
                    3) cat >> "$temp_file" << _BEOF
        if ProcessInfo.processInfo.activeProcessorCount == 0 { let _d = "_zt_${bs}".data(using: .utf8); _ = _d }
_BEOF
                        ;;
                    4) cat >> "$temp_file" << _BEOF
        if Bundle.main.bundleIdentifier?.hashValue == ${bv} { let _m: [String: Any] = ["k": ${bv}, "s": "_zt_${bs}"]; _ = _m }
_BEOF
                        ;;
                    5) cat >> "$temp_file" << _BEOF
        if Thread.isMainThread == false && Thread.isMainThread == true { DispatchQueue.main.async { _ = "_zt_${bs}_\(${bv})" } }
_BEOF
                        ;;
                    6) cat >> "$temp_file" << _BEOF
        if ProcessInfo.processInfo.processorCount > ${bv} { let _s = "_zt_${bs}_\(UInt(${bv2}))"; _ = _s }
_BEOF
                        ;;
                    7) cat >> "$temp_file" << _BEOF
        if Locale.current.identifier.count > ${bv} { let _arr: [Any] = [${bv}, ${bv2}, "_zt_${bs}"]; _ = _arr }
_BEOF
                        ;;
                    8) cat >> "$temp_file" << _BEOF
        if FileManager.default.fileExists(atPath: "/_zt_${bs}_${bv}") { var _d: [String: Any] = [:]; _d["v"] = ${bv2}; _ = _d }
_BEOF
                        ;;
                    9) cat >> "$temp_file" << _BEOF
        if TimeZone.current.secondsFromGMT() == ${bv} { let _d = Data("_zt_${bs}".utf8); _ = _d }
_BEOF
                        ;;
                    10) cat >> "$temp_file" << _BEOF
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion > ${bv} { let _v: [String: UInt] = ["_zt_${bs}": UInt(${bv2})]; _ = _v }
_BEOF
                        ;;
                    11) cat >> "$temp_file" << _BEOF
        if arc4random_uniform(1) > ${bv} { let _s: Set<AnyHashable> = [${bv}, "_zt_${bs}", ${bv2}]; _ = _s }
_BEOF
                        ;;
                esac
            done

            inject_count=$((inject_count + 1))
        fi
    done < "$file"

    if [[ -s "$temp_file" ]] && [[ $inject_count -gt 0 ]]; then
        if ! grep -q '^import Foundation' "$temp_file" 2>/dev/null; then
            local import_file
            import_file=$(mktemp)
            {
                echo "import Foundation"
                echo ""
                cat "$temp_file"
            } > "$import_file"
            mv "$import_file" "$temp_file"
        fi
        mv "$temp_file" "$file"
        [[ "$VERBOSE" == "true" ]] && log_info "    [L3] $(basename "$file"): 注入 $inject_count 个函数 × 多 Swift 死分支" || true
    else
        rm -f "$temp_file"
    fi
}

# =============================================
# 编译验证
# =============================================

# 尝试编译单个 ObjC 文件验证语法正确性
# 用法: bt_verify_objc_file <file>
# 返回: 0=成功, 1=失败
bt_verify_objc_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    local sdk_path
    sdk_path=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
    [[ -z "$sdk_path" ]] && return 0  # 没有 Xcode 就跳过验证

    local tmp_obj
    tmp_obj=$(mktemp /tmp/zt_verify_XXXXX.o)

    if xcrun clang -c -fobjc-arc -x objective-c \
        -isysroot "$sdk_path" \
        -target arm64-apple-ios13.0 \
        "$file" -o "$tmp_obj" 2>/dev/null; then
        rm -f "$tmp_obj"
        return 0
    else
        rm -f "$tmp_obj"
        return 1
    fi
}

# 验证插件目录下所有注入/修改的 ObjC 文件
# 用法: bt_verify_plugin <plugin_dir>
bt_verify_plugin() {
    local plugin_dir="$1"
    local errors=0
    local checked=0

    while IFS= read -r file; do
        checked=$((checked + 1))
        if ! bt_verify_objc_file "$file"; then
            log_warning "    编译验证失败: $(basename "$file")"
            errors=$((errors + 1))
        fi
    done < <(find "$plugin_dir" -name "${INJECT_PREFIX}*.m" -type f 2>/dev/null)

    if [[ $errors -gt 0 ]]; then
        log_warning "  验证: $errors/$checked 文件编译失败"
        return 1
    elif [[ $checked -gt 0 ]]; then
        [[ "$VERBOSE" == "true" ]] && log_info "  验证: $checked 个注入文件全部通过" || true
    fi
    return 0
}
