#!/usr/bin/env bash
# =============================================================================
# Privacy-Storage-Toolchain / termux-encrypt / crypto-engine.sh  (v1.3)
# AES-256-CTR + HMAC-SHA256 (Encrypt-then-MAC)
# 文件格式（64 字节头部 + 密文）：
#   [7B Magic "PSTv1AE"][1B Ver][8B Salt][16B IV][32B MAC][Ciphertext...]
# =============================================================================

set -Eeuo pipefail

readonly PST_MAGIC="PSTv1AE"          # 7 字节
readonly PST_MAGIC_HEX="50535476314145"
readonly PST_VERSION_HEX="01"
readonly PST_KDF_ITER="${PST_KDF_ITER:-310000}"
readonly PST_SALT_LEN=8
readonly PST_IV_LEN=16
readonly PST_MAC_LEN=32
readonly PST_HEADER_LEN=64            # 7+1+8+16+32
readonly PST_CIPHER="aes-256-ctr"
readonly PST_DIGEST="sha256"
readonly PST_DOMAIN_DEFAULT="PST"
readonly PST_DOMAIN_INDEX="PST-INDEX"

die()  { printf '[crypto-engine] 错误: %s\n' "$*" >&2; exit 1; }
info() { printf '[crypto-engine] %s\n' "$*" >&2; }

_TMPDIRS=()
_new_tmpdir() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/pst.XXXXXX")" || return 1
    chmod 700 "$d"
    _TMPDIRS+=("$d")
    printf '%s' "$d"
}
_cleanup() {
    local d
    for d in "${_TMPDIRS[@]:-}"; do
        [[ -d "$d" ]] && rm -rf -- "$d" 2>/dev/null || true
    done
}
trap _cleanup EXIT INT TERM

_check_openssl() {
    command -v openssl >/dev/null 2>&1 || die "未找到 openssl"
    openssl enc -list 2>/dev/null | grep -qiw "$PST_CIPHER" \
        || die "openssl 不支持 $PST_CIPHER"
    if ! printf 'probe\n' | openssl enc -"$PST_CIPHER" -pbkdf2 -iter 1 \
            -md "$PST_DIGEST" -S "0011223344556677" -pass stdin -P \
            >/dev/null 2>&1; then
        die "openssl 不支持 -pbkdf2 -iter -S -pass stdin（需要 >= 1.1.1）"
    fi
}

_read_passphrase() {
    local pass
    if [[ -t 0 ]]; then
        IFS= read -r -s -p "主口令: " pass
        printf '\n' >&2
    else
        IFS= read -r pass
    fi
    [[ -n "$pass" ]] || die "口令为空"
    printf '%s' "$pass"
}

_derive_subkeys() {
    local pass="$1" salt_hex="$2" td master_file enc_hex mac_hex
    td="$(_new_tmpdir)" || return 1
    master_file="$td/master.bin"

    printf '%s\n' "$pass" \
        | openssl enc -"$PST_CIPHER" -pbkdf2 -iter "$PST_KDF_ITER" \
            -md "$PST_DIGEST" -S "$salt_hex" -pass stdin -P 2>&1 \
        | sed -n 's/^key *= *//p' \
        | xxd -r -p > "$master_file" \
        || return 1

    [[ -s "$master_file" ]] || return 1
    chmod 600 "$master_file"

    enc_hex="$(openssl dgst -"$PST_DIGEST" -hmac "PST-ENC-v1" -binary "$master_file" | xxd -p -c 256)"
    mac_hex="$(openssl dgst -"$PST_DIGEST" -hmac "PST-MAC-v1" -binary "$master_file" | xxd -p -c 256)"

    printf '%s\n%s\n' "$enc_hex" "$mac_hex"
}

