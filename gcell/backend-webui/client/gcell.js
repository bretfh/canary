// gcell WebGL2 client.
//
// Mounts a fullscreen canvas, builds a font atlas in a hidden 2D
// canvas, uploads it as a texture, and renders the server-pushed cell
// grid as a single instanced draw call per frame.  Input events are
// shipped back through webui.call('input', json).
//
// The server pushes binary frames via webui_send_raw, which webui's
// bridge delivers as a call to window.gcellFrame with a Uint8Array.

const MAGIC = 0x4C454347; // "GCEL" little-endian.
const HEADER_SIZE = 16;
const CELL_SIZE   = 13;

// Frame layout (matches encode-frame in gcell/backend-webui.scm):
//   u32 magic 0..3
//   u8  version 4   (v4 adds delta frames)
//   u8  frame_type 5  (0=full grid, 1=delta from previous frame)
//   u16 width 6..7
//   u16 height 8..9
//   u16 cursor_col 10..11
//   u16 cursor_row 12..13
//   u8  cursor_style (0=hidden, 1=block, 2=underline, 3=bar) 14
//   u8  cursor_attrs (bit 0 blink) 15
//
// Cell section depends on frame_type:
//   full:  width*height * 13 bytes (u32 cp, u32 fg, u32 bg, u8 attrs)
//   delta: u32 count + count entries of (u32 cell_index, 13 bytes)
//
// Hyperlink overlay (v2+) and image-placement overlay (v3+) follow.

const FONT_PX = 16;
const CELL_W  = 9;
const CELL_H  = 18;
const ATLAS_COLS = 16;
const ATLAS_ROWS = 16;

const canvas = document.getElementById('cv');
const gl = canvas.getContext('webgl2', { antialias: false, premultipliedAlpha: false });
if (!gl) throw new Error('webgl2 required');

// ---- Atlas: three font weights (regular / bold / italic) rasterised
// into separate hidden 2D canvases, uploaded together as a WebGL 2
// sampler2DArray texture.  The shader picks a layer per cell based on
// the bold/italic attr bits.

const ATLAS_LAYERS = 3;
const LAYER_REGULAR = 0;
const LAYER_BOLD    = 1;
const LAYER_ITALIC  = 2;
const LAYER_FONTS = ['', 'bold ', 'italic '];

const atlasCanvases = [];
const atlasCtxs = [];
for (let i = 0; i < ATLAS_LAYERS; i++) {
  const c = document.createElement('canvas');
  c.width  = ATLAS_COLS * CELL_W;
  c.height = ATLAS_ROWS * CELL_H;
  const ctx = c.getContext('2d');
  ctx.imageSmoothingEnabled = false;
  atlasCanvases.push(c);
  atlasCtxs.push(ctx);
}

const atlasMap = new Map(); // codepoint -> slot (shared across layers)
let nextSlot = 0;
let atlasDirty = true;

function rasteriseGlyph(cp, slot) {
  const x = (slot % ATLAS_COLS) * CELL_W;
  const y = Math.floor(slot / ATLAS_COLS) * CELL_H;
  for (let i = 0; i < ATLAS_LAYERS; i++) {
    const actx = atlasCtxs[i];
    actx.fillStyle = '#000';
    actx.fillRect(x, y, CELL_W, CELL_H);
    actx.fillStyle = '#fff';
    actx.font = `${LAYER_FONTS[i]}${FONT_PX}px monospace`;
    actx.textBaseline = 'top';
    actx.fillText(String.fromCodePoint(cp || 32), x, y);
  }
}

function atlasIndexFor(cp) {
  const safe = cp || 32;
  let slot = atlasMap.get(safe);
  if (slot !== undefined) return slot;
  if (nextSlot >= ATLAS_COLS * ATLAS_ROWS) return atlasMap.get(63) || 0; // '?'
  slot = nextSlot++;
  atlasMap.set(safe, slot);
  rasteriseGlyph(safe, slot);
  atlasDirty = true;
  return slot;
}

// Pre-rasterise printable ASCII into every layer.
for (let cp = 32; cp < 127; cp++) atlasIndexFor(cp);

