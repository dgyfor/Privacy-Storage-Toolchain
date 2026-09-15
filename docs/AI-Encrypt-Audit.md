本报告由AI协同开发工具针对Termux加密脚本（v1.0）生成，用于评估接口标准化与真机安全风险。

以下为**脱敏重生成版**。  
所有路径统一写成 `/storage/emulated/0/Documents/...`，真实目录名统一用 `Project_A`、`Study_Notes`、`Chapter_01` 这类通用词替代。不再出现原始真实路径、真实文件夹名或云盘名。

---

# Privacy-Storage-Toolchain 重构评估（脱敏版）

先说明：你提到 `/docs/INTERFACE.md`，但本次没有贴出该文件内容，所以我无法逐字段对照。下面按“接口要求机器可读 `index.json`、字段稳定、可扩展、可原子更新、退出码统一”的通用标准评估。等你贴出 `INTERFACE.md`，我可以再做逐字段映射表。

## 一、现有输出是否符合接口标准

### 1. 现状：有状态文件，但没有接口级 `index.json`

当前脚本主要依赖多份文本状态：

| 文件 | 格式 | 用途 | 接口问题 |
|---|---|---|---|
| 全局索引 | `enc \| orig \| rel \| cloud \| path \| size` | 主索引 | 不是 JSON；用 `|` 分隔，文件名含 `|` 会错位 |
| 本地缓存 | `enc\|fullpath` | 本地文件存在性 | 内部缓存，不应作为接口输出 |
| 加密对照表 | `enc = orig` | 对照关系 | 与主索引重复，容易不一致 |
| 大小缓存 | `enc\|size` | 大小加速 | 单文件/批量写入格式不统一 |
| 分组索引 | 按首字母分文件 | 加速判断已加密 | 可重建，但主索引一坏就全坏 |
| 映射文件 | 人类可读文本 | 云盘映射 | 不是 JSON，接口无法消费 |

如果 `/docs/INTERFACE.md` 要求 `index.json`，那么当前脚本**没有任何 JSON 输出**，这是最大不符合项。

### 2. 建议：`index.json` 作为唯一真相

脱敏后的建议路径：

```bash
INDEX_JSON="/storage/emulated/0/Documents/Project_A/Mapping/index.json"
INDEX_LOCK="/storage/emulated/0/Documents/Project_A/Mapping/.index.lock"
GLOBAL_INDEX="/storage/emulated/0/Documents/Project_A/Mapping/index.txt"
```

`index.json` 最小 schema 建议：

```json
{
  "schema_version": 1,
  "generated_at": "2026-09-15T12:00:00+08:00",
  "records": [
    {
      "id": "enc_1757900000_1234",
      "encrypted_name": "enc_1757900000_1234.dat",
      "original_name": "note 01.pdf",
      "relative_path": "Study_Notes/Chapter_01",
      "sizes": {
        "encrypted": 123456,
        "original": 123000
      },
      "cipher": {
        "name": "aes-256-cbc",
        "kdf": "pbkdf2",
        "iter": 100000,
        "salt": "base64..."
      },
      "hashes": {
        "sha256_encrypted": "..."
      },
      "remote": {
        "provider": "Provider_A",
        "path": "/EncryptedRepo/Study_Notes/Chapter_01"
      },
      "status": "local",
      "password_alias": "1",
      "created_at": "2026-09-15T12:00:00+08:00",
      "updated_at": "2026-09-15T12:00:00+08:00"
    }
  ]
}
```

现有字段映射：

| 现有字段 | JSON 字段 |
|---|---|
| 第 1 列加密 basename | `id` / `encrypted_name` |
| 第 2 列原始文件名 | `original_name` |
| 第 3 列相对路径 | `relative_path` |
| 第 4 列云盘名 | `remote.provider` |
| 第 5 列云盘路径 | `remote.path` |
| 第 6 列加密大小 | `sizes.encrypted` |
| 缺少 | `original_size`、`cipher`、`kdf`、`iter`、`salt`、`hash`、`created_at`、`status`、`password_alias` |

### 3. P0 级问题与改法

#### P0-1：批量加密写索引第一列是完整路径，不是 basename

`_encrypt_file_batch()` 当前返回类似：

```bash
echo "${enc_name%.dat}|$(basename "$file")|$rel_path|$dat_size"
```

`${enc_name%.dat}` 是完整路径，例如：

```text
/storage/emulated/0/Documents/Project_A/EncryptedRepo/Study_Notes/enc_xxx
```

但缓存里用的是 basename：

```bash
local enc=$(basename "$f" .dat)
echo "$enc|$f" >> "$CACHE_FILE"
```

于是 `_get_local_path()` 用 `grep "^${enc}|"` 找不到批量加密的文件。

**改法：**

```bash
echo "$(basename "${enc_name%.dat}")|$(basename "$file")|$rel_path|$dat_size"
```

同时大小缓存、对照表都统一写 basename。

