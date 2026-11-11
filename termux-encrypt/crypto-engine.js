#!/usr/bin/env node
// =============================================================================
// Privacy-Storage-Toolchain / termux-encrypt / crypto-engine.js  (v2.2)
// AES-256-GCM (AEAD) + PBKDF2-SHA256(310000) + HKDF domain separation
// 文件格式（44 字节头部 + 密文）：
//   [7B Magic "PSTv2GM"][1B Ver=02][8B Salt][12B Nonce][16B Tag][Ciphertext...]
// 信封模式 wrapped_dek（120 hex = 60 字节）：
//   [12B Nonce][16B Tag][32B 加密后的 DEK]
//
// v2.2 变更（10GB+ 大文件 / 恒定内存）：
//   - 加解密全部流式：fs.createReadStream + createCipheriv/Decipheriv + pipeline
//   - 加密先写 44B 占位头，pipeline 结束后 fs.writeSync 回写 Tag
//   - GCM 失败 / 加密中途失败都会 unlink 半成品
//   - rewrap 口令走 stdin（旧×1、新×2 确认），命令行不再传密码
//   - rewrap 只 readSync 前 44B 头，不碰大文件主体
//   - rewrap 新 .dek 走 tmp+rename 原子替换，允许 dek_in === dek_out
//   - encrypt-envelope 顺序：先写 .dek，再流式加密大文件
// =============================================================================
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { pipeline } = require('stream/promises');

const MAGIC = Buffer.from('PSTv2GM');
const VERSION = Buffer.from([0x02]);
const SALT_LEN = 8;
const NONCE_LEN = 12;
const TAG_LEN = 16;
const HEADER_LEN = MAGIC.length + VERSION.length + SALT_LEN + NONCE_LEN + TAG_LEN; // 44
const TAG_OFFSET = MAGIC.length + VERSION.length + SALT_LEN + NONCE_LEN;            // 28
const DEK_LEN = 32;
const WRAPPED_DEK_LEN = NONCE_LEN + TAG_LEN + DEK_LEN; // 60

const KDF_ITER = (() => {
  const v = parseInt(process.env.PST_KDF_ITER || '310000', 10);
  if (!Number.isFinite(v) || v < 100000) {
    process.stderr.write('[crypto-engine] 错误: PST_KDF_ITER 必须 >= 100000\n');
    process.exit(1);
  }
  return v;
})();

const DOMAIN_DEFAULT = 'PST';
const DOMAIN_INDEX = 'PST-INDEX';
const DOMAIN_ENVELOPE = 'PST-ENVELOPE';

// ---------- 通用工具 ----------
function die(msg) {
  process.stderr.write(`[crypto-engine] 错误: ${msg}\n`);
  process.exit(1);
}
function info(msg) {
  process.stderr.write(`[crypto-engine] ${msg}\n`);
}
function safeUnlink(p) {
  try { fs.unlinkSync(p); } catch (_) { /* 忽略 */ }
}

// 原子写：同目录 tmp → renameSync，避免断点毁文件
function atomicWriteFileSync(filePath, data, options = {}) {
  const tmp = `${filePath}.tmp.${process.pid}.${Date.now()}.${crypto.randomBytes(4).toString('hex')}`;
  try {
    fs.writeFileSync(tmp, data, options);
    fs.renameSync(tmp, filePath);
  } catch (err) {
    safeUnlink(tmp);
    throw err;
  }
}

// 只读取前 44 字节头，绝不碰大文件主体
function readHeaderOnly(filePath) {
  const buf = Buffer.alloc(HEADER_LEN);
  const fd = fs.openSync(filePath, 'r');
  let n;
  try {
    n = fs.readSync(fd, buf, 0, HEADER_LEN, 0);
  } finally {
    fs.closeSync(fd);
  }
  if (n < HEADER_LEN) die('文件过短，不是有效密文');
  return parseHeader(buf);
}

// 拒绝 in === out（流式处理无内存兜底，必须提前拦截）
function assertDistinctPaths(a, b, msg) {
  if (path.resolve(a) === path.resolve(b)) {
    die(msg || '输入文件和输出文件不能是同一路径');
  }
}

