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

// One coordinate system everywhere: CSS pixels.  Canvas backing
// equals canvas display equals window inner size.  No DPR
// multiplication anywhere -- DPR drifts between window states on
// some compositors and any place that touched it would silently
// rescale.  The atlas is rasterised at a 2x oversampling so glyphs
// have enough source resolution; LINEAR atlas filter downsamples
// to the shader's CSS-pixel cell size with no aliasing.
const __qs = new URLSearchParams(window.location.search);
const CSS_CELL_W = parseInt(__qs.get('cw'),   10) || 10;
const CSS_CELL_H = parseInt(__qs.get('ch'),   10) || 20;
const FONT_CSS_PX = parseInt(__qs.get('font'), 10) || 16;
const ATLAS_OVERSAMPLE = 2;
// Atlas slot size in pixels (only used to rasterise the texture).
const CELL_W  = CSS_CELL_W  * ATLAS_OVERSAMPLE;
const CELL_H  = CSS_CELL_H  * ATLAS_OVERSAMPLE;
const FONT_PX = FONT_CSS_PX * ATLAS_OVERSAMPLE;
const ATLAS_COLS = 16;
const ATLAS_ROWS = 16;

const canvas = document.getElementById('cv');
// Make the canvas focusable so click + keyboard events route here
// reliably; without tabindex the canvas can't take focus, and on
// some browsers that drops keydown events for non-textual keys when
// the page is loaded inside a popup-style window like webui's.
canvas.setAttribute('tabindex', '0');
canvas.style.outline = 'none';
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

// Family with deliberate, broad coverage of box-drawing / block
// characters.  "ui-monospace" picks the system's terminal-grade font
// on Mac+modern Linux; the fallbacks cover X11 minimal envs.
const ATLAS_FONT_FAMILY =
  'ui-monospace, "Cascadia Mono", "DejaVu Sans Mono", "Liberation Mono", Menlo, Consolas, monospace';

function rasteriseGlyph(cp, slot) {
  const x = (slot % ATLAS_COLS) * CELL_W;
  const y = Math.floor(slot / ATLAS_COLS) * CELL_H;
  const s = String.fromCodePoint(cp || 32);
  for (let i = 0; i < ATLAS_LAYERS; i++) {
    const actx = atlasCtxs[i];
    actx.save();
    actx.fillStyle = '#000';
    actx.fillRect(x, y, CELL_W, CELL_H);
    // Clip strictly to the cell so AA bleed from this glyph cannot
    // touch neighbouring slots in the atlas -- NEAREST sampling would
    // otherwise show those stray pixels as "random dots" under and
    // around tall/wide glyphs (r, t, j, comma, etc.).
    actx.beginPath();
    actx.rect(x, y, CELL_W, CELL_H);
    actx.clip();
    actx.fillStyle = '#fff';
    actx.font = `${LAYER_FONTS[i]}${FONT_PX}px ${ATLAS_FONT_FAMILY}`;
    actx.textAlign = 'center';
    actx.textBaseline = 'middle';
    actx.fillText(s, x + CELL_W / 2, y + CELL_H / 2);
    actx.restore();
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

// Every GPU-side resource lives in a `let` so the context-restore
// path can re-create them after a `webglcontextlost` event.  The
// CPU-side atlas canvases survive the loss; only the texture has to
// be rebuilt + re-uploaded.
let atlasTex;
function buildAtlasTexture() {
  atlasTex = gl.createTexture();
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D_ARRAY, atlasTex);
  // LINEAR: atlas is oversampled (2x); shader's per-frame cell size
  // is in device pixels via current DPR, which is usually < atlas
  // resolution.  LINEAR downscale keeps glyphs crisp; NEAREST would
  // alias when downscaling.
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  // Immutable storage so we don't keep allocating per upload.
  gl.texStorage3D(gl.TEXTURE_2D_ARRAY, 1, gl.RGBA8,
                  ATLAS_COLS * CELL_W, ATLAS_ROWS * CELL_H, ATLAS_LAYERS);
  // Force the next syncAtlas to re-upload from the (still alive) 2D
  // canvases.
  atlasDirty = true;
}

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

// Per cell: 2 cell + 1 glyph + 4 fg + 4 bg + 1 attrs = 12 floats.
const FLOATS_PER_CELL = 12;
const cellStride = FLOATS_PER_CELL * 4;

let program, uCellSize, uViewport, uAtlasCells, uAtlas;
let aQuad, aCell, aGlyph, aFg, aBg, aAttrs;
let quadBuf, cellsBuf, vao;

function buildCellProgram() {
  program = gl.createProgram();
  gl.attachShader(program, compile(gl.VERTEX_SHADER,   VS));
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FS));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(program) || 'program link failed');
  }
  gl.useProgram(program);

  uCellSize   = gl.getUniformLocation(program, 'u_cellSize');
  uViewport   = gl.getUniformLocation(program, 'u_viewport');
  uAtlasCells = gl.getUniformLocation(program, 'u_atlasCells');
  uAtlas      = gl.getUniformLocation(program, 'u_atlas');

  gl.uniform2f(uCellSize,   CELL_W, CELL_H);
  gl.uniform2f(uAtlasCells, ATLAS_COLS, ATLAS_ROWS);
  gl.uniform1i(uAtlas, 0);

  // ---- Geometry: one quad, instanced per cell.
  quadBuf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
  gl.bufferData(gl.ARRAY_BUFFER,
                new Float32Array([0,0, 1,0, 0,1, 0,1, 1,0, 1,1]),
                gl.STATIC_DRAW);

  aQuad  = gl.getAttribLocation(program, 'a_quad');
  aCell  = gl.getAttribLocation(program, 'a_cell');
  aGlyph = gl.getAttribLocation(program, 'a_glyph');
  aFg    = gl.getAttribLocation(program, 'a_fg');
  aBg    = gl.getAttribLocation(program, 'a_bg');
  aAttrs = gl.getAttribLocation(program, 'a_attrs');

  vao = gl.createVertexArray();
  gl.bindVertexArray(vao);

  gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
  gl.enableVertexAttribArray(aQuad);
  gl.vertexAttribPointer(aQuad, 2, gl.FLOAT, false, 0, 0);

  cellsBuf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, cellsBuf);
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
}

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

