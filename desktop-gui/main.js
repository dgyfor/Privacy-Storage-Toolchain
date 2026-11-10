const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const { exec } = require('child_process');

function createWindow() {
  const win = new BrowserWindow({
    width: 1000,
    height: 700,
    title: "个人隐私文件管理系统",
    autoHideMenuBar: true,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      preload: path.join(__dirname, 'preload.js')
    }
  });

  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());

  win.loadFile('index.html');
}

// IPC 白名单：只暴露特定操作，不暴露任意命令执行
ipcMain.handle('pst:test-engine', async () => {
  return new Promise((resolve) => {
    exec('echo 底层引擎已启动', { windowsHide: true, timeout: 10000 }, (error, stdout) => {
      if (error) {
        resolve({ ok: false, error: error.message });
        return;
      }
      resolve({ ok: true, output: stdout.trim() });
    });
  });
});

app.whenReady().then(createWindow);
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});