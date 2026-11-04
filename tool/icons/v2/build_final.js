/**
 * 音狐最终图标生成：藏青 #16324A + 橙 #F49B33
 *
 * 矢量源来自 ref_navy_d.json / ref_orange_d.json（参考图矢量化路径）。
 * 一次产出：
 *   tool/icons/app_icon_bg.png          1024 白底方形（Android 传统 / iOS）
 *   tool/icons/app_icon_foreground.png  1024 透明（Android 自适应前景）
 *   assets/icon/logo.webp               1024 透明（关于页运行时 logo）
 *   android mipmap 各密度 ic_launcher.png             48/72/96/144/192
 *   android drawable 各密度 ic_launcher_foreground    108/162/216/324/432
 *   ios AppIcon.appiconset/*.png        全部尺寸（白底不透明）
 */
const sharp = require('sharp');
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const ROOT = path.resolve(HERE, '../../..');

const NAVY = '#16324A';
const ORANGE = '#F49B33';

const navy = JSON.parse(fs.readFileSync(path.join(HERE, 'ref_navy_d.json'), 'utf8'));
const orange = JSON.parse(fs.readFileSync(path.join(HERE, 'ref_orange_d.json'), 'utf8'));

function svgSource({ strokeWidth = 10, size = 1024, background = '#ffffff' } = {}) {
  const bg = background ? `<rect width="512" height="512" fill="${background}"/>` : '';
  const navyPaths = navy
    .map(
      (d) =>
        `<path d="${d}" fill="${NAVY}" fill-rule="evenodd" stroke="${NAVY}" ` +
        `stroke-width="${strokeWidth}" stroke-linejoin="round" stroke-linecap="round"/>`,
    )
    .join('');
  const orangePaths = orange
    .map((d) => `<path d="${d}" fill="${ORANGE}" fill-rule="evenodd"/>`)
    .join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 512 512">${bg}${navyPaths}${orangePaths}</svg>`;
}

/** 先裁到内容边界，再等比缩放到 inner 并居中留白 */
async function fit(svg, inner, canvas, background) {
  const trimmed = await sharp(Buffer.from(svg)).trim({ threshold: 10 }).toBuffer();
  const resized = await sharp(trimmed)
    .resize(inner, inner, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();
  const pad = Math.round((canvas - inner) / 2);
  return sharp({
    create: {
      width: canvas,
      height: canvas,
      channels: 4,
      background: background === 'white'
        ? { r: 255, g: 255, b: 255, alpha: 1 }
        : { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: resized, left: pad, top: pad }])
    .png()
    .toBuffer();
}

const write = async (buf, rel) => {
  const p = path.join(ROOT, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, buf);
  console.log('  ', rel);
};

const ANDROID = [
  ['mdpi', 48, 108],
  ['hdpi', 72, 162],
  ['xhdpi', 96, 216],
  ['xxhdpi', 144, 324],
  ['xxxhdpi', 192, 432],
];

const IOS = [
  ['20x20@1x', 20], ['20x20@2x', 40], ['20x20@3x', 60],
  ['29x29@1x', 29], ['29x29@2x', 58], ['29x29@3x', 87],
  ['40x40@1x', 40], ['40x40@2x', 80], ['40x40@3x', 120],
  ['50x50@1x', 50], ['50x50@2x', 100],
  ['57x57@1x', 57], ['57x57@2x', 114],
  ['60x60@2x', 120], ['60x60@3x', 180],
  ['72x72@1x', 72], ['72x72@2x', 144],
  ['76x76@1x', 76], ['76x76@2x', 152],
  ['83.5x83.5@2x', 167],
  ['1024x1024@1x', 1024],
];

(async () => {
  const svgWhite = svgSource({ background: '#ffffff' });
  const svgClear = svgSource({ background: null });

  // 1024 主图（白底，内容占 76%）
  const masterWhite = await fit(svgWhite, 778, 1024, 'white');
  await write(masterWhite, 'tool/icons/app_icon_bg.png');
  await write(masterWhite, 'tool/icons/app_icon.png');

  // 自适应图标前景：透明底，内容占 66%（108dp 安全圆内）
  const foreground = await fit(svgClear, 676, 1024, 'clear');
  await write(foreground, 'tool/icons/app_icon_foreground.png');

  // 关于页运行时 logo：透明底，内容占 85%（外层卡片另有 12% padding）
  const logo = await fit(svgClear, 870, 1024, 'clear');
  const webp = await sharp(logo).webp({ quality: 92, lossless: false }).toBuffer();
  await write(webp, 'assets/icon/logo.webp');

  // Android 传统图标
  for (const [density, size] of ANDROID) {
    const b = await sharp(masterWhite).resize(size, size, { kernel: 'lanczos3' }).png().toBuffer();
    await write(b, `android/app/src/main/res/mipmap-${density}/ic_launcher.png`);
  }

  // Android 自适应前景层
  for (const [density, , fgSize] of ANDROID) {
    const b = await sharp(foreground).resize(fgSize, fgSize, { kernel: 'lanczos3' }).png().toBuffer();
    await write(b, `android/app/src/main/res/drawable-${density}/ic_launcher_foreground.png`);
  }

  // iOS（不透明）
  for (const [suffix, size] of IOS) {
    const b = await sharp(masterWhite).resize(size, size, { kernel: 'lanczos3' })
      .flatten({ background: '#ffffff' }).png().toBuffer();
    await write(b, `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-${suffix}.png`);
  }

  // 圆角预览（启动器效果参考）
  const round = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256">` +
    `<rect x="0" y="0" width="256" height="256" rx="58" ry="58" fill="#ffffff"/></svg>`,
  );
  await sharp(masterWhite)
    .resize(256, 256)
    .composite([{ input: await sharp(round).png().toBuffer(), blend: 'dest-in' }])
    .png()
    .toFile(path.join(HERE, 'preview_rounded.png'));

  console.log('done');
})();
