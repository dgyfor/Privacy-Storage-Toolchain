#!/usr/bin/env bash
# crypto-engine.sh v2.0 — Node.js crypto 后端薄壳，接口与 v1.3 兼容
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_ENGINE="$SCRIPT_DIR/crypto-engine.js"

[[ -f "$NODE_ENGINE" ]] || { echo "[crypto-engine] 错误: 找不到 $NODE_ENGINE" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "[crypto-engine] 错误: 未找到 node（请安装 Node.js）" >&2; exit 1; }

exec node "$NODE_ENGINE" "$@"