const atlasTex = gl.createTexture();
gl.activeTexture(gl.TEXTURE0);
gl.bindTexture(gl.TEXTURE_2D_ARRAY, atlasTex);
gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
// Immutable storage so we don't keep allocating per upload.
gl.texStorage3D(gl.TEXTURE_2D_ARRAY, 1, gl.RGBA8,
                ATLAS_COLS * CELL_W, ATLAS_ROWS * CELL_H, ATLAS_LAYERS);

function syncAtlas() {
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D_ARRAY, atlasTex);
  for (let i = 0; i < ATLAS_LAYERS; i++) {
    gl.texSubImage3D(gl.TEXTURE_2D_ARRAY, 0,
                     0, 0, i,
                     ATLAS_COLS * CELL_W, ATLAS_ROWS * CELL_H, 1,
                     gl.RGBA, gl.UNSIGNED_BYTE, atlasCanvases[i]);
  }
  atlasDirty = false;
}
syncAtlas();

// ---- Cell shaders + program.
//
// Vertex stage maps gl_InstanceID to grid (col, row).  Fragment stage
// samples the atlas, mixes fg/bg by alpha, and applies the per-cell
// attribute bits: inverse swaps fg/bg, faint dims fg, underline /
// strikethrough draw a band in the cell's lower or middle strip.

const VS = `#version 300 es
in vec2 a_quad;
in vec2 a_cell;
in float a_glyph;
in vec4 a_fg;
in vec4 a_bg;
in float a_attrs;       // float because gl.vertexAttribPointer wants float types
uniform vec2 u_cellSize;
uniform vec2 u_viewport;
uniform vec2 u_atlasCells;
out vec2 v_uv;
out vec2 v_cellUv;       // 0..1 within the cell, for underline/strikethrough bands
out vec4 v_fg;
out vec4 v_bg;
flat out float v_attrs;
void main() {
  vec2 px = (a_cell + a_quad) * u_cellSize;
  vec2 ndc = (px / u_viewport) * 2.0 - 1.0;
  ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
  float slot = a_glyph;
  vec2 atlasIdx = vec2(mod(slot, u_atlasCells.x), floor(slot / u_atlasCells.x));
  v_uv = (atlasIdx + a_quad) / u_atlasCells;
  v_cellUv = a_quad;
  v_fg = a_fg;
  v_bg = a_bg;
  v_attrs = a_attrs;
}`;

const FS = `#version 300 es
precision mediump float;
uniform mediump sampler2DArray u_atlas;
in vec2 v_uv;
in vec2 v_cellUv;
in vec4 v_fg;
in vec4 v_bg;
flat in float v_attrs;
out vec4 fragColor;

bool hasAttr(float attrs, float bit) {
  float v = floor(attrs / bit);
  return mod(v, 2.0) >= 1.0;
}

void main() {
  bool bold    = hasAttr(v_attrs, 1.0);
  bool italic  = hasAttr(v_attrs, 2.0);
  bool ulined  = hasAttr(v_attrs, 4.0);
  bool inverse = hasAttr(v_attrs, 8.0);
  bool struck  = hasAttr(v_attrs, 16.0);
  bool faint   = hasAttr(v_attrs, 32.0);

  // Atlas layer: 0 regular, 1 bold, 2 italic.  Bold wins over italic
  // when both flags are set; we don't carry a bold-italic layer yet.
  float layer = bold ? 1.0 : (italic ? 2.0 : 0.0);

  vec4 fg = v_fg;
  vec4 bg = v_bg;
  if (inverse) { vec4 t = fg; fg = bg; bg = t; }
  if (faint)   { fg = vec4(fg.rgb * 0.6, fg.a); }

  float a = texture(u_atlas, vec3(v_uv, layer)).r;
  vec4 col = mix(bg, fg, a);

  // Underline: lower ~12% of cell.
  if (ulined && v_cellUv.y > 0.88) col = fg;
  // Strikethrough: middle ~8% band.
  if (struck && v_cellUv.y > 0.46 && v_cellUv.y < 0.54) col = fg;

  fragColor = col;
}`;

function compile(type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(s) || 'shader compile failed');
  }
  return s;
}

const program = gl.createProgram();
gl.attachShader(program, compile(gl.VERTEX_SHADER,   VS));
gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FS));
gl.linkProgram(program);
if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
  throw new Error(gl.getProgramInfoLog(program) || 'program link failed');
}
gl.useProgram(program);

