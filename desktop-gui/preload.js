const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('pst', {
  testEngine: () => ipcRenderer.invoke('pst:test-engine'),

  getFilePath: (file) => webUtils.getPathForFile(file),

  encryptFile: (filePath, password) => ipcRenderer.invoke('pst:encrypt-file', { filePath, password }),
  decryptFile: (filePath, password) => ipcRenderer.invoke('pst:decrypt-file', { filePath, password }),

  createBackup: (filePath) => ipcRenderer.invoke('pst:create-backup', { filePath }),
  repairFile: (par2Path) => ipcRenderer.invoke('pst:repair-file', { par2Path }),

  onProgress(cb) {
    ipcRenderer.on('pst:progress', (_, data) => cb(data));
  },
});