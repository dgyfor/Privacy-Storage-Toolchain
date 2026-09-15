# 接口字段对照与修复方案（AI评估报告配套）

## 一、字段映射与修复指南

1. 【id】 / 【encrypted_name】
   - 现有字段：enc_base
   - 状态：P0级别不符
   - 分析：当前是完整路径，导致后续基于basename的查询全挂。
   - 改法：修改函数 _encrypt_file_batch，用 $(basename "${enc_name%.dat}") 替换原变量。

2. 【original_name】
   - 现有字段：orig_name
   - 状态：受P0-3分隔符影响
   - 分析：若原文件名含竖线`|`，会导致字段错位。
   - 改法：接口层改用JSON；若沿用文本，用jq -n生成。

3. 【relative_path】
   - 现有字段：rel_path
   - 状态：P0级别致命错误
   - 分析：代码中 `${var// /}` 删除了所有空格，破坏了安卓真机路径。
   - 改法：全局删除 `${var// /}`。在脚本顶部加 trim() 函数，改为 `path="$(trim "$path")"`。

4. 【remote.provider】 / 【remote.path】
   - 现有字段：cloud_name / cloud_path
   - 状态：符合
   - 分析：无
   - 改法：保持不变。

5. 【sizes.encrypted】
   - 现有字段：size
   - 状态：符合
   - 分析：无
   - 改法：保持不变。

6. 【sizes.original】
   - 现有字段：无
   - 状态：缺失
   - 分析：只记录了加密后大小。
   - 改法：加密前用 `stat -c %s "$file"` 获取原始大小。

7. 【cipher.name】 / 【cipher.kdf】
   - 现有字段：无
   - 状态：缺失
   - 分析：未记录算法和派生方式。
   - 改法：硬编码记录为 "aes-256-cbc" 和 "pbkdf2"。

8. 【cipher.iter】
   - 现有字段：无
   - 状态：缺失
   - 分析：未指定迭代次数，跨版本无法复现。
   - 改法：在 openssl enc 命令中显式添加 `-iter 100000` 并写入索引。

9. 【cipher.salt】
   - 现有字段：无
   - 状态：缺失
   - 分析：未记录盐值。
   - 改法：加密时用 `-p` 参数输出盐值并记录。

10. 【hashes.sha256_encrypted】
    - 现有字段：无
    - 状态：缺失
    - 分析：缺完整性校验。
    - 改法：加密后用 `sha256sum` 计算并写入索引。

11. 【status】 / 【password_alias】
    - 现有字段：无
    - 状态：缺失
    - 分析：无法区分状态、没有密码别名表。
    - 改法：初始化记录 status 为 "local"，并实现 PASSWORDS_FILE 的别名查表。

12. 【created_at】 / 【updated_at】
    - 现有字段：无
    - 状态：缺失
    - 分析：缺少时间戳。
    - 改法：用 `date -Iseconds` 获取 ISO 8601 时间，更新时同步修改 updated_at。

## 二、补充提醒
- P0-4主索引带空格：写入时去掉竖线两边空格（`echo "$enc|$orig|..."`），读取时用 trim() 替代 xargs。