const uCellSize   = gl.getUniformLocation(program, 'u_cellSize');
const uViewport   = gl.getUniformLocation(program, 'u_viewport');
const uAtlasCells = gl.getUniformLocation(program, 'u_atlasCells');
const uAtlas      = gl.getUniformLocation(program, 'u_atlas');

gl.uniform2f(uCellSize,   CELL_W, CELL_H);
gl.uniform2f(uAtlasCells, ATLAS_COLS, ATLAS_ROWS);
gl.uniform1i(uAtlas, 0);

// ---- Geometry: one quad, instanced per cell.

const quadBuf = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
gl.bufferData(gl.ARRAY_BUFFER,
              new Float32Array([0,0, 1,0, 0,1, 0,1, 1,0, 1,1]),
              gl.STATIC_DRAW);

const aQuad  = gl.getAttribLocation(program, 'a_quad');
const aCell  = gl.getAttribLocation(program, 'a_cell');
const aGlyph = gl.getAttribLocation(program, 'a_glyph');
const aFg    = gl.getAttribLocation(program, 'a_fg');
const aBg    = gl.getAttribLocation(program, 'a_bg');
const aAttrs = gl.getAttribLocation(program, 'a_attrs');

const vao = gl.createVertexArray();
gl.bindVertexArray(vao);

gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
gl.enableVertexAttribArray(aQuad);
gl.vertexAttribPointer(aQuad, 2, gl.FLOAT, false, 0, 0);

const cellsBuf = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, cellsBuf);
// Per cell: 2 cell + 1 glyph + 4 fg + 4 bg + 1 attrs = 12 floats.
const FLOATS_PER_CELL = 12;
const cellStride = FLOATS_PER_CELL * 4;
gl.enableVertexAttribArray(aCell);
gl.vertexAttribPointer(aCell, 2, gl.FLOAT, false, cellStride, 0);
gl.vertexAttribDivisor(aCell, 1);
gl.enableVertexAttribArray(aGlyph);
gl.vertexAttribPointer(aGlyph, 1, gl.FLOAT, false, cellStride, 8);
gl.vertexAttribDivisor(aGlyph, 1);
gl.enableVertexAttribArray(aFg);
gl.vertexAttribPointer(aFg, 4, gl.FLOAT, false, cellStride, 12);
gl.vertexAttribDivisor(aFg, 1);
gl.enableVertexAttribArray(aBg);
gl.vertexAttribPointer(aBg, 4, gl.FLOAT, false, cellStride, 28);
gl.vertexAttribDivisor(aBg, 1);
gl.enableVertexAttribArray(aAttrs);
gl.vertexAttribPointer(aAttrs, 1, gl.FLOAT, false, cellStride, 44);
gl.vertexAttribDivisor(aAttrs, 1);

// ---- Cursor pass: one quad, no instancing, driven by uniforms.
//
// Shares the atlas-shader's uniform block (cellSize, viewport) but
// uses its own program that paints a solid colour with a style mask
// (block, underline, bar).  Drawn after the cells so it overlays.

const cursorVS = `#version 300 es
in vec2 a_quad;
uniform vec2 u_cursorCell;
uniform vec2 u_cellSize;
uniform vec2 u_viewport;
out vec2 v_q;
void main() {
  vec2 px = (u_cursorCell + a_quad) * u_cellSize;
  vec2 ndc = (px / u_viewport) * 2.0 - 1.0;
  ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
  v_q = a_quad;
}`;

const cursorFS = `#version 300 es
precision mediump float;
uniform int u_cursorStyle;     // 1 block, 2 underline, 3 bar
uniform float u_cursorAlpha;   // 0..1; client animates for blink
uniform vec4 u_cursorColor;
in vec2 v_q;
out vec4 fragColor;
void main() {
  bool draw = false;
  if (u_cursorStyle == 1) draw = true;
  else if (u_cursorStyle == 2) draw = v_q.y > 0.86;
  else if (u_cursorStyle == 3) draw = v_q.x < 0.12;
  if (!draw) discard;
  fragColor = vec4(u_cursorColor.rgb, u_cursorColor.a * u_cursorAlpha);
}`;

