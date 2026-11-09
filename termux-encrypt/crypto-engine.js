#!/usr/bin/env node
// =============================================================================
// Privacy-Storage-Toolchain / termux-encrypt / crypto-engine.js  (v2.0)
// AES-256-GCM (AEAD) + PBKDF2-SHA256(310000) + HKDF domain separation
// 文件格式（44 字节头部 + 密文）：
//   [7B Magic "PSTv2GM"][1B Ver=02][8B Salt][12B Nonce][16B Tag][Ciphertext...]
// 信封模式 wrapped_dek（120 hex = 60 字节）：
//   [12B Nonce][16B Tag][32B 加密后的 DEK]
// =============================================================================
const crypto = require('crypto');
const fs = require('fs');

const MAGIC = Buffer.from('PSTv2GM');
const VERSION = Buffer.from([0x02]);
const SALT_LEN = 8;
const NONCE_LEN = 12;
const TAG_LEN = 16;
const HEADER_LEN = MAGIC.length + VERSION.length + SALT_LEN + NONCE_LEN + TAG_LEN; // 44
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

function die(msg) {
  process.stderr.write(`[crypto-engine] 错误: ${msg}\n`);
  process.exit(1);
}
function info(msg) {
  process.stderr.write(`[crypto-engine] ${msg}\n`);
}

// PBKDF2 派生主密钥，再用 HKDF 按 domain 分离子密钥。
// 好处：PBKDF2 只算一次（贵），HKDF 几乎免费，且加密/索引/信封三种用途得到独立密钥。
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

function buildHeader(salt, nonce, tag) {
  return Buffer.concat([MAGIC, VERSION, salt, nonce, tag]);
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

async function cmdEncrypt(infile, outfile, domain) {
  if (!fs.existsSync(infile)) die(`输入文件不存在: ${infile}`);
  const pass = await readPassphrase();
  const salt = crypto.randomBytes(SALT_LEN);
  const nonce = crypto.randomBytes(NONCE_LEN);
  const key = deriveKey(pass, salt, domain);
  const plain = fs.readFileSync(infile);
  const { ciphertext, tag } = encryptWithKey(plain, key, nonce);
  const header = buildHeader(salt, nonce, tag);
  fs.writeFileSync(outfile, Buffer.concat([header, ciphertext]));
  info(`加密完成: ${outfile} (${header.length + ciphertext.length} bytes)`);
}

async function cmdDecrypt(infile, outfile, domain) {
  if (!fs.existsSync(infile)) die(`密文文件不存在: ${infile}`);
  const pass = await readPassphrase();
  const buf = fs.readFileSync(infile);
  const { salt, nonce, tag, ciphertext } = parseHeader(buf);
  const key = deriveKey(pass, salt, domain);
  let plain;
  try {
    plain = decryptWithKey(ciphertext, key, nonce, tag);
  } catch (_) {
    die('完整性校验失败：文件可能被篡改或口令错误');
  }
  fs.writeFileSync(outfile, plain);
  info(`解密完成并通过完整性校验: ${outfile}`);
}

async function cmdEncryptEnvelope(infile, outfile, dekOutfile) {
  if (!fs.existsSync(infile)) die(`输入文件不存在: ${infile}`);
  const pass = await readPassphrase();

  const dek = crypto.randomBytes(DEK_LEN);
  const salt = crypto.randomBytes(SALT_LEN);
  const nonce = crypto.randomBytes(NONCE_LEN);
  const plain = fs.readFileSync(infile);
  const { ciphertext, tag } = encryptWithKey(plain, dek, nonce);
  const header = buildHeader(salt, nonce, tag);
  fs.writeFileSync(outfile, Buffer.concat([header, ciphertext]));

  // 用 KEK 包裹 DEK
  const kek = deriveKey(pass, salt, DOMAIN_ENVELOPE);
  const dekNonce = crypto.randomBytes(NONCE_LEN);
  const { ciphertext: dekCt, tag: dekTag } = encryptWithKey(dek, kek, dekNonce);
  const wrapped = Buffer.concat([dekNonce, dekTag, dekCt]);
  fs.writeFileSync(dekOutfile, wrapped.toString('hex'));
  info(`信封加密完成: 文件=${outfile}, 包裹DEK=${dekOutfile}`);
}

async function cmdDecryptEnvelope(infile, outfile, dekInfile) {
  if (!fs.existsSync(infile)) die('密文文件不存在');
  if (!fs.existsSync(dekInfile)) die('包裹的 DEK 文件不存在');
  const pass = await readPassphrase();

  const buf = fs.readFileSync(infile);
  const { salt, nonce, tag, ciphertext } = parseHeader(buf);

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

  let plain;
  try {
    plain = decryptWithKey(ciphertext, dek, nonce, tag);
  } catch (_) {
    die('文件内容被篡改');
  }
  fs.writeFileSync(outfile, plain);
  info(`信封解密完成: ${outfile}`);
}

function readPassphrase() {
  return new Promise((resolve, reject) => {
    if (process.stdin.isTTY) {
      process.stderr.write('主口令: ');
      const stdin = process.stdin;
      stdin.setRawMode(true);
      stdin.resume();
      stdin.setEncoding('utf8');
      let pass = '';
      const onData = (chunk) => {
        for (const c of chunk) {
          if (c === '\r' || c === '\n') {
            stdin.setRawMode(false);
            stdin.pause();
            stdin.removeListener('data', onData);
            process.stderr.write('\n');
            if (pass.length === 0) return reject(new Error('口令为空'));
            resolve(pass);
            return;
          } else if (c === '\u0003') { // Ctrl+C
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
      let data = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (c) => { data += c; });
      process.stdin.on('end', () => {
        const pass = data.replace(/\r?\n$/, '');
        if (pass.length === 0) return reject(new Error('口令为空'));
        resolve(pass);
      });
      process.stdin.resume();
    }
  });
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 3) {
    process.stderr.write(
      `用法: ${process.argv[1]} {encrypt|decrypt|encrypt-index|decrypt-index|encrypt-envelope|decrypt-envelope} <参数...>\n`
    );
    process.exit(2);
  }
  try {
    switch (args[0]) {
      case 'encrypt':          await cmdEncrypt(args[1], args[2], DOMAIN_DEFAULT); break;
      case 'decrypt':          await cmdDecrypt(args[1], args[2], DOMAIN_DEFAULT); break;
      case 'encrypt-index':    await cmdEncrypt(args[1], args[2], DOMAIN_INDEX); break;
      case 'decrypt-index':    await cmdDecrypt(args[1], args[2], DOMAIN_INDEX); break;
      case 'encrypt-envelope': {
        if (args.length < 4) die('encrypt-envelope 需要 3 个参数 <in> <out> <dek_out>');
        await cmdEncryptEnvelope(args[1], args[2], args[3]);
        break;
      }
      case 'decrypt-envelope': {
        if (args.length < 4) die('decrypt-envelope 需要 3 个参数 <in> <out> <dek_in>');
        await cmdDecryptEnvelope(args[1], args[2], args[3]);
        break;
      }
      default: die(`未知模式: ${args[0]}`);
    }
  } catch (e) {
    die(e && e.message ? e.message : String(e));
  }
}

main();