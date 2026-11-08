// mapping-spa/server.js
const http = require('http')
const fs = require('fs')
const os = require('os')
const path = require('path')
const crypto = require('crypto')
const { spawn } = require('child_process')

// 路径适配：server.js 在 mapping-spa/ 下，脚本在 termux-encrypt/ 下
const ROOT = __dirname
const REPO_ROOT = path.join(ROOT, '..')
const ENGINE = path.join(REPO_ROOT, 'termux-encrypt', 'crypto-engine.sh')
const INDEX_SYNC = path.join(REPO_ROOT, 'termux-encrypt', 'index-sync.sh')

// 模拟云盘根目录
const VAULT_DIR = path.join(REPO_ROOT, 'vault')
const INDEX_ENC = path.join(VAULT_DIR, 'index.jsonl.enc')
const PORT = 3178
const CSRF_TOKEN = crypto.randomBytes(16).toString('hex')

fs.mkdirSync(VAULT_DIR, { recursive: true })

let sessionPass = null

function runBash(script, args, pass, timeoutMs = 60000) {
  return new Promise((resolve, reject) => {
    const child = spawn('bash', [script, ...args], { windowsHide: true })
    let stderr = ''
    let stdout = ''
    child.stdout.on('data', (d) => { stdout += d; process.stdout.write(d) })
    child.stderr.on('data', (d) => { 
      stderr += d; 
      // 过滤掉正常提示信息，避免在 Node 终端里看着像报错
      if (!d.toString().includes('[crypto-engine]')) {
        process.stderr.write(d) 
      }
    })
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('timeout')) }, timeoutMs)
    child.on('close', (code) => {
      clearTimeout(timer)
      if (code === 0) {
        resolve(stdout) // 只要退出码是 0，哪怕 stderr 有 log 也是成功
      } else {
        reject(new Error(`Bash Exit Code ${code}: ` + stderr.trim()))
      }
    })
    child.on('error', reject)
    if (pass != null) { child.stdin.write(pass + '\n'); child.stdin.end() }
  })
}

async function readIndex(pass) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pst-idx-'))
  const out = path.join(tmp, 'i.jsonl')
  try {
    await runBash(INDEX_SYNC, ['decrypt', INDEX_ENC, out], pass)
    return fs.readFileSync(out, 'utf8').split('\n').filter(Boolean).map(JSON.parse)
  } finally { try { fs.rmSync(tmp, { recursive: true, force: true }) } catch (_) {} }
}

async function writeIndex(entries, pass) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pst-idx-'))
  const inp = path.join(tmp, 'i.jsonl')
  try {
    fs.writeFileSync(inp, entries.map(JSON.stringify).join('\n') + '\n', { mode: 0o600 })
    await runBash(INDEX_SYNC, ['encrypt', inp, INDEX_ENC], pass)
  } finally { try { fs.rmSync(tmp, { recursive: true, force: true }) } catch (_) {} }
}

function parseMultipart(buf, boundary) {
  const delim = Buffer.from('--' + boundary)
  const parts = []
  let pos = buf.indexOf(delim)
  while (pos !== -1) {
    const next = buf.indexOf(delim, pos + delim.length)
    if (next === -1) break
    const chunk = buf.subarray(pos + delim.length + 2, next - 2)
    const hEnd = chunk.indexOf('\r\n\r\n')
    if (hEnd !== -1) {
      const headers = chunk.subarray(0, hEnd).toString()
      const body = chunk.subarray(hEnd + 4)
      const m = /filename="([^"]*)"/.exec(headers)
      if (m) parts.push({ filename: m[1], body })
    }
    pos = next
  }
  return parts
}

