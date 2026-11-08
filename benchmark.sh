#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/termux-encrypt/crypto-engine.sh"
TEST_DIR="$SCRIPT_DIR/test_bench"
RESULT_CSV="$SCRIPT_DIR/benchmark_result.csv"
PASS="test-passphrase-123"

mkdir -p "$TEST_DIR"
echo "文件大小(MB),文件类型,加密耗时(ms),解密耗时(ms),总耗时(ms)" > "$RESULT_CSV"

get_ms() {
    if date +%s%3N >/dev/null 2>&1; then
        date +%s%3N
    else
        python -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s000
    fi
}

generate_file() {
    local size="$1" type="$2" filepath="$3"
    case "$type" in
        "文本")
            head -c "$size" /dev/urandom | base64 > "$filepath"
            ;;
        "二进制")
            head -c "$size" /dev/urandom > "$filepath"
            ;;
    esac
}

sizes=("1" "10" "50")
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
        
        generate_file "$size_bytes" "$type" "$plain_file"
        
        start_time=$(get_ms)
        printf '%s\n' "$PASS" | bash "$ENGINE" encrypt-envelope "$plain_file" "$enc_file" "$dek_file" >/dev/null 2>&1
        end_time=$(get_ms)
        enc_cost=$((end_time - start_time))
        
        start_time=$(get_ms)
        printf '%s\n' "$PASS" | bash "$ENGINE" decrypt-envelope "$enc_file" "$dec_file" "$dek_file" >/dev/null 2>&1
        end_time=$(get_ms)
        dec_cost=$((end_time - start_time))
        
        if cmp -s "$plain_file" "$dec_file"; then
            echo "通过 (加密 ${enc_cost}ms, 解密 ${dec_cost}ms)"
            echo "$size_mb,$type,$enc_cost,$dec_cost,$((enc_cost + dec_cost))" >> "$RESULT_CSV"
        else
            echo "【失败】解密后文件不一致！"
        fi
        
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