// ---------- 密码学原语 ----------
function deriveKey(passphrase, salt, domain) {
  const masterKey = crypto.pbkdf2Sync(passphrase, salt, KDF_ITER, 32, 'sha256');
  const derived = crypto.hkdfSync(
    'sha256', masterKey, Buffer.alloc(0), Buffer.from(domain, 'utf8'), 32
  );
  return Buffer.from(derived);
}

function encryptWithKey(plainBuf, key, nonce) {
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  const ct = Buffer.concat([cipher.update(plainBuf), cipher.final()]);
  const tag = cipher.getAuthTag();
  return { ciphertext: ct, tag };
}

function decryptWithKey(ctBuf, key, nonce, tag) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ctBuf), decipher.final()]);
}

function parseHeader(buf) {
  if (buf.length < HEADER_LEN) die('文件过短，不是有效密文');
  if (!buf.subarray(0, 7).equals(MAGIC)) die('Magic 不匹配，不是 PSTv2GM 文件');
  if (buf[7] !== 0x02) die(`不支持的版本: 0x${buf[7].toString(16)}`);
  return {
    salt: buf.subarray(8, 16),
    nonce: buf.subarray(16, 28),
    tag: buf.subarray(28, 44),
    ciphertext: buf.subarray(44),
  };
}

// 构造前 28 字节头（magic+version+salt+nonce），Tag 留白后回写
function buildPreHeader(salt, nonce) {
  return Buffer.concat([MAGIC, VERSION, salt, nonce]);
}

// 精准回写 Tag 到文件头 offset=28
function writeTagBack(filePath, tag) {
  if (tag.length !== TAG_LEN) throw new Error('Tag 长度异常');
  const fd = fs.openSync(filePath, 'r+');
  try {
    fs.writeSync(fd, tag, 0, TAG_LEN, TAG_OFFSET);
  } finally {
    fs.closeSync(fd);
  }
}

// ---------- 流式加密 / 解密核心 ----------
async function streamEncryptFile(infile, outfile, key, salt, nonce) {
  if (salt.length !== SALT_LEN) throw new Error('Salt 长度异常');
  if (nonce.length !== NONCE_LEN) throw new Error('Nonce 长度异常');

  // 1. 先写 44 字节占位头（28 字节 pre-header + 16 字节 tag 占位）
  const preHeader = buildPreHeader(salt, nonce);
  const tagPlaceholder = Buffer.alloc(TAG_LEN);
  try {
    fs.writeFileSync(outfile, Buffer.concat([preHeader, tagPlaceholder]));
  } catch (err) {
    safeUnlink(outfile);
    throw err;
  }

  // 2. 流式加密主体：从 offset 44 开始写
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  const rs = fs.createReadStream(infile);
  const ws = fs.createWriteStream(outfile, { flags: 'r+', start: HEADER_LEN });

  try {
    await pipeline(rs, cipher, ws);
  } catch (err) {
    safeUnlink(outfile);
    throw err;
  }

  // 3. 回写 Tag（此时 cipher.final() 已由 pipeline 内部触发）
  const tag = cipher.getAuthTag();
  try {
    writeTagBack(outfile, tag);
  } catch (err) {
    safeUnlink(outfile);
    throw err;
  }
}

async function streamDecryptFile(infile, outfile, key, nonce, tag, domain) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
  decipher.setAuthTag(tag);

  const rs = fs.createReadStream(infile, { start: HEADER_LEN });
  const ws = fs.createWriteStream(outfile);

  try {
    // pipeline 内部 await 完成 = 流正常结束 + GCM Tag 验证通过
    // GCM 失败时 decipher 抛 error，pipeline 会 reject 并销毁流
    await pipeline(rs, decipher, ws);
  } catch (err) {
    safeUnlink(outfile);
    const msg = err && err.message ? err.message : String(err);
    if (/authenticate|bad decrypt|Unsupported state/i.test(msg)) {
      die(`完整性校验失败（domain=${domain}）：文件可能被篡改、口令错误，或用错了命令`);
    }
    die(msg);
  }
}

// ---------- 命令实现 ----------
async function cmdEncrypt(infile, outfile, domain) {
  if (!fs.existsSync(infile)) die(`输入文件不存在: ${infile}`);
  assertDistinctPaths(infile, outfile, '输入文件和输出文件不能是同一路径（流式加密无内存兜底）');

  const pass = await readPassphrase();
  const salt = crypto.randomBytes(SALT_LEN);
  const nonce = crypto.randomBytes(NONCE_LEN);
  const key = deriveKey(pass, salt, domain);

  try {
    await streamEncryptFile(infile, outfile, key, salt, nonce);
  } catch (err) {
    die(err && err.message ? err.message : String(err));
  }

  const size = fs.statSync(outfile).size;
  info(`加密完成: ${outfile} (${size} bytes)`);
}

