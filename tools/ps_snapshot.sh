#!/usr/bin/env bash
# ps_snapshot.sh — 在加密进程运行时采样 ps，抓命令行参数
set -u

SRC=/tmp/big.dat
DST=/tmp/big.enc
PASS='test-pass-123'
LOG=/tmp/ps_snapshot.log
ENGINE=termux-encrypt/crypto-engine.sh

# 生成 500MB 大文件，保证加密进程有足够时间被采样
if [[ ! -f "$SRC" ]] || [[ $(stat -c%s "$SRC" 2>/dev/null || echo 0) -lt 524288000 ]]; then
    echo "生成 500MB 测试文件..."
    dd if=/dev/urandom of="$SRC" bs=1M count=500 2>/dev/null
fi
rm -f "$DST" "$LOG"

# 后台启动加密
( printf '%s\n' "$PASS" | bash "$ENGINE" encrypt "$SRC" "$DST" ) > /tmp/enc_run.log 2>&1 &
PID=$!
echo "加密进程 PID=$PID，开始采样..."
echo "==================================================" | tee "$LOG"

# 采样 30 次，每 100ms 一次
for i in $(seq 1 30); do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "[采样 $i] 加密进程已结束，停止采样" | tee -a "$LOG"
        break
    fi
    echo "--- 快照 $i（进程存活） ---" | tee -a "$LOG"

    # 方式 1：Git Bash 的 ps（MSYS 进程）
    ps -ef 2>/dev/null | grep -E 'node|crypto-engine|openssl' | grep -v grep | tee -a "$LOG"

    # 方式 2：Windows 原生进程（如果 node 是 Windows 原生版）
    if command -v powershell >/dev/null 2>&1; then
        powershell -NoProfile -Command \
          "Get-CimInstance Win32_Process -Filter \"Name='node.exe' OR Name='openssl.exe'\" | Select-Object ProcessId,Name,CommandLine | Format-Table -AutoSize -Wrap" \
          2>/dev/null | tee -a "$LOG"
    fi

    echo "" | tee -a "$LOG"
    sleep 0.1
done

wait "$PID"; RC=$?
echo "==================================================" | tee -a "$LOG"
echo "加密退出码: $RC" | tee -a "$LOG"
echo "--- 加密输出 ---" | tee -a "$LOG"
cat /tmp/enc_run.log | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "完整日志已保存到: $LOG" | tee -a "$LOG"