cmd_encrypt() {
    local infile="$1" outfile="$2"
    [[ -f "$infile" ]] || die "输入文件不存在: $infile"

    local pass salt_hex iv_hex td enc_hex mac_hex body mac_hex_calc subkeys
    pass="$(_read_passphrase)"
    salt_hex="$(openssl rand -hex "$PST_SALT_LEN")"
    iv_hex="$(openssl rand -hex "$PST_IV_LEN")"

    subkeys="$(_derive_subkeys "$pass" "$salt_hex")" || die "子密钥派生失败（PBKDF2 无输出）"
    enc_hex="$(printf '%s\n' "$subkeys" | sed -n '1p')"
    mac_hex="$(printf '%s\n' "$subkeys" | sed -n '2p')"
    [[ -n "$enc_hex" && -n "$mac_hex" ]] || die "子密钥派生失败（输出为空）"

    td="$(_new_tmpdir)"
    body="$td/body.bin"

    openssl enc -"$PST_CIPHER" -e -K "$enc_hex" -iv "$iv_hex" \
        -in "$infile" -out "$body" -nopad 2>/dev/null \
        || die "加密失败"

    # 头部前缀 hex：Magic(7B)+Ver(1B)+Salt(8B)+IV(16B) = 32 字节 = 64 hex
    local header_prefix_hex
    header_prefix_hex="${PST_MAGIC_HEX}${PST_VERSION_HEX}${salt_hex}${iv_hex}"

    printf '%s' "$header_prefix_hex" | xxd -r -p > "$td/header-no-mac.bin"
    [[ "$(wc -c < "$td/header-no-mac.bin" | tr -d ' ')" -eq 32 ]] \
        || die "头部前缀长度异常"

    mac_hex_calc="$(
        cat "$td/header-no-mac.bin" "$body" \
        | openssl dgst -"$PST_DIGEST" -hmac "$mac_hex" -binary \
        | xxd -p -c 256
    )" || die "HMAC 计算失败"

    {
        printf '%s' "$header_prefix_hex" | xxd -r -p
        printf '%s' "$mac_hex_calc"      | xxd -r -p
        cat "$body"
    } > "$outfile"

    local expected actual
    expected=$((32 + 32 + $(wc -c < "$infile" | tr -d ' ')))
    actual="$(wc -c < "$outfile" | tr -d ' ')"
    [[ "$actual" -eq "$expected" ]] \
        || die "加密后大小异常: 期望 $expected, 实际 $actual"

    info "加密完成: $outfile ($actual bytes)"
}

