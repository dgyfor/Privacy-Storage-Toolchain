#!/usr/bin/env bash
# =============================================================================
# benchmark.sh - 加密引擎自动化性能压测脚本
# 输出 CSV 格式，可直接导入 Excel 绘制折线图
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/termux-encrypt/crypto-engine.sh"
TEST_DIR="$SCRIPT_DIR/test_bench"
RESULT_CSV="$SCRIPT_DIR/benchmark_result.csv"

# 统一的测试口令
PASS="test-passphrase-123"

mkdir -p "$TEST_DIR"

echo "文件大小,文件类型,加密耗时(ms),解密耗时(ms),总耗时(ms)" > "$RESULT_CSV"

# 获取当前时间（毫秒级）
get_ms() {
    # 兼容 Windows Git Bash 和 Linux 的毫秒时间戳获取
    if date +%s%3N >/dev/null 2>&1; then
        date +%s%3N
    else
        # Termux / 旧版 macOS 回退方案
        python -c 'import time; print(int(time.time() * 1000))'
    fi
}

# 生成测试文件
generate_file() {
    local size="$1" type="$2" filepath="$3"
    case "$type" in
        "文本")
            # 生成 base64 文本，避免过长的单行
            head -c "$size" /dev/urandom | base64 > "$filepath"
            ;;
        "二进制")
            head -c "$size" /dev/urandom > "$filepath"
            ;;
    esac
}

# 开始压测
sizes=("1" "10" "50") # MB
types=("文本" "二进制")

echo "==========================================="
echo " 开始性能压测 (使用口令: $PASS)"
echo " 注：大文件加密可能需要几秒到几十秒，请耐心等待"
echo "==========================================="

for size_mb in "${sizes[@]}"; do
    for type in "${types[@]}"; do
        size_bytes=$((size_mb * 1024 * 1024))
        plain_file="$TEST_DIR/plain_${size_mb}MB_${type}.dat"
        enc_file="$TEST_DIR/enc_${size_mb}MB_${type}.enc"
        dec_file="$TEST_DIR/dec_${size_mb}MB_${type}.dat"
        dek_file="$TEST_DIR/dek_${size_mb}MB_${type}.txt"
        
        echo -n "测试 ${size_mb}MB ${type} 文件... "
        
        # 生成文件
        generate_file "$size_bytes" "$type" "$plain_file"
        
        # 测试加密（信封加密）
        start_time=$(get_ms)
        printf '%s\n' "$PASS" | bash "$ENGINE" encrypt-envelope "$plain_file" "$enc_file" "$dek_file" >/dev/null 2>&1
        end_time=$(get_ms)
        enc_cost=$((end_time - start_time))
        
        # 测试解密
        start_time=$(get_ms)
        printf '%s\n' "$PASS" | bash "$ENGINE" decrypt-envelope "$enc_file" "$dec_file" "$dek_file" >/dev/null 2>&1
        end_time=$(get_ms)
        dec_cost=$((end_time - start_time))
        
        # 校验文件一致性
        if cmp -s "$plain_file" "$dec_file"; then
            echo "通过 (加密 ${enc_cost}ms, 解密 ${dec_cost}ms)"
            echo "$size_mb,$type,$enc_cost,$dec_cost,$((enc_cost + dec_cost))" >> "$RESULT_CSV"
        else
            echo "【失败】解密后文件不一致！"
        fi
        
        # 清理大文件释放空间，保留 1MB 的做示例
        if [ "$size_mb" -gt 1 ]; then
            rm -f "$plain_file" "$enc_file" "$dec_file" "$dek_file"
        fi
    done
done

echo "==========================================="
echo " 压测完成！"
echo " 数据已保存至: $RESULT_CSV"
echo " 你可以用 Excel 打开该 CSV 文件，选中数据插入『折线图』。"
echo "==========================================="