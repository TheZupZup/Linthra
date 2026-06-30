// Linthra — Reddit brand assets generator.
// Renders a community icon and a wide banner in three brand "skins"
// (classic / mono / community) from one source of truth: the canonical
// violet→orange four-bar equalizer mark and the app's exact palette.
//
// Prerequisite: Playwright's Chromium (used only to rasterise the SVGs to PNG):
//   npm i -D playwright && npx playwright install chromium
//
// Usage (paths are optional; defaults write next to this script):
//   node tool/branding/reddit/generate_reddit_assets.mjs \
//     assets/brand/reddit tool/branding/reddit/fonts
import { createRequire } from 'module';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';
// Resolve Playwright from a normal node_modules; fall back to a global install
// (e.g. NODE_PATH / a CI image that ships Playwright globally).
const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch {
  ({ chromium } = require(path.join(
    process.env.NODE_PATH || '/usr/lib/node_modules', 'playwright')));
}

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OUT = process.argv[2] || path.join(__dirname, 'out');
const FONT_DIR = process.argv[3] || path.join(__dirname, 'fonts');
mkdirSync(OUT, { recursive: true });

// ---------------------------------------------------------------------------
// Brand palette — mirrors lib/app/colors.dart and tool/branding/linthra_icon.svg
// ---------------------------------------------------------------------------
const C = {
  bgTop: '#1C1730', bgBottom: '#100E18',     // squircle / banner backdrop
  brand: '#7C5CFF', brandBright: '#9C84FF', brandDeep: '#5B3FD9',
  accent: '#FF9F43', accentBright: '#FFB867', accentDeep: '#F2861E',
  ink: '#F6F7FB', inkSoft: '#D8D5E8', inkMuted: '#9E9CB0',
};

// Canonical equalizer mark — four rounded bars in 512 user-space (verbatim from
// tool/branding/linthra_icon.svg). One violet→orange sweep across their shared
// vertical span (y 75.8 → 391.2) so the mark reads as a single motion.
const BARS = [
  { x: 71.2, y: 183.9, w: 58.6, h: 207.3, r: 29.3 },
  { x: 174.8, y: 75.8, w: 58.6, h: 315.4, r: 29.3 },
  { x: 278.5, y: 138.9, w: 58.6, h: 252.3, r: 29.3 },
  { x: 382.1, y: 238.0, w: 58.6, h: 153.2, r: 29.3 },
];
const MARK = { cx: 255.95, cy: 233.5, top: 75.8, bottom: 391.2, h: 315.4 };

// Place the mark so its bounding-box centre lands at (cx,cy) with a given
// pixel height; returns the SVG transform string.
function markXform(cx, cy, targetH) {
  const s = targetH / MARK.h;
  return `translate(${(cx - MARK.cx * s).toFixed(3)} ${(cy - MARK.cy * s).toFixed(3)}) scale(${s.toFixed(5)})`;
}
function barsMarkup(gradId) {
  return `<g fill="url(#${gradId})">` +
    BARS.map(b => `<rect x="${b.x}" y="${b.y}" width="${b.w}" height="${b.h}" rx="${b.r}" ry="${b.r}"/>`).join('') +
    `</g>`;
}
// One vertical sweep across the bars' span (userSpaceOnUse → shared across bars).
function barsGradient(id, top, bottom) {
  return `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="0" y1="${MARK.top}" x2="0" y2="${MARK.bottom}">` +
    `<stop offset="0" stop-color="${top}"/><stop offset="1" stop-color="${bottom}"/></linearGradient>`;
}