cmd_decrypt() {
    local infile="$1" outfile="$2"
    [[ -f "$infile" ]] || die "密文文件不存在: $infile"

    local fsize
    fsize="$(wc -c < "$infile" | tr -d ' ')"
    [[ "$fsize" -ge "$PST_HEADER_LEN" ]] || die "文件过短，不是有效密文"

    # 用 xxd -p 把头部转成纯 ASCII hex，再按 hex 偏移切片。
    # 避开 dd + 二进制字符串比较在 MSYS2/UCRT64 下的不可靠行为。
    local header_hex magic_hex version_hex salt_hex iv_hex stored_mac_hex
    header_hex="$(head -c "$PST_HEADER_LEN" "$infile" | xxd -p -c 256 | tr -d '\n')"
    [[ ${#header_hex} -eq $((PST_HEADER_LEN * 2)) ]] \
        || die "头部读取异常（hex 长度 ${#header_hex}）"

    magic_hex="${header_hex:0:14}"       # 7 字节
    version_hex="${header_hex:14:2}"     # 1 字节
    salt_hex="${header_hex:16:16}"       # 8 字节
    iv_hex="${header_hex:32:32}"         # 16 字节
    stored_mac_hex="${header_hex:64:64}" # 32 字节

    [[ "$magic_hex" == "$PST_MAGIC_HEX" ]] || die "Magic 不匹配，不是 PSTv1AE 文件"
    [[ "$version_hex" == "$PST_VERSION_HEX" ]] || die "不支持的版本: $version_hex"

    local pass enc_hex mac_hex td body mac_calc_hex subkeys
    pass="$(_read_passphrase)"
    subkeys="$(_derive_subkeys "$pass" "$salt_hex")" || die "子密钥派生失败（PBKDF2 无输出）"
    enc_hex="$(printf '%s\n' "$subkeys" | sed -n '1p')"
    mac_hex="$(printf '%s\n' "$subkeys" | sed -n '2p')"
    [[ -n "$enc_hex" && -n "$mac_hex" ]] || die "子密钥派生失败（输出为空）"

    td="$(_new_tmpdir)"
    body="$td/body.bin"

    dd if="$infile" bs=1 skip="$PST_HEADER_LEN" of="$body" 2>/dev/null \
        || die "读取 body 失败"

    local header_prefix_hex
    header_prefix_hex="${magic_hex}${version_hex}${salt_hex}${iv_hex}"

    mac_calc_hex="$(
        { printf '%s' "$header_prefix_hex" | xxd -r -p; cat "$body"; } \
        | openssl dgst -"$PST_DIGEST" -hmac "$mac_hex" -binary \
        | xxd -p -c 256
    )"

    [[ "$mac_calc_hex" == "$stored_mac_hex" ]] \
        || die "完整性校验失败：文件可能被篡改，拒绝解密"

    openssl enc -"$PST_CIPHER" -d -K "$enc_hex" -iv "$iv_hex" \
        -in "$body" -out "$outfile" -nopad 2>/dev/null \
        || die "解密失败"

    info "解密完成并通过完整性校验: $outfile"
}
# ---------- 信封加密（DEK 随机化） ----------
cmd_encrypt_envelope() {
    local infile="$1" outfile="$2" dek_outfile="$3"
    [[ -f "$infile" ]] || die "输入文件不存在: $infile"

    local pass salt_hex iv_hex td body mac_hex_calc subkeys kek_enc_hex kek_mac_hex
    pass="$(_read_passphrase)"
    
    local dek_hex
    dek_hex="$(openssl rand -hex 32)"

    salt_hex="$(openssl rand -hex "$PST_SALT_LEN")"
    iv_hex="$(openssl rand -hex "$PST_IV_LEN")"
    td="$(_new_tmpdir)"
    body="$td/body.bin"

    openssl enc -"$PST_CIPHER" -e -K "$dek_hex" -iv "$iv_hex" -in "$infile" -out "$body" -nopad 2>/dev/null || die "文件加密失败"

    local header_prefix_hex
    header_prefix_hex="${PST_MAGIC_HEX}${PST_VERSION_HEX}${salt_hex}${iv_hex}"
    printf '%s' "$header_prefix_hex" | xxd -r -p > "$td/header-no-mac.bin"
    mac_hex_calc="$(cat "$td/header-no-mac.bin" "$body" | openssl dgst -"$PST_DIGEST" -hmac "$dek_hex" -binary | xxd -p -c 256)"

    { printf '%s' "$header_prefix_hex" | xxd -r -p; printf '%s' "$mac_hex_calc" | xxd -r -p; cat "$body"; } > "$outfile"

    subkeys="$(_derive_subkeys "$pass" "$salt_hex" "PST-ENVELOPE")" || die "KEK 派生失败"
    kek_enc_hex="$(printf '%s\n' "$subkeys" | sed -n '1p')"
    kek_mac_hex="$(printf '%s\n' "$subkeys" | sed -n '2p')"

    local dek_iv_hex dek_mac_calc dek_body_hex
    dek_iv_hex="$(openssl rand -hex 16)"
    dek_body_hex="$(printf '%s' "$dek_hex" | xxd -r -p | openssl enc -"$PST_CIPHER" -e -K "$kek_enc_hex" -iv "$dek_iv_hex" -nopad | xxd -p -c 256)"
    dek_mac_calc="$(printf '%s' "$dek_iv_hex$dek_body_hex" | xxd -r -p | openssl dgst -"$PST_DIGEST" -hmac "$kek_mac_hex" -binary | xxd -p -c 256)"

    printf '%s' "${dek_iv_hex}${dek_mac_calc}${dek_body_hex}" > "$dek_outfile"
    info "信封加密完成: 文件=$outfile, 包裹DEK=$dek_outfile"
}

# ---------- 信封解密 ----------
cmd_decrypt_envelope() {
    local infile="$1" outfile="$2" dek_infile="$3"
    [[ -f "$infile" ]] || die "密文文件不存在"
    [[ -f "$dek_infile" ]] || die "包裹的 DEK 文件不存在"

    local pass salt_hex iv_hex stored_mac_hex header_hex
    header_hex="$(head -c "$PST_HEADER_LEN" "$infile" | xxd -p -c 256 | tr -d '\n')"
    salt_hex="${header_hex:16:16}"
    iv_hex="${header_hex:32:32}"
    stored_mac_hex="${header_hex:64:64}"

    local wrapped_hex dek_iv_hex dek_stored_mac_hex dek_body_hex
    wrapped_hex="$(cat "$dek_infile" | tr -d '\r\n ')"
    dek_iv_hex="${wrapped_hex:0:32}"
    dek_stored_mac_hex="${wrapped_hex:32:64}"
    dek_body_hex="${wrapped_hex:96:64}"

    pass="$(_read_passphrase)"
    local subkeys kek_enc_hex kek_mac_hex dek_mac_calc dek_hex
    subkeys="$(_derive_subkeys "$pass" "$salt_hex" "PST-ENVELOPE")" || die "KEK 派生失败"
    kek_enc_hex="$(printf '%s\n' "$subkeys" | sed -n '1p')"
    kek_mac_hex="$(printf '%s\n' "$subkeys" | sed -n '2p')"

    dek_mac_calc="$(printf '%s' "$dek_iv_hex$dek_body_hex" | xxd -r -p | openssl dgst -"$PST_DIGEST" -hmac "$kek_mac_hex" -binary | xxd -p -c 256)"
    [[ "$dek_mac_calc" == "$dek_stored_mac_hex" ]] || die "包裹的 DEK 被篡改或口令错误"

    dek_hex="$(printf '%s' "$dek_body_hex" | xxd -r -p | openssl enc -"$PST_CIPHER" -d -K "$kek_enc_hex" -iv "$dek_iv_hex" -nopad | xxd -p -c 256)"
    [[ ${#dek_hex} -eq 64 ]] || die "DEK 解密异常"

    local td body mac_calc_hex header_prefix_hex
    td="$(_new_tmpdir)"
    body="$td/body.bin"
    dd if="$infile" bs=1 skip="$PST_HEADER_LEN" of="$body" 2>/dev/null || die "读取文件体失败"

    header_prefix_hex="${PST_MAGIC_HEX}${PST_VERSION_HEX}${salt_hex}${iv_hex}"
    mac_calc_hex="$({ printf '%s' "$header_prefix_hex" | xxd -r -p; cat "$body"; } | openssl dgst -"$PST_DIGEST" -hmac "$dek_hex" -binary | xxd -p -c 256)"

    [[ "$mac_calc_hex" == "$stored_mac_hex" ]] || die "文件内容被篡改"

    openssl enc -"$PST_CIPHER" -d -K "$dek_hex" -iv "$iv_hex" -in "$body" -out "$outfile" -nopad 2>/dev/null || die "文件解密失败"
    info "信封解密完成: $outfile"
}
main() {
    _check_openssl
    [[ $# -ge 3 ]] || {
        printf '用法: %s {encrypt|decrypt|encrypt-index|decrypt-index|encrypt-envelope|decrypt-envelope} <参数...>\n' "$0" >&2
        exit 2
    }
        case "$1" in
        encrypt)          cmd_encrypt "$2" "$3" "$PST_DOMAIN_DEFAULT" ;;
        decrypt)          cmd_decrypt "$2" "$3" "$PST_DOMAIN_DEFAULT" ;;
        encrypt-index)    cmd_encrypt "$2" "$3" "$PST_DOMAIN_INDEX"   ;;
        decrypt-index)    cmd_decrypt "$2" "$3" "$PST_DOMAIN_INDEX"   ;;
        encrypt-envelope) cmd_encrypt_envelope "$2" "$3" "$4"         ;;
        decrypt-envelope) cmd_decrypt_envelope "$2" "$3" "$4"         ;;
        *) die "未知模式: $1" ;;
    esac
}

main "$@"