let cursorProgram, cuCell, cuCellSize, cuViewport, cuStyle, cuAlpha, cuColor;
let cuQuadLoc, cursorVao;

function buildCursorProgram() {
  cursorProgram = gl.createProgram();
  gl.attachShader(cursorProgram, compile(gl.VERTEX_SHADER,   cursorVS));
  gl.attachShader(cursorProgram, compile(gl.FRAGMENT_SHADER, cursorFS));
  gl.linkProgram(cursorProgram);
  if (!gl.getProgramParameter(cursorProgram, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(cursorProgram) || 'cursor link failed');
  }

  cuCell      = gl.getUniformLocation(cursorProgram, 'u_cursorCell');
  cuCellSize  = gl.getUniformLocation(cursorProgram, 'u_cellSize');
  cuViewport  = gl.getUniformLocation(cursorProgram, 'u_viewport');
  cuStyle     = gl.getUniformLocation(cursorProgram, 'u_cursorStyle');
  cuAlpha     = gl.getUniformLocation(cursorProgram, 'u_cursorAlpha');
  cuColor     = gl.getUniformLocation(cursorProgram, 'u_cursorColor');
  cuQuadLoc   = gl.getAttribLocation(cursorProgram, 'a_quad');

  cursorVao = gl.createVertexArray();
  gl.bindVertexArray(cursorVao);
  gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
  gl.enableVertexAttribArray(cuQuadLoc);
  gl.vertexAttribPointer(cuQuadLoc, 2, gl.FLOAT, false, 0, 0);

  gl.bindVertexArray(vao);
}

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

