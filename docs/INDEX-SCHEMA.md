# 跨环境数据接口契约（INDEX-SCHEMA V8）

**适用场景**：前端映射盘（消费者/渲染） ↔ MT端加密脚本（生产者） ↔ Termux端容灾脚本（备份）

**核心说明**：
- **唯一事实来源**：采用 `index.jsonl` 格式，**每行是一个独立的 JSON 对象**（不要 `records` 数组，不要顶层大括号）。
- **多云盘支持**：一个文件可映射到 0~N 个云盘（通过 `clouds` 数组实现）。
- **向后兼容**：保留 MT 端需要的绝对路径 `encrypted_path`，前端渲染时优先使用 `clouds` 数组。

## 字段定义（每行 JSON）

| 字段名 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | String | 否 | 唯一标识（如 `enc_1757900000_1234`）。前端目前不强制依赖。 |
| `encrypted_name` | String | 是 | 加密后的密文文件名。 |
| `original_name` | String | 是 | 加密前的原始文件名。**（前端本地盘渲染依赖此字段）** |
| `relative_path` | String | 是 | 文件在本地仓库中的相对路径（如 `Project_A/Study_Notes`）。根目录为空字符串。 |
| `encrypted_path` | String | 否 | 密文文件在设备上的绝对路径（供 Termux 容灾脚本使用）。 |
| `clouds` | Array | 是 | 云盘映射数组。若无映射，则为 `[]`。**（前端动态 Tab 渲染依赖此字段）** |
| `clouds[].name` | String | 是 | 云盘名称（如 "测试盘"）。前端据此生成 Tab。 |
| `clouds[].path` | String | 是 | 云盘上的相对路径（如 `/backup`）。 |
| `sizes` | Object | 否 | 大小信息。包含 `encrypted` 和 `original`。 |
| `hashes` | Object | 否 | 哈希信息。如 `{"sha256_encrypted": "..."}`。 |
| `cipher` | String/Object| 否 | 加密算法（如 `AES-256-CBC`）。 |
| `created_at` | String | 是 | ISO 8601 时间戳。 |
| `status` | String | 否 | 记录状态（如 `local`、`uploaded`）。 |

## 示例（注意：这是 JSONL 格式）

````json
{"id":"enc_1757900000_1234","encrypted_name":"enc_1757900000_1234.dat","original_name":"简历.pdf","relative_path":"work","encrypted_path":"/storage/emulated/0/.../enc_1757900000_1234.dat","clouds":[{"name":"测试盘","path":"/backup"},{"name":"光鸭盘","path":"/work"}],"sizes":{"encrypted":123456,"original":123000},"hashes":{"sha256_encrypted":"..."},"cipher":"AES-256-CBC","created_at":"2026-09-16T10:00:00+08:00","status":"local"}
{"id":"enc_1757900000_5678","encrypted_name":"enc_1757900000_5678.dat","original_name":"笔记.txt","relative_path":"docs","encrypted_path":"/storage/emulated/0/.../enc_1757900000_5678.dat","clouds":[],"sizes":{"encrypted":456},"cipher":"AES-256-CBC","created_at":"2026-09-16T10:05:00+08:00","status":"local"}