async function cmdDecrypt(infile, outfile, domain) {
  if (!fs.existsSync(infile)) die(`密文文件不存在: ${infile}`);
  assertDistinctPaths(infile, outfile, '密文输入和明文输出不能是同一路径');

  const pass = await readPassphrase();
  const { salt, nonce, tag } = readHeaderOnly(infile);
  const key = deriveKey(pass, salt, domain);

  await streamDecryptFile(infile, outfile, key, nonce, tag, domain);
  info(`解密完成并通过完整性校验: ${outfile}`);
}

async function cmdEncryptEnvelope(infile, outfile, dekOutfile) {
  if (!fs.existsSync(infile)) die(`输入文件不存在: ${infile}`);
  assertDistinctPaths(infile, outfile, '输入文件和加密输出不能是同一路径');
  assertDistinctPaths(infile, dekOutfile, '输入文件不能被 DEK 输出覆盖');

  const pass = await readPassphrase();

  // 第一步：随机 DEK + 用 KEK 包裹 DEK（快速、最容易出错的部分先做）
  const dek = crypto.randomBytes(DEK_LEN);
  const salt = crypto.randomBytes(SALT_LEN);
  const kek = deriveKey(pass, salt, DOMAIN_ENVELOPE);
  const dekNonce = crypto.randomBytes(NONCE_LEN);
  const { ciphertext: dekCt, tag: dekTag } = encryptWithKey(dek, kek, dekNonce);
  const wrapped = Buffer.concat([dekNonce, dekTag, dekCt]);

  try {
    atomicWriteFileSync(dekOutfile, wrapped.toString('hex'), { mode: 0o600 });
  } catch (err) {
    die(`写入 DEK 包裹文件失败: ${err.message}`);
  }

  // 第二步：用 DEK 流式加密大文件；失败则连 .dek 一起清理
  const nonce = crypto.randomBytes(NONCE_LEN);
  try {
    await streamEncryptFile(infile, outfile, dek, salt, nonce);
  } catch (err) {
    safeUnlink(dekOutfile);
    die(`加密大文件失败: ${err && err.message ? err.message : String(err)}`);
  }

  const size = fs.statSync(outfile).size;
  info(`信封加密完成: 文件=${outfile} (${size} bytes), 包裹DEK=${dekOutfile}`);
}

async function cmdDecryptEnvelope(infile, outfile, dekInfile) {
  if (!fs.existsSync(infile)) die('密文文件不存在');
  if (!fs.existsSync(dekInfile)) die('包裹的 DEK 文件不存在');
  assertDistinctPaths(infile, outfile, '密文输入和明文输出不能是同一路径');

  const pass = await readPassphrase();
  const { salt, nonce, tag } = readHeaderOnly(infile);

  // 先解包 DEK（失败时还没开始流式解密，无半成品问题）
  const wrappedHex = fs.readFileSync(dekInfile, 'utf8').trim();
  if (!/^[0-9a-fA-F]+$/.test(wrappedHex) || wrappedHex.length !== WRAPPED_DEK_LEN * 2) {
    die('包裹DEK格式异常');
  }
  const wrapped = Buffer.from(wrappedHex, 'hex');
  const dekNonce = wrapped.subarray(0, NONCE_LEN);
  const dekTag = wrapped.subarray(NONCE_LEN, NONCE_LEN + TAG_LEN);
  const dekCt = wrapped.subarray(NONCE_LEN + TAG_LEN);

  const kek = deriveKey(pass, salt, DOMAIN_ENVELOPE);
  let dek;
  try {
    dek = decryptWithKey(dekCt, kek, dekNonce, dekTag);
  } catch (_) {
    die('包裹的 DEK 被篡改或口令错误');
  }
  if (dek.length !== DEK_LEN) die('DEK 长度异常');

  // 主体流式解密，GCM Tag 兜底校验
  await streamDecryptFile(infile, outfile, dek, nonce, tag, DOMAIN_ENVELOPE);
  info(`信封解密完成: ${outfile}`);
}