const cursorProgram = gl.createProgram();
gl.attachShader(cursorProgram, compile(gl.VERTEX_SHADER,   cursorVS));
gl.attachShader(cursorProgram, compile(gl.FRAGMENT_SHADER, cursorFS));
gl.linkProgram(cursorProgram);
if (!gl.getProgramParameter(cursorProgram, gl.LINK_STATUS)) {
  throw new Error(gl.getProgramInfoLog(cursorProgram) || 'cursor link failed');
}

const cuCell      = gl.getUniformLocation(cursorProgram, 'u_cursorCell');
const cuCellSize  = gl.getUniformLocation(cursorProgram, 'u_cellSize');
const cuViewport  = gl.getUniformLocation(cursorProgram, 'u_viewport');
const cuStyle     = gl.getUniformLocation(cursorProgram, 'u_cursorStyle');
const cuAlpha     = gl.getUniformLocation(cursorProgram, 'u_cursorAlpha');
const cuColor     = gl.getUniformLocation(cursorProgram, 'u_cursorColor');
const cuQuadLoc   = gl.getAttribLocation(cursorProgram, 'a_quad');

const cursorVao = gl.createVertexArray();
gl.bindVertexArray(cursorVao);
gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
gl.enableVertexAttribArray(cuQuadLoc);
gl.vertexAttribPointer(cuQuadLoc, 2, gl.FLOAT, false, 0, 0);

gl.bindVertexArray(vao);

// ---- Frame application

let cellsArray = new Float32Array(0);
let cellCount = 0;
let gridW = 0;
let gridH = 0;
let cursorCol = 0;
let cursorRow = 0;
let cursorStyle = 1;
let cursorBlink = false;

const DEFAULT_FG = [0.9, 0.9, 0.9, 1.0];
const DEFAULT_BG = [0.0, 0.0, 0.0, 1.0];

function unpackColor(packed, out, off, fallback) {
  if (packed === 0xFFFFFFFF) {
    out[off]   = fallback[0];
    out[off+1] = fallback[1];
    out[off+2] = fallback[2];
    out[off+3] = fallback[3];
  } else {
    out[off]   = ((packed >> 16) & 0xFF) / 255;
    out[off+1] = ((packed >>  8) & 0xFF) / 255;
    out[off+2] = ((packed >>  0) & 0xFF) / 255;
    out[off+3] = 1.0;
  }
}

// Per-frame (col,row) → URL hit-test map for OSC-8 hyperlinks.
// Rebuilt from the trailing overlay section each frame; rare to be
// large.
const hyperlinks = new Map();
function linkKey(col, row) { return (row << 16) | col; }

const utf8Decoder = new TextDecoder('utf-8');

function writeCellSlot(idx, w, cp, fg, bg, attrs) {
  const col = idx % w;
  const row = (idx - col) / w;
  let p = idx * FLOATS_PER_CELL;
  cellsArray[p++] = col;
  cellsArray[p++] = row;
  cellsArray[p++] = atlasIndexFor(cp);
  unpackColor(fg, cellsArray, p, DEFAULT_FG); p += 4;
  unpackColor(bg, cellsArray, p, DEFAULT_BG); p += 4;
  cellsArray[p++] = attrs;
}

