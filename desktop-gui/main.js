const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const { spawn, exec } = require('child_process');
const fs = require('fs');

function createWindow() {
  const win = new BrowserWindow({
    width: 1000, height: 750,
    title: "个人隐私文件管理系统",
    autoHideMenuBar: true,
    webPreferences: {
      nodeIntegration: false, contextIsolation: true, sandbox: true,
      preload: path.join(__dirname, 'preload.js')
    }
  });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  win.loadFile('index.html');
}

// 1. 加密
ipcMain.handle('pst:encrypt-file', async (event, args) => {
  const { filePath, password } = args;
  const enginePath = path.join(__dirname, '..', 'termux-encrypt', 'crypto-engine.js');
  const outPath = filePath + '.enc';
  return runNodeCrypto(enginePath, ['encrypt', filePath, outPath], password, outPath, event);
});

// 2. 解密
ipcMain.handle('pst:decrypt-file', async (event, args) => {
  const { filePath, password } = args;
  const enginePath = path.join(__dirname, '..', 'termux-encrypt', 'crypto-engine.js');
  // 默认解密后的文件名：去掉 .enc 后缀
  const outPath = filePath.replace(/\.enc$/, '');
  return runNodeCrypto(enginePath, ['decrypt', filePath, outPath], password, outPath, event);
});

// 3. PAR2 容灾生成（调用根目录的 par2.exe）
ipcMain.handle('pst:create-backup', async (event, args) => {
  const { filePath } = args;
  const par2Path = path.join(__dirname, '..', 'par2.exe');
  
  return new Promise((resolve) => {
    event.sender.send('pst:progress', `[容灾] 正在为 ${path.basename(filePath)} 生成 PAR2 冗余...\n`);
    // -r3 表示生成 3% 的冗余数据
    const child = spawn(par2Path, ['create', '-r3', path.basename(filePath)], { 
        cwd: path.dirname(filePath), windowsHide: true 
    });

    let log = '';
    child.stdout.on('data', d => { log += d.toString(); event.sender.send('pst:progress', d.toString()); });
    child.stderr.on('data', d => { log += d.toString(); event.sender.send('pst:progress', d.toString()); });
    
    child.on('close', (code) => {
      if (code === 0) resolve({ ok: true, output: 'PAR2 冗余生成成功！' });
      else resolve({ ok: false, error: `PAR2 退出码: ${code}` });
    });
  });
});

// 4. PAR2 修复（调用根目录的 par2.exe）
ipcMain.handle('pst:repair-file', async (event, args) => {
  const { par2Path } = args;
  const exePath = path.join(__dirname, '..', 'par2.exe');
  
  return new Promise((resolve) => {
    event.sender.send('pst:progress', `[修复] 正在尝试修复损坏文件...\n`);
    const child = spawn(exePath, ['repair', path.basename(par2Path)], { 
        cwd: path.dirname(par2Path), windowsHide: true 
    });

    child.stdout.on('data', d => event.sender.send('pst:progress', d.toString()));
    child.stderr.on('data', d => event.sender.send('pst:progress', d.toString()));
    
    child.on('close', (code) => {
      if (code === 0) resolve({ ok: true, output: '文件修复成功！' });
      else resolve({ ok: false, error: `修复失败，退出码: ${code}` });
    });
  });
});

// 封装底层的 Node.js 加密引擎调用
function runNodeCrypto(engine, args, password, outPath, event) {
  return new Promise((resolve) => {
    const child = spawn('node', [engine, ...args], { windowsHide: true });
    child.stdout.on('data', (d) => event.sender.send('pst:progress', d.toString()));
    child.stderr.on('data', (d) => event.sender.send('pst:progress', d.toString()));
    child.on('error', (err) => resolve({ ok: false, error: err.message }));
    child.stdin.write(password + '\n');
    child.stdin.end();
    child.on('close', (code) => {
      if (code === 0) resolve({ ok: true, output: outPath });
      else resolve({ ok: false, error: `退出码: ${code}` });
    });
  });
}

app.whenReady().then(createWindow);