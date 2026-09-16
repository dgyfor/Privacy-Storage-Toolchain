#!/data/data/com.termux/files/usr/bin/bash
shopt -s nullglob

# ============================================================
#  全局配置
# ============================================================
DECRYPT_ROOT="/storage/emulated/0/Documents/Encrypted_Vault/解密输出"
ENCRYPT_ROOT="/storage/emulated/0/Documents/Encrypted_Vault/加密文件"
MAPPING_ROOT="/storage/emulated/0/Documents/Encrypted_Vault/对照表"
GLOBAL_INDEX="/storage/emulated/0/encrypted_index.txt"
PASSWORDS_FILE="$MAPPING_ROOT/passwords.txt"
CACHE_FILE="$MAPPING_ROOT/.enc_cache"
PAR2_ROOT="/storage/emulated/0/Documents/Encrypted_Vault/Par2_Backups"

mkdir -p "$MAPPING_ROOT" "$(dirname "$GLOBAL_INDEX")" "$PAR2_ROOT"
touch "$PASSWORDS_FILE"

# ============================================================
#  核心辅助函数
# ============================================================
get_relative_path() {
    local rel_path="${PWD#/storage/emulated/0/}"
    rel_path="${rel_path#/sdcard/}"
    local encrypt_root_clean="${ENCRYPT_ROOT#/storage/emulated/0/}"
    rel_path="${rel_path#$encrypt_root_clean}"
    rel_path="${rel_path#/}"
    rel_path="${rel_path# Documents/}"
    rel_path="${rel_path#爱-Allow/AV/}"
    rel_path="${rel_path#爱-Allow/}"
    rel_path=$(echo "$rel_path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g')
    [[ -z "$rel_path" ]] && rel_path="."
    echo "$rel_path"
}

get_password() {
    echo "$1"
}
# 修改加密文件对应的原始文件名
log_encrypted_file() {
    local enc_base="$1"
    local orig_name="$2"
    local rel_path="$3"
    [[ -z "$enc_base" || -z "$orig_name" ]] && return
    rel_path=$(echo "$rel_path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g')
    mkdir -p "$(dirname "$GLOBAL_INDEX")"
    if ! grep -q "^$enc_base |" "$GLOBAL_INDEX" 2>/dev/null; then
        echo "$enc_base | $orig_name | $rel_path |  |  | 0" >> "$GLOBAL_INDEX"
    fi
}

human_size() {
    local b=$1
    if [[ $b -ge 1073741824 ]]; then
        echo "$(echo "scale=2; $b/1073741824" | bc) GB"
    elif [[ $b -ge 1048576 ]]; then
        echo "$(echo "scale=2; $b/1048576" | bc) MB"
    elif [[ $b -ge 1024 ]]; then
        echo "$(echo "scale=2; $b/1024" | bc) KB"
    else
        echo "$b B"
    fi
}

unique_filename() {
    local target_dir="$1"
    local base_name="$2"
    local ext="$3"
    local out="${target_dir}/${base_name}${ext}"
    local counter=1
    while [[ -e "$out" ]]; do
        if [[ "$ext" == *.* ]]; then
            out="${target_dir}/${base_name}_${counter}${ext}"
        else
            out="${target_dir}/${base_name}_${counter}${ext}"
        fi
        ((counter++))
    done
    echo "$out"
}

_build_cache() {
    echo "🔄 正在扫描本地加密文件..." >&2
    mkdir -p "$MAPPING_ROOT"
    > "$CACHE_FILE"
    find /storage/emulated/0/ -type f -name 'enc_*.dat' \
        \( -not -path "*/Android/*" -not -path "*/mapcache/*" -not -path "*/scenic/*" -not -path "*/vmap/*" \) \
        -print0 2>/dev/null | while IFS= read -r -d '' f; do
        local enc=$(basename "$f" .dat)
        echo "$enc|$f" >> "$CACHE_FILE"
    done
    local count=$(wc -l < "$CACHE_FILE" 2>/dev/null)
    echo "✅ 缓存已更新（$count 个文件）" >&2
}

_is_local() {
    local enc="$1"
    grep -q "^${enc}|" "$CACHE_FILE" 2>/dev/null
}

_get_local_path() {
    local enc="$1"
    grep "^${enc}|" "$CACHE_FILE" 2>/dev/null | cut -d'|' -f2- | head -1
}

_get_enc_size() {
    local enc_base="$1"
    local dat_file="$(_get_local_path "$enc_base")"
    if [[ -n "$dat_file" && -f "$dat_file" ]]; then
        stat -c %s "$dat_file" 2>/dev/null && return 0
    fi
    if [[ -f "$MAPPING_ROOT/.enc_sizes.txt" ]]; then
        local size=$(grep "^$enc_base|" "$MAPPING_ROOT/.enc_sizes.txt" 2>/dev/null | head -1 | cut -d'|' -f2)
        if [[ -n "$size" ]]; then
            echo "$size"
            return 0
        fi
    fi
    echo "0"
}
get_original_name() {
    local dat_file="$1"
    local enc_base="$(basename "${dat_file%.dat}")"
    local orig=$(awk -F'|' -v e="$enc_base" '
        {
            gsub(/^[ \t]+|[ \t]+$/, "", $1);
            if ($1 == e) {
                gsub(/^[ \t]+|[ \t]+$/, "", $2);
                print $2;
                exit;
            }
        }' "$GLOBAL_INDEX" 2>/dev/null)
    echo "${orig:-${dat_file%.dat}.mp4}"
}
# ============================================================
#  加密
# ============================================================
_encrypt_file() {
    local file="$1"
    local pass="$2"
    local timestamp=$(date +%s)
    local rand=$((RANDOM%10000))
    local rel_path="$(get_relative_path)"
    mkdir -p "$ENCRYPT_ROOT/$rel_path"
    local enc_name="$ENCRYPT_ROOT/$rel_path/enc_${timestamp}_${rand}.dat"
    local counter=1
    while [[ -e "$enc_name" ]]; do
        enc_name="$ENCRYPT_ROOT/$rel_path/enc_${timestamp}_${rand}_${counter}.dat"
        ((counter++))
    done
    openssl enc -aes-256-cbc -pbkdf2 -salt -in "$file" -out "$enc_name" -k "$pass" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✅ 加密成功: $enc_name"
        local mapfile="$MAPPING_ROOT/加密对照表.txt"
        echo "${enc_name%.dat} = $(basename "$file")" >> "$mapfile"
        local dat_size=$(stat -c %s "$enc_name" 2>/dev/null || echo 0)
        log_encrypted_file "$(basename "${enc_name%.dat}")" "$(basename "$file")" "$rel_path"
        # 更新大小列（第6列）
        awk -F'|' -v enc="$(basename "${enc_name%.dat}")" -v sz="$dat_size" '
            BEGIN {OFS=FS}
            {
                gsub(/^[ \t]+|[ \t]+$/, "", $1);
                if ($1 == enc) $6 = sz;
                print $0
            }
        ' "$GLOBAL_INDEX" > "$GLOBAL_INDEX.tmp" && mv "$GLOBAL_INDEX.tmp" "$GLOBAL_INDEX"
        echo "$enc_name|$dat_size" >> "$MAPPING_ROOT/.enc_sizes.txt"
        rebuild_idx &
        return 0
    else
        echo "❌ 加密失败: $file"
        rm -f "$enc_name"
        return 1
    fi
}
# 批量加密（不写入索引，返回加密文件信息）
_encrypt_file_batch() {
    local file="$1"
    local pass="$2"
    local timestamp=$(date +%s)
    local rand=$((RANDOM%10000))
    local rel_path="$(get_relative_path)"
    mkdir -p "$ENCRYPT_ROOT/$rel_path"
    local enc_name="$ENCRYPT_ROOT/$rel_path/enc_${timestamp}_${rand}.dat"
    local counter=1
    while [[ -e "$enc_name" ]]; do
        enc_name="$ENCRYPT_ROOT/$rel_path/enc_${timestamp}_${rand}_${counter}.dat"
        ((counter++))
    done

    openssl enc -aes-256-cbc -pbkdf2 -salt -in "$file" -out "$enc_name" -k "$pass" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        local dat_size=$(stat -c %s "$enc_name" 2>/dev/null || echo 0)
        echo "${enc_name%.dat}|$(basename "$file")|$rel_path|$dat_size"
        return 0
    else
        echo "❌ 加密失败: $file" >&2
        rm -f "$enc_name"
        return 1
    fi
}
ea() {
    echo "===== 加密当前目录 ====="
    local rel_path="$(get_relative_path)"
    echo "🔍 当前相对路径: [$rel_path]"

    # 获取当前目录所有普通文件（排除 .dat）
    local -a files=()
    for f in *; do
        if [[ -f "$f" && ! "$f" =~ \.dat$ ]]; then
            files+=("$f")
        fi
    done

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "📁 当前目录没有可加密的文件。"
        return
    fi

    # --- 分类已加密/未加密（使用辅助索引）---
    local -A encrypted_nospace
    local group_dir="$MAPPING_ROOT/.idx_groups"
    # 收集所有文件首字母
    declare -A first_chars
    for f in "${files[@]}"; do
        local first_char=$(echo "${f:0:1}" | tr '[:lower:]' '[:upper:]')
        if [[ "$first_char" =~ [A-Z] ]]; then
            first_chars["$first_char"]=1
        elif [[ "$first_char" =~ [0-9] ]]; then
            first_chars["0-9"]=1
        else
            first_chars["OTHER"]=1
        fi
    done
    for group in "${!first_chars[@]}"; do
        local group_file="$group_dir/${group}.txt"
        if [[ -f "$group_file" ]]; then
            while IFS= read -r line; do
                local orig=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
                if [[ -z "$orig" ]]; then
                    orig=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
                fi
                local key="${orig// /}"
                encrypted_nospace["$key"]=1
            done < "$group_file"
        fi
    done

    local -a encrypted_files=()
    local -a unencrypted_files=()
    for f in "${files[@]}"; do
        local f_nospace="${f// /}"
        if [[ -n "${encrypted_nospace[$f_nospace]}" ]]; then
            encrypted_files+=("$f")
        else
            unencrypted_files+=("$f")
        fi
    done

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📁 已加密文件（${#encrypted_files[@]} 个）"
    for f in "${encrypted_files[@]}"; do
        local size=$(stat -c %s "$f" 2>/dev/null || echo 0)
        echo "  ✅ $f  ($(human_size "$size"))"
    done
    echo ""
    echo "📁 未加密文件（${#unencrypted_files[@]} 个）"
    local i=1
    for f in "${unencrypted_files[@]}"; do
        local size=$(stat -c %s "$f" 2>/dev/null || echo 0)
        printf "  [%d] %s  (大小: %s)\n" "$i" "$f" "$(human_size "$size")"
        ((i++))
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ${#unencrypted_files[@]} -eq 0 ]]; then
        echo "✅ 所有文件都已加密。"
        return
    fi

    echo -n "请选择要加密的编号 (空格分隔多个，all 全部加密，q 取消): "
    read -r selection
    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        echo "已取消。"
        return
    fi

    local -a selected_files=()
    if [[ "$selection" == "all" ]]; then
        selected_files=("${unencrypted_files[@]}")
    else
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#unencrypted_files[@]} )); then
                selected_files+=("${unencrypted_files[$((num-1))]}")
            fi
        done
    fi

    if [[ ${#selected_files[@]} -eq 0 ]]; then
        echo "没有选择文件。"
        return
    fi

    echo -n "请输入加密密码（数字=代号）: "
    read -r pass_input
    local pass=$(get_password "$pass_input")
    echo -n "请再次输入密码: "
    read -r pass_input2
    local pass2=$(get_password "$pass_input2")
    if [[ "$pass" != "$pass2" ]]; then
        echo "两次密码不一致。"
        return
    fi

    # --- 批量加密（延迟索引）---
    echo "🔐 开始批量加密 ${#selected_files[@]} 个文件..."
    local -a success_records=()
    local failed_files=()
    local count=0
    for f in "${selected_files[@]}"; do
        ((count++))
        echo -ne "\r⏳ 进度: $count / ${#selected_files[@]} ..." >&2
        result=$(_encrypt_file_batch "$f" "$pass")
        if [[ $? -eq 0 ]]; then
            success_records+=("$result")
        else
            failed_files+=("$f")
        fi
    done
    echo ""  # 换行

    # --- 如果有成功加密的文件，一次性写入索引 ---
    if [[ ${#success_records[@]} -gt 0 ]]; then
        echo "📝 正在更新索引（${#success_records[@]} 个文件）..."
        # 追加到主索引和辅助索引
        local tmp_idx=$(mktemp)
        cat "$GLOBAL_INDEX" > "$tmp_idx"
        for record in "${success_records[@]}"; do
            IFS='|' read -r enc orig path size <<< "$record"
            echo "$enc | $orig | $path |  |  | $size" >> "$tmp_idx"
            # 同时更新 .enc_sizes.txt
            echo "$enc|$size" >> "$MAPPING_ROOT/.enc_sizes.txt"
            # 更新对照表
            echo "$enc = $orig" >> "$MAPPING_ROOT/加密对照表.txt"
        done
        mv "$tmp_idx" "$GLOBAL_INDEX"
        echo "✅ 索引更新完成。"
        # 重建辅助索引
        rebuild_idx
    fi

    # --- 报告结果 ---
    local success_count=${#success_records[@]}
    local fail_count=${#failed_files[@]}
    echo "加密完成：成功 $success_count，失败 $fail_count。"
    if [[ $fail_count -gt 0 ]]; then
        echo "❌ 失败的文件："
        for f in "${failed_files[@]}"; do
            echo "  $f"
        done
    fi
    _build_cache
}
# ============================================================
#  解密
# ============================================================
decrypt_one() {
    local dat_file="$1"
    local pass="$2"
    local target_dir="$3"

    local avail_bytes=$(df -B1 "$target_dir" 2>/dev/null | tail -1 | awk '{print $4}')
    local file_size=$(stat -c %s "$dat_file" 2>/dev/null || echo 0)
    local need_bytes=$((file_size * 15 / 10))
    if [[ -n "$avail_bytes" ]] && [[ $file_size -gt 0 ]] && [[ $avail_bytes -lt $need_bytes ]]; then
        echo "❌ 空间不足（需要约 $((need_bytes/1024/1024)) MB，可用 $((avail_bytes/1024/1024)) MB）。"
        return 1
    fi

    local orig_name="$(get_original_name "$dat_file")"
    [[ -z "$orig_name" ]] && orig_name="${dat_file%.dat}.mp4"
    mkdir -p "$target_dir"

    local target_file="${target_dir}/${orig_name}"
    local target_file_nospace="${target_dir}/${orig_name// /}"
    if [[ -f "$target_file" || -f "$target_file_nospace" ]]; then
        return 2
    fi

    local base="${orig_name%.*}"
    local ext="${orig_name##*.}"
    [[ "$ext" != "$orig_name" ]] && ext=".${ext}" || ext=""
    local out_file="$(unique_filename "$target_dir" "$base" "$ext")"
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$dat_file" -out "$out_file" -k "$pass" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        [[ -z "$QUIET" ]] && echo "✅ 解密成功: $out_file"
        return 0
    else
        [[ -z "$QUIET" ]] && echo "❌ 解密失败: $dat_file"
        rm -f "$out_file"
        return 1
    fi
}

decrypt_with_prompt() {
    local dat_file="$1"
    local pass="$2"
    local enc_base="$(basename "${dat_file%.dat}")"
    local raw_rel_path=""
    raw_rel_path=$(awk -F'|' -v e="$enc_base" '
        {
            gsub(/^[ \t]+|[ \t]+$/, "", $1);
            if ($1 == e) {
                gsub(/^[ \t]+|[ \t]+$/, "", $3);
                print $3;
                exit;
            }
        }' "$GLOBAL_INDEX" 2>/dev/null)
    if [[ -z "$raw_rel_path" ]]; then
        local file_dir="$(dirname "$dat_file")"
        raw_rel_path="${file_dir#$ENCRYPT_ROOT/}"
        raw_rel_path="${raw_rel_path#/storage/emulated/0/}"
        raw_rel_path="${raw_rel_path#/sdcard/}"
        [[ -z "$raw_rel_path" ]] && raw_rel_path="."
    fi
    local target_dir="$DECRYPT_ROOT/$raw_rel_path"
    mkdir -p "$target_dir"
    decrypt_one "$dat_file" "$pass" "$target_dir"
    return $?
}

da() {
    echo "===== 单文件解密 ====="
    local dat_files=( *.dat )
    if [[ ${#dat_files[@]} -eq 0 ]]; then
        echo "当前目录没有 .dat 文件。"
        return
    fi

    local i=1
    for f in "${dat_files[@]}"; do
        printf "[%d] %s\n" "$i" "$f"
        ((i++))
    done
    echo ""
    echo -n "请输入编号（空格分隔多个，输入 all 全选，q 取消）: "
    read -r selection

    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        echo "已取消。"
        return
    fi

    local -a selected_files=()
    if [[ "$selection" == "all" ]]; then
        selected_files=("${dat_files[@]}")
    else
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#dat_files[@]} )); then
                selected_files+=("${dat_files[$((num-1))]}")
            else
                echo "忽略无效编号: $num"
            fi
        done
    fi

    if [[ ${#selected_files[@]} -eq 0 ]]; then
        echo "没有选择文件。"
        return
    fi

    if [[ ${#selected_files[@]} -gt 1 ]]; then
        echo -n "请输入解密密码（数字=代号）: "
        read -r pass_input
        local pass=$(get_password "$pass_input")
        if [[ -z "$pass" ]]; then
            echo "❌ 密码无效"
            return
        fi
        local test_file="${selected_files[0]}"
        if ! openssl enc -d -aes-256-cbc -pbkdf2 -in "$test_file" -out /dev/null -k "$pass" 2>/dev/null; then
            echo "❌ 密码错误，请重新运行。"
            return 1
        fi
        echo "✅ 密码正确，开始批量解密..."
        local success=0 fail=0 exists=0
        local count=0
        export QUIET=1
        for f in "${selected_files[@]}"; do
            ((count++))
            echo -ne "\r⏳ 正在解密: $count / ${#selected_files[@]} ..." >&2
            decrypt_with_prompt "$f" "$pass"
            local ret=$?
            case $ret in
                0) ((success++));;
                2) ((exists++));;
                *) ((fail++));;
            esac
        done
        unset QUIET
        echo ""
        echo "解密完成：成功 $success，已存在 $exists，失败 $fail。"
    else
        local dat_file="${selected_files[0]}"
        local pass_input
        while true; do
            echo -n "请输入解密密码（数字=代号）: "
            read -r pass_input
            local pass=$(get_password "$pass_input")
            if [[ -z "$pass" ]]; then
                echo "❌ 无效密码输入。"
                continue
            fi
            if openssl enc -d -aes-256-cbc -pbkdf2 -in "$dat_file" -out /dev/null -k "$pass" 2>/dev/null; then
                echo "✅ 密码正确！"
                break
            else
                echo "❌ 密码错误，请重试（或输入 q 取消）"
                read -r -p "继续 (q 退出): " choice
                if [[ "$choice" == "q" ]]; then
                    echo "已取消。"
                    return
                fi
            fi
        done
        decrypt_with_prompt "$dat_file" "$pass"
    fi
}

db() {
    echo "===== 批量解密所有加密文件 ====="
    local dat_files=()
    if [[ -d "$ENCRYPT_ROOT" ]]; then
        while IFS= read -r -d '' f; do
            dat_files+=("$f")
        done < <(find "$ENCRYPT_ROOT" -type f -name 'enc_*.dat' -print0 2>/dev/null)
    fi
    if [[ ${#dat_files[@]} -eq 0 ]]; then
        echo "❌ 没有找到加密文件。"
        return
    fi
    local total=${#dat_files[@]}
    echo "找到 $total 个加密文件。"

    echo -n "请输入解密密码（数字=代号）: "
    read -r pass_input
    local pass=$(get_password "$pass_input")
    if [[ -z "$pass" ]]; then
        echo "❌ 密码无效"
        return
    fi

    echo "🔍 验证密码是否正确..."
    local test_file="${dat_files[0]}"
    if openssl enc -d -aes-256-cbc -pbkdf2 -in "$test_file" -out /dev/null -k "$pass" 2>/dev/null; then
        echo "✅ 密码正确，开始批量解密..."
    else
        echo "❌ 密码错误，请重新运行 db 并输入正确密码。"
        return 1
    fi

    local success=0 fail=0 exists=0
    local count=0
    local -a failed_files=()  # 存储失败的文件路径
    export QUIET=1
    for f in "${dat_files[@]}"; do
        ((count++))
        echo -ne "\r⏳ 正在解密: $count / $total ..." >&2
        decrypt_with_prompt "$f" "$pass"
        local ret=$?
        case $ret in
            0) ((success++));;
            2) ((exists++));;
            *)
                ((fail++))
                failed_files+=("$f")
                ;;
        esac
    done
    unset QUIET
    echo ""  # 换行
    echo "解密完成：成功 $success，已存在 $exists，失败 $fail。"
    if [[ $fail -gt 0 ]]; then
        echo ""
        echo "❌ 以下 $fail 个文件解密失败："
        for f in "${failed_files[@]}"; do
            echo "  $f"
        done
    fi
}
# ============================================================
#  查询与浏览 (lk) 模块
# ============================================================
_lk_list_files() {
    local dir="$1"
    local keyword="$2"
    local -a enc_list orig_list
    local dir_nospace="${dir// /}"
    while IFS='|' read -r enc orig path rest; do
        enc="${enc// /}"
        orig="${orig// /}"
        path="${path// /}"
        if [[ "$path" == "$dir_nospace" ]]; then
            enc_list+=("$enc")
            orig_list+=("$orig")
        fi
    done < "$GLOBAL_INDEX"

    local count=${#enc_list[@]}
    if [[ $count -eq 0 ]]; then
        echo "该目录下没有文件。"
        return 1
    fi

    while true; do
        echo ""
        echo "📁 目录: $dir  ($count 个文件)"
        echo "----------------------------------------"
        for ((i=0; i<count; i++)); do
            local status="☁️"
            local fpath="$(_get_local_path "${enc_list[$i]}")"
            if [[ -n "$fpath" && -f "$fpath" ]]; then
                status="📁"
            fi
            local display_name="$(basename "${orig_list[$i]}")"
            printf "[%2d] %s %s.dat -> %s\n" "$((i+1))" "$status" "${enc_list[$i]}" "$display_name"
        done
        echo "----------------------------------------"
        echo "操作: 输入编号查看详情，输入 d+编号 解密，输入 g 生成映射，输入 b 返回上级，q 退出"
        echo -n "选择: "
        read -r op

        case "$op" in
            b|B) return 2 ;;
            q|Q) return 1 ;;
            g|G)
                echo "▶️ 正在为目录 '$dir' 生成映射文件..."
                genmap "$dir"
                echo "按 Enter 继续..."
                read -r
                continue
                ;;
            d*)
                local num="${op#d}"
                if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= count )); then
                    local idx=$((num-1))
                    local enc="${enc_list[$idx]}"
                    local fpath="$(_get_local_path "$enc")"
                    if [[ -n "$fpath" && -f "$fpath" ]]; then
                        echo -n "请输入解密密码（数字=代号）: "
                        read -r pass_input
                        local pass=$(get_password "$pass_input")
                        if [[ -n "$pass" ]]; then
                            decrypt_with_prompt "$fpath" "$pass"
                        else
                            echo "密码无效。"
                        fi
                    else
                        echo "该文件不在本地，无法解密。"
                    fi
                    echo "按 Enter 继续..."
                    read -r
                    continue
                else
                    echo "无效编号。"
                    continue
                fi
                ;;
            *)
                if [[ "$op" =~ ^[0-9]+$ ]] && (( op >= 1 && op <= count )); then
                    local idx=$((op-1))
                    local enc="${enc_list[$idx]}"
                    local orig="${orig_list[$idx]}"
                    local fpath="$(_get_local_path "$enc")"
                    echo ""
                    echo "📄 原文件名: $(basename "$orig")"
                    echo "🔐 加密文件: $enc.dat"
                    if [[ -n "$fpath" && -f "$fpath" ]]; then
                        local size=$(stat -c %s "$fpath" 2>/dev/null)
                        local mtime=$(stat -c %y "$fpath" 2>/dev/null | cut -d. -f1)
                        echo "📁 本地存在: $fpath"
                        [[ -n "$size" ]] && echo "📦 大小: $(human_size "$size")"
                        [[ -n "$mtime" ]] && echo "🕒 修改时间: $mtime"
                        echo ""
                        echo -n "是否解密此文件？(y/n): "
                        read -r dec_ans
                        if [[ "$dec_ans" == "y" ]]; then
                            echo -n "请输入解密密码: "
                            read -r pass_input
                            local pass=$(get_password "$pass_input")
                            if [[ -n "$pass" ]]; then
                                decrypt_with_prompt "$fpath" "$pass"
                            else
                                echo "密码无效。"
                            fi
                        fi
                    else
                        echo "📁 本地不存在（已删除或未下载）"
                        local cloud_info=$(awk -F'|' -v e="$enc" '
                            $1 == e { if ($4 != "") print $4 ":" $5; else print "" }' "$GLOBAL_INDEX")
                        if [[ -n "$cloud_info" ]]; then
                            echo "☁️ 云盘位置: $cloud_info"
                        fi
                    fi
                    echo "按 Enter 继续..."
                    read -r
                    continue
                else
                    echo "无效输入。"
                    continue
                fi
                ;;
        esac
    done
}
# ============================================================
#  _lk_browse_dirs  - 根目录浏览（顶级目录）
# ============================================================
_lk_browse_dirs() {
    # 收集所有顶级目录（第一层路径）
    declare -A top_dirs
    while IFS='|' read -r enc orig path rest; do
        path="${path// /}"          # 去除空格
        [[ -z "$path" ]] && path="."
        # 取第一层
        local top="${path%%/*}"
        [[ -z "$top" ]] && top="."
        # 跳过根目录自身（仅用于组织子目录）
        if [[ "$top" != "." ]]; then
            top_dirs["$top"]=1
        fi
    done < "$GLOBAL_INDEX"

    if [[ ${#top_dirs[@]} -eq 0 ]]; then
        echo "索引中没有顶级目录。"
        return
    fi

    # 排序
    local -a sorted=($(printf '%s\n' "${!top_dirs[@]}" | sort))

    while true; do
        echo ""
        echo "📁 根目录 (顶级目录)"
        echo "----------------------------------------"
        local idx=1
        for d in "${sorted[@]}"; do
            # 统计该目录下的直接文件数（不含子目录）
            local count=0
            while IFS='|' read -r enc2 orig2 path2 rest2; do
                path2="${path2// /}"
                [[ -z "$path2" ]] && path2="."
                if [[ "$path2" == "$d" || "$path2" == "$d"/* ]]; then
                    ((count++))
                fi
            done < "$GLOBAL_INDEX"
            printf "[%2d] 📁 %s  (%d 个文件)\n" "$idx" "$d" "$count"
            ((idx++))
        done
        echo "----------------------------------------"
        echo "操作: 输入编号进入目录，b 返回（已在最顶层），q 退出"
        echo -n "选择: "
        read -r op
        case "$op" in
            b|B)
                echo "已在最顶层。"
                continue
                ;;
            q|Q)
                return 0
                ;;
            *)
                if [[ "$op" =~ ^[0-9]+$ ]] && (( op >= 1 && op <= ${#sorted[@]} )); then
                    local selected="${sorted[$((op-1))]}"
                    # 进入子目录
                    _lk_browse_files "$selected"
                    local ret=$?
                    if [[ $ret -eq 1 ]]; then
                        # 用户按 q 退出整个浏览
                        return 0
                    fi
                    # ret=2 表示返回上级，继续循环（仍在根目录）
                else
                    echo "无效输入。"
                fi
                ;;
        esac
    done
}

# ============================================================
#  _lk_browse_files  - 目录内浏览（先文件后子目录）
#  参数: $1 = 当前目录路径（已去除空格）
#  返回: 0 正常退出 (q), 1 退出整个浏览, 2 返回上级
# ============================================================
_lk_browse_files() {
    local current_dir="$1"
    [[ -z "$current_dir" ]] && current_dir="."

    # 读取索引，收集当前目录下的文件和子目录
    local -a file_encs=() file_oris=()
    declare -A subdirs
    local current_nospace="${current_dir// /}"

    while IFS='|' read -r enc orig path rest; do
        enc="${enc// /}"
        orig="${orig// /}"
        path="${path// /}"
        [[ -z "$path" ]] && path="."

        if [[ "$path" == "$current_nospace" ]]; then
            # 本层文件
            file_encs+=("$enc")
            file_oris+=("$orig")
        elif [[ "$path" == "$current_nospace"/* ]]; then
            # 子目录
            local sub="${path#$current_nospace/}"
            sub="${sub%%/*}"
            if [[ -n "$sub" && "$sub" != "$current_nospace" ]]; then
                subdirs["$sub"]=1
            fi
        fi
    done < "$GLOBAL_INDEX"

    # 子目录排序
    local -a sub_list=($(printf '%s\n' "${!subdirs[@]}" | sort))

    while true; do
        local file_count=${#file_encs[@]}
        local sub_count=${#sub_list[@]}

        echo ""
        echo "📁 当前目录: $current_dir  (本层文件数: $file_count)"
        echo "----------------------------------------"

        # 1. 显示文件列表
        if [[ $file_count -gt 0 ]]; then
            echo "📄 文件："
            local i
            for ((i=0; i<file_count; i++)); do
                local enc="${file_encs[$i]}"
                local orig="${file_oris[$i]}"
                local fpath="$(_get_local_path "$enc")"
                local status="☁️"
                [[ -n "$fpath" && -f "$fpath" ]] && status="📁"
                # 获取原始文件名（可能带空格，但这里显示原始）
                local display_name="${orig##*/}"
                printf "  [%2d] %s %s.dat -> %s\n" "$((i+1))" "$status" "$enc" "$display_name"
            done
        else
            echo "  （本层无文件）"
        fi

        # 2. 显示子目录
        if [[ $sub_count -gt 0 ]]; then
            echo "----------------------------------------"
            echo "📂 子目录："
            local j
            for ((j=0; j<sub_count; j++)); do
                local sub="${sub_list[$j]}"
                # 统计该子目录下的文件总数（递归）
                local count=0
                local sub_nospace="${sub// /}"
                local sub_prefix="$current_nospace/${sub_nospace}"
                while IFS='|' read -r enc2 orig2 path2 rest2; do
                    path2="${path2// /}"
                    if [[ "$path2" == "$sub_prefix" || "$path2" == "$sub_prefix"/* ]]; then
                        ((count++))
                    fi
                done < "$GLOBAL_INDEX"
                printf "  [d%2d] 📁 %s  (%d 个文件)\n" "$((j+1))" "$sub" "$count"
            done
        else
            echo "----------------------------------------"
            echo "  （无子目录）"
        fi

        echo "----------------------------------------"
        echo -n "操作: 输入编号查看文件详情，d+编号进入子目录，b 返回上级，g 生成映射，q 退出: "
        read -r op

        case "$op" in
            b|B)
                # 返回上级（由调用者处理）
                return 2
                ;;
            q|Q)
                return 1
                ;;
            g|G)
                echo "▶️ 正在为目录 '$current_dir' 生成映射文件..."
                genmap "$current_dir"
                echo "按 Enter 继续..."
                read -r
                continue
                ;;
            d*)
                local num="${op#d}"
                if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= sub_count )); then
                    local sub="${sub_list[$((num-1))]}"
                    local new_dir="${current_dir}/${sub}"
                    # 进入子目录
                    _lk_browse_files "$new_dir"
                    local ret=$?
                    if [[ $ret -eq 1 ]]; then
                        # 用户按 q 退出整个浏览
                        return 1
                    fi
                    # ret=2 表示返回，继续循环（留在当前目录）
                    continue
                else
                    echo "无效子目录编号。"
                    continue
                fi
                ;;
            *)
                # 尝试作为文件编号处理
                if [[ "$op" =~ ^[0-9]+$ ]] && (( op >= 1 && op <= file_count )); then
                    local idx=$((op-1))
                    local enc="${file_encs[$idx]}"
                    local orig="${file_oris[$idx]}"
                    local fpath="$(_get_local_path "$enc")"
                    echo ""
                    echo "📄 原文件名: $(basename "$orig")"
                    echo "🔐 加密文件: $enc.dat"
                    if [[ -n "$fpath" && -f "$fpath" ]]; then
                        local size=$(stat -c %s "$fpath" 2>/dev/null)
                        local mtime=$(stat -c %y "$fpath" 2>/dev/null | cut -d. -f1)
                        echo "📁 本地存在: $fpath"
                        [[ -n "$size" ]] && echo "📦 大小: $(human_size "$size")"
                        [[ -n "$mtime" ]] && echo "🕒 修改时间: $mtime"
                        echo ""
                        echo -n "是否解密此文件？(y/n): "
                        read -r dec_ans
                        if [[ "$dec_ans" == "y" ]]; then
                            echo -n "请输入解密密码: "
                            read -r pass_input
                            local pass=$(get_password "$pass_input")
                            if [[ -n "$pass" ]]; then
                                decrypt_with_prompt "$fpath" "$pass"
                            else
                                echo "密码无效。"
                            fi
                        fi
                    else
                        echo "📁 本地不存在（已删除或未下载）"
                        local cloud_info=$(awk -F'|' -v e="$enc" '
                            $1 == e { if ($4 != "") print $4 ":" $5; else print "" }' "$GLOBAL_INDEX")
                        if [[ -n "$cloud_info" ]]; then
                            echo "☁️ 云盘位置: $cloud_info"
                        fi
                    fi
                    echo "按 Enter 继续..."
                    read -r
                    continue
                else
                    echo "无效输入。"
                    continue
                fi
                ;;
        esac
    done
}
lk() {
    if [[ ! -f "$GLOBAL_INDEX" ]]; then
        echo "⚠️ 全局索引不存在。"
        return 1
    fi
    if [[ ! -s "$CACHE_FILE" ]]; then
        _build_cache
    fi

    if [[ $# -eq 0 ]]; then
        _lk_browse_dirs
    else
        local keyword="$1"
        declare -A match_dirs_raw
        while IFS='|' read -r enc orig path rest; do
            enc="${enc// /}"
            orig="${orig// /}"
            path="${path// /}"
            if [[ "$orig" =~ $keyword || "$path" =~ $keyword || "$enc" =~ $keyword ]]; then
                match_dirs_raw["$path"]=1
            fi
        done < "$GLOBAL_INDEX"

        if [[ ${#match_dirs_raw[@]} -eq 0 ]]; then
            echo "未找到匹配记录。"
            return
        fi

        local -a sorted_paths
        sorted_paths=($(printf '%s\n' "${!match_dirs_raw[@]}" | sort))
        declare -A merged_dirs
        local last_path=""
        for p in "${sorted_paths[@]}"; do
            if [[ -z "$last_path" ]]; then
                last_path="$p"
                merged_dirs["$p"]=1
            else
                if [[ "$p" == "$last_path"/* ]]; then
                    continue
                else
                    last_path="$p"
                    merged_dirs["$p"]=1
                fi
            fi
        done

        echo "🔍 匹配关键词 '$keyword' 的目录："
        local -a dirs=()
        local idx=1
        for d in "${!merged_dirs[@]}"; do
            dirs+=("$d")
            local count=0
            while IFS='|' read -r enc orig path rest; do
                path="${path// /}"
                if [[ "$path" == "$d" || "$path" == "$d"/* ]]; then
                    if [[ "$orig" =~ $keyword || "$path" =~ $keyword || "$enc" =~ $keyword ]]; then
                        ((count++))
                    fi
                fi
            done < "$GLOBAL_INDEX"
            printf "[%2d] %s  (%d 个匹配文件)\n" "$idx" "$d" "$count"
            ((idx++))
        done

        while true; do
            echo ""
            echo -n "请输入目录编号查看文件 (b 返回, q 退出): "
            read -r choice
            if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
                return
            fi
            if [[ "$choice" == "b" || "$choice" == "B" ]]; then
                return
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dirs[@]} )); then
                local selected_dir="${dirs[$((choice-1))]}"
                _lk_browse_files "$selected_dir" "$keyword"
            else
                echo "无效输入。"
            fi
        done
    fi
}

# ============================================================
#  云盘路径登记
# ============================================================
setcloud() {
    echo "📋 未登记云盘路径的记录："
    local -a missing_items=()
    local idx=1
    while IFS='|' read -r enc orig path cloud_name cloud_path size; do
        orig="${orig// /}"
        path="${path// /}"
        cloud_name="${cloud_name// /}"
        if [[ -z "$cloud_name" ]]; then
            missing_items+=("$enc|$orig|$path|$size")
            printf "[%3d] %s (路径: %s)\n" "$idx" "${orig:0:35}" "$path"
            ((idx++))
        fi
    done < "$GLOBAL_INDEX"
    
    if [[ ${#missing_items[@]} -eq 0 ]]; then
        echo "✅ 所有记录都已登记云盘路径。"
        return
    fi
    
    echo ""
    echo -n "请选择编号 (空格分隔多个, a全选, q退出): "
    read -r selection
    [[ "$selection" == "q" ]] && return
    
    local -a selected_indices=()
    if [[ "$selection" == "a" ]]; then
        for ((i=0; i<${#missing_items[@]}; i++)); do selected_indices+=("$i"); done
    else
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#missing_items[@]} )); then
                selected_indices+=("$((num-1))")
            fi
        done
    fi
    
    if [[ ${#selected_indices[@]} -eq 0 ]]; then
        echo "没有选择任何记录。"
        return
    fi
    
    echo -n "请输入云盘名称 (阿里盘/光鸭盘): "
    read -r cloud_name
    [[ -z "$cloud_name" ]] && echo "云盘名称不能为空。" && return
    echo -n "请输入这些文件在云盘上的目录路径: "
    read -r cloud_path
    [[ -z "$cloud_path" ]] && echo "路径不能为空。" && return
    
    cp "$GLOBAL_INDEX" "$GLOBAL_INDEX.bak"
    for idx in "${selected_indices[@]}"; do
        local item="${missing_items[$idx]}"
        IFS='|' read -r enc orig path size <<< "$item"
        awk -F'|' -v enc="$enc" -v orig="$orig" -v path="$path" -v cname="$cloud_name" -v cpath="$cloud_path" '
            BEGIN {OFS=FS}
            {
                gsub(/^[ \t]+|[ \t]+$/, "", $1);
                gsub(/^[ \t]+|[ \t]+$/, "", $2);
                gsub(/^[ \t]+|[ \t]+$/, "", $3);
                if ($1 == enc && $2 == orig && $3 == path) {
                    $4 = cname;
                    $5 = cpath;
                }
                print $0
            }
        ' "$GLOBAL_INDEX" > "$GLOBAL_INDEX.tmp" && mv "$GLOBAL_INDEX.tmp" "$GLOBAL_INDEX"
    done
    echo "✅ 已更新 ${#selected_indices[@]} 条记录的云盘信息。"
}

uploaded() {
    echo "📋 已登记云盘信息的记录："
    local count=0
    while IFS='|' read -r enc orig path cloud_name cloud_path size; do
        orig="${orig// /}"
        cloud_name="${cloud_name// /}"
        cloud_path="${cloud_path// /}"
        if [[ -n "$cloud_name" && -n "$cloud_path" ]]; then
            printf "✅ %-30s → %s:%s\n" "${orig:0:30}" "$cloud_name" "$cloud_path"
            ((count++))
        fi
    done < "$GLOBAL_INDEX"
    echo ""
    echo "共 $count 条记录。"
}

# ============================================================
#  搜索统计
# ============================================================
search() {
    if [[ $# -eq 0 ]]; then
        echo "用法: search <关键词>"
        return 1
    fi
    local keyword="$1"
    if [[ ! -f "$GLOBAL_INDEX" ]]; then
        echo "❌ 全局索引不存在。"
        return 1
    fi
    local matches=$(grep -iF "$keyword" "$GLOBAL_INDEX")
    if [[ -z "$matches" ]]; then
        echo "❌ 未找到包含关键词 '$keyword' 的记录。"
        return 1
    fi

    declare -A dir_size dir_count
    local total_bytes=0 total_files=0
    while IFS='|' read -r enc orig path rest; do
        enc=$(echo "$enc" | xargs)
        orig=$(echo "$orig" | xargs)
        path=$(echo "$path" | xargs)
        [[ -z "$path" ]] && path="."
        local size=$(_get_enc_size "$enc")
        dir_size["$path"]=$(( ${dir_size["$path"]:-0} + size ))
        dir_count["$path"]=$(( ${dir_count["$path"]:-0} + 1 ))
        total_bytes=$((total_bytes + size))
        ((total_files++))
    done <<< "$matches"

    echo "🔍 搜索结果（关键词: $keyword）"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 总大小: $(human_size "$total_bytes")"
    echo "📄 总文件数: $total_files"
    echo ""
    echo "各目录明细："
    echo "----------------------------------------"
    printf "%s\n" "${!dir_size[@]}" | sort | while IFS= read -r d; do
        printf "%-40s %10s  (%d个文件)\n" "$d/" "$(human_size "${dir_size[$d]}")" "${dir_count[$d]}"
    done
}

cloud() {
    echo "===== 云盘/已删除加密文件 ====="
    if [[ ! -f "$GLOBAL_INDEX" ]]; then
        echo "❌ 全局索引不存在。"
        return 1
    fi
    if [[ ! -s "$CACHE_FILE" ]]; then
        _build_cache
    fi

    declare -A cloud_dirs
    local total=0
    while IFS='|' read -r enc orig path rest; do
        enc=$(echo "$enc" | xargs)
        orig=$(echo "$orig" | xargs)
        path=$(echo "$path" | xargs)
        [[ -z "$path" ]] && path="."
        local local_path="$(_get_local_path "$enc")"
        if [[ -z "$local_path" || ! -f "$local_path" ]]; then
            local size=$(_get_enc_size "$enc")
            cloud_dirs["$path"]+="${enc}|${orig}|${size}"$'\n'
            ((total++))
        fi
    done < "$GLOBAL_INDEX"

    if [[ $total -eq 0 ]]; then
        echo "✅ 所有索引文件均存在于本地。"
        return
    fi

    local -a dirs=()
    local idx=1
    echo "找到 $total 个不在本地的加密文件："
    for d in "${!cloud_dirs[@]}"; do
        dirs+=("$d")
        local count=$(echo -n "${cloud_dirs[$d]}" | grep -c '^')
        printf "[%d] %s  (%d个文件)\n" "$idx" "$d" "$count"
        ((idx++))
    done

    echo -n "请输入目录编号查看详情 (q 退出): "
    read -r choice
    if [[ "$choice" == "q" ]]; then
        return
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#dirs[@]} )); then
        echo "无效编号。"
        return
    fi

    local selected_dir="${dirs[$((choice-1))]}"
    echo ""
    echo "📁 目录: $selected_dir"
    echo "----------------------------------------"
    local file_lines="${cloud_dirs[$selected_dir]}"
    local -a file_infos=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        file_infos+=("$line")
    done <<< "$file_lines"

    local i=1
    for info in "${file_infos[@]}"; do
        IFS='|' read -r enc orig size <<< "$info"
        local size_human=$(human_size "$size")
        printf "[%d] %s  ->  %s.dat  (大小: %s)\n" "$i" "$orig" "$enc" "$size_human"
        ((i++))
    done
}

# ============================================================
#  映射生成
# ============================================================
genmap() {
    local target_dir="$1"
    local rel_path=""

    if [[ -z "$target_dir" ]]; then
        target_dir="$(pwd)"
    fi

    if [[ "$target_dir" == "/storage/emulated/0/"* ]]; then
        rel_path="${target_dir#/storage/emulated/0/}"
    elif [[ "$target_dir" == "/sdcard/"* ]]; then
        rel_path="${target_dir#/sdcard/}"
    else
        rel_path="$target_dir"
    fi

    local rel_path_original="$rel_path"
    local rel_path_nospace="${rel_path// /}"

    local dir_lines=""
    while IFS= read -r line; do
        local path_col=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); gsub(/[[:space:]]/, "", $3); print $3}')
        if [[ "$path_col" == "$rel_path_nospace" ]]; then
            dir_lines+="$line"$'\n'
        fi
    done < "$GLOBAL_INDEX"

    if [[ -z "$dir_lines" ]]; then
        echo "❌ 目录 '$rel_path_original' 在索引中没有加密记录。"
        return 1
    fi

    echo "请选择目标云盘："
    echo "  1) 阿里云盘"
    echo "  2) 光鸭盘"
    echo "  3) 其他 (手动输入)"
    echo -n "请输入编号 (1/2/3): "
    read -r disk_choice
    case "$disk_choice" in
        1) cloud_name="阿里盘" ;;
        2) cloud_name="光鸭盘" ;;
        3) echo -n "请输入云盘名称: "; read -r cloud_name ;;
        *) echo "无效选择，默认阿里盘"; cloud_name="阿里盘" ;;
    esac
    echo -n "请输入云盘上的对应目录路径: "
    read -r cloud_path
    cloud_path="${cloud_path//>//}"
    [[ -z "$cloud_path" ]] && echo "❌ 路径不能为空" && return 1

    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local safe_name=$(echo "$rel_path_original" | sed -e 's/[\/]/_/g' -e 's/[[:space:]]/_/g')
    [[ -z "$safe_name" ]] && safe_name="root"
    local output_file="mapping_${safe_name}_${timestamp}.txt"

    {
        echo "本地盘, $cloud_name"
        echo "$rel_path_original, $cloud_path"
        while IFS='|' read -r enc orig path cloud; do
            orig="${orig// /}"
            enc="${enc// /}"
            if [[ -n "$orig" && -n "$enc" ]]; then
                local size=$(_get_enc_size "$enc")
                echo "$(basename "$orig") ↔ $enc.dat | $size"
            fi
        done <<< "$dir_lines"
    } > "$output_file"

    if [[ $? -eq 0 ]] && [[ -s "$output_file" ]]; then
        echo "✅ 映射文件已生成: $output_file"
        echo "📋 共 $(($(wc -l < "$output_file") - 2)) 条映射记录"
    else
        echo "❌ 生成失败。"
        return 1
    fi
}
rebuild_idx() {
    echo "🔄 正在重建辅助索引（按首字母分组）..."
    local group_dir="$MAPPING_ROOT/.idx_groups"
    mkdir -p "$group_dir"
    # 清空旧文件
    rm -f "$group_dir"/*.txt

    # 遍历主索引，按第二列首字母分组
    while IFS= read -r line; do
        # 提取第二列原始文件名
        local orig=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
        # 如果 orig 为空，则用第一列加密文件名
        if [[ -z "$orig" ]]; then
            orig=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
        fi
        # 取首字母转为大写
        local first_char=$(echo "${orig:0:1}" | tr '[:lower:]' '[:upper:]')
        local group_file=""
        if [[ "$first_char" =~ [A-Z] ]]; then
            group_file="$group_dir/${first_char}.txt"
        elif [[ "$first_char" =~ [0-9] ]]; then
            group_file="$group_dir/0-9.txt"
        else
            group_file="$group_dir/OTHER.txt"
        fi
        echo "$line" >> "$group_file"
    done < "$GLOBAL_INDEX"

    echo "✅ 辅助索引重建完成，共 $(wc -l < "$GLOBAL_INDEX") 条记录，分布在 $(ls -1 "$group_dir" | wc -l) 个分组文件中。"
}
gen() {
    if [[ "$1" == "-a" || "$1" == "--all" ]]; then
        echo "===== 批量生成所有目录的映射 ====="
        [[ ! -f "$GLOBAL_INDEX" ]] && echo "❌ 全局索引不存在。" && return 1
        local -a all_dirs
        while IFS='|' read -r enc orig path rest; do
            path="${path// /}"
            [[ -z "$path" ]] && path="."
            all_dirs+=("$path")
        done < "$GLOBAL_INDEX"
        if [[ ${#all_dirs[@]} -eq 0 ]]; then
            echo "索引中没有目录记录。"
            return 1
        fi
        declare -A seen
        local -a unique_dirs
        for d in "${all_dirs[@]}"; do
            if [[ -z "${seen[$d]}" ]]; then
                seen[$d]=1
                unique_dirs+=("$d")
            fi
        done
        for d in "${unique_dirs[@]}"; do
            echo ""
            echo ">>> 生成目录: $d"
            genmap "$d"
        done
        echo ""
        echo "🎉 全部完成！"
    else
        genmap "$@"
    fi
}

# ============================================================
#  整理 (org)
# ============================================================
org() {
    echo "🔍 整理加密文件到统一目录..."
    local dat_files=()
    local exclude_dirs=("Android" "mapcache" "scenic" "vmap" "Encrypted_Vault")
    local find_exclude=()
    for d in "${exclude_dirs[@]}"; do
        find_exclude+=(-not -path "*/$d/*")
    done
    while IFS= read -r -d '' f; do
        dat_files+=("$f")
    done < <(
        find /storage/emulated/0/ -type f -name 'enc_*.dat' "${find_exclude[@]}" -print0 2>/dev/null
    )
    [[ ${#dat_files[@]} -eq 0 ]] && echo "未找到任何 enc_*.dat 文件。" && return
    echo "找到 ${#dat_files[@]} 个加密文件，开始整理..."
    local moved=0 skipped=0 no_record=0
    for f in "${dat_files[@]}"; do
        local base="$(basename "$f" .dat)"
        local rel_path=$(grep "^$base |" "$GLOBAL_INDEX" | head -1 | awk -F'|' '{print $3}' | xargs)
        if [[ -z "$rel_path" ]]; then
            echo "⚠️ 无索引记录，跳过: $f"
            ((no_record++))
            continue
        fi
        local target_dir="$ENCRYPT_ROOT/$rel_path"
        mkdir -p "$target_dir"
        local target_file="$target_dir/$(basename "$f")"
        if [[ -f "$target_file" && "$(readlink -f "$f" 2>/dev/null)" == "$(readlink -f "$target_file" 2>/dev/null)" ]]; then
            ((skipped++))
            continue
        fi
        mv -n "$f" "$target_dir/"
        if [[ $? -eq 0 ]]; then
            echo "✅ 移动: $f -> $target_dir/"
            ((moved++))
        else
            echo "❌ 移动失败: $f"
        fi
    done
    find "$ENCRYPT_ROOT" -type d -empty -delete 2>/dev/null
    echo "🎉 整理完成！移动 $moved，跳过 $skipped，无记录 $no_record。"
    _build_cache
}

# ============================================================
#  信息 / 统计 / 诊断
# ============================================================
info() {
    if [[ $# -eq 0 ]]; then
        echo "用法: info <加密文件名>"
        return 1
    fi
    local enc_name="$1"
    local enc_base="${enc_name%.dat}"
    local line=$(awk -F'|' -v e="$enc_base" '
        {
            gsub(/^[ \t]+|[ \t]+$/, "", $1);
            if ($1 == e) { print $0; exit; }
        }' "$GLOBAL_INDEX" 2>/dev/null)
    if [[ -z "$line" ]]; then
        echo "❌ 未找到该加密文件记录。"
        return 1
    fi
    IFS='|' read -r enc orig path cloud_name cloud_path size <<< "$line"
    enc=$(echo "$enc" | xargs)
    orig=$(echo "$orig" | xargs)
    path=$(echo "$path" | xargs)
    cloud_name=$(echo "$cloud_name" | xargs)
    cloud_path=$(echo "$cloud_path" | xargs)
    echo "📄 加密文件信息："
    echo "  加密文件名: ${enc}.dat"
    echo "  原始文件名: $orig"
    echo "  相对路径: $path"
    [[ -n "$cloud_name" && -n "$cloud_path" ]] && echo "  云盘位置: $cloud_name:$cloud_path"
    local dat_file=$(_get_local_path "$enc")
    if [[ -n "$dat_file" ]]; then
        local sz=$(stat -c %s "$dat_file" 2>/dev/null)
        local mtime=$(stat -c %y "$dat_file" 2>/dev/null | cut -d. -f1)
        echo "  文件大小: $(human_size "$sz")"
        echo "  修改时间: $mtime"
        echo "  本地路径: $dat_file"
    else
        echo "  本地文件: ❌ 未找到"
    fi
}

stats() {
    [[ ! -f "$GLOBAL_INDEX" ]] && echo "❌ 索引不存在。" && return 1
    local total=$(wc -l < "$GLOBAL_INDEX" 2>/dev/null)
    echo "📊 统计信息："
    echo "  总记录数: $total"
    local local_count=$(wc -l < "$CACHE_FILE" 2>/dev/null)
    echo "  本地存在的加密文件数: $local_count"
    local total_size=0
    while IFS='|' read -r enc fpath; do
        size=$(stat -c %s "$fpath" 2>/dev/null)
        total_size=$((total_size + size))
    done < "$CACHE_FILE"
    echo "  总大小: $(human_size "$total_size")"
}

doctor() {
    echo "🔧 系统检查..."
    local errors=0
    [[ -f "$GLOBAL_INDEX" ]] || { echo "❌ 索引文件缺失"; ((errors++)); }
    [[ -d "$DECRYPT_ROOT" ]] || { echo "❌ 解密目录不存在"; ((errors++)); }
    [[ -d "$ENCRYPT_ROOT" ]] || { echo "❌ 加密目录不存在"; ((errors++)); }
    [[ -d "$MAPPING_ROOT" ]] || { echo "❌ 对照目录不存在"; ((errors++)); }
    echo "检查索引与本地文件一致性..."
    local missing=0
    while IFS='|' read -r enc orig path rest; do
        enc=$(echo "$enc" | xargs)
        if ! _is_local "$enc"; then
            echo "  ⚠️ 缺失: ${enc}.dat (原: $orig)"
            ((missing++))
        fi
    done < "$GLOBAL_INDEX"
    if [[ $missing -eq 0 ]]; then
        echo "  ✅ 所有索引文件均存在。"
    else
        echo "  ❌ 发现 $missing 个缺失文件。"
        ((errors++))
    fi
    if [[ $errors -eq 0 ]]; then
        echo "✅ 系统状态正常。"
    else
        echo "❌ 发现 $errors 个问题，请检查。"
    fi
}

refresh() {
    _build_cache
    rebuild_idx
}
dup() {
    echo "🔍 检查重复记录..."
    [[ ! -f "$GLOBAL_INDEX" ]] && echo "❌ 索引不存在。" && return 1
    local dup_count=$(awk -F'|' '
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3);
            key = $2 "|" $3;
            count[key]++;
        }
        END {
            for (key in count) {
                if (count[key] > 1) print key;
            }
        }' "$GLOBAL_INDEX" | wc -l)
    if [[ $dup_count -eq 0 ]]; then
        echo "✅ 无重复记录。"
    else
        echo "⚠️ 发现 $dup_count 组重复记录。"
        echo "运行 'dup --fix' 可交互式清理。"
    fi
}

# ============================================================
#  帮助
# ============================================================
h() {
    if [[ $# -eq 0 ]]; then
        echo "可用命令："
        echo ""
        echo "【加密】"
        echo "  ea           - 加密当前目录的文件（交互选择）"
        echo ""
        echo "【解密】"
        echo "  da           - 单文件解密（当前目录，支持 all 全选）"
        echo "  db           - 批量解密所有加密文件（带进度，失败列表）"
        echo ""
        echo "【查询与列表】"
        echo "  lk [关键词]  - 搜索索引（小屏优化：先目录后文件）"
        echo "  uploaded     - 查看已登记云盘路径的记录"
        echo ""
        echo "【云盘登记】"
        echo "  setcloud     - 交互式批量登记云盘路径"
        echo ""
        echo "【映射生成】"
        echo "  genmap [目录] - 为指定目录生成映射文件（三盘映射器格式）"
        echo "  gen -a        - 为所有目录批量生成映射文件"
        echo ""
        echo "【修改】"
        echo "  rnm <加密文件> [新名称] - 修改加密文件对应的原始文件名"
        echo ""
        echo "【统计与诊断】"
        echo "  search 关键词 - 按目录汇总文件总大小"
        echo "  cloud        - 列出所有不在本地的加密文件"
        echo "  stats        - 统计信息"
        echo "  doctor       - 系统健康检查"
        echo "  dup          - 检查重复记录"
        echo ""
        echo "【维护】"
        echo "  org          - 整理加密文件到统一目录"
        echo "  info <文件>  - 查看加密文件详细信息"
        echo "  refresh      - 手动刷新本地缓存"
        echo ""
        echo "  h            - 此帮助"
        echo "  h <命令>     - 查看指定命令的详细用法"
        return
    fi

    local cmd="$1"
    case "$cmd" in
        ea) echo "ea - 加密当前目录\n  用法: ea\n  交互选择当前目录下的文件进行加密，自动跳过已加密文件。" ;;
        da) echo "da - 单文件解密\n  用法: da\n  交互选择当前目录下的 .dat 文件进行解密，支持输入 all 全选。" ;;
        db) echo "db - 批量解密\n  用法: db\n  自动扫描所有加密目录中的 .dat 文件并解密，带进度显示，最后列出失败文件列表。" ;;
        lk) echo "lk - 搜索/浏览索引\n  用法: lk [关键词]\n  无关键词：按目录浏览全部\n  有关键词：显示匹配的目录，进入后文件标记 ⭐" ;;
        setcloud) echo "setcloud - 批量登记云盘路径\n  用法: setcloud\n  交互式列出未登记记录，可多选，批量填充云盘名称和路径。" ;;
        uploaded) echo "uploaded - 查看已登记云盘的记录\n  用法: uploaded\n  显示已填写云盘信息的记录（文件名→云盘位置）。" ;;
        search) echo "search - 搜索并汇总\n  用法: search <关键词>\n  按目录分组显示匹配文件的总大小。" ;;
        cloud) echo "cloud - 列出云盘文件\n  用法: cloud\n  显示所有不在本地的加密文件及其大小。" ;;
        genmap) echo "genmap - 生成映射\n  用法: genmap [目录]\n  为指定目录生成映射文件（格式：本地盘,云盘名\\n相对路径,云盘路径）。" ;;
        gen) echo "gen - 批量生成映射\n  用法: gen -a\n  为所有目录批量生成映射文件。" ;;
        rnm) echo "rnm - 修改原始文件名\n  用法: rnm <加密文件名> [新原始文件名]\n  示例: rnm enc_1234567890_1234.dat '新名称.jpg'\n  如果不提供新名称，会交互式询问。修改索引和对照表，不影响 .dat 文件本身。" ;;
        org) echo "org - 整理加密文件\n  用法: org\n  将散落的加密文件移动到统一目录。" ;;
        info) echo "info - 查看文件信息\n  用法: info <加密文件名>\n  示例: info enc_1234567890_1234.dat" ;;
        stats) echo "stats - 统计信息\n  用法: stats\n  显示总记录数、本地文件数、总大小等。" ;;
        doctor) echo "doctor - 系统检查\n  用法: doctor\n  检查目录、索引、文件完整性。" ;;
        dup) echo "dup - 检查重复\n  用法: dup\n  检查索引中是否有重复记录。" ;;
        refresh) echo "refresh - 刷新缓存\n  用法: refresh\n  重新扫描本地加密文件并更新缓存。" ;;
        h) echo "h - 帮助\n  用法: h          - 显示所有命令\n       h <命令>   - 查看命令详情" ;;
        *) echo "❌ 未知命令: $cmd" ;;
    esac
}
# ============================================================
#  初始化
# ============================================================
# ============================================================
#  初始化
# ============================================================
if [[ ! -s "$CACHE_FILE" ]]; then
    _build_cache
fi

# 修改加密文件对应的原始文件名（awk精确匹配，自动保留扩展名）
rnm() {
    if [[ $# -lt 1 ]]; then
        echo "用法: rnm <加密文件名> [新原始文件名]"
        echo "示例: rnm enc_1234567890_1234.dat '新名称'"
        echo "如果不提供新名称，会交互式询问。"
        return 1
    fi

    local enc_file="$1"
    local enc_base="${enc_file%.dat}"
    local new_name="$2"

    local old_line=$(awk -F'|' -v e="$enc_base" '
        {
            gsub(/^[ \t]+|[ \t]+$/, "", $1);
            if ($1 == e) { print $0; exit; }
        }' "$GLOBAL_INDEX" 2>/dev/null)

    if [[ -z "$old_line" ]]; then
        echo "❌ 未找到加密文件 '$enc_file' 的记录。"
        return 1
    fi

    local old_orig=$(echo "$old_line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
    echo "当前原始文件名: $old_orig"

    local old_ext="${old_orig##*.}"
    local old_base="${old_orig%.*}"

    if [[ -z "$new_name" ]]; then
        echo -n "请输入新的原始文件名（不含扩展名）: "
        read -r new_name
        if [[ -z "$new_name" ]]; then
            echo "❌ 名称不能为空。"
            return 1
        fi
    fi

    new_name="$(echo "$new_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [[ "$new_name" != *.* && "$old_ext" != "$old_orig" ]]; then
        new_name="${new_name}.${old_ext}"
        echo "🔧 已自动保留原扩展名: $new_name"
    fi

    cp "$GLOBAL_INDEX" "$GLOBAL_INDEX.bak"
    echo "📦 已备份索引到 $GLOBAL_INDEX.bak"

    awk -F'|' -v e="$enc_base" -v newname="$new_name" '
        BEGIN {OFS=FS}
        {
            gsub(/^[ \t]+|[ \t]+$/, "", $1);
            if ($1 == e) {
                $2 = newname;
            }
            print $0
        }
    ' "$GLOBAL_INDEX" > "$GLOBAL_INDEX.tmp" && mv "$GLOBAL_INDEX.tmp" "$GLOBAL_INDEX"

    if [[ $? -eq 0 ]]; then
        echo "✅ 索引已更新，新原始文件名: $new_name"
    else
        echo "❌ 更新失败。"
        return 1
    fi

    local mapfile="$MAPPING_ROOT/加密对照表.txt"
    if [[ -f "$mapfile" ]]; then
        sed -i "s/^$enc_base = .*/$enc_base = $new_name/" "$mapfile"
        echo "📝 已同步更新对照表。"
    fi
    echo "✅ 修改完成。"
}