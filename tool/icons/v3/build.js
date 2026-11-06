/**
 * 音狐图标 v3：狐首 + 音符（直杆版）
 *
 * 源：tool/icons/v3/source.png（1252×1248，纯白底，墨蓝 #082F56 + 橙 #FB901C）
 * 做法：把白底按「两次 unmix」还原成直通 alpha（抗锯齿边缘按通道反解，不靠阈值硬切），
 *      得到透明底的双色线条图，再等比 contain 进各尺寸画布。
 * 一次产出：
 *   tool/icons/app_icon.png / app_icon_bg.png   1024 白底（传统图标 / flutter_launcher_icons 源）
 *   tool/icons/app_icon_foreground.png          1024 透明（自适应前景，内容 66%）
 *   assets/icon/logo.webp                       关于页运行时 logo
 *   logo.png                                    README 用母版
 *   mipmap-*dpi/ic_launcher.png                 48/72/96/144/192
 *   drawable-*dpi/ic_launcher_foreground.png    108/162/216/324/432
 *   drawable-*dpi/ic_launcher_monochrome.png    同上（Android 13 主题图标剪影层）
 *   drawable-*dpi/splash_logo.png               昼（墨蓝）
 *   drawable-night-*dpi/splash_logo.png         夜（白）
 *   drawable-*dpi/splash_foreground.png         启动图前景（昼/夜）
 *   ohos/.../app_icon.png、icon.png             鸿蒙
 *
 * 用法：cd tool/icons && node v3/build.js
 */
const sharp = require('sharp');
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const ROOT = path.resolve(HERE, '../../..');
const SRC = path.join(HERE, 'source.png');

const INK = [8, 47, 86];        // #082F56
const ACCENT = [251, 144, 28];  // #FB901C
const NIGHT_ORANGE = [246, 167, 71];
const WHITE = [255, 255, 255];

/** 白底 → 直通 alpha。alpha 永远按「源图墨色」反解（与输出色无关）：
 *  白线版本若拿白色自己的 B 通道做分母会除零，夜间图会炸成噪点。 */
