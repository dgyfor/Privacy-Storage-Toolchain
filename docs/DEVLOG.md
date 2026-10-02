# DEVLOG — 开发日志

按时间倒序记录开发过程。与 CHANGELOG.md 的区别：CHANGELOG 记对外可见的变更，DEVLOG 记过程、坑、决策、未决问题。

---

## 2026-10-02

### 完成

1. **docs/INTERFACE.md / docs/CHANGELOG.md** —— 补上 README 引用但缺失的两个文档，清死链。
2. **mapping-spa/index.html（P2a）** —— 三盘映射器前端首版。纯静态单页，原生 JS 无框架，读 index.jsonl 渲染表格：原文件名 / 加密名 / 相对路径 / 大小 / 创建时间 / SHA-256。隐私设计：`<input type="file">` 手动选文件，不用 fetch，数据不出浏览器。
3. **云盘列 join（P2b，前端路线）** —— index.jsonl 不含云盘字段，前端同时读 GLOBAL_INDEX（encrypted_index.txt），按 encrypted_name 做客户端 join，补齐云盘名称与路径两列。未改动 encrypt_new.sh。

### 技术决策

- **双索引客户端 join，不改主脚本**。备选方案是把云盘字段塞进 index.jsonl，但那样需要动 62837 字节主脚本的核心写入逻辑，牵动 setcloud / cloud / ea 所有读 7 列的地方，风险大收益小。前端 join 零风险，且今天即可验证。
- **不用 fetch 自动加载数据文件**。即使本地 file:// 场景，也坚持手动选文件。理由：避免任何自动读取本地文件的可能，答辩时是可陈述的隐私设计点。

### 发现一个真 Bug（待修，编号 P2c）

**`termux-encrypt/encrypt_new.sh` 第 352 行：index.jsonl 每次 `ea` 被整份覆盖。**

机制：写主索引时先 `cat "$GLOBAL_INDEX" > "$tmp_idx"` 保留历史再追加；写 JSONL 时 `$tmp_json` 没有这一步，直接追加到空文件，最后 `mv` 覆盖。

实证：GLOBAL_INDEX 有 2 条记录（test.txt / map_test.txt），index.jsonl 仅存 1 条（map_test.txt），test.txt 记录已丢失。

修法（下次执行）：在 352 行前插入 `cat "$INDEX_JSON" > "$tmp_json" 2>/dev/null || true`，与 tmp_idx 逻辑对齐。改前先备份脚本，改后真机跑双文件加密验证。

### 环境变更

- Git 2.56.0 安装在 `D:\Program Files\Git`（非默认路径）。
- 把 `D:\Program Files\Git\cmd` 加入用户 PATH。PowerShell 与 Git Bash 现均可直接调用 git。

### 踩坑记录（供后续避雷）

| 现象 | 原因 | 规避 |
|---|---|---|
| PowerShell 报 git 不是命令 | git.exe 不在 PATH | 已修，见上 |
| `cd /d/...` 在 PowerShell 报路径不存在 | 那是 Git Bash 的盘符写法 | 终端命令不混用 |
| 一次粘贴多行命令糊成一行 | 终端粘贴行为 | 一行一行粘，等提示符返回 |
| 终端出现 `^[[200~` 乱码 | bracketed paste mode | 长命令手敲或右键粘贴 |
| 浏览器重选同名文件仍显示旧数据 | file:// 同源策略下的缓存 | 数据文件改名后再选 |
| Termux 中 cat 长行显示被截 | 终端显示宽度，非文件问题 | 用 `wc -l` / `od -c` 核实真字节 |

### 项目状态

- 最新 commit：`000f6ec`
- 主链路：端侧加密 → index.jsonl → PAR2 容灾 → ea 显示原名，闭环
- P2 前端路线：完成
- 新增待办 P2c：修 index.jsonl 覆盖 bug