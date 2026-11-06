// 备用源上游探针：按平台并发打一遍候选接口，只认 flac 及以上
// 用法: node probe.mjs [平台...]，默认五平台
const IDS = {
  kw: '51685512',
  kg: 'A925B6F4818F1F73FFD6B7E146010046',
  tx: '0039MnYb0qxYhV',
  wy: '347230',
  mg: '60054701923',
  name: encodeURIComponent('晴天'),
};

const FLAC_RE = /\.(flac|flac24|ape|wav|alac)(\?|$)/i;
const MP3_RE = /\.(mp3|m4a|aac|ogg|wma)(\?|$)/i;

function verdict(url) {
  if (!url || !/^https?:\/\//i.test(url)) return 'no-url';
  if (FLAC_RE.test(url)) return 'FLAC';
  if (MP3_RE.test(url)) return '有损';
  return '未知后缀';
}

async function get(url, opt = {}) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), opt.timeout || 12000);
  try {
    const r = await fetch(url, {
      method: opt.method || 'GET',
      headers: opt.headers,
      body: opt.body,
      redirect: 'follow',
      signal: ctl.signal,
    });
    const text = await r.text();
    return { status: r.status, text, finalUrl: r.url };
  } catch (e) {
    return { status: 0, text: String(e.message || e), finalUrl: '' };
  } finally {
    clearTimeout(t);
  }
}

function pick(text, keys) {
  let data;
  try { data = JSON.parse(text); } catch { return null; }
  for (const k of keys) {
    const v = k.split('.').reduce((o, p) => (o == null ? undefined : o[p]), data);
    if (typeof v === 'string' && /^https?:\/\//i.test(v.trim())) return v.trim();
  }
  return null;
}

const P = {
  kw: [
    ['nxinxz kw flac', `http://music.nxinxz.com/kw.php?id=${IDS.kw}&level=flac&type=mp3`, { keys: ['url', 'data.url'] }],
    ['nxinxz kw 24bit', `http://music.nxinxz.com/kw.php?id=${IDS.kw}&level=24bit&type=mp3`, { keys: ['url', 'data.url'] }],
    ['haitangw kw flac', `https://musicapi.haitangw.net/music/kw.php?type=mp3&id=${IDS.kw}&level=flac`, { keys: ['url', 'data.url'] }],
    ['haitangw kw 24bit', `https://musicapi.haitangw.net/music/kw.php?type=mp3&id=${IDS.kw}&level=24bit`, { keys: ['url', 'data.url'] }],
    ['oiapi kuwo sq', `https://oiapi.net/api/Kuwo?msg=${IDS.name}&n=1&br=sq`, { keys: ['data.url', 'url'] }],
    ['xcvts kuwo', `https://api.xcvts.cn/api/music/kuwo?msg=${IDS.name}&br=SQ`, { keys: ['data.url', 'url', 'data'] }],
  ],
  kg: [
    ['haitangw kg lossless', `https://music.haitangw.cc/kgqq/kg.php?type=mp3&id=${IDS.kg}&level=lossless`, { keys: ['url', 'data.url'] }],
    ['haitangw kg flac', `https://music.haitangw.cc/kgqq/kg.php?type=mp3&id=${IDS.kg}&level=flac`, { keys: ['url', 'data.url'] }],
    ['nxinxz kg flac', `https://music.nxinxz.com/kgqq/kg.php?id=${IDS.kg}&level=flac&type=mp3`, { keys: ['url', 'data.url'] }],
    ['xcvts kugou', `https://api.xcvts.cn/api/music/kugou?msg=${IDS.name}&br=SQ`, { keys: ['data.url', 'url', 'data'] }],
  ],
  tx: [
    ['175 qq flac', `http://175.27.166.236/kgqq/qq.php?type=mp3&id=${IDS.tx}&level=flac`, { keys: ['url', 'data.url'] }],
    ['nxinxz tx flac', `https://music.nxinxz.com/kgqq/tx.php?id=${IDS.tx}&level=flac&type=mp3`, { keys: ['url', 'data.url'] }],
    ['tang s01s', `https://tang.api.s01s.cn/music_open_api.php?mid=${IDS.tx}`, { keys: ['song_play_url_sq', 'song_play_url_pq'] }],
    ['aacab qq SQ', `https://a.aa.cab/qq.music?msg=${IDS.name}&n=1&type=4`, { keys: ['data.music', 'data.url'] }],
  ],
  wy: [
    ['wwwweb wy flac', `https://c.wwwweb.top/music/url`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ source: 'wy', musicId: IDS.wy, quality: 'flac' }), keys: ['url', 'data.url'] }],
    ['gdapi wy br999', `https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=${IDS.wy}&br=999`, { keys: ['url'] }],
    ['nxinxz wy flac', `http://music.nxinxz.com/wy.php?id=${IDS.wy}&level=flac&type=mp3`, { keys: ['url', 'data.url'] }],
    ['mcp nianxin wy', `https://mcp.nianxinxz.com/share/ceshi/wy.php?id=${IDS.wy}&level=lossless`, { keys: ['url', 'data.url'] }],
  ],
  mg: [
    ['oiapi migu SQ', `https://oiapi.net/api/MiGu_Music?msg=${IDS.name}&n=1&br=SQ`, { keys: ['data.url', 'url'] }],
    ['xcvts migu', `https://api.xcvts.cn/api/music/migu?msg=${IDS.name}&br=SQ`, { keys: ['data.url', 'url', 'data'] }],
    ['nxinxz mg flac', `http://music.nxinxz.com/mg.php?id=${IDS.mg}&level=flac&type=mp3`, { keys: ['url', 'data.url'] }],
  ],
};

const only = process.argv.slice(2);
const targets = only.length ? only : Object.keys(P);

for (const s of targets) {
  console.log(`\n===== ${s}`);
  await Promise.all(P[s].map(async ([name, url, opt]) => {
    const t0 = Date.now();
    const r = await get(url, opt);
    const found = pick(r.text, opt.keys);
    const v = verdict(found);
    const ms = Date.now() - t0;
    const head = (r.text || '').replace(/\s+/g, ' ').slice(0, 90);
    console.log(
      `${v === 'FLAC' ? '✅' : '❌'} ${name.padEnd(22)} ${String(ms).padStart(5)}ms  ${v}  ${found ? found.slice(0, 70) : head}`
    );
  }));
}