const server = http.createServer(async (req, res) => {
  const send = (code, obj) => {
    if (!res.headersSent) {
      res.writeHead(code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(obj));
    }
  }
  
  try {
    if (req.method === 'POST' && req.headers['x-csrf-token'] !== CSRF_TOKEN) return send(403, { error: 'csrf' })
    if (req.method === 'GET' && req.url === '/api/csrf') return send(200, { token: CSRF_TOKEN })

    if (req.method === 'POST' && req.url === '/api/unlock') {
      const body = await readBody(req)
      const { passphrase } = JSON.parse(body)
      try { 
        if (fs.existsSync(INDEX_ENC)) {
          await readIndex(passphrase)
        }
        sessionPass = passphrase
        return send(200, { ok: true }) 
      }
      catch (e) { return send(400, { ok: false, error: '口令错误或索引损坏' }) }
    }
    if (req.method === 'POST' && req.url === '/api/lock') { sessionPass = null; return send(200, { ok: true }) }

    if (req.method === 'GET' && req.url === '/api/index') {
      if (!sessionPass) return send(401, { error: 'locked' })
      const entries = fs.existsSync(INDEX_ENC) ? await readIndex(sessionPass) : []
      return send(200, entries)
    }

    if (req.method === 'POST' && req.url === '/api/encrypt') {
      if (!sessionPass) return send(401, { error: 'locked' })
      const ct = req.headers['content-type'] || ''
      const bm = /boundary=(.+)$/.exec(ct); if (!bm) return send(400, { error: 'bad multipart' })
      const buf = await readBody(req)
      const files = parseMultipart(Buffer.from(buf), bm[1])
      if (!files.length) return send(400, { error: 'no file' })
      
      const { filename, body } = files[0]
      const id = crypto.randomUUID()
      const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pst-enc-'))
      const plain = path.join(tmp, 'p')
      const enc = path.join(VAULT_DIR, id + '.enc')
      const dekFile = path.join(tmp, 'dek.txt')
      
      try {
        fs.writeFileSync(plain, body, { mode: 0o600 })
        await runBash(ENGINE, ['encrypt-envelope', plain, enc, dekFile], sessionPass)
        const wrappedDek = fs.readFileSync(dekFile, 'utf8').trim()
        const entries = fs.existsSync(INDEX_ENC) ? await readIndex(sessionPass) : []
        entries.push({ id, name: filename, size: body.length, createdAt: Date.now(), wrapped_dek: wrappedDek })
        await writeIndex(entries, sessionPass)
        return send(200, { id, name: filename, size: body.length })
      } finally { 
        try { fs.rmSync(tmp, { recursive: true, force: true }) } catch (_) {}
      }
    }

    if (req.method === 'GET' && req.url.startsWith('/api/decrypt/')) {
      if (!sessionPass) return send(401, { error: 'locked' })
      const id = req.url.split('/').pop()
      if (!/^[0-9a-f-]{36}$/.test(id)) return send(400, { error: 'bad id' })
      
      const enc = path.join(VAULT_DIR, id + '.enc')
      if (!fs.existsSync(enc)) return send(404, { error: 'not found' })

      const entries = fs.existsSync(INDEX_ENC) ? await readIndex(sessionPass) : []
      const entry = entries.find(e => e.id === id)
      if (!entry || !entry.wrapped_dek) return send(404, { error: '缺少 DEK 元数据' })

      const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pst-dec-'))
      const out = path.join(tmp, 'out')
      const dekFile = path.join(tmp, 'dek.txt')
      
      try {
        fs.writeFileSync(dekFile, entry.wrapped_dek)
        await runBash(ENGINE, ['decrypt-envelope', enc, out, dekFile], sessionPass)
        const buf = fs.readFileSync(out)
        if (!res.headersSent) {
          res.writeHead(200, { 'Content-Type': 'application/octet-stream' })
          res.end(buf)
        }
      } catch(e) {
        send(500, { error: '解密失败: ' + e.message })
      } finally { 
        try { fs.rmSync(tmp, { recursive: true, force: true }) } catch (_) {}
      }
    }

    if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
      return res.end(fs.readFileSync(path.join(ROOT, 'public', 'index.html')))
    }
    send(404, { error: 'not found' })
  } catch (e) { 
    console.error('Server error:', e)
    send(500, { error: e.message }) 
  }
})

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0
    req.on('data', (c) => { size += c.length; if (size > 200 * 1024 * 1024) { req.destroy(); reject(new Error('too large')) } else chunks.push(c) })
    req.on('end', () => resolve(Buffer.concat(chunks)))
    req.on('error', reject)
  })
}

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[pst] Server: http://127.0.0.1:${PORT}`)
  console.log(`[pst] Vault:  ${VAULT_DIR}`)
  console.log(`[pst] Engine: ${ENGINE}`)
})