async function cmdRewrap(infile, dekInfile, dekOutfile) {
  if (!fs.existsSync(infile)) die('密文文件不存在');
  if (!fs.existsSync(dekInfile)) die('包裹的旧 DEK 文件不存在');
  assertDistinctPaths(infile, dekOutfile, '数据文件不能被 DEK 输出覆盖');

  // 只读前 44 字节头，绝不碰大文件主体
  const { salt } = readHeaderOnly(infile);

  // 读取旧 DEK 包裹
  const wrappedHex = fs.readFileSync(dekInfile, 'utf8').trim();
  if (!/^[0-9a-fA-F]+$/.test(wrappedHex) || wrappedHex.length !== WRAPPED_DEK_LEN * 2) {
    die('原包裹DEK格式异常');
  }
  const wrapped = Buffer.from(wrappedHex, 'hex');
  const dekNonce = wrapped.subarray(0, NONCE_LEN);
  const dekTag = wrapped.subarray(NONCE_LEN, NONCE_LEN + TAG_LEN);
  const dekCt = wrapped.subarray(NONCE_LEN + TAG_LEN);

  // 旧口令（1 次）
  const oldPass = await readPassphrase('旧主口令: ');
  if (oldPass.length === 0) die('旧口令不能为空');

  const oldKek = deriveKey(oldPass, salt, DOMAIN_ENVELOPE);
  let dek;
  try {
    dek = decryptWithKey(dekCt, oldKek, dekNonce, dekTag);
  } catch (_) {
    die('旧密码错误，无法解锁原 DEK');
  }
  if (dek.length !== DEK_LEN) die('DEK 长度异常');

  // 新口令（2 次：输入 + 确认）
  const newPass = await readPassphrase('新主口令: ');
  if (newPass.length === 0) die('新口令不能为空');
  const newPassConfirm = await readPassphrase('确认新主口令: ');
  if (newPass !== newPassConfirm) die('两次输入的新口令不一致');

  // 重新包裹 DEK
  const newKek = deriveKey(newPass, salt, DOMAIN_ENVELOPE);
  const newDekNonce = crypto.randomBytes(NONCE_LEN);
  const { ciphertext: newDekCt, tag: newDekTag } = encryptWithKey(dek, newKek, newDekNonce);
  const newWrapped = Buffer.concat([newDekNonce, newDekTag, newDekCt]);

  // 原子替换（允许 dek_in === dek_out）
  try {
    atomicWriteFileSync(dekOutfile, newWrapped.toString('hex'), { mode: 0o600 });
  } catch (err) {
    die(`写入新包裹 DEK 失败: ${err.message}`);
  }

  info(`密钥重包裹成功，原数据文件未做任何修改: ${dekOutfile}`);
}

// ---------- 口令输入 ----------
// 非 TTY：逐行读 stdin，支持多次调用（rewrap 需 3 行）
const stdinLineState = {
  init: false,
  leftover: '',
  lines: [],
  pending: [],
  ended: false,
  error: null,
};

function initStdinLineReader() {
  if (stdinLineState.init) return;
  stdinLineState.init = true;
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    stdinLineState.leftover += chunk;
    let idx;
    while ((idx = stdinLineState.leftover.indexOf('\n')) !== -1) {
      let line = stdinLineState.leftover.slice(0, idx);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      stdinLineState.leftover = stdinLineState.leftover.slice(idx + 1);
      deliverStdinLine(line);
    }
  });
  process.stdin.on('end', () => {
    if (stdinLineState.leftover.length > 0) {
      let line = stdinLineState.leftover;
      if (line.endsWith('\r')) line = line.slice(0, -1);
      stdinLineState.leftover = '';
      deliverStdinLine(line);
    }
    stdinLineState.ended = true;
    drainStdinPending();
  });
  process.stdin.on('error', (err) => {
    stdinLineState.error = err;
    stdinLineState.ended = true;
    drainStdinPending();
  });
  process.stdin.resume();
}

function deliverStdinLine(line) {
  if (stdinLineState.pending.length > 0) {
    const p = stdinLineState.pending.shift();
    p.resolve(line);
  } else {
    stdinLineState.lines.push(line);
  }
}

