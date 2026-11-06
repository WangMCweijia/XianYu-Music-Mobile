// 校验：取链结果的文件头是否与档位相符（防止"给 .flac 实际是 mp3"或"要 320K 给 96K"）
// 用法: node verify.mjs [平台...] [档位]
//   例: node verify.mjs             → 五平台 × flac
//       node verify.mjs all all     → 五平台 × 全档位
import fs from 'node:fs'
import path from 'node:path'
import vm from 'node:vm'
import crypto from 'node:crypto'

const code = fs.readFileSync(path.resolve(process.cwd(), '../../sources/backup-all.js'), 'utf8')
const EVENT_NAMES = { request: 'request', inited: 'inited' }
let handler = null
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
}
sandbox.globalThis = sandbox
sandbox.lx = {
  EVENT_NAMES,
  request,
  on: (e, f) => {
    if (e === EVENT_NAMES.request) handler = f
  },
  send: (e, p) => {
    if (e === EVENT_NAMES.inited) resolveInit(p)
  },
  utils: { crypto: { md5: (s) => crypto.createHash('md5').update(String(s), 'utf8').digest('hex') } },
  env: 'mobile',
  version: '2.0.7',
}
vm.createContext(sandbox)
vm.runInContext(code, sandbox, { filename: 'backup-all.js' })
await initPromise

const CASES = {
  kw: { rid: '26445261', name: '起风了', singer: '买辣椒也用券' },
  kg: { hash: 'A925B6F4818F1F73FFD6B7E146010046', name: '晴天', singer: '周杰伦' },
  tx: { songmid: '0039MnYb0qxYhV', name: '晴天', singer: '周杰伦' },
  wy: { songmid: '347230', name: '起风了', singer: '买辣椒也用券' },
  mg: { copyrightId: '60054701923', name: '晴天', singer: '周杰伦' },
}
const ALL_TIERS = ['128k', '320k', 'flac', 'flac24bit']
const arg1 = process.argv[2] || 'all'
const arg2 = process.argv[3] || 'flac'
const platforms = arg1 === 'all' ? Object.keys(CASES) : [arg1]
const tiers = arg2 === 'all' ? ALL_TIERS : [arg2]

// 读前若干字节判断真实容器
function kindOf(buf) {
  const h4 = buf.slice(0, 4).toString('hex')
  if (h4 === '664c6143') return 'FLAC'
  if (h4 === '4f676753') return 'OGG'
  if (h4 === '52494646') return 'WAV'
  if (buf.slice(4, 8).toString() === 'ftyp') return 'M4A'
  if (h4.startsWith('494433')) return 'MP3'
  if (buf[0] === 0xff && (buf[1] & 0xe0) === 0xe0) return 'MP3'
  return '?' + h4
}

for (const s of platforms) {
  for (const q of tiers) {
    try {
      const r = await handler({ source: s, action: 'musicUrl', info: { type: q, musicInfo: CASES[s] } })
      const res = await fetch(r.url, { headers: { Range: 'bytes=0-15' }, redirect: 'follow' })
      const buf = Buffer.from(await res.arrayBuffer())
      const kind = kindOf(buf)
      const ct = res.headers.get('content-type') || ''
      const range = res.headers.get('content-range') || ''
      const size = range ? range.split('/')[1] : res.headers.get('content-length')
      const mb = size ? (Number(size) / 1048576).toFixed(1) + 'MB' : '?'
      const wantLossless = q === 'flac' || q === 'flac24bit'
      const lossless = kind === 'FLAC' || kind === 'WAV'
      const lossy = kind === 'MP3' || kind === 'M4A' || kind === 'AAC' || kind === 'OGG'
      // 无损档必须是 FLAC；有损档给 FLAC 属于"升档"（拿不到该档时故意给更好的），不算错
      const ok = wantLossless ? lossless : lossy || lossless
      const note = !wantLossless && lossless ? ' ↑升档' : ''
      console.log(
        `${ok ? '✅' : '❌'} ${s}/${String(q).padEnd(9)} → ${String(r.type).padEnd(9)} 实际=${kind.padEnd(5)} ${mb.padStart(
          8
        )}${note.padEnd(8)} 上游=${r.provider}`
      )
    } catch (e) {
      console.log(`❌ ${s}/${String(q).padEnd(9)}  ${e && e.message ? e.message : e}`)
    }
  }
}
