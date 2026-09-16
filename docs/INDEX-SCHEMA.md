# 跨环境数据接口契约（INDEX-SCHEMA）

**适用场景**：MT端加密脚本（生产者） → Termux端容灾脚本（消费者）

**说明**：
- 顶层 `schema_version`、`generated_at`、`storage_root` 用于描述全局环境。
- `records` 数组中的每一个对象，代表一个被加密的文件。
- MT端负责生成此文件，Termux端 PAR2 脚本只读取此文件，不读取 GLOBAL_INDEX。
- 优先使用 `encrypted_path`（绝对路径）定位文件，备选 `storage_root + relative_path`。
- 
顶层结构建议
json
{
  "schema_version": 1,
  "generated_at": "2026-09-16T10:00:00+08:00",
  "storage_root": "/storage/emulated/0/Documents/Encrypted_Vault/加密文件",
  "records": [ ... ]
}
storage_root 放顶层，records[].encrypted_path 放绝对路径，两边冗余但安全。

{
  "schema_version": 1,
  "generated_at": "2026-09-16T10:00:00+08:00",
  "storage_root": "/storage/emulated/0/Documents/Encrypted_Vault/加密文件",
  "records": [
    {
      "id": "enc_1757900000_1234",
      "encrypted_name": "enc_1757900000_1234.dat",
      "encrypted_path": "/storage/emulated/0/Documents/Encrypted_Vault/加密文件/Project_A/Study_Notes/enc_1757900000_1234.dat",
      "storage_root": "/storage/emulated/0/Documents/Encrypted_Vault/加密文件",
      "relative_path": "Project_A/Study_Notes",
      "sizes": {
        "encrypted": 123456,
        "original": 123000
      },
      "hashes": {
        "sha256_encrypted": "..."
      },
      "cipher": {
        "name": "aes-256-cbc",
        "kdf": "pbkdf2",
        "iter": 100000
      },
      "created_at": "2026-09-16T10:00:00+08:00",
      "status": "local"
    }
  ]
}