function drainStdinPending() {
  while (stdinLineState.pending.length > 0) {
    const p = stdinLineState.pending.shift();
    if (stdinLineState.error) p.reject(stdinLineState.error);
    else p.reject(new Error('stdin 已关闭，无法读取口令'));
  }
}

function readLineNonTTY() {
  initStdinLineReader();
  return new Promise((resolve, reject) => {
    if (stdinLineState.lines.length > 0) {
      return resolve(stdinLineState.lines.shift());
    }
    if (stdinLineState.ended) {
      if (stdinLineState.error) return reject(stdinLineState.error);
      return reject(new Error('stdin 已关闭，无法读取口令'));
    }
    stdinLineState.pending.push({ resolve, reject });
  });
}

function readPassphrase(prompt = '主口令: ') {
  return new Promise((resolve, reject) => {
    if (process.stdin.isTTY) {
      process.stderr.write(prompt);
      const stdin = process.stdin;
      stdin.setRawMode(true);
      stdin.resume();
      stdin.setEncoding('utf8');
      let pass = '';
      let done = false;
      const onData = (chunk) => {
        if (done) return;
        for (const c of chunk) {
          if (c === '\r' || c === '\n') {
            done = true;
            stdin.removeListener('data', onData);
            process.stderr.write('\n');
            if (pass.length === 0) return reject(new Error('口令为空'));
            return resolve(pass);
          } else if (c === '\u0003') {
            process.exit(1);
          } else if (c === '\u007f' || c === '\b') {
            pass = pass.slice(0, -1);
          } else {
            pass += c;
          }
        }
      };
      stdin.on('data', onData);
    } else {
      readLineNonTTY().then((line) => {
        if (line.length === 0) return reject(new Error('口令为空'));
        resolve(line);
      }, reject);
    }
  });
}

// 进程退出时恢复终端原始模式（防止 TTY 卡在无回显状态）
process.on('exit', () => {
  try {
    if (process.stdin.isTTY) process.stdin.setRawMode(false);
  } catch (_) { /* 忽略 */ }
});

// ---------- 入口 ----------
function printUsage() {
  process.stderr.write(
    `用法: ${process.argv[1]} <mode> <args...>\n` +
    `  encrypt          <in_file> <out_file>\n` +
    `  decrypt          <in_file> <out_file>\n` +
    `  encrypt-index    <in_file> <out_file>\n` +
    `  decrypt-index    <in_file> <out_file>\n` +
    `  encrypt-envelope <in_file> <out_file> <dek_out>\n` +
    `  decrypt-envelope <in_file> <out_file> <dek_in>\n` +
    `  rewrap           <in_file> <dek_in> <dek_out>\n` +
    `      口令从 stdin 读取（旧 1 次 + 新 2 次确认）；允许 dek_in === dek_out\n`
  );
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    printUsage();
    process.exit(2);
  }

  // rewrap 专用防呆：3 个位置参数非空（口令走 stdin，不在命令行）
  if (args[0] === 'rewrap') {
    if (!args[1] || !args[2] || !args[3]) {
      die('用法: rewrap <in_file> <dek_in> <dek_out>（口令从 stdin 读取：旧 1 次 + 新 2 次）');
    }
  } else if (args[0] === 'encrypt-envelope' || args[0] === 'decrypt-envelope') {
    if (!args[1] || !args[2] || !args[3]) {
      printUsage();
      process.exit(2);
    }
  } else {
    if (!args[1] || !args[2]) {
      printUsage();
      process.exit(2);
    }
  }

  try {
    switch (args[0]) {
      case 'encrypt':          await cmdEncrypt(args[1], args[2], DOMAIN_DEFAULT); break;
      case 'decrypt':          await cmdDecrypt(args[1], args[2], DOMAIN_DEFAULT); break;
      case 'encrypt-index':    await cmdEncrypt(args[1], args[2], DOMAIN_INDEX); break;
      case 'decrypt-index':    await cmdDecrypt(args[1], args[2], DOMAIN_INDEX); break;
      case 'encrypt-envelope': await cmdEncryptEnvelope(args[1], args[2], args[3]); break;
      case 'decrypt-envelope': await cmdDecryptEnvelope(args[1], args[2], args[3]); break;
      case 'rewrap':           await cmdRewrap(args[1], args[2], args[3]); break;
      default: die(`未知模式: ${args[0]}`);
    }
  } catch (e) {
    die(e && e.message ? e.message : String(e));
  }
}

main();