function applyFrame(buf) {
  const u8 = (buf instanceof Uint8Array) ? buf : new Uint8Array(buf);
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  if (dv.getUint32(0, true) !== MAGIC) return;
  // version & frame_type.  v1 cells only; v2 hyperlinks overlay;
  // v3 image-placement overlay; v4 byte 5 carries frame_type
  // (0 full, 1 delta).
  const version   = dv.getUint8(4);
  const frameType = (version >= 4) ? dv.getUint8(5) : 0;
  const w = dv.getUint16(6, true);
  const h = dv.getUint16(8, true);
  cursorCol   = dv.getUint16(10, true);
  cursorRow   = dv.getUint16(12, true);
  cursorStyle = dv.getUint8(14);
  cursorBlink = (dv.getUint8(15) & 1) !== 0;
  const total = w * h;
  if (cellsArray.length !== total * FLOATS_PER_CELL) {
    // Grid resized: any cells we had are stale and the delta we just
    // received (if any) can't be applied to a fresh array.  The server
    // clears its cache on resize so the next frame should be full --
    // until then we paint what we can.
    cellsArray = new Float32Array(total * FLOATS_PER_CELL);
  }
  gridW = w; gridH = h;
  let cellsEnd;
  if (frameType === 1) {
    const deltaCount = dv.getUint32(HEADER_SIZE, true);
    let off = HEADER_SIZE + 4;
    for (let i = 0; i < deltaCount; i++) {
      const idx   = dv.getUint32(off,       true);
      const cp    = dv.getUint32(off +  4,  true);
      const fg    = dv.getUint32(off +  8,  true);
      const bg    = dv.getUint32(off + 12,  true);
      const attrs = dv.getUint8 (off + 16);
      writeCellSlot(idx, w, cp, fg, bg, attrs);
      off += 17;
    }
    cellsEnd = off;
  } else {
    for (let i = 0; i < total; i++) {
      const off   = HEADER_SIZE + i * CELL_SIZE;
      const cp    = dv.getUint32(off,     true);
      const fg    = dv.getUint32(off + 4, true);
      const bg    = dv.getUint32(off + 8, true);
      const attrs = dv.getUint8 (off + 12);
      writeCellSlot(i, w, cp, fg, bg, attrs);
    }
    cellsEnd = HEADER_SIZE + total * CELL_SIZE;
  }
  cellCount = total;

  // Hyperlink overlay (v2+).  Each entry: u16 col, u16 row, u16 len,
  // <len> utf-8 bytes.  Clear the previous map so links that left the
  // frame stop hit-testing.
  hyperlinks.clear();
  let overlayOff = cellsEnd;
  if (version >= 2 && u8.byteLength >= overlayOff + 2) {
    const linkCount = dv.getUint16(overlayOff, true);
    let off = overlayOff + 2;
    for (let i = 0; i < linkCount; i++) {
      const col  = dv.getUint16(off, true);
      const row  = dv.getUint16(off + 2, true);
      const len  = dv.getUint16(off + 4, true);
      const url  = utf8Decoder.decode(u8.subarray(off + 6, off + 6 + len));
      hyperlinks.set(linkKey(col, row), url);
      off += 6 + len;
    }
    overlayOff = off;
  }

  // Image-placement overlay (v3+).  Entry: u32 id, u16 col, u16 row,
  // u16 w, u16 h, u16 sx, u16 sy, u16 sw, u16 sh.  20 bytes each.
  imagesPlaced = [];
  if (version >= 3 && u8.byteLength >= overlayOff + 2) {
    const imgCount = dv.getUint16(overlayOff, true);
    let off = overlayOff + 2;
    for (let i = 0; i < imgCount; i++) {
      imagesPlaced.push({
        id:  dv.getUint32(off,       true),
        col: dv.getUint16(off +  4,  true),
        row: dv.getUint16(off +  6,  true),
        w:   dv.getUint16(off +  8,  true),
        h:   dv.getUint16(off + 10,  true),
        sx:  dv.getUint16(off + 12,  true),
        sy:  dv.getUint16(off + 14,  true),
        sw:  dv.getUint16(off + 16,  true),
        sh:  dv.getUint16(off + 18,  true),
      });
      off += 20;
    }
  }

  if (atlasDirty) syncAtlas();
  gl.bindBuffer(gl.ARRAY_BUFFER, cellsBuf);
  gl.bufferData(gl.ARRAY_BUFFER, cellsArray, gl.STREAM_DRAW);
  draw();
}

function cursorAlpha() {
  // Solid by default; clients with blink hint pulse via sin().
  if (!cursorBlink) return 1.0;
  const t = (performance.now() % 1000) / 1000;
  return 0.5 + 0.5 * Math.cos(t * 2 * Math.PI);
}

function draw() {
  gl.viewport(0, 0, canvas.width, canvas.height);
  gl.uniform2f(uViewport, canvas.width, canvas.height);
  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  if (cellCount > 0) {
    gl.useProgram(program);
    gl.bindVertexArray(vao);
    gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, cellCount);
  }
  drawImagePlacements();
  if (cursorStyle !== 0) {
    gl.useProgram(cursorProgram);
    gl.bindVertexArray(cursorVao);
    gl.uniform2f(cuCellSize, CELL_W, CELL_H);
    gl.uniform2f(cuViewport, canvas.width, canvas.height);
    gl.uniform2f(cuCell, cursorCol, cursorRow);
    gl.uniform1i(cuStyle, cursorStyle);
    gl.uniform1f(cuAlpha, cursorAlpha());
    gl.uniform4f(cuColor, 0.9, 0.9, 0.9, 0.5);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    gl.disable(gl.BLEND);
    gl.bindVertexArray(vao);
  }
}

