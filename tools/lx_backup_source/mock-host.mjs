// 本地模拟 LX 宿主，直接跑 sources/backup-all.js 验证取链
// 用法: node mock-host.mjs [平台...] [档位]
//   例: node mock-host.mjs               → 五平台 × flac
//       node mock-host.mjs kw 320k       → 酷我 320K
//       node mock-host.mjs all all       → 五平台 × 全档位矩阵
import fs from 'node:fs'
import path from 'node:path'
import vm from 'node:vm'
import crypto from 'node:crypto'

const scriptPath = path.resolve(process.cwd(), '../../sources/backup-all.js')
const code = fs.readFileSync(scriptPath, 'utf8')

const EVENT_NAMES = {
  request: 'request',
  inited: 'inited',
  updateAlert: 'updateAlert',
}

let handler = null
let initPayload = null
let resolveInit
const initPromise = new Promise((r) => (resolveInit = r))

function request(url, options, cb) {
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), (options && options.timeout) || 15000)
  fetch(url, {
    method: (options && options.method) || 'GET',
    headers: options && options.headers,
    body: options && options.body,
    redirect: 'follow',
    signal: ctl.signal,
  })
    .then(async (r) => {
      const text = await r.text()
      cb(null, { statusCode: r.status, body: text, headers: {} })
    })
    .catch((e) => cb(e))
    .finally(() => clearTimeout(t))
}

const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  Promise,
  JSON,
  Math,
  Date,
  encodeURIComponent,
  decodeURIComponent,
  Error,
  Object,
  Array,
  String,
  Number,
  RegExp,
  globalThis: null,
}
sandbox.globalThis = sandbox
sandbox.lx = {
  EVENT_NAMES,
  request,
  on(evt, fn) {
    if (evt === EVENT_NAMES.request) handler = fn
  },
  send(evt, payload) {
    if (evt === EVENT_NAMES.inited) {
      initPayload = payload
      resolveInit(payload)
    }
  },
  utils: {
    crypto: {
      md5: (s) => crypto.createHash('md5').update(String(s), 'utf8').digest('hex'),
    },
  },
  env: 'mobile',
  version: '2.0.7',
}

vm.createContext(sandbox)
vm.runInContext(code, sandbox, { filename: 'backup-all.js' })

const inited = await Promise.race([
  initPromise,
  new Promise((_, rej) => setTimeout(() => rej(new Error('初始化超时')), 8000)),
])
console.log('声明档位:', JSON.stringify(inited.sources, null, 0))

const CASES = {
  kw: { rid: '26445261', name: '起风了', singer: '买辣椒也用券' },
  kg: { hash: 'A925B6F4818F1F73FFD6B7E146010046', name: '晴天', singer: '周杰伦' },
  tx: { songmid: '0039MnYb0qxYhV', name: '晴天', singer: '周杰伦' },
  wy: { songmid: '347230', name: '起风了', singer: '买辣椒也用券' },
  mg: { copyrightId: '60054701923', name: '晴天', singer: '周杰伦' },
}

const ALL_TIERS = ['128k', '192k', '320k', 'flac', 'flac24bit']

const arg1 = process.argv[2] || 'all'
const arg2 = process.argv[3] || 'flac'
const targets = arg1 === 'all' ? Object.keys(CASES) : [arg1]
const tiers = arg2 === 'all' ? ALL_TIERS : [arg2]

// KID=xxx / KNAME=xxx 可临时替换某平台的 id 或歌名，用于验证失败路径
if (process.env.KNAME) {
  const p = process.env.KP
  CASES[p] = { ...CASES[p], name: process.env.KNAME, singer: process.env.KSINGER || CASES[p].singer }
}
if (process.env.KID && process.env.KP) {
  const p = process.env.KP
  const f = p === 'wy' ? 'songmid' : p === 'kw' ? 'rid' : p === 'tx' ? 'songmid' : p === 'kg' ? 'hash' : 'copyrightId'
  CASES[p] = { ...CASES[p], [f]: process.env.KID }
}

const LOSSY = /\.(mp3|m4a|aac|ogg|wma)(\?|$)/i

// 用 Range 读前 4 字节，确认文件真身
async function sniff(url) {
  try {
    const r = await fetch(url, { headers: { Range: 'bytes=0-3' }, redirect: 'follow' })
    const b = Buffer.from(await r.arrayBuffer())
    const hex = b.toString('hex')
    if (hex === '664c6143') return 'FLAC'
    if (hex.startsWith('494433') || hex.startsWith('fffb') || hex.startsWith('fffa')) return 'MP3'
    if (b.slice(4, 8).toString() === 'ftyp') return 'M4A'
    if (hex.startsWith('4f676753')) return 'OGG'
    return '?' + hex
  } catch (e) {
    return 'ERR'
  }
}

for (const s of targets) {
  for (const q of tiers) {
    const t0 = Date.now()
    try {
      const r = await handler({ source: s, action: 'musicUrl', info: { type: q, musicInfo: CASES[s] } })
      const ms = Date.now() - t0
      const got = r.type || q
      const lossyUrl = LOSSY.test(r.url.split('?')[0])
      const wantLossless = q === 'flac' || q === 'flac24bit'
      const bad = wantLossless && lossyUrl
      const tag = bad ? '❌降质' : '✅'
      console.log(
        `${tag} ${s}/${String(q).padEnd(9)} → ${String(got).padEnd(9)} ${String(ms).padStart(5)}ms  上游=${String(
          r.provider || '-'
        ).padEnd(13)} ${r.url.slice(0, 76)}`
      )
    } catch (e) {
      console.log(
        `❌ ${s}/${String(q).padEnd(9)}   ${String(Date.now() - t0).padStart(5)}ms  ${e && e.message ? e.message : e}`
      )
    }
  }
}
