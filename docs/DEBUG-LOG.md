# 真机调试日志与排错记录

## Bug-001：跨环境生成 index.json 静默失败

**发现时间**：2026-09-20 上午（图书馆）
**问题现象**：在 Termux 中运行 `ea` 加密命令，终端明确输出“✅ 索引更新完成”，但去对照表目录中却找不到 `index.json` 文件。
**排查过程**：
1. 初步怀疑是 `mv` 命令跨文件系统失败。因脚本原使用 `mktemp` 在 Termux 内部存储生成临时文件，再 `mv` 到 `/storage/emulated/0/`，安卓底层会静默拦截。
2. 修改代码：将临时文件路径改为 `local tmp_json="$MAPPING_ROOT/.tmp_index.json"`，确保在共享存储中直接生成。
3. 使用 `bash -x encrypt_new.sh` 开启调试模式，打印执行路径。发现脚本在脱敏时已将路径更改为 `/storage/emulated/0/Documents/Encrypted_Vault/...`，并非原本寻找的 `/storage/emulated/0/我的文件/...`。
**最终解决**：
修正脚本加载方式（`source encrypt_new.sh`），确认为跨环境脱敏路径。重新跑加密，成功在 `Encrypted_Vault/对照表/` 下生成 `index.json`。
**经验总结**：
1. 跨环境（MT/Termux）文件移动，应避免使用内部存储的 `mktemp`。
2. 路径脱敏修改后，需要同步更新对应的索引存储目录。排查时应善用 `bash -x` 或 `set -x` 进行断点追踪。
