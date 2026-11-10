### 威胁 5：Electron 渲染进程权限过大 (RCE风险)
*   **修复机制**：关闭 nodeIntegration，开启 sandbox，使用 preload 白名单 IPC。
*   **截图 5.1**：`screenshots/T5_electron_sandbox_verify.png` (左侧调用成功，右侧 require 为 undefined，window.pst 仅含 testEngine)