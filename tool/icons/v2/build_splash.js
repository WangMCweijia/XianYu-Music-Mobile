/**
 * 音狐品牌资源铺满：闪屏（昼/夜）+ 鸿蒙图标
 * 与 build_final.js 共用同一套矢量路径，保证所有位一致。
 */
const sharp = require('sharp');
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const ROOT = path.resolve(HERE, '../../..');

const NAVY = '#16324A';
const ORANGE = '#F49B33';
const WHITE = '#FFFFFF';
const NIGHT_ORANGE = '#F6A747';

const navy = JSON.parse(fs.readFileSync(path.join(HERE, 'ref_navy_d.json'), 'utf8'));
const orange = JSON.parse(fs.readFileSync(path.join(HERE, 'ref_orange_d.json'), 'utf8'));

function svgSource({ size = 1024, ink = NAVY, accent = ORANGE, strokeWidth = 10, background = null } = {}) {
  const bg = background ? `<rect width="512" height="512" fill="${background}"/>` : '';
  const navyPaths = navy
    .map(
      (d) =>
        `<path d="${d}" fill="${ink}" fill-rule="evenodd" stroke="${ink}" ` +
        `stroke-width="${strokeWidth}" stroke-linejoin="round" stroke-linecap="round"/>`,
    )
    .join('');
  const orangePaths = orange
    .map((d) => `<path d="${d}" fill="${accent}" fill-rule="evenodd"/>`)
    .join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 512 512">${bg}${navyPaths}${orangePaths}</svg>`;
}

/** 内容 contain 进 w×h 画布并居中（画布可非正方） */
async function fitBox(svg, contentW, canvasW, canvasH, opaqueBg = null) {
  const trimmed = await sharp(Buffer.from(svg)).trim({ threshold: 10 }).toBuffer();
  const resized = await sharp(trimmed)
    .resize(contentW, contentW, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();
  const left = Math.round((canvasW - contentW) / 2);
  const top = Math.round((canvasH - contentW) / 2);
  return sharp({
    create: {
      width: canvasW,
      height: canvasH,
      channels: 4,
      background: opaqueBg ?? { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: resized, left, top }])
    .png()
    .toBuffer();
}

const write = async (buf, rel) => {
  const p = path.join(ROOT, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, buf);
  console.log('  ', rel);
};

const DENSITIES = [
  ['mdpi', 1],
  ['hdpi', 1.5],
  ['xhdpi', 2],
  ['xxhdpi', 3],
  ['xxxhdpi', 4],
];

(async () => {
  // 闪屏 logo 基准：592x571 画布，内容 493（与原图 36..568 / 50..543 一致）
  for (const [d, k] of DENSITIES) {
    const w = Math.round(148 * k);
    const h = Math.round(143 * k);
    const content = Math.round(123 * k); // 493/4 = 123.25
    const day = await fitBox(svgSource({ ink: NAVY, accent: ORANGE }), content, w, h);
    await write(day, `android/app/src/main/res/drawable-${d}/splash_logo.png`);
    await write(day, `android/app/src/main/res/drawable-${d}/splash_logo_dark.png`);
    const night = await fitBox(
      svgSource({ ink: WHITE, accent: NIGHT_ORANGE }),
      content,
      w,
      h,
    );
    await write(night, `android/app/src/main/res/drawable-night-${d}/splash_logo.png`);
  }

  // 夜间 Android 12+ 自适应前景：432 画布，内容 136（0.315）
  for (const [d, k] of DENSITIES) {
    const canvas = Math.round(108 * k);
    const content = Math.round(34 * k);
    const buf = await fitBox(svgSource({ ink: WHITE, accent: NIGHT_ORANGE }), content, canvas, canvas);
    await write(buf, `android/app/src/main/res/drawable-night-${d}/splash_foreground.png`);
    const bufDay = await fitBox(svgSource({ ink: NAVY, accent: ORANGE }), content, canvas, canvas);
    await write(bufDay, `android/app/src/main/res/drawable-${d}/splash_foreground.png`);
  }

  // 鸿蒙图标（白底方形）
  const ohos = await fitBox(
    svgSource({ background: '#ffffff' }),
    Math.round(1024 * 0.76),
    1024,
    1024,
    { r: 255, g: 255, b: 255, alpha: 1 },
  );
  await write(ohos, 'ohos/AppScope/resources/base/media/app_icon.png');
  await write(ohos, 'ohos/entry/src/main/resources/base/media/icon.png');
  await write(ohos, 'ohos/entry/src/ohosTest/resources/base/media/icon.png');

  console.log('done');
})();