async function unmix(ink, accent) {
  const { data, info } = await sharp(SRC).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const { width: w, height: h } = info;
  const ch = info.channels; // removeAlpha 后是 3 通道，步长必须按 channels 取
  const out = Buffer.alloc(w * h * 4);
  let minX = w, minY = h, maxX = -1, maxY = -1;
  for (let i = 0; i < w * h; i++) {
    const r = data[i * ch];
    const b = data[i * ch + 2];
    const warm = r - b > 45;
    const c = warm ? accent : ink;               // 输出色
    const base = warm ? ACCENT : INK;            // 反解基准（源图色）
    let a = (255 - b) / (255 - base[2]);
    if (a < 0) a = 0;
    else if (a > 1) a = 1;
    if (a < 0.035) a = 0; // 背景噪声（255,255,253 之类）归零
    out[i * 4] = c[0];
    out[i * 4 + 1] = c[1];
    out[i * 4 + 2] = c[2];
    out[i * 4 + 3] = Math.round(a * 255);
    if (a > 0) {
      const x = i % w;
      const y = (i - x) / w;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  const buf = await sharp(out, { raw: { width: w, height: h, channels: 4 } }).png().toBuffer();
  return { buf, box: { left: minX, top: minY, width: maxX - minX + 1, height: maxY - minY + 1 } };
}

/** 把已裁边的图 contain 进 canvas 方形画布（内容边长 content） */
async function fit(trimmed, content, canvas, bg) {
  const resized = await sharp(trimmed)
    .resize(content, content, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();
  const meta = await sharp(resized).metadata();
  const left = Math.round((canvas - meta.width) / 2);
  const top = Math.round((canvas - meta.height) / 2);
  const plate = sharp({
    create: {
      width: canvas,
      height: canvas,
      channels: 4,
      background: bg === 'white' ? { r: 255, g: 255, b: 255, alpha: 1 } : { r: 0, g: 0, b: 0, alpha: 0 },
    },
  });
  return plate.composite([{ input: resized, left, top }]).png().toBuffer();
}

/** 异形画布：内容按高度缩放后居中（宽高都不裁） */
async function fitBox(trimmed, contentH, canvasW, canvasH) {
  const resized = await sharp(trimmed).resize({ height: contentH }).png().toBuffer();
  const meta = await sharp(resized).metadata();
  // 舍入后内容可能比画布宽 1px（等比缩放），画布跟着放宽，避免 composite 报错
  canvasW = Math.max(canvasW, meta.width);
  canvasH = Math.max(canvasH, meta.height);
  return sharp({
    create: { width: canvasW, height: canvasH, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  })
    .composite([
      {
        input: resized,
        left: Math.round((canvasW - meta.width) / 2),
        top: Math.round((canvasH - meta.height) / 2),
      },
    ])
    .png()
    .toBuffer();
}

/** 剪影层：保留 alpha，整体刷成单色 */
async function silhouette(trimmed, color = WHITE) {
  const meta = await sharp(trimmed).metadata();
  const plate = await sharp({
    create: {
      width: meta.width,
      height: meta.height,
      channels: 4,
      background: { r: color[0], g: color[1], b: color[2], alpha: 1 },
    },
  })
    .png()
    .toBuffer();
  return sharp(plate).composite([{ input: trimmed, blend: 'dest-in' }]).png().toBuffer();
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

// 源图内容宽高比（610×938）
const ASPECT = 610 / 938;

(async () => {
  // 包围盒自己算（sharp 的 trim 在 RGB 全白的夜间图上认不出边界）
  const d = await unmix(INK, ACCENT);
  const n = await unmix(WHITE, NIGHT_ORANGE);
  const box = d.box;
  const day = await sharp(d.buf).extract(box).png().toBuffer();
  const night = await sharp(n.buf).extract(box).png().toBuffer();
  const mono = await silhouette(day);

  const dayMeta = await sharp(day).metadata();
  console.log(`源内容 ${dayMeta.width}×${dayMeta.height}，比例 ${(dayMeta.width / dayMeta.height).toFixed(3)}`);

  // 传统方形图标（白底，内容占 76%）
  const bgMaster = await fit(day, 778, 1024, 'white');
  await write(bgMaster, 'tool/icons/app_icon_bg.png');
  await write(bgMaster, 'tool/icons/app_icon.png');

  // 自适应前景（透明）。实测：内容占 67% 时 6.2% 的笔画会出 66dp 安全圆，
  // 圆形遮罩 ROM 上耳尖和音符底会被切；降到 60% 后越界 0%（见 v3 注释）。
  const fgMaster = await fit(day, 614, 1024, 'clear');
  await write(fgMaster, 'tool/icons/app_icon_foreground.png');

  // 关于页 logo（内容 85%）
  const logo = await fit(day, 870, 1024, 'clear');
  await write(await sharp(logo).webp({ quality: 92 }).toBuffer(), 'assets/icon/logo.webp');
  await write(logo, 'logo.png');

  for (const [d, k] of DENSITIES) {
    const legacy = Math.round(48 * k);
    await write(
      await sharp(bgMaster).resize(legacy, legacy, { kernel: 'lanczos3' }).png().toBuffer(),
      `android/app/src/main/res/mipmap-${d}/ic_launcher.png`,
    );
    const canvas = Math.round(108 * k);
    await write(
      await sharp(fgMaster).resize(canvas, canvas, { kernel: 'lanczos3' }).png().toBuffer(),
      `android/app/src/main/res/drawable-${d}/ic_launcher_foreground.png`,
    );
    const monoLayer = await fit(mono, 614, 1024, 'clear');
    await write(
      await sharp(monoLayer).resize(canvas, canvas, { kernel: 'lanczos3' }).png().toBuffer(),
      `android/app/src/main/res/drawable-${d}/ic_launcher_monochrome.png`,
    );

    // 启动图 logo：画布紧贴内容比例（123dp 高），避免 v31 的 bitmap fill 拉伸变形
    const sH = Math.round(123 * k);
    const sW = Math.ceil(sH * ASPECT);
    await write(await fitBox(day, sH, sW, sH), `android/app/src/main/res/drawable-${d}/splash_logo.png`);
    await write(await fitBox(day, sH, sW, sH), `android/app/src/main/res/drawable-${d}/splash_logo_dark.png`);
    await write(await fitBox(night, sH, sW, sH), `android/app/src/main/res/drawable-night-${d}/splash_logo.png`);

    // Android 12+ 启动图前景（内容 34dp）
    const sfH = Math.round(34 * k);
    await write(await fitBox(day, sfH, canvas, canvas), `android/app/src/main/res/drawable-${d}/splash_foreground.png`);
    await write(
      await fitBox(night, sfH, canvas, canvas),
      `android/app/src/main/res/drawable-night-${d}/splash_foreground.png`,
    );
  }

  // 鸿蒙（白底方形）
  for (const rel of [
    'ohos/AppScope/resources/base/media/app_icon.png',
    'ohos/entry/src/main/resources/base/media/icon.png',
    'ohos/entry/src/ohosTest/resources/base/media/icon.png',
  ]) {
    if (fs.existsSync(path.dirname(path.join(ROOT, rel)))) await write(bgMaster, rel);
  }

  console.log('done');
})();
