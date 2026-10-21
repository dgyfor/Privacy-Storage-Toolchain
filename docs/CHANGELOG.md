# CHANGELOG

格式：日期倒序。只记对外可见的变更，不记内部调试。

## [Unreleased]

### 待办
- P2.5 index.jsonl 从明文落盘改为密文落盘（见 DECISIONS D-003）
- 密码别名表真正实现（`PASSWORDS_FILE` 目前未启用，`get_password` 为直通）
- 三盘映射器 HTML 接入密文 index.jsonl
- termux_shared.sh fixdat/fp 路径对齐

## 2026-10-21

### 新增
- encrypt_new.sh 全平台自适应：自动检测 Termux / Windows Git Bash，路径根自适应
- 纯 Bash 实现 setcloud 写 index.jsonl，移除 sync_clouds.py 依赖
- human_size 改纯 Bash 整数运算，移除 bc 依赖

### 修复
- ea 跨目录误判：判重键加入 relative_path，同名文件在不同目录不再被静默跳过
- index.jsonl 写入增加 JSON 转义：文件名含 `"` 或 `\` 时不再产生非法 JSON

### 变更
- 仓库清理：删除测试垃圾文件（my_secret_doc.txt / secret.txt / par2.exe），归档旧版脚本到 termux-encrypt/archive/，移除无关目录 diary-site
- .gitignore 补充：test_vault/、archive/、*.bak、passwords.txt、mapping_*.txt

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
- 装 bc，PAR2 大小统计正常（注：2026-10-21 已移除 bc 依赖）
- .gitignore 挡私人数据

## 2026-10-01 及之前

- 端侧加密 AES-256-CBC + pbkdf2
- index.jsonl 含 sha256/created_at/cipher/encrypted_name/original_name/relative_path/sizes.encrypted
- PAR2 容灾：par22 扫 Encrypt_ROOT，输出 Par2_Backups 镜像路径