// Keep the cursor blink animation going even when the server hasn't
// pushed a new frame.  Cheap (single quad), harmless.
function tickCursor() {
  if (cursorBlink && cursorStyle !== 0) draw();
  requestAnimationFrame(tickCursor);
}
requestAnimationFrame(tickCursor);

// ---- Outbound shape.

function send(type, extra) {
  if (!window.webui) return;
  // sent_ms is Date.now() (unix epoch ms) so the server's gettimeofday
  // sees the same epoch; otherwise the comparison is meaningless.
  // performance.now() is monotonic-from-navigation, do NOT use it here.
  const payload = Object.assign({ type, sent_ms: Date.now() }, extra);
  webui.call('input', JSON.stringify(payload));
}

// Browser-side diagnostics travel through the same input bind tagged
// type="log".  The server routes them into gcell's engine-log!, and
// the existing log overlay surfaces them on the cell grid -- no F12
// required, no parallel debug channel.

function shipLog(level, text) {
  send('log', { level, text });
}

window.addEventListener('error', e => {
  const where = e.filename ? `${e.filename}:${e.lineno}:${e.colno} ` : '';
  shipLog('error', `${where}${e.message || e.error || 'unknown error'}`);
});

window.addEventListener('unhandledrejection', e => {
  const r = e.reason;
  const text = r && r.stack ? r.stack : (r && r.message ? r.message : String(r));
  shipLog('error', `unhandled rejection: ${text}`);
});

(function wrapConsole() {
  const wrap = (orig, level) => function (...args) {
    try {
      const text = args.map(a =>
        a instanceof Error ? (a.stack || a.message)
        : (typeof a === 'object' ? JSON.stringify(a) : String(a))).join(' ');
      shipLog(level, text);
    } catch (_) { /* never let logging crash logging */ }
    return orig.apply(console, args);
  };
  console.error = wrap(console.error.bind(console), 'error');
  console.warn  = wrap(console.warn .bind(console), 'warn');
  console.info  = wrap(console.info .bind(console), 'info');
})();

function onResize() {
  const dpr = window.devicePixelRatio || 1;
  canvas.width  = Math.floor(window.innerWidth  * dpr);
  canvas.height = Math.floor(window.innerHeight * dpr);
  const cols = Math.max(20, Math.floor(canvas.width  / CELL_W));
  const rows = Math.max(5,  Math.floor(canvas.height / CELL_H));
  send('resize', { width: cols, height: rows });
  draw();
}

window.addEventListener('resize', onResize);

// ---- Input

function keySym(e) {
  // Single-char printables go through as their own symbol; longer
  // names (Enter, ArrowLeft, ...) come back lowercased.
  if (e.key.length === 1) return e.key;
  const k = e.key.toLowerCase();
  // Map a few DOM names to gcell's conventions.
  if (k === 'arrowleft')  return 'left';
  if (k === 'arrowright') return 'right';
  if (k === 'arrowup')    return 'up';
  if (k === 'arrowdown')  return 'down';
  return k;
}

document.addEventListener('keydown', (e) => {
  const mods = [];
  if (e.ctrlKey)  mods.push('control');
  if (e.shiftKey) mods.push('shift');
  if (e.altKey)   mods.push('alt');
  if (e.metaKey)  mods.push('meta');
  send('key', { sym: keySym(e), mods: mods.join(',') });
  // Block browser-default shortcuts that interfere with the app
  // (Tab, arrow scroll, etc.).
  if (e.key === 'Tab' || e.key.startsWith('Arrow')) e.preventDefault();
});

function cellPosFromMouseEvent(e) {
  const rect = canvas.getBoundingClientRect();
  const cssX = e.clientX - rect.left;
  const cssY = e.clientY - rect.top;
  const dpr = window.devicePixelRatio || 1;
  return {
    x: Math.floor((cssX * dpr) / CELL_W),
    y: Math.floor((cssY * dpr) / CELL_H),
  };
}

