# 设计决策记录

按时间倒序，最新在上。

---

## 2026-10-10

### D-005 云盘数据模型用数组（方案 Y）

一个加密文件可挂 0~N 个云盘，`index.jsonl` 中 `clouds` 为数组：

```json
"clouds": [
  {"name": "阿里盘", "path": "/我的备份/加密区"},
  {"name": "光鸭盘", "path": "/backup/vault"}
]
```

放弃方案 X（一行一云盘）。理由：前端一次读一行拿全，无需按 encrypted_name 聚合。

### D-004 三盘不写死

用户自选云盘，本地 / 阿里 / 光鸭只是默认组合。`setcloud` 接受任意云盘名。

### D-003 对照表加密（P2.5）

`index.jsonl` 从明文落盘改为密文落盘，算法复用 AES-256-CBC + PBKDF2。前端用时解密到内存，不落盘明文。

状态：待实现。

### D-002 简令输入机制

用户自定义"简令 → 真密码"映射，非硬编码。
- 简令由用户设定，源码不含任何简令字面值
- 定位：使用便利 + 轻度防护，**不作为强安全边界**
- 映射表存哪、前端是否支持，待定

状态：待实现。

### D-001 P2 数据源确定

mapping-spa 前端只读 `index.jsonl`，不读 `GLOBAL_INDEX`。
云盘字段必须进 index.jsonl（原方案"前端合并双索引"弃用）。

---

## 待联动

- D-001 / D-005 影响 `encrypt_new.sh`（ea 写空 clouds）、`setcloud`（写 clouds）、`mapping-spa`
- D-003 影响 `encrypt_new.sh`、`setcloud`、`mapping-spa`
- `INDEX-SCHEMA.md` 待更新（新增 clouds 字段）

## 约定

- 编号 D-xxx 只增不改。推翻旧决策时新增一条，注明推翻谁
- 本文件替代口头约定，避免下次对话丢信息