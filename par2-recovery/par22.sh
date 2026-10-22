#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  PAR2 容灾恢复模块 (par22 & fixdat)
#  依赖: par2cmdline (Termux: pkg install par2)
# ============================================================

# 1. par22：为所有加密文件生成 PAR2 恢复包
par22() {
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        echo "用法: par22"
        echo "功能: 递归扫描 \$ENCRYPT_ROOT 下所有 .dat，生成 PAR2 到 \$PAR2_ROOT"
        return 0
    fi

    local PAR2_CMD=$(command -v par2 2>/dev/null)
    if [ -z "$PAR2_CMD" ] || [ ! -x "$PAR2_CMD" ]; then
        echo "❌ par2 命令不可用，请确保已安装: pkg install par2"
        return 1
    fi

    if [ ! -d "$ENCRYPT_ROOT" ]; then
        echo "❌ 加密根目录不存在: $ENCRYPT_ROOT"
        return 1
    fi
    mkdir -p "$PAR2_ROOT" || { echo "❌ 无法创建 PAR2 目录"; return 1; }

    local tmpfile=$(mktemp)
    find "$ENCRYPT_ROOT" -type f -name "*.dat" > "$tmpfile" 2>/dev/null
    local total=$(wc -l < "$tmpfile" | tr -d ' ')
    
    if [ "$total" -eq 0 ]; then
        echo "📭 没有找到 .dat 文件"
        rm -f "$tmpfile"
        return 1
    fi

    local success=0 skip=0 fail=0 count=0 total_size=0
    while IFS= read -r f; do
        ((count++))
        local base=$(basename "$f")
        local rel_dir=$(dirname "${f#$ENCRYPT_ROOT/}")
        [ "$rel_dir" = "." ] && rel_dir=""
        local target_dir="$PAR2_ROOT/$rel_dir"
        
        mkdir -p "$target_dir" || { echo "❌ 无法创建 $target_dir"; ((fail++)); continue; }
        echo "📊 进度: [$count/$total] - 正在处理 $base"
        
        # 如果已存在主文件或卷文件则跳过
        if [ -f "$target_dir/${base}.par2" ] || ls "$target_dir/${base}.vol"*.par2 >/dev/null 2>&1; then
            echo "⏩ 跳过 $base（已存在）"
            ((skip++))
            continue
        fi

        echo "🔄 处理 $base"
        local errfile=$(mktemp)
        ( cd "$(dirname "$f")" && "$PAR2_CMD" create -r3 "$base" > /dev/null 2> "$errfile" && mv "${base}.par2" "${base}.vol"*.par2 "$target_dir/" 2>/dev/null )
        
        if [ $? -eq 0 ]; then
            local size=0
            if [ -f "$target_dir/${base}.par2" ]; then
                local s=$(stat -c%s "$target_dir/${base}.par2" 2>/dev/null || echo 0)
                size=$((size + s))
            fi
            for vol in "$target_dir/${base}.vol"*.par2; do
                [ -f "$vol" ] && local s=$(stat -c%s "$vol" 2>/dev/null || echo 0) && size=$((size + s))
            done
            total_size=$((total_size + size))
            echo "✅ 成功"
            ((success++))
        else
            echo "❌ 失败"
            [ -s "$errfile" ] && cat "$errfile" | sed 's/^/   /'
            ((fail++))
        fi
        rm -f "$errfile"
    done < "$tmpfile"
    rm -f "$tmpfile"

    local size_str=""
    if [ $total_size -ge 1073741824 ]; then
        size_str="$((total_size / 1073741824)) GB"
    elif [ $total_size -ge 1048576 ]; then
        size_str="$((total_size / 1048576)) MB"
    elif [ $total_size -ge 1024 ]; then
        size_str="$((total_size / 1024)) KB"
    else
        size_str="${total_size} B"
    fi

    echo "========== 统计 =========="
    echo "总文件: $total | 本次生成: $success | 跳过: $skip | 失败: $fail"
    echo "本次生成大小: $size_str"
    echo "=========================="
}

