# INTERFACE.md — 接口与数据契约

任何脚本/前端改动不得破坏以下契约。

## 1. 目录结构

| 用途 | 路径 |
|---|---|
| 加密输出 | /storage/emulated/0/Documents/Encrypted_Vault/加密文件/ |
| 解密输出 | /storage/emulated/0/Documents/Encrypted_Vault/解密输出/ |
| 对照表 | /storage/emulated/0/Documents/Encrypted_Vault/对照表/ |
| PAR2备份 | /storage/emulated/0/Documents/Encrypted_Vault/Par2_Backups/ |
| 主索引(人读) | /storage/emulated/0/encrypted_index.txt |
| JSONL索引(机读) | .../对照表/index.jsonl |

## 2. index.jsonl 契约（机读）

一行一 JSON，前端解析：

    const rows = text.split('\n').filter(Boolean).map(JSON.parse);

字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| encrypted_name | string | 加密文件名(basename)，与 GLOBAL_INDEX 第1列对齐 |
| original_name | string | 原文件名 |
| relative_path | string | 相对加密根目录的子路径 |
| cipher | string | 固定 AES-256-CBC |
| created_at | string | ISO8601 UTC |
| sha256 | string | 密文 SHA-256 |
| sizes.encrypted | number | 密文字节数 |

示例：

    {"encrypted_name":"enc_1790925335_9217","original_name":"map_test.txt","relative_path":"test_encrypt","cipher":"AES-256-CBC","created_at":"2026-10-02T07:15:35Z","sha256":"7223fe7f62fa7ed289f6e1762a620f47eded5d49cda5d71c03b4df321f271fc0","sizes":{"encrypted":32}}

## 3. GLOBAL_INDEX 契约（人读）

竖线 7 列：

    enc_name|orig_name|rel_path|cloud_name|cloud_path|size|reserved

## 4. 脚本接口

- 加密：source ~/Privacy-Storage-Toolchain/termux-encrypt/encrypt_new.sh 然后 ea
- PAR2：source /sdcard/termux_shared.sh 然后 par22

## 5. 不变式

1. 临时文件写共享存储，不 mktemp 到 Termux 内部
2. encrypted_name 用 basename
3. 改脚本用 UTF-8 无 BOM
4. 云盘字段当前仅在 GLOBAL_INDEX 第4、5列，尚未进 index.jsonl（待办）