const MOUSE_BTNS = ['left', 'middle', 'right'];

let mouseHeld = 'none';   // currently-held button for drag tracking.
let lastMove = { x: -1, y: -1, ts: 0 };

canvas.addEventListener('mousedown', (e) => {
  const { x, y } = cellPosFromMouseEvent(e);
  mouseHeld = MOUSE_BTNS[e.button] || 'left';
  // OSC-8 hyperlinks: a left-click on a linked cell opens the URL
  // in a new tab and skips the gcell input shipment, matching the
  // behaviour terminals adopt for OSC-8 (clicks are claimed by the
  // link layer).
  if (mouseHeld === 'left') {
    const url = hyperlinks.get(linkKey(x, y));
    if (url) {
      window.open(url, '_blank', 'noopener,noreferrer');
      mouseHeld = 'none';
      return;
    }
  }
  send('mouse', { x, y, button: mouseHeld, action: 'press' });
});

canvas.addEventListener('mouseup', (e) => {
  const { x, y } = cellPosFromMouseEvent(e);
  const btn = MOUSE_BTNS[e.button] || 'left';
  send('mouse', { x, y, button: btn, action: 'release' });
  mouseHeld = 'none';
});

canvas.addEventListener('mousemove', (e) => {
  const { x, y } = cellPosFromMouseEvent(e);
  // Hover affordance for hyperlinks: switch the cursor to pointer
  // when over a linked cell, default otherwise.
  canvas.style.cursor = hyperlinks.has(linkKey(x, y)) ? 'pointer' : 'default';
  const now = performance.now();
  // Coalesce moves to ~60 Hz AND to actual cell-position changes.
  // gcell's input loop does the same throttle for ANSI mouse events.
  if (x === lastMove.x && y === lastMove.y) return;
  if (now - lastMove.ts < 16) return;
  lastMove = { x, y, ts: now };
  send('mouse', { x, y, button: mouseHeld, action: 'move' });
});

canvas.addEventListener('wheel', (e) => {
  const { x, y } = cellPosFromMouseEvent(e);
  send('mouse', {
    x, y,
    button: 'none',
    action: e.deltaY < 0 ? 'scroll-up' : 'scroll-down',
  });
  e.preventDefault();
}, { passive: false });

canvas.addEventListener('contextmenu', (e) => e.preventDefault());

// Clipboard read: the browser raises a `paste` event on document when
// the user fires it (Ctrl-V or middle-click).  We pull the text and
// ship it as gcell's <paste> protocol msg.
document.addEventListener('paste', (e) => {
  if (!e.clipboardData) return;
  const text = e.clipboardData.getData('text/plain');
  if (text) send('paste', { text });
});

// ---- Image cache.
//
// gcellImage receives PNG/JPEG bytes via webui_send_raw:
//   u32 image_id  u32 length  raw_bytes
// We decode via createImageBitmap (browser does it off-thread),
// upload as a WebGL texture, and stash in the cache keyed by id.

const imageCache = new Map(); // id -> { tex, w, h }
let imagesPlaced = [];        // current frame's placements

function uploadImageBitmap(id, bitmap) {
  const tex = gl.createTexture();
  gl.activeTexture(gl.TEXTURE1);
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
  imageCache.set(id, { tex, w: bitmap.width, h: bitmap.height });
  // Trigger a redraw -- the placements from the most recent frame
  // were waiting on this texture to land.
  draw();
}

window.gcellImage = function (buf) {
  const u8 = (buf instanceof Uint8Array) ? buf : new Uint8Array(buf);
  if (u8.byteLength < 8) return;
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  const id = dv.getUint32(0, true);
  const len = dv.getUint32(4, true);
  if (u8.byteLength < 8 + len) return;
  const blob = new Blob([u8.subarray(8, 8 + len)]);
  createImageBitmap(blob)
    .then(bitmap => uploadImageBitmap(id, bitmap))
    .catch(err => shipLog('error', `image ${id} decode: ${err}`));
};

// Image-draw program: textured quads laid over the cell grid.