// Per-frame list of clickable rectangles (from gcell's on-click /
// on-hover wrappers).  Cells inside these rects get a pointer cursor
// affordance so the user knows interactive surfaces at a glance.
let clickRects = [];
function pointInRect(x, y, r) {
  return x >= r.col && x < r.col + r.w &&
         y >= r.row && y < r.row + r.h;
}
function anyClickableAt(x, y) {
  for (let i = 0; i < clickRects.length; i++) {
    if (pointInRect(x, y, clickRects[i])) return true;
  }
  return false;
}

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
  if (gl.isContextLost()) return;
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
  if (w !== gridW || h !== gridH) {
    shipLog('info', `frame newdim ${gridW}x${gridH} -> ${w}x${h} type=${frameType}`);
    // Snap canvas display + backing to exactly grid * CSS_CELL.
    // Backing FIRST (resets bitmap), style after.  See onResize for
    // why -- otherwise mid-flight composites scale the old content
    // into the new display and look like font scaling.
    const cw = w * CSS_CELL_W;
    const ch = h * CSS_CELL_H;
    canvas.width  = cw;
    canvas.height = ch;
    canvas.style.width  = cw + 'px';
    canvas.style.height = ch + 'px';
  }
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
    overlayOff = off;
  }

  // Click-region overlay (v5+).  Entry: u16 col, u16 row, u16 w, u16 h.
  // Stored as rectangles; we keep them as a flat list and hit-test on
  // mousemove for the cursor=pointer affordance.
  clickRects = [];
  if (version >= 5 && u8.byteLength >= overlayOff + 2) {
    const n = dv.getUint16(overlayOff, true);
    let off = overlayOff + 2;
    for (let i = 0; i < n; i++) {
      clickRects.push({
        col: dv.getUint16(off,     true),
        row: dv.getUint16(off + 2, true),
        w:   dv.getUint16(off + 4, true),
        h:   dv.getUint16(off + 6, true),
      });
      off += 8;
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
  if (gl.isContextLost()) return;
  // Cells are always CSS_CELL_W x CSS_CELL_H *CSS pixels* in size.
  // Canvas backing equals the window in CSS pixels (no DPR).  Shader
  // paints at the same CSS-pixel scale -- one source of truth.
  gl.viewport(0, 0, canvas.width, canvas.height);
  gl.uniform2f(uViewport, canvas.width, canvas.height);
  gl.useProgram(program);
  gl.uniform2f(uCellSize, CSS_CELL_W, CSS_CELL_H);
  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  if (cellCount > 0) {
    gl.bindVertexArray(vao);
    gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, cellCount);
  }
  drawImagePlacements(CSS_CELL_W, CSS_CELL_H);
  if (cursorStyle !== 0) {
    gl.useProgram(cursorProgram);
    gl.bindVertexArray(cursorVao);
    gl.uniform2f(cuCellSize, CSS_CELL_W, CSS_CELL_H);
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

function onResize(reason) {
  try {
    const cssW = window.innerWidth;
    const cssH = window.innerHeight;
    const cols = Math.max(20, Math.floor(cssW / CSS_CELL_W));
    const rows = Math.max(5,  Math.floor(cssH / CSS_CELL_H));
    const cw = cols * CSS_CELL_W;
    const ch = rows * CSS_CELL_H;
    // Resize the backing FIRST.  Setting canvas.width/height resets
    // the bitmap to transparent black at the new dims.  Setting
    // canvas.style.width AFTER means the browser never sees a frame
    // where display=NEW but backing=OLD-content -- which would
    // composite as the old cells SCALED into the new display, and
    // would look exactly like the font shrinking on a drag-resize.
    canvas.width  = cw;
    canvas.height = ch;
    canvas.style.width  = cw + 'px';
    canvas.style.height = ch + 'px';
    // cellsArray still holds the OLD frame's cell data, indexed by the
    // OLD grid width.  Drawing it onto the NEW bigger canvas would
    // paint the old cells in the top-left and leave the rest blank
    // until the server's new-dim frame arrives -- which reads as
    // "cells never updated, stuck in old position".  Instead: clear
    // the framebuffer + drop the stale cells, and let applyFrame
    // paint the next frame from the server.  Invalidating the local
    // grid state also forces applyFrame to treat the next frame as a
    // dim change (full repaint guaranteed).
    cellCount = 0;
    cellsArray = new Float32Array(0);
    gridW = 0;
    gridH = 0;
    gl.viewport(0, 0, cw, ch);
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    shipLog('info', `onResize(${reason||'?'}) inner=${cssW}x${cssH}`
                   +` canvas=${cw}x${ch} grid=${cols}x${rows}`);
    send('resize', { width: cols, height: rows });
  } catch (e) {
    shipLog('error', `onResize threw: ${e && e.message ? e.message : e}`);
  }
}

window.addEventListener('resize',  () => { shipLog('info','evt=window.resize'); onResize('window.resize'); });
window.addEventListener('orientationchange', () => { shipLog('info','evt=orientationchange'); onResize('orientationchange'); });
document.addEventListener('fullscreenchange', () => { shipLog('info','evt=fullscreenchange'); onResize('fullscreenchange'); });
if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(() => { shipLog('info','evt=resizeObserver'); onResize('resizeObserver'); }).observe(document.documentElement);
}
let __lastW = window.innerWidth, __lastH = window.innerHeight;
setInterval(() => {
  if (window.innerWidth !== __lastW || window.innerHeight !== __lastH) {
    shipLog('info', `evt=poll innerChanged ${__lastW}x${__lastH} -> ${window.innerWidth}x${window.innerHeight}`);
    __lastW = window.innerWidth;
    __lastH = window.innerHeight;
    onResize('poll');
  }
}, 250);
// Heartbeat: ships current dims every 2s.  If these stop, JS is
// frozen / page died.  If canvas backing diverges from style * DPR,
// onResize is not effectively taking hold.
setInterval(() => {
  // Get the actual rendered rect (post-layout, post any browser
  // scaling).  If this differs from canvas.style.* the browser is
  // scaling the canvas behind our backs.
  const r = canvas.getBoundingClientRect();
  const vv = window.visualViewport;
  const vvScale = vv ? vv.scale : '?';
  const vvW = vv ? Math.round(vv.width) : '?';
  shipLog('info', `hb inner=${window.innerWidth}x${window.innerHeight}`
                 +` outer=${window.outerWidth}x${window.outerHeight}`
                 +` screen=${screen.width}x${screen.height}`
                 +` dpr=${window.devicePixelRatio}`
                 +` vv=${vvW}@${vvScale}`
                 +` canvas=${canvas.width}x${canvas.height}`
                 +` style=${canvas.style.width || '?'}x${canvas.style.height || '?'}`
                 +` rect=${Math.round(r.width)}x${Math.round(r.height)}`
                 +` cellPx=${(r.width / Math.max(1, gridW)).toFixed(2)}`
                 +` gridW=${gridW} gridH=${gridH}`);
}, 2000);
// Make sure clicks land focus -- some webui-launched windows boot
// without document focus and then keydown events miss the document.
canvas.addEventListener('mousedown', () => canvas.focus());
window.addEventListener('load',      () => canvas.focus());
document.addEventListener('visibilitychange',
  () => { if (document.visibilityState === 'visible') canvas.focus(); });

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

// Modifier-only events from `e.key` are useless on the gcell side --
// the next non-modifier key will carry the mod flags.
const MODIFIER_KEYS = new Set([
  'Shift', 'Control', 'Alt', 'Meta', 'CapsLock', 'NumLock', 'ScrollLock',
  'OS', 'AltGraph', 'ContextMenu',
]);

// Keys whose browser default has to be suppressed so they reach the
// app: Backspace (back-nav in some browsers), Tab (focus jump), space
// (page scroll on body), arrows / page nav (scroll), function keys
// (some are reserved), Enter (form submit).  We send them all to the
// engine, then preventDefault.
function shouldPreventDefault(e) {
  if (e.key === 'Tab' || e.key === 'Backspace' || e.key === 'Enter' ||
      e.key === ' '   || e.key === 'Delete'    || e.key === 'Home'  ||
      e.key === 'End' || e.key.startsWith('Arrow') ||
      e.key.startsWith('Page') || /^F\d/.test(e.key)) {
    return true;
  }
  return false;
}

function keyEventOf(e) {
  // Browser auto-repeat: e.repeat=true.  gcell's engine has a
  // held-set timeout of several seconds, so without 'repeat / 'release
  // bookkeeping the second tap of the same key (backspace, etc.)
  // would be re-classified as a held-key repeat by the engine and
  // dropped by widgets that only listen to 'press (e.g. textinput).
  if (e.type === 'keyup') return 'release';
  return e.repeat ? 'repeat' : 'press';
}

function dispatchKey(e) {
  if (MODIFIER_KEYS.has(e.key)) return;
  const mods = [];
  if (e.ctrlKey)  mods.push('control');
  if (e.shiftKey) mods.push('shift');
  if (e.altKey)   mods.push('alt');
  if (e.metaKey)  mods.push('meta');
  send('key', {
    sym:   keySym(e),
    mods:  mods.join(','),
    event: keyEventOf(e),
  });
  if (shouldPreventDefault(e)) e.preventDefault();
}

document.addEventListener('keydown', dispatchKey);
document.addEventListener('keyup',   dispatchKey);

function cellPosFromMouseEvent(e) {
  const rect = canvas.getBoundingClientRect();
  // CSS-pixel offsets / CSS cell size yields the same grid coords the
  // server sees from the resize event.
  return {
    x: Math.floor((e.clientX - rect.left) / CSS_CELL_W),
    y: Math.floor((e.clientY - rect.top)  / CSS_CELL_H),
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
  // Hover affordance: pointer cursor over any clickable region (or
  // OSC-8 hyperlink), default otherwise.  Tells the user at a glance
  // which cells are interactive without the widget itself having to
  // add a visual hover style.
  const overClickable = hyperlinks.has(linkKey(x, y)) || anyClickableAt(x, y);
  canvas.style.cursor = overClickable ? 'pointer' : 'default';
  // Same-cell movement is invisible to a cell grid; only emit on a
  // real cell change.  No time throttle: the cell granularity bounds
  // the rate by mouse speed already, and dropping any cell-cross
  // makes hover affordances flicker / stick.
  if (x === lastMove.x && y === lastMove.y) return;
  lastMove = { x, y, ts: 0 };
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

let imageProgram, iuPos, iuSize, iuUv, iuCellSize, iuViewport, iuImg, iaQuadLoc;
let imageVao;

function buildImageProgram() {
  imageProgram = gl.createProgram();
  gl.attachShader(imageProgram, compile(gl.VERTEX_SHADER,   imageVS));
  gl.attachShader(imageProgram, compile(gl.FRAGMENT_SHADER, imageFS));
  gl.linkProgram(imageProgram);
  if (!gl.getProgramParameter(imageProgram, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(imageProgram) || 'image link failed');
  }

  iuPos      = gl.getUniformLocation(imageProgram, 'a_pos');
  iuSize     = gl.getUniformLocation(imageProgram, 'a_size');
  iuUv       = gl.getUniformLocation(imageProgram, 'a_uvRect');
  iuCellSize = gl.getUniformLocation(imageProgram, 'u_cellSize');
  iuViewport = gl.getUniformLocation(imageProgram, 'u_viewport');
  iuImg      = gl.getUniformLocation(imageProgram, 'u_img');
  iaQuadLoc  = gl.getAttribLocation(imageProgram, 'a_quad');

  imageVao = gl.createVertexArray();
  gl.bindVertexArray(imageVao);
  gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
  gl.enableVertexAttribArray(iaQuadLoc);
  gl.vertexAttribPointer(iaQuadLoc, 2, gl.FLOAT, false, 0, 0);

  gl.bindVertexArray(vao);
}

// Bootstrap + context-loss/restore wire-up.
function buildAllGl() {
  buildAtlasTexture();
  buildCellProgram();
  buildCursorProgram();
  buildImageProgram();
  syncAtlas();
  // GPU-side image textures are gone on a context loss; the cache
  // entries point at dead handles.  Drop them so the next placement
  // re-uploads (server's image-ids hash is server-side; for now the
  // image data has to be resent by the server -- not blocking the
  // common case of the terminal example which has no images).
  imageCache.clear();
  imagesPlaced = [];
}
buildAllGl();

canvas.addEventListener('webglcontextlost', (e) => {
  // Must preventDefault, otherwise the browser never fires the
  // restored event.  See WEBGL_lose_context.
  e.preventDefault();
  shipLog('error', 'webgl context lost');
});
canvas.addEventListener('webglcontextrestored', () => {
  shipLog('info', 'webgl context restored, rebuilding GL state');
  buildAllGl();
  // Force a full frame from the server: the engine will encode at
  // current dims regardless of what the client thinks, but we want
  // the client's grid invalidated so applyFrame's newdim path runs
  // and reallocates cellsArray cleanly.
  gridW = 0; gridH = 0;
  cellCount = 0;
  cellsArray = new Float32Array(0);
  send('resize', {
    width:  Math.max(20, Math.floor(window.innerWidth  / CSS_CELL_W)),
    height: Math.max(5,  Math.floor(window.innerHeight / CSS_CELL_H)),
  });
});

function drawImagePlacements(cellW, cellH) {
  if (imagesPlaced.length === 0) return;
  gl.useProgram(imageProgram);
  gl.bindVertexArray(imageVao);
  gl.uniform2f(iuCellSize, cellW || CELL_W, cellH || CELL_H);
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
