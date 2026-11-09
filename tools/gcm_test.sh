#!/usr/bin/env bash
# gcm_test.sh — 测试当前 OpenSSL 是否支持 AES-256-GCM 的 enc -tag 用法
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$DIR/.gcm_test"
rm -rf "$WORK"
mkdir -p "$WORK"

PASS='gcm-test-pass'
SALT='0011223344556677'      # 8 字节 hex
NONCE='00112233445566778899aabb'  # 12 字节 hex
ITER=1000                    # 测试用低迭代，只为验证功能

echo "=== 0. 环境 ==="
openssl version
echo "OPENSSL_CONF=${OPENSSL_CONF:-<unset>}"
echo "工作目录: $WORK"
echo

echo "=== 1. cipher 列表是否包含 aes-256-gcm ==="
if openssl enc -list 2>/dev/null | tr ' ' '\n' | grep -qx 'aes-256-gcm'; then
    echo "PASS: enc -list 包含 aes-256-gcm"
else
    echo "WARN: enc -list 未列出 aes-256-gcm（有些版本仍可用，继续测）"
fi
echo

echo "=== 2. 准备明文 ==="
printf 'hello gcm test\n' > "$WORK/plain.txt"
wc -c < "$WORK/plain.txt" | tr -d ' '
echo

echo "=== 3. GCM 加密（-tag 输出 tag 文件） ==="
printf '%s\n' "$PASS" | openssl enc -aes-256-gcm -e -pbkdf2 -iter "$ITER" \
    -md sha256 -S "$SALT" -pass stdin \
    -iv "$NONCE" \
    -in "$WORK/plain.txt" -out "$WORK/cipher.bin" -tag "$WORK/tag.bin"
E1=$?
echo "encrypt exit=$E1"
if [[ $E1 -eq 0 && -f "$WORK/cipher.bin" && -f "$WORK/tag.bin" ]]; then
    echo "PASS: 加密成功，cipher 和 tag 文件都已生成"
    echo "cipher 大小: $(wc -c < "$WORK/cipher.bin" | tr -d ' ') bytes"
    echo "tag 大小:    $(wc -c < "$WORK/tag.bin" | tr -d ' ') bytes (期望 16)"
else
    echo "FAIL: 加密失败或未生成 tag 文件"
    echo "--- 目录内容 ---"; ls -la "$WORK"
    echo "=== 结论：当前 OpenSSL 不支持 enc -aes-256-gcm -tag，停止后续测试 ==="
    exit 1
fi
echo

echo "=== 4. GCM 解密（正确密码 + 正确 tag） ==="
printf '%s\n' "$PASS" | openssl enc -d -aes-256-gcm -pbkdf2 -iter "$ITER" \
    -md sha256 -S "$SALT" -pass stdin \
    -iv "$NONCE" \
    -in "$WORK/cipher.bin" -out "$WORK/dec.bin" -tag "$WORK/tag.bin"
E2=$?
echo "decrypt exit=$E2"
if [[ $E2 -eq 0 ]] && cmp -s "$WORK/plain.txt" "$WORK/dec.bin"; then
    echo "PASS: 解密成功且与明文一致"
else
    echo "FAIL: 解密失败或内容不一致"
    echo "--- plain ---"; cat "$WORK/plain.txt"
    echo "--- dec ---";   cat "$WORK/dec.bin" 2>/dev/null || echo "<无输出>"
fi
echo

echo "=== 5. 篡改 tag，解密必须失败 ==="
cp "$WORK/tag.bin" "$WORK/tag_bad.bin"
printf '\x00' | dd of="$WORK/tag_bad.bin" bs=1 seek=0 conv=notrunc 2>/dev/null
printf '%s\n' "$PASS" | openssl enc -d -aes-256-gcm -pbkdf2 -iter "$ITER" \
    -md sha256 -S "$SALT" -pass stdin \
    -iv "$NONCE" \
    -in "$WORK/cipher.bin" -out "$WORK/dec_bad.bin" -tag "$WORK/tag_bad.bin" 2>"$WORK/tag_err.log"
E3=$?
echo "tampered-tag decrypt exit=$E3 (期望非 0)"
echo "--- stderr ---"; cat "$WORK/tag_err.log"
echo

echo "=== 6. 错误密码，解密必须失败 ==="
printf 'wrong-pass\n' | openssl enc -d -aes-256-gcm -pbkdf2 -iter "$ITER" \
    -md sha256 -S "$SALT" -pass stdin \
    -iv "$NONCE" \
    -in "$WORK/cipher.bin" -out "$WORK/dec_wrong.bin" -tag "$WORK/tag.bin" 2>"$WORK/pwd_err.log"
E4=$?
echo "wrong-pass decrypt exit=$E4 (期望非 0)"
echo "--- stderr ---"; cat "$WORK/pwd_err.log"
echo

echo "=== 7. 汇总 ==="
printf 'encrypt=%s  decrypt=%s  tampered_tag=%s  wrong_pass=%s\n' "$E1" "$E2" "$E3" "$E4"
if [[ $E1 -eq 0 && $E2 -eq 0 && $E3 -ne 0 && $E4 -ne 0 ]]; then
    echo "结论: ✅ 支持 GCM + -tag，且完整性/口令校验生效，可以迁 GCM"
else
    echo "结论: ❌ 不满足全部条件，先不要迁 GCM，保留 CTR+HMAC"
fi