#!/usr/bin/env bash
# test_pst.sh — 放在 Privacy-Storage-Toolchain 根目录运行
set -u
PASS='test-pass-123'
P=termux-encrypt/crypto-engine.sh
I=termux-encrypt/index-sync.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== 0. 环境检查 ==="
command -v openssl >/dev/null || { echo "NO openssl"; exit 1; }
openssl version

echo "=== 1. 普通加密→解密→哈希一致 ==="
echo "hello pst" > "$TMP/p.txt"
printf '%s\n' "$PASS" | bash "$P" encrypt "$TMP/p.txt" "$TMP/p.enc"
echo "encrypt exit=$? ; p.enc exists: $( [[ -f "$TMP/p.enc" ]] && echo yes || echo NO )"
printf '%s\n' "$PASS" | bash "$P" decrypt "$TMP/p.enc" "$TMP/p.dec"
echo "decrypt exit=$?"
sha256sum "$TMP/p.txt" "$TMP/p.dec"

echo "=== 2. 篡改一字节，正确密码解密必须失败 ==="
cp "$TMP/p.enc" "$TMP/p.bad"
printf '\x00' | dd of="$TMP/p.bad" bs=1 seek=70 conv=notrunc 2>/dev/null
printf '%s\n' "$PASS" | bash "$P" decrypt "$TMP/p.bad" "$TMP/p.out"; echo "tamper exit=$?"

echo "=== 3. 错误密码解密必须失败 ==="
printf 'wrongpass\n' | bash "$P" decrypt "$TMP/p.enc" "$TMP/p.out"; echo "wrongpass exit=$?"

echo "=== 4. 索引加密→解密→diff ==="
cp test_vault/对照表/index.jsonl "$TMP/index.jsonl"
printf '%s\n' "$PASS" | bash "$I" encrypt "$TMP/index.jsonl" "$TMP/index.enc"
printf '%s\n' "$PASS" | bash "$I" decrypt "$TMP/index.enc" "$TMP/index.dec"
diff "$TMP/index.jsonl" "$TMP/index.dec" && echo "index roundtrip OK"

echo "=== 5. 信封加密→解密→哈希一致 ==="
printf '%s\n' "$PASS" | bash "$P" encrypt-envelope "$TMP/p.txt" "$TMP/p.env.enc" "$TMP/p.dek"
printf '%s\n' "$PASS" | bash "$P" decrypt-envelope "$TMP/p.env.enc" "$TMP/p.env.dec" "$TMP/p.dek"
sha256sum "$TMP/p.txt" "$TMP/p.env.dec"

echo "=== 6. 并发锁测试（各自独立喂密码） ==="
printf '%s\n' "$PASS" | bash "$I" encrypt "$TMP/index.jsonl" "$TMP/index2.enc" > "$TMP/lock1.log" 2>&1 &
PID1=$!
printf '%s\n' "$PASS" | bash "$I" encrypt "$TMP/index.jsonl" "$TMP/index2.enc" > "$TMP/lock2.log" 2>&1 &
PID2=$!
wait "$PID1"; E1=$?
wait "$PID2"; E2=$?
echo "lock exits: $E1 $E2"
echo "--- lock1.log ---"; cat "$TMP/lock1.log"
echo "--- lock2.log ---"; cat "$TMP/lock2.log"