const imageVS = `#version 300 es
in vec2 a_quad;
uniform vec2 a_pos;      // top-left in cells
uniform vec2 a_size;     // w,h in cells
uniform vec4 a_uvRect;   // src x,y,w,h in 0..1 of source texture
uniform vec2 u_cellSize;
uniform vec2 u_viewport;
out vec2 v_uv;
void main() {
  vec2 px = (a_pos + a_quad * a_size) * u_cellSize;
  vec2 ndc = (px / u_viewport) * 2.0 - 1.0;
  ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
  v_uv = a_uvRect.xy + a_quad * a_uvRect.zw;
}`;

const imageFS = `#version 300 es
precision mediump float;
uniform sampler2D u_img;
in vec2 v_uv;
out vec4 fragColor;
void main() {
  fragColor = texture(u_img, v_uv);
}`;

const imageProgram = gl.createProgram();
gl.attachShader(imageProgram, compile(gl.VERTEX_SHADER,   imageVS));
gl.attachShader(imageProgram, compile(gl.FRAGMENT_SHADER, imageFS));
gl.linkProgram(imageProgram);
if (!gl.getProgramParameter(imageProgram, gl.LINK_STATUS)) {
  throw new Error(gl.getProgramInfoLog(imageProgram) || 'image link failed');
}

const iuPos      = gl.getUniformLocation(imageProgram, 'a_pos');
const iuSize     = gl.getUniformLocation(imageProgram, 'a_size');
const iuUv       = gl.getUniformLocation(imageProgram, 'a_uvRect');
const iuCellSize = gl.getUniformLocation(imageProgram, 'u_cellSize');
const iuViewport = gl.getUniformLocation(imageProgram, 'u_viewport');
const iuImg      = gl.getUniformLocation(imageProgram, 'u_img');
const iaQuadLoc  = gl.getAttribLocation(imageProgram, 'a_quad');

const imageVao = gl.createVertexArray();
gl.bindVertexArray(imageVao);
gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
gl.enableVertexAttribArray(iaQuadLoc);
gl.vertexAttribPointer(iaQuadLoc, 2, gl.FLOAT, false, 0, 0);

gl.bindVertexArray(vao);

function drawImagePlacements() {
  if (imagesPlaced.length === 0) return;
  gl.useProgram(imageProgram);
  gl.bindVertexArray(imageVao);
  gl.uniform2f(iuCellSize, CELL_W, CELL_H);
  gl.uniform2f(iuViewport, canvas.width, canvas.height);
  gl.uniform1i(iuImg, 1);
  gl.activeTexture(gl.TEXTURE1);
  for (const p of imagesPlaced) {
    const entry = imageCache.get(p.id);
    if (!entry) continue;  // bytes still in flight; skip until decoded
    gl.bindTexture(gl.TEXTURE_2D, entry.tex);
    gl.uniform2f(iuPos,  p.col, p.row);
    gl.uniform2f(iuSize, p.w,   p.h);
    // src-x/y/w/h come from the server in pixel coords against the
    // source image; normalise here using the cached bitmap size.
    gl.uniform4f(iuUv,
                 p.sx / entry.w, p.sy / entry.h,
                 p.sw / entry.w, p.sh / entry.h);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }
  gl.bindVertexArray(vao);
}

// ---- Receive frames pushed by the server.
//
// webui_send_raw(window, "gcellFrame", bytes) routes through the
// bridge to a call on window.gcellFrame in the browser.
window.gcellFrame = applyFrame;

// ---- Boot
//
// Wait until webui.js has finished negotiating the WebSocket before
// we announce our initial size; otherwise the server gets a resize
// before it's accepted any binds.

function whenWebuiReady(cb) {
  if (window.webui && window.webui.isConnected && window.webui.isConnected()) {
    cb();
    return;
  }
  // Older webui.js builds expose `webui.event`, an EventTarget that
  // fires 'connected' when the WS handshake completes.  Newer builds
  // expose `webui.onConnect(fn)`.  Fall back to polling isConnected.
  if (window.webui) {
    if (typeof webui.onConnect === 'function') {
      webui.onConnect(cb);
      return;
    }
    if (webui.event && typeof webui.event.addEventListener === 'function') {
      webui.event.addEventListener('connected', cb, { once: true });
      return;
    }
  }
  setTimeout(() => whenWebuiReady(cb), 32);
}

whenWebuiReady(() => onResize());