// ---------------------------------------------------------------------------
// Per-skin styling
//
// bgInner/bgOuter are the radial backdrop endpoints. Classic derives them from
// the canonical squircle gradient (#1C1730 → #100E18, see linthra_icon.svg),
// lifted a touch at the centre for radial depth; Community keeps a richer violet
// on purpose; Monochrome is strictly grey-black → pure black.
// tagOp/subOp let Monochrome build text hierarchy from *white at lower opacity*
// instead of grey, so its hue stays dogmatically black-and-white like the app's
// Black & White variant (lib/features/appearance/app_icon_variant.dart).
// ---------------------------------------------------------------------------
const SKINS = {
  classic: {
    label: 'Classic',
    barTop: C.brandBright, barBottom: C.accent,
    bgInner: '#1F1836', bgOuter: C.bgBottom,
    ring: C.brand, ringOpacity: 0.22,
    glowA: C.brandBright, glowB: C.accent,
    word: C.ink, tag: C.inkSoft, sub: C.inkMuted, tagOp: 1, subOp: 1,
    wave: C.brand, waveOpacity: 0.16,
  },
  mono: {
    label: 'Monochrome',
    barTop: '#FFFFFF', barBottom: '#FFFFFF',   // flat pure white, like the app's B&W mark
    bgInner: '#161618', bgOuter: '#000000',
    ring: '#FFFFFF', ringOpacity: 0.14,
    glowA: '#FFFFFF', glowB: '#FFFFFF',
    word: '#FFFFFF', tag: '#FFFFFF', sub: '#FFFFFF', tagOp: 0.82, subOp: 0.5,
    wave: '#FFFFFF', waveOpacity: 0.10,
  },
  community: {
    label: 'Community',
    barTop: C.brandBright, barBottom: C.accent,
    bgInner: '#1B1330', bgOuter: '#0C0A14',
    ring: C.accent, ringOpacity: 0.30,
    glowA: C.brand, glowB: C.accent,
    word: C.ink, tag: C.accentBright, sub: C.inkMuted, tagOp: 1, subOp: 1,
    wave: C.accent, waveOpacity: 0.20,
  },
};

