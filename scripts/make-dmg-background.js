#!/usr/bin/env node
//
//  make-dmg-background.js
//
//  Draws the disk image background. It is generated rather than exported
//  from a design tool so the brand colour, the icon positions and the arrow
//  between them all come from the same numbers the Makefile lays the icons
//  out with — move an icon in one place and the art follows.
//
//  Deliberately typography-free: Finder already writes "Polaris" in the
//  title bar and under the app icon, and a wordmark painted into the
//  background would need a font renderer to sit here for no gain.
//
//  Writes @1x and @2x PNGs; the Makefile combines them into one HiDPI TIFF
//  with tiffutil, which is what Finder wants for a sharp background on a
//  retina display.
//
//  Usage: node scripts/make-dmg-background.js [outDir]
//

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// --- geometry, in @1x points. Shared with the Makefile's osascript. -------
const W = 520, H = 340;
const APP = { x: 140, y: 158 };   // centre of the app icon
const DEST = { x: 380, y: 158 };  // centre of the Applications alias
const ICON = 104;                 // icon size Finder is told to draw at

// --- palette, from docs/index.html dark theme ----------------------------
const BG = [0x12, 0x12, 0x12];
const ACCENT = [0xFF, 0x5F, 0x22];

function png(scale) {
  const w = W * scale, h = H * scale;
  const px = Buffer.alloc(w * h * 4);

  const put = (x, y, [r, g, b], a) => {
    if (x < 0 || y < 0 || x >= w || y >= h || a <= 0) return;
    const i = (y * w + x) * 4;
    const src = Math.min(1, a);
    // Straight alpha over whatever is already there.
    px[i]     = px[i]     * (1 - src) + r * src;
    px[i + 1] = px[i + 1] * (1 - src) + g * src;
    px[i + 2] = px[i + 2] * (1 - src) + b * src;
    px[i + 3] = 255;
  };

  // Base, plus a warm bloom behind the app icon so the eye starts on the
  // left — the thing being dragged — rather than in the middle of the arrow.
  // A wide, shallow gradient across 8-bit channels bands into visible
  // rings, so every pixel gets a sub-LSB of noise before it is truncated.
  const dither = () => (Math.random() - 0.5) * 1.4;
  const glowX = APP.x * scale, glowY = APP.y * scale, glowR = 380 * scale;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      const d = Math.hypot(x - glowX, y - glowY) / glowR;
      const t = Math.max(0, 1 - d) ** 2.6 * 0.085;
      px[i]     = BG[0] + (ACCENT[0] - BG[0]) * t + dither();
      px[i + 1] = BG[1] + (ACCENT[1] - BG[1]) * t + dither();
      px[i + 2] = BG[2] + (ACCENT[2] - BG[2]) * t + dither();
      px[i + 3] = 255;
    }
  }

  // A soft vignette keeps the corners from competing with the two icons.
  const cx = w / 2, cy = h / 2, maxD = Math.hypot(cx, cy);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const t = (Math.hypot(x - cx, y - cy) / maxD) ** 2.4 * 0.35;
      put(x, y, [0, 0, 0], t);
    }
  }

  // --- the drag arrow --------------------------------------------------
  // Starts and ends clear of both icons so it never runs under a label.
  const pad = ICON / 2 + 26;
  const x0 = (APP.x + pad) * scale;
  const x1 = (DEST.x - pad) * scale;
  const ay = APP.y * scale;
  const thick = 2 * scale;

  // Dashes, drawn with a soft edge so they don't crawl at @1x.
  const dash = 3 * scale, gap = 9 * scale;
  const headLen = 13 * scale;
  const shaftEnd = x1 - headLen;
  for (let x = x0; x < shaftEnd; x++) {
    if ((x - x0) % (dash + gap) >= dash) continue;
    for (let y = ay - thick; y <= ay + thick; y++) {
      const a = 1 - Math.abs(y - ay) / (thick + 1);
      put(Math.round(x), Math.round(y), ACCENT, a * 0.85);
    }
  }

  // Solid chevron head.
  for (let k = 0; k <= headLen; k++) {
    const spread = k * 0.78;
    for (let t = -thick; t <= thick; t++) {
      const a = 1 - Math.abs(t) / (thick + 1);
      put(Math.round(x1 - k), Math.round(ay - spread + t), ACCENT, a);
      put(Math.round(x1 - k), Math.round(ay + spread + t), ACCENT, a);
    }
  }

  return encode(w, h, px);
}

// --- minimal PNG encoder -------------------------------------------------
function encode(w, h, rgba) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0; // filter: none
    rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;    // bit depth
  ihdr[9] = 6;    // colour type: RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body) >>> 0);
  return Buffer.concat([len, body, crc]);
}

const outDir = process.argv[2] || path.join(__dirname, '..', 'Resources', 'dmg');
fs.mkdirSync(outDir, { recursive: true });
for (const scale of [1, 2]) {
  const name = scale === 1 ? 'background.png' : 'background@2x.png';
  const file = path.join(outDir, name);
  fs.writeFileSync(file, png(scale));
  console.log(`${file}  ${W * scale}×${H * scale}`);
}
