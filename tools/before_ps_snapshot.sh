#!/usr/bin/env bash
set -u
OLD_ENGINE=termux-encrypt/archive/crypto-engine.v1.3.sh.bak
SRC=/tmp/big.dat
DST=/tmp/big_v1.enc
PASS='test-pass-123'
LOG=docs/evidence/before_ctr_hmac_ps.log
[[ -f "$OLD_ENGINE" ]] || { echo "找不到 $OLD_ENGINE" >&2; exit 1; }
mkdir -p docs/evidence
if [[ ! -f "$SRC" ]] || [[ $(stat -c%s "$SRC" 2>/dev/null || echo 0) -lt 268435456 ]]; then
    echo "生成 256MB 测试文件..."
    dd if=/dev/urandom of="$SRC" bs=1M count=256 2>/dev/null
fi
rm -f "$DST" "$LOG"
( printf '%s\n' "$PASS" | bash "$OLD_ENGINE" encrypt "$SRC" "$DST" ) > /tmp/enc_v1_run.log 2>&1 &
PID=$!
{
    echo "=== BEFORE: v1.3 OpenSSL CTR+HMAC 的命令行可见性 ==="
    echo "采样时间: $(date)"
    echo "旧引擎: $OLD_ENGINE"
    echo "文件大小: $(stat -c%s "$SRC" | tr -d ' ') bytes"
    echo "加密进程 PID: $PID"
    echo "=================================================="
} | tee "$LOG"
for i in $(seq 1 300); do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "[采样 $i] 加密进程已结束，停止采样" | tee -a "$LOG"
        break
    fi
    ps -ef 2>/dev/null | grep -E '[o]penssl' | tee -a "$LOG"
    sleep 0.02
done
wait "$PID"; RC=$?
{
    echo "=================================================="
    echo "旧引擎退出码: $RC"
    echo "--- 加密输出 ---"
    cat /tmp/enc_v1_run.log
    echo ""
    echo "--- 输出文件 ---"
    ls -la "$DST" 2>&1
} | tee -a "$LOG"
echo ""
echo "日志已保存到: $LOG"