// ---------------------------------------------------------------------------
// ICON — 512×512, designed for Reddit's circular community-icon crop
// ---------------------------------------------------------------------------
function icon(skinId) {
  const s = SKINS[skinId];
  const W = 512, c = 256;
  const markH = 232;
  const community = skinId === 'community';
  const mono = skinId === 'mono';
  const placedMark = `<g transform="${markXform(c, c, markH)}">${barsMarkup('barGrad')}</g>`;

  // Soft circular "vinyl" rings, concentric with Reddit's crop.
  const rings = community
    ? `<circle cx="${c}" cy="${c}" r="232" fill="none" stroke="url(#ringGrad)" stroke-width="3" stroke-opacity="0.55" stroke-dasharray="3 9" stroke-linecap="round"/>
       <circle cx="${c}" cy="${c}" r="214" fill="none" stroke="${s.ring}" stroke-width="1.5" stroke-opacity="0.18"/>`
    : `<circle cx="${c}" cy="${c}" r="230" fill="none" stroke="${s.ring}" stroke-width="2" stroke-opacity="${s.ringOpacity}"/>
       <circle cx="${c}" cy="${c}" r="210" fill="none" stroke="${s.ring}" stroke-width="1" stroke-opacity="${s.ringOpacity * 0.5}"/>`;

  // Background: radial lift in the centre, deep at the edges.
  const glows = community
    ? `<circle cx="150" cy="150" r="230" fill="url(#glowV)"/>
       <circle cx="372" cy="386" r="230" fill="url(#glowO)"/>`
    : mono
      ? `<circle cx="${c}" cy="232" r="190" fill="url(#glowV)"/>`
      : `<circle cx="${c}" cy="206" r="210" fill="url(#glowV)"/>
         <circle cx="${c}" cy="338" r="170" fill="url(#glowO)" opacity="0.7"/>`;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${W}" viewBox="0 0 ${W} ${W}">
  <defs>
    <radialGradient id="bg" cx="50%" cy="42%" r="72%">
      <stop offset="0" stop-color="${s.bgInner}"/>
      <stop offset="1" stop-color="${s.bgOuter}"/>
    </radialGradient>
    <radialGradient id="glowV" cx="50%" cy="50%" r="50%">
      <stop offset="0" stop-color="${s.glowA}" stop-opacity="${mono ? 0.10 : 0.34}"/>
      <stop offset="1" stop-color="${s.glowA}" stop-opacity="0"/>
    </radialGradient>
    ${mono ? '' : `<radialGradient id="glowO" cx="50%" cy="50%" r="50%">
      <stop offset="0" stop-color="${s.glowB}" stop-opacity="0.30"/>
      <stop offset="1" stop-color="${s.glowB}" stop-opacity="0"/>
    </radialGradient>`}
    ${community ? `<linearGradient id="ringGrad" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${C.brandBright}"/>
      <stop offset="1" stop-color="${C.accent}"/>
    </linearGradient>` : ''}
    ${barsGradient('barGrad', s.barTop, s.barBottom)}
    <filter id="soft" x="-40%" y="-40%" width="180%" height="180%">
      <feGaussianBlur stdDeviation="9"/>
    </filter>
  </defs>
  <rect width="${W}" height="${W}" fill="${s.bgOuter}"/>
  <circle cx="${c}" cy="${c}" r="256" fill="url(#bg)"/>
  ${glows}
  ${rings}
  <g filter="url(#soft)" opacity="${mono ? 0.45 : 0.7}">${placedMark}</g>
  ${placedMark}
</svg>`;
}

// ---------------------------------------------------------------------------
// Banner — 1920×384 (Reddit community banner). Content centred for mobile crop.
// ---------------------------------------------------------------------------
function spectrum(cx, baseline, totalW, opacity, color, seed) {
  // A faint full-width equalizer spectrum, fading at both edges.
  const n = 96, gap = totalW / n, bw = gap * 0.42, r = bw / 2;
  let bars = '';
  for (let i = 0; i < n; i++) {
    const t = i / (n - 1);
    // deterministic organic heights from summed sines
    const h = 10 + 54 * Math.abs(
      0.55 * Math.sin(i * 0.7 + seed) +
      0.30 * Math.sin(i * 0.27 + seed * 2.1) +
      0.22 * Math.sin(i * 1.9 + seed * 0.6));
    const x = cx - totalW / 2 + i * gap + (gap - bw) / 2;
    bars += `<rect x="${x.toFixed(1)}" y="${(baseline - h).toFixed(1)}" width="${bw.toFixed(1)}" height="${h.toFixed(1)}" rx="${r.toFixed(1)}"/>`;
  }
  return `<g fill="${color}" opacity="${opacity}" mask="url(#fade)">${bars}</g>`;
}

function banner(skinId, fontCss, wordW) {
  const s = SKINS[skinId];
  const W = 1920, H = 384, cx = W / 2;
  const mono = skinId === 'mono';
  const community = skinId === 'community';

  // Lockup: [mark] gap [wordmark], centred as a group, sitting above the taglines.
  const markH = 132, gap = 40;
  const lockupW = markH + gap + wordW;
  const lockupX = cx - lockupW / 2;
  const lockupCY = 146;                       // vertical centre of the lockup row
  const markCX = lockupX + markH / 2;
  const wordX = lockupX + markH + gap;        // left edge of wordmark text
  const wordBaseline = lockupCY + 38;         // optical baseline for 104px caps

  const tagY = 260, subY = 304;

  // Self-hosted / server motif: faint stacked "nodes" tucked at the edges
  // (these live in the mobile-crop zone, so they're decoration, never content).
  const nodeColor = community ? C.accent : s.ring;
  function nodes(ox, dir) {
    let g = '';
    for (let r = 0; r < 3; r++) {
      const y = 150 + r * 34;
      g += `<rect x="${ox}" y="${y}" width="116" height="20" rx="10" fill="none" stroke="${nodeColor}" stroke-width="1.4" stroke-opacity="0.5"/>`;
      g += `<circle cx="${ox + (dir > 0 ? 16 : 100)}" cy="${y + 10}" r="3.2" fill="${nodeColor}" fill-opacity="0.8"/>`;
    }
    return `<g opacity="0.5">${g}</g>`;
  }

  const glows = mono
    ? `<ellipse cx="${cx}" cy="170" rx="640" ry="240" fill="url(#glowV)"/>`
    : community
      ? `<ellipse cx="430" cy="150" rx="620" ry="300" fill="url(#glowV)"/>
         <ellipse cx="1500" cy="250" rx="620" ry="300" fill="url(#glowO)"/>`
      : `<ellipse cx="${cx}" cy="150" rx="760" ry="280" fill="url(#glowV)"/>
         <ellipse cx="${cx}" cy="360" rx="520" ry="200" fill="url(#glowO)" opacity="0.7"/>`;

  const underline = community
    ? `<rect x="${wordX}" y="${wordBaseline + 18}" width="${wordW}" height="4" rx="2" fill="url(#ulGrad)"/>`
    : '';

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <style>${fontCss}</style>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${s.bgInner}"/>
      <stop offset="1" stop-color="${s.bgOuter}"/>
    </linearGradient>
    <radialGradient id="glowV" cx="50%" cy="50%" r="50%">
      <stop offset="0" stop-color="${s.glowA}" stop-opacity="${mono ? 0.10 : 0.30}"/>
      <stop offset="1" stop-color="${s.glowA}" stop-opacity="0"/>
    </radialGradient>
    ${mono ? '' : `<radialGradient id="glowO" cx="50%" cy="50%" r="50%">
      <stop offset="0" stop-color="${s.glowB}" stop-opacity="0.26"/>
      <stop offset="1" stop-color="${s.glowB}" stop-opacity="0"/>
    </radialGradient>`}
    ${community ? `<linearGradient id="ulGrad" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="${C.brandBright}"/>
      <stop offset="1" stop-color="${C.accent}"/>
    </linearGradient>` : ''}
    ${barsGradient('barGrad', s.barTop, s.barBottom)}
    <linearGradient id="hair" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="${s.ring}" stop-opacity="0"/>
      <stop offset="0.5" stop-color="${s.ring}" stop-opacity="${community ? 0.5 : 0.32}"/>
      <stop offset="1" stop-color="${s.ring}" stop-opacity="0"/>
    </linearGradient>
    <mask id="fade">
      <linearGradient id="fadeGrad" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0" stop-color="#000"/>
        <stop offset="0.30" stop-color="#fff"/>
        <stop offset="0.70" stop-color="#fff"/>
        <stop offset="1" stop-color="#000"/>
      </linearGradient>
      <rect width="${W}" height="${H}" fill="url(#fadeGrad)"/>
    </mask>
  </defs>
  <rect width="${W}" height="${H}" fill="${s.bgOuter}"/>
  <rect width="${W}" height="${H}" fill="url(#bg)"/>
  ${glows}
  ${spectrum(cx, 384, W * 1.05, s.waveOpacity, s.wave, 1.3)}
  ${nodes(150, +1)}
  ${nodes(1654, -1)}
  <rect x="${cx - 470}" y="${tagY - 30}" width="940" height="1" fill="url(#hair)"/>
  <g transform="${markXform(markCX, lockupCY, markH)}">${barsMarkup('barGrad')}</g>
  <text x="${wordX}" y="${wordBaseline}" font-family="'Space Grotesk'" font-weight="600" font-size="104" letter-spacing="-2" fill="${s.word}">Linthra</text>
  ${underline}
  <text x="${cx}" y="${tagY}" text-anchor="middle" font-family="Inter" font-weight="500" font-size="33" letter-spacing="0.3" fill="${s.tag}" fill-opacity="${s.tagOp}">Your music, beautifully yours.</text>
  <text x="${cx}" y="${subY}" text-anchor="middle" font-family="Inter" font-weight="400" font-size="20" letter-spacing="0.2" fill="${s.sub}" fill-opacity="${s.subOp}">Open-source music player for Jellyfin, Plex, Navidrome/Subsonic, and local music.</text>
</svg>`;
}