#### P0-2：`${var// /}` 删除所有空格，破坏 Android 路径

脚本里大量出现：

```bash
enc="${enc// /}"
orig="${orig// /}"
path="${path// /}"
```

这会删除所有空格，不是 trim。Android 路径中某些目录段可能带空格，文件名也可能带空格。删除后目录无法匹配，`lk`、`genmap`、`setcloud` 都可能错。

**改法：** 只 trim 首尾。

```bash
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
```

把：

```bash
path="${path// /}"
```

改成：

```bash
path="$(trim "$path")"
```

#### P0-3：用 `|` 作为字段分隔符不安全

Linux/Android 文件名可以包含 `|`，甚至可以包含换行。当前主索引、缓存、批量 record 都用 `|` 分隔。只要文件名含 `|`，字段就错位。

**改法：** 接口层统一用 JSON，内部遍历用 `find -print0` + `read -r -d ''`，不要手拼 `|` 索引。

#### P0-4：主索引写入带前后空格，读取时又到处 trim

当前写入：

```bash
echo "$enc_base | $orig_name | $rel_path |  |  | 0" >> "$GLOBAL_INDEX"
```

读取时又用 `xargs` 或删空格，容易破坏路径。

**改法：** 写入不要加美观空格：

```bash
echo "$enc_base|$orig_name|$rel_path|||0" >> "$GLOBAL_INDEX"
```

读取时用 `trim`，不要用 `xargs`。

#### P0-5：`openssl -k` 暴露密码到进程参数

当前类似：

```bash
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$file" -out "$enc_name" -k "$pass"
```

**改法：**

```bash
printf '%s' "$pass" | openssl enc -aes-256-cbc -pbkdf2 -salt -iter 100000 \
  -in "$file" -out "$enc_name" -pass stdin
```

并显式写 `-iter 100000`，记录到 `index.json`，保证可复现。

#### P0-6：没有锁，后台 `rebuild_idx &` 会制造竞态

批量加密最后同步 `rebuild_idx`，单文件加密又后台 `rebuild_idx &`。主流程还可能写主索引，会出现读一半、辅助索引落后、并发写坏索引。

**改法：** 所有索引写入走统一函数，加锁：

```bash
exec 9>"$INDEX_LOCK"
flock -x 9
# 读-改-写
mv tmp "$INDEX_JSON"
```

如果 Termux 没有 `flock`，用 `mkdir "$INDEX_LOCK.d"` 自旋锁。

### 4. 接口输出建议

保留人类可读输出，增加机器可读模式：

```bash
pst index rebuild --json
pst info enc_xxx --json
pst browse --json
```

人类提示走 `stderr`，JSON 走 `stdout`。退出码建议统一：

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 通用错误 |
| 2 | 参数错误 |
| 3 | 密码错误 |
| 4 | 空间不足 |
| 5 | 目标已存在 |
| 6 | 部分失败 |

---

## 二、模块划分：抽库 + 入口兼容，不建议推倒重写

建议目录结构：

```text
privacy-storage-toolchain/
├── bin/
│   └── pst
├── lib/
│   ├── common.sh
│   ├── index.sh
│   ├── crypto.sh
│   ├── browse.sh
│   ├── remote.sh
│   └── maintenance.sh
├── compat/
│   └── aliases.sh
└── docs/
    └── INTERFACE.md
```

职责：

- `lib/common.sh`：配置、`trim`、`human_size`、日志、退出码、锁。
- `lib/index.sh`：`index.json` 读写、兼容导出 `GLOBAL_INDEX`、缓存、`rebuild_idx`。
- `lib/crypto.sh`：`openssl` 封装、加密、解密、空间检查、密码别名。
- `lib/browse.sh`：`lk`、`search`、`cloud`、`info`、`stats`。
- `lib/remote.sh`：`setcloud`、`uploaded`、`genmap`。
- `lib/maintenance.sh`：`org`、`doctor`、`dup`、`refresh`。
- `compat/aliases.sh`：旧命令别名。

主入口 `pst`：

```bash
pst encrypt [目录]
pst decrypt [文件]
pst decrypt-all
pst index rebuild
pst index query <关键词>
pst browse [关键词]
pst remote set
pst remote list
pst map gen [目录]
pst map gen-all
pst org
pst doctor
```

兼容旧习惯：

```bash
ea()  { pst encrypt "$@"; }
da()  { pst decrypt "$@"; }
db()  { pst decrypt-all "$@"; }
lk()  { pst browse "$@"; }
genmap(){ pst map gen "$@"; }
gen() { pst map gen-all "$@"; }
```

数据流建议：

```text
加密：
  文件 -> crypto 加密 -> record -> index.sh 原子追加 index.json -> 导出 GLOBAL_INDEX -> 重建 cache

解密：
  index.json 查询 -> crypto 解密 -> 目标目录

浏览/搜索：
  只读 index.json；cache 只做本地存在性加速，可随时重建

云盘映射：
  index.json 查询 -> 生成 mapping.json / mapping.txt
```