# 2. fixdat：交互式修复损坏的 .dat 文件
fixdat() {
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        echo "用法: fixdat"
        echo "功能: 交互式修复损坏的 .dat（从 \$PAR2_ROOT 复制 PAR2 到 .dat 所在目录进行修复）"
        return 0
    fi

    local PAR2_CMD=$(command -v par2 2>/dev/null)
    if [ -z "$PAR2_CMD" ]; then
        echo "❌ par2 命令不可用，请确保已安装: pkg install par2"
        return 1
    fi

    echo "=============================="
    echo "      PAR2 修复工具 fixdat"
    echo "=============================="
    echo "输入关键字搜索 (例如 547)，或直接按 Enter 列出全部文件："
    read -p "关键字: " keyword

    local files=""
    if [ -z "$keyword" ]; then
        files=$(find "$ENCRYPT_ROOT" -type f -name "*.dat" 2>/dev/null)
    else
        files=$(find "$ENCRYPT_ROOT" -type f -name "*$keyword*.dat" 2>/dev/null)
    fi

    if [ -z "$files" ]; then
        echo "❌ 未找到匹配的 .dat 文件"
        return 1
    fi

    set -f; IFS=$'\n'
    set -- $files
    set +f; unset IFS
    local count=$#

    echo "找到 $count 个文件："
    local i=0
    for f in "$@"; do
        echo "  [$i] $(basename "$f") (路径: ${f#$ENCRYPT_ROOT/})"
        ((i++))
    done

    echo -n "请输入编号进行修复（空格分隔，如 0 2 3）或输入 all 全选: "
    read -r selection

    local indices=""
    if [ "$selection" = "all" ]; then
        indices=$(seq 0 $((count-1)))
    else
        indices=$selection
    fi

    local success=0 fail=0 processed=0
    local total_selected=$(echo "$indices" | wc -w | tr -d ' ')

    for num in $indices; do
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -ge "$count" ]; then
            echo "忽略无效编号: $num"
            continue
        fi

        local idx=0 target=""
        for f in "$@"; do
            if [ $idx -eq "$num" ]; then target="$f"; break; fi
            ((idx++))
        done
        [ -z "$target" ] && continue

        local base=$(basename "$target" .dat)
        local rel_dir=$(dirname "${target#$ENCRYPT_ROOT/}")
        [ "$rel_dir" = "." ] && rel_dir=""
        
        local par2_file="$PAR2_ROOT/$rel_dir/${base}.dat.par2"

        if [ ! -f "$par2_file" ]; then
            local vol_file=$(find "$PAR2_ROOT/$rel_dir" -maxdepth 1 -name "${base}.dat.vol*.par2" 2>/dev/null | head -1)
            if [ -z "$vol_file" ]; then
                echo "❌ 跳过：$base (PAR2 备份不存在)"
                ((fail++)); continue
            fi
        fi

        echo "🔧 处理: $(basename "$target") ..."
        cd "$(dirname "$target")" || { echo "❌ 无法进入目录"; ((fail++)); continue; }
        
        cp "$par2_file" . 2>/dev/null
        for vol in "$PAR2_ROOT/$rel_dir/${base}.dat.vol"*.par2; do
            [ -f "$vol" ] && cp "$vol" . 2>/dev/null
        done

        if "$PAR2_CMD" repair "${base}.dat.par2" > /dev/null 2>&1; then
            echo "   ✅ 成功修复"
            ((success++))
        else
            echo "   ❌ 修复失败"
            ((fail++))
        fi

        rm -f "${base}.dat.par2" "${base}.dat.vol"*.par2 2>/dev/null
        ((processed++))
        echo "   ($processed / $total_selected)"
    done

    echo "=============================="
    echo "修复完成：总处理 $total_selected 个，成功 $success 个，失败 $fail 个。"
}