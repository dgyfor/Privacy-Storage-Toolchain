#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/crypto-engine.sh"
die()  { printf '[index-sync] 错误: %s\n' "$*" >&2; exit 1; }
info() { printf '[index-sync] %s\n' "$*" >&2; }
[[ -x "$ENGINE" ]] || die "找不到可执行的 crypto-engine.sh: $ENGINE"
[[ $# -eq 3 ]] || die "用法: $0 {encrypt|decrypt} <src> <dst>"
mode="$1"; src="$2"; dst="$3"
LOCK_DIR="${dst}.lock"
TMP_FILES=()
LOCK_HELD=0

cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [[ -f "$f" ]] && rm -f -- "$f" || true
    done
    if [[ "$LOCK_HELD" -eq 1 ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    return 0
}
trap cleanup EXIT INT TERM

# 只有成功 mkdir 的进程才把 LOCK_HELD 置 1
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "无法获取锁（另一个进程正在操作索引）"
fi
LOCK_HELD=1

case "$mode" in
    encrypt)
        [[ -f "$src" ]] || die "明文索引不存在: $src"
        tmp="${dst}.tmp.$$"
        backup="${dst}.bak"
        TMP_FILES+=("$tmp")
        bash "$ENGINE" encrypt-index "$src" "$tmp" || die "加密失败"
        [[ -f "$dst" ]] && cp -f -- "$dst" "$backup" || true
        mv -f -- "$tmp" "$dst" || die "原子替换失败"
        info "索引已加密: $dst"
        ;;
    decrypt)
        [[ -f "$src" ]] || die "密文索引不存在: $src"
        tmp="${dst}.tmp.$$"
        TMP_FILES+=("$tmp")
        bash "$ENGINE" decrypt-index "$src" "$tmp" || die "解密或完整性校验失败"
        mv -f -- "$tmp" "$dst" || die "原子替换失败"
        info "索引已解密: $dst"
        ;;
    *) die "未知模式: $mode" ;;
esac