当前有 5 份状态：主索引、本地缓存、大小缓存、对照表、分组索引。建议：

- `index.json`：唯一真相；
- `GLOBAL_INDEX`：兼容导出，可重建；
- `.enc_cache`：本地缓存，可重建；
- `.idx_groups`：性能辅助，可重建；
- `加密对照表.txt`：导出文件，不再作为写入口。

---

## 三、真机排错点注释（可直接放脚本顶部）

```bash
# ============================================================
#  Termux / Android 真机排错注释（脱敏版）
# ============================================================
# 1. 路径空格：
#    Android 路径段可能含空格，例如 /storage/emulated/0/Documents/Project_A/Study_Notes/。
#    所有路径变量必须双引号："$ENCRYPT_ROOT"、"$rel_path"。
#    禁止使用 ${var// /} 删除所有空格；只允许 trim 首尾。
#
# 2. 文件名特殊字符：
#    Android/Linux 文件名允许空格、|、换行。不要用 | 作为字段分隔符。
#    接口层统一用 JSON；内部遍历用 find -print0 + read -r -d ''。
#
# 3. find 全盘扫描：
#    find /storage/emulated/0 很慢，且可能遇到权限拒绝和媒体扫描延迟。
#    缓存 _build_cache 应只扫 $ENCRYPT_ROOT；org 才做全盘整理。
#
# 4. 批量 IO 阻塞：
#    不要在 for 循环里反复 grep/awk 整个 GLOBAL_INDEX。
#    先一次性载入内存或生成临时映射，再处理文件。
#    进度输出到 stderr，避免污染 stdout JSON。
#
# 5. openssl：
#    -k 会把密码暴露到 ps；改用 -pass stdin 或 -pass file:。
#    显式指定 -iter 100000，并记录到 index.json。
#    AES-CBC 无认证；若接口要求完整性，应换 AES-GCM 或 encrypt-then-MAC。
#
# 6. 批量索引事务：
#    批量加密最后才写索引，中途失败会产生无索引 .dat。
#    应先写临时日志，全部成功后原子合并；失败文件要回滚或标记。
#    禁止后台 rebuild_idx & 与主流程并发；索引用 flock 或 mkdir 锁。
#
# 7. 当前 P0 bug：
#    _encrypt_file_batch 返回 ${enc_name%.dat} 是完整路径，
#    但 .enc_cache 存的是 basename，导致 _get_local_path 找不到。
#    必须改成 basename "${enc_name%.dat}"。
#
# 8. 数组与空格：
#    不要 arr=($(printf '%s\n' ... | sort))，目录名含空格会被拆开。
#    用 mapfile -t arr < <(printf '%s\n' ... | sort)。
#
# 9. df 兼容性：
#    df -B1 在部分 Termux 环境不稳定；优先 df -Pk 并解析。
#
# 10. 中文/多字节：
#    ${var:0:1} 对中文按字节取，首字母分组会进 OTHER，可接受但要注释。
#
# 11. 权限：
#    先 termux-setup-storage；/storage/emulated/0 下文件可能被媒体扫描延迟。
#
# 12. 密码别名：
#    PASSWORDS_FILE 目前 touch 了但没使用，get_password 直接 echo 输入。
#    若接口要求“数字=代号”，必须实现别名查表，并 chmod 600。
# ============================================================
```

---

## 四、重构结论

不需要推倒重写。建议路线：

1. **先修 P0 bug，不改变交互**
   - `_encrypt_file_batch` 返回 basename；
   - 大小缓存、对照表统一 basename；
   - 移除所有 `${var// /}`，改 `trim`；
   - 主索引写入去掉美观空格；
   - `openssl` 改 `-pass stdin` + 显式 `-iter`；
   - 索引写入加锁，去掉后台 `rebuild_idx &`。

2. **新增 `index.json` 适配层**
   - `index.json` 是唯一真相；
   - `GLOBAL_INDEX` 只做兼容导出；
   - 查询逐步改为读 `index.json`；
   - 提供 `--json` 输出和统一退出码。

3. **抽库，不拆散**
   - 先抽 `lib/common.sh`、`lib/index.sh`、`lib/crypto.sh`；
   - 旧命令 `ea/da/db/lk` 保留为别名；
   - 新入口 `pst` 子命令。

4. **性能优化**
   - `lk` 的目录统计当前是 O(n*m)，大索引会卡；
   - 建议一次性 awk 生成目录树，或缓存目录统计；
   - 避免每文件 `stat`、每目录重扫全索引。

如果你把 `/docs/INTERFACE.md` 内容贴出来，我可以继续给你做一张逐字段对照表：  
`INTERFACE.md 要求字段 -> 现有代码字段 -> 缺失/不符 -> 具体 Bash/jq 改法`。
