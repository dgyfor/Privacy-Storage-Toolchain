# CHANGELOG

格式：日期倒序。只记对外可见的变更，不记内部调试。

## [Unreleased]

### 待办
- P2 三盘映射器 HTML 接入 index.jsonl
- P3 电脑端 Git Bash 跑通 encrypt.sh
- 云盘字段进 index.jsonl
- genmap/setcloud 并入 encrypt_new.sh
- termux_shared.sh fixdat/fp 路径对齐

## 2026-10-02

### 新增
- index.jsonl 双轨索引：JSONL 给机器，竖线文本给人
- PAR2 跳过逻辑：已存在则跳过
- ea 加密后显示 "原文件名 → 加密文件名"

### 修复
- 跨文件系统 mv 静默失败（临时文件改用 $MAPPING_ROOT/.tmp_*）
- termux_shared.sh 第321行语法错
- .bashrc 旧函数覆盖
- 删重复 par22 定义

### 变更
- 装 bc，PAR2 大小统计正常
- .gitignore 挡私人数据

## 2026-10-01 及之前

- 端侧加密 AES-256-CBC + pbkdf2
- index.jsonl 含 sha256/created_at/cipher/encrypted_name/original_name/relative_path/sizes.encrypted
- PAR2 容灾：par22 扫 Encrypt_ROOT，输出 Par2_Backups 镜像路径