// ---------------------------------------------------------------------------
// Fonts (embedded base64) + render pipeline
// ---------------------------------------------------------------------------
function fontFace(family, file, range) {
  const b64 = readFileSync(path.join(FONT_DIR, file)).toString('base64');
  return `@font-face{font-family:'${family}';font-style:normal;font-weight:${range};` +
    `src:url(data:font/woff2;base64,${b64}) format('woff2');}`;
}
const FONT_CSS =
  fontFace('Inter', 'Inter-variable.woff2', '100 900') +
  fontFace('Space Grotesk', 'SpaceGrotesk-variable.woff2', '300 700');

async function measureWordmark(page) {
  await page.setContent(`<!doctype html><html><head><style>${FONT_CSS}
    body{margin:0}#w{position:absolute;font-family:'Space Grotesk';font-weight:600;font-size:104px;letter-spacing:-2px;white-space:nowrap}</style></head>
    <body><span id="w">Linthra</span></body></html>`);
  await page.evaluate(() => document.fonts.ready);
  return await page.evaluate(() => document.getElementById('w').getBoundingClientRect().width);
}

async function render(page, svg, w, h, file) {
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0}</style></head><body>${svg}</body></html>`;
  await page.setViewportSize({ width: w, height: h });
  await page.setContent(html, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  writeFileSync(path.join(OUT, file.replace(/\.png$/, '.svg')), svg);
  await page.screenshot({ path: path.join(OUT, file), clip: { x: 0, y: 0, width: w, height: h } });
  console.log('wrote', file);
}

const browser = await chromium.launch();
const page = await browser.newPage({ deviceScaleFactor: 1 });
const wordW = await measureWordmark(page);
console.log('wordmark width =', wordW.toFixed(1));

for (const id of ['classic', 'mono', 'community']) {
  await render(page, icon(id), 512, 512, `linthra-reddit-icon-${id}.png`);
  await render(page, banner(id, FONT_CSS, wordW), 1920, 384, `linthra-reddit-banner-${id}.png`);
}
await browser.close();
console.log('done →', OUT);
