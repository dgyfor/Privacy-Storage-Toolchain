const { contextBridge, ipcRenderer } = require('electron');

// 只暴露白名单 API，不暴露 ipcRenderer 本身
contextBridge.exposeInMainWorld('pst', {
  testEngine: () => ipcRenderer.invoke('pst:test-engine')
});