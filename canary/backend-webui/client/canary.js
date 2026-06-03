// canary WebGL2 client.
//
// Frame layout (matches encode-frame in canary/backend-webui.scm):
//   u32 magic 0..3       0x4C454347 "GCEL" little-endian
//   u8  version 4        v5 carries click overlay; v4 added delta
//   u8  frame_type 5     0=full grid, 1=delta-from-previous
//   u16 width 6..7
//   u16 height 8..9
//   u16 cursor_col 10..11
//   u16 cursor_row 12..13
//   u8  cursor_style 14  (0 hidden, 1 block, 2 underline, 3 bar)
//   u8  cursor_attrs 15  (bit 0 blink)
//   ... cells (full or delta) ...
//   ... hyperlink overlay (v2+) ...
//   ... image-placement overlay (v3+) ...
//   ... click-region overlay (v5+) ...

const MAGIC       = 0x4C454347;
const HEADER_SIZE = 16;
const CELL_SIZE   = 13;

const __qs = new URLSearchParams(window.location.search);
const __cfg = window.__CANARY_CONFIG || {};
const DEBUG = __qs.get('debug') === '1';

function __read(key, qsKey, fallback) {
  if (__cfg[key] != null) return __cfg[key];
  if (qsKey) {
    const v = parseInt(__qs.get(qsKey), 10);
    if (!Number.isNaN(v) && v > 0) return v;
  }
  return fallback;
}

const FONT_PX_DEV = __read('fontPx', 'font', 16);
const ATLAS_OVERSAMPLE = __read('atlasOversample', null, 2);
const FONT_PX = FONT_PX_DEV * ATLAS_OVERSAMPLE;
const ATLAS_COLS = __read('atlasCols', null, 16);
const ATLAS_ROWS = __read('atlasRows', null, 16);
const ATLAS_LAYERS = __read('atlasLayers', null, 3);
const ATLAS_FONT_FAMILY = __cfg.fontFamily ||
  'ui-monospace, "Cascadia Mono", "DejaVu Sans Mono", "Liberation Mono", Menlo, Consolas, monospace';
const LAYER_FONTS = __cfg.layerFonts || ['', 'bold ', 'italic '];
const LAYER_FOR_BOLD = __cfg.layerForBold != null ? __cfg.layerForBold : 1;
const LAYER_FOR_ITALIC = __cfg.layerForItalic != null ? __cfg.layerForItalic : 2;
const UNDERLINE_Y = __cfg.underlineY != null ? __cfg.underlineY : 0.86;
const STRIKE_Y_MIN = __cfg.strikeYMin != null ? __cfg.strikeYMin : 0.46;
const STRIKE_Y_MAX = __cfg.strikeYMax != null ? __cfg.strikeYMax : 0.54;
const COLOR_DEFAULT_SENTINEL = 0xFFFFFFFF;

function __sentinelOr(value, fallback) {
  if (value == null || value === COLOR_DEFAULT_SENTINEL) return fallback;
  const r = ((value >> 16) & 0xFF) / 255;
  const g = ((value >> 8) & 0xFF) / 255;
  const b = (value & 0xFF) / 255;
  return [r, g, b, 1.0];
}

const DEFAULT_FG = __sentinelOr(__cfg.defaultFg, [1.0, 1.0, 1.0, 1.0]);
const DEFAULT_BG = __sentinelOr(__cfg.defaultBg, [0.0, 0.0, 0.0, 1.0]);

let CELL_W_DEV;
let CELL_H_DEV;
let CELL_W;
let CELL_H;

function __measureCell() {
  const c = document.createElement('canvas');
  const ctx = c.getContext('2d');
  ctx.font = FONT_PX_DEV + 'px ' + ATLAS_FONT_FAMILY;
  const m = ctx.measureText('M');
  const advance = Math.ceil(m.width);
  const ascent = (m.fontBoundingBoxAscent != null)
    ? m.fontBoundingBoxAscent
    : (m.actualBoundingBoxAscent || FONT_PX_DEV * 0.8);
  const descent = (m.fontBoundingBoxDescent != null)
    ? m.fontBoundingBoxDescent
    : (m.actualBoundingBoxDescent || FONT_PX_DEV * 0.2);
  return [Math.max(1, advance), Math.max(1, Math.ceil(ascent + descent))];
}

{
  const userW = __read('cellW', 'cell-w', null);
  const userH = __read('cellH', 'cell-h', null);
  if (userW && userH) {
    CELL_W_DEV = userW;
    CELL_H_DEV = userH;
  } else {
    const [mw, mh] = __measureCell();
    CELL_W_DEV = userW || mw;
    CELL_H_DEV = userH || mh;
  }
  CELL_W = CELL_W_DEV * ATLAS_OVERSAMPLE;
  CELL_H = CELL_H_DEV * ATLAS_OVERSAMPLE;
}

const canvas = document.getElementById('cv');
// tabindex so the canvas can take focus and receive keydowns reliably
// across browsers and webui's app-mode window flavours.
canvas.setAttribute('tabindex', '0');
canvas.style.outline = 'none';
// Size the drawing buffer to final dims BEFORE getContext.  Resizing
// the canvas after the GL context exists can trigger ctx loss +
// restore under sway/Wayland with fractional scaling; that cycle
// throws away buildAllGl + uploaded cells and costs hundreds of ms
// of round-trip work.  Sizing first means the GL context is born at
// final dims; the later applyCanvas() at the same size is a no-op.
{
  const dpr = window.devicePixelRatio || 1;
  canvas.width  = Math.max(1, Math.round(window.innerWidth  * dpr));
  canvas.height = Math.max(1, Math.round(window.innerHeight * dpr));
  canvas.style.width  = window.innerWidth  + 'px';
  canvas.style.height = window.innerHeight + 'px';
}
const gl = canvas.getContext('webgl2', { antialias: false, premultipliedAlpha: false });
if (!gl) throw new Error('webgl2 required');

const state = {
  cssW: 0, cssH: 0, dpr: 1,
  backingW: 0, backingH: 0,
  cols: 0, rows: 0,

  cellsArray: new Float32Array(0),
  cellCount:  0,

  serverCols: 0, serverRows: 0,

  cursorCol:   0,
  cursorRow:   0,
  cursorStyle: 1,
  cursorBlink: false,

  hyperlinks:   new Map(),
  clickRects:   [],
  imagesPlaced: [],
};

const FLOATS_PER_CELL = 12;
const cellStride = FLOATS_PER_CELL * 4;

// ---- Atlas: N font-weight layers rasterised into 2D canvases,
// uploaded as a sampler2DArray.  Identity layout: codepoint -> slot
// (shared across layers), shader picks layer per cell from attr bits
// via the LAYER_FOR_BOLD / LAYER_FOR_ITALIC config uniforms.

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

const atlasMap = new Map();
let nextSlot = 0;
let atlasDirty = true;

function rasteriseGlyph(cp, slot) {
  const x = (slot % ATLAS_COLS) * CELL_W;
  const y = Math.floor(slot / ATLAS_COLS) * CELL_H;
  const s = String.fromCodePoint(cp || 32);
  for (let i = 0; i < ATLAS_LAYERS; i++) {
    const actx = atlasCtxs[i];
    actx.save();
    actx.fillStyle = '#000';
    actx.fillRect(x, y, CELL_W, CELL_H);
    // Clip per cell so AA bleed from this glyph can't touch neighbour
    // slots in the atlas; otherwise NEAREST sampling would show stray
    // pixels around tall/wide glyphs (r, t, j, comma, ...).
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
  if (nextSlot >= ATLAS_COLS * ATLAS_ROWS) return atlasMap.get(63) || 0;
  slot = nextSlot++;
  atlasMap.set(safe, slot);
  rasteriseGlyph(safe, slot);
  atlasDirty = true;
  return slot;
}

// Pre-rasterise only space and '?' so atlasIndexFor's overflow
// fallback (line above) returns a sensible result.  Every other
// glyph is rasterised on demand the first time applyFrame asks for
// it.  This keeps module load off the show-to-paint critical path —
// the old eager loop ran rasteriseGlyph 95 times × 3 atlas layers =
// 285 Canvas 2D fillText calls, which on slower CPUs was 30-100ms
// of visible lull before the canvas could paint.
atlasIndexFor(32);
atlasIndexFor(63);

let atlasTex;
function buildAtlasTexture() {
  atlasTex = gl.createTexture();
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D_ARRAY, atlasTex);
  // LINEAR downscale: atlas is oversampled 2x, shader paints at
  // device-pixel cell size which is usually < atlas resolution.
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texStorage3D(gl.TEXTURE_2D_ARRAY, 1, gl.RGBA8,
                  ATLAS_COLS * CELL_W, ATLAS_ROWS * CELL_H, ATLAS_LAYERS);
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

// ---- Cell shader + program ----------------------------------------
//
// Vertex stage maps (a_cell.x, a_cell.y) to grid (col, row).  Fragment
// stage samples the atlas, mixes fg/bg by alpha, then applies attr
// bits: inverse swaps fg/bg, faint dims fg, underline / strikethrough
// draw a band in the cell's lower or middle strip.

const VS = `#version 300 es
in vec2 a_quad;
in vec2 a_cell;
in float a_glyph;
in vec4 a_fg;
in vec4 a_bg;
in float a_attrs;
uniform vec2 u_cellSize;
uniform vec2 u_viewport;
uniform vec2 u_atlasCells;
out vec2 v_uv;
out vec2 v_cellUv;
out vec4 v_fg;
out vec4 v_bg;
flat out int  v_attrs;
void main() {
  vec2 px = (a_cell + a_quad) * u_cellSize;
  vec2 ndc = (px / u_viewport) * 2.0 - 1.0;
  ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
  float slot = a_glyph;
  vec2 atlasCell = vec2(mod(slot, u_atlasCells.x),
                        floor(slot / u_atlasCells.x));
  v_uv = (atlasCell + a_quad) / u_atlasCells;
  v_cellUv = a_quad;
  v_fg = a_fg;
  v_bg = a_bg;
  v_attrs = int(a_attrs);
}`;

const FS = `#version 300 es
precision mediump float;
in vec2 v_uv;
in vec2 v_cellUv;
in vec4 v_fg;
in vec4 v_bg;
flat in int  v_attrs;
uniform mediump sampler2DArray u_atlas;
uniform int u_layer_for_bold;
uniform int u_layer_for_italic;
uniform float u_underline_y;
uniform float u_strike_y_min;
uniform float u_strike_y_max;
out vec4 fragColor;
void main() {
  int layer = 0;
  if ((v_attrs & 1) != 0 && u_layer_for_bold >= 0) layer = u_layer_for_bold;
  else if ((v_attrs & 2) != 0 && u_layer_for_italic >= 0) layer = u_layer_for_italic;
  float a = texture(u_atlas, vec3(v_uv, float(layer))).r;
  vec4 fg = v_fg;
  vec4 bg = v_bg;
  if ((v_attrs & 8)  != 0) { vec4 t = fg; fg = bg; bg = t; }
  if ((v_attrs & 32) != 0) fg.rgb *= 0.5;
  vec4 col = mix(bg, fg, a);
  if ((v_attrs & 4)  != 0 && v_cellUv.y > u_underline_y) col = fg;
  if ((v_attrs & 16) != 0 && v_cellUv.y > u_strike_y_min && v_cellUv.y < u_strike_y_max) col = fg;
  fragColor = col;
}`;

function compile(type, src) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(sh) || 'shader compile failed');
  }
  return sh;
}

let program, uCellSize, uViewport, uAtlasCells, uAtlas;
let aQuad, aCell, aGlyph, aFg, aBg, aAttrs;
let quadBuf, cellsBuf, vao;

function buildCellProgram() {
  program = gl.createProgram();
  gl.attachShader(program, compile(gl.VERTEX_SHADER,   VS));
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FS));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(program) || 'cell link failed');
  }

  uCellSize   = gl.getUniformLocation(program, 'u_cellSize');
  uViewport   = gl.getUniformLocation(program, 'u_viewport');
  uAtlasCells = gl.getUniformLocation(program, 'u_atlasCells');
  uAtlas      = gl.getUniformLocation(program, 'u_atlas');

  gl.useProgram(program);
  gl.uniform2f(uAtlasCells, ATLAS_COLS, ATLAS_ROWS);
  gl.uniform1i(uAtlas, 0);
  gl.uniform1i(gl.getUniformLocation(program, 'u_layer_for_bold'),   LAYER_FOR_BOLD);
  gl.uniform1i(gl.getUniformLocation(program, 'u_layer_for_italic'), LAYER_FOR_ITALIC);
  gl.uniform1f(gl.getUniformLocation(program, 'u_underline_y'),  UNDERLINE_Y);
  gl.uniform1f(gl.getUniformLocation(program, 'u_strike_y_min'), STRIKE_Y_MIN);
  gl.uniform1f(gl.getUniformLocation(program, 'u_strike_y_max'), STRIKE_Y_MAX);

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
uniform int u_cursorStyle;
uniform float u_cursorAlpha;
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

  cuCell     = gl.getUniformLocation(cursorProgram, 'u_cursorCell');
  cuCellSize = gl.getUniformLocation(cursorProgram, 'u_cellSize');
  cuViewport = gl.getUniformLocation(cursorProgram, 'u_viewport');
  cuStyle    = gl.getUniformLocation(cursorProgram, 'u_cursorStyle');
  cuAlpha    = gl.getUniformLocation(cursorProgram, 'u_cursorAlpha');
  cuColor    = gl.getUniformLocation(cursorProgram, 'u_cursorColor');
  cuQuadLoc  = gl.getAttribLocation(cursorProgram,  'a_quad');

  cursorVao = gl.createVertexArray();
  gl.bindVertexArray(cursorVao);
  gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
  gl.enableVertexAttribArray(cuQuadLoc);
  gl.vertexAttribPointer(cuQuadLoc, 2, gl.FLOAT, false, 0, 0);

  gl.bindVertexArray(vao);
}

// ---- Image overlay --------------------------------------------------
//
// canaryImage receives PNG/JPEG bytes:  u32 image_id  u32 length  bytes.
// createImageBitmap decodes off-thread; we upload as a 2D texture and
// the image-program draws placements over the cell grid.

const imageCache = new Map();   // id -> { tex, w, h }

const imageVS = `#version 300 es
in vec2 a_quad;
uniform vec2 a_pos;
uniform vec2 a_size;
uniform vec4 a_uvRect;
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
void main() { fragColor = texture(u_img, v_uv); }`;

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
  iaQuadLoc  = gl.getAttribLocation(imageProgram,  'a_quad');

  imageVao = gl.createVertexArray();
  gl.bindVertexArray(imageVao);
  gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
  gl.enableVertexAttribArray(iaQuadLoc);
  gl.vertexAttribPointer(iaQuadLoc, 2, gl.FLOAT, false, 0, 0);

  gl.bindVertexArray(vao);
}

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
  paint();
}

function handleImage(buf) {
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
}

function drawImagePlacements() {
  if (state.imagesPlaced.length === 0) return;
  // The image program is deferred past first paint; skip image cmds
  // until it's compiled.  Anything queued before that point will be
  // drawn on the next paint after buildDeferredPrograms lands.
  if (!deferredProgramsReady) return;
  gl.useProgram(imageProgram);
  gl.bindVertexArray(imageVao);
  gl.uniform2f(iuCellSize, CELL_W_DEV, CELL_H_DEV);
  gl.uniform2f(iuViewport, state.backingW, state.backingH);
  gl.uniform1i(iuImg, 1);
  gl.activeTexture(gl.TEXTURE1);
  for (const p of state.imagesPlaced) {
    const entry = imageCache.get(p.id);
    if (!entry) continue;
    gl.bindTexture(gl.TEXTURE_2D, entry.tex);
    gl.uniform2f(iuPos,  p.col, p.row);
    gl.uniform2f(iuSize, p.w,   p.h);
    gl.uniform4f(iuUv,
                 p.sx / entry.w, p.sy / entry.h,
                 p.sw / entry.w, p.sh / entry.h);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }
  gl.bindVertexArray(vao);
}

// Shader compiles are the bulk of the GL-boot lull (cursor + image
// programs together can run 30-100ms on slower GPUs).  The cell
// program is the only one needed to paint the first frame, so build
// it synchronously and defer the other two past the first paint.
let deferredProgramsReady = false;

function buildAllGl() {
  buildAtlasTexture();
  buildCellProgram();
  syncAtlas();
  // GPU image textures are gone on context loss; cache entries point
  // at dead handles.  Drop them so the next placement re-decodes.
  imageCache.clear();
  state.imagesPlaced = [];
  // Force cursor + image programs to be rebuilt — buildAllGl runs on
  // both initial boot and webglcontextrestored, and a restored
  // context has stale program handles.
  deferredProgramsReady = false;
}

function buildDeferredPrograms() {
  if (deferredProgramsReady) return;
  buildCursorProgram();
  buildImageProgram();
  deferredProgramsReady = true;
}

// ---- Frame parsing --------------------------------------------------

const utf8Decoder = new TextDecoder('utf-8');

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

function linkKey(col, row) { return (row << 16) | col; }

function writeCellSlot(idx, w, cp, fg, bg, attrs) {
  const col = idx % w;
  const row = (idx - col) / w;
  let p = idx * FLOATS_PER_CELL;
  state.cellsArray[p++] = col;
  state.cellsArray[p++] = row;
  state.cellsArray[p++] = atlasIndexFor(cp);
  unpackColor(fg, state.cellsArray, p, DEFAULT_FG); p += 4;
  unpackColor(bg, state.cellsArray, p, DEFAULT_BG); p += 4;
  state.cellsArray[p++] = attrs;
}

function applyFrame(buf) {
  if (gl.isContextLost()) return;
  const u8 = (buf instanceof Uint8Array) ? buf : new Uint8Array(buf);
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  if (dv.getUint32(0, true) !== MAGIC) return;
  const version   = dv.getUint8(4);
  const frameType = (version >= 4) ? dv.getUint8(5) : 0;
  const w = dv.getUint16(6, true);
  const h = dv.getUint16(8, true);
  state.cursorCol   = dv.getUint16(10, true);
  state.cursorRow   = dv.getUint16(12, true);
  state.cursorStyle = dv.getUint8(14);
  state.cursorBlink = (dv.getUint8(15) & 1) !== 0;

  const total = w * h;
  if (state.cellsArray.length !== total * FLOATS_PER_CELL) {
    state.cellsArray = new Float32Array(total * FLOATS_PER_CELL);
  }
  state.serverCols = w;
  state.serverRows = h;

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
  state.cellCount = total;

  // Hyperlink overlay (v2+).
  state.hyperlinks.clear();
  let overlayOff = cellsEnd;
  if (version >= 2 && u8.byteLength >= overlayOff + 2) {
    const linkCount = dv.getUint16(overlayOff, true);
    let off = overlayOff + 2;
    for (let i = 0; i < linkCount; i++) {
      const col = dv.getUint16(off, true);
      const row = dv.getUint16(off + 2, true);
      const len = dv.getUint16(off + 4, true);
      const url = utf8Decoder.decode(u8.subarray(off + 6, off + 6 + len));
      state.hyperlinks.set(linkKey(col, row), url);
      off += 6 + len;
    }
    overlayOff = off;
  }

  // Image-placement overlay (v3+).
  state.imagesPlaced = [];
  if (version >= 3 && u8.byteLength >= overlayOff + 2) {
    const imgCount = dv.getUint16(overlayOff, true);
    let off = overlayOff + 2;
    for (let i = 0; i < imgCount; i++) {
      state.imagesPlaced.push({
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

  // Click-region overlay (v5+).
  state.clickRects = [];
  if (version >= 5 && u8.byteLength >= overlayOff + 2) {
    const n = dv.getUint16(overlayOff, true);
    let off = overlayOff + 2;
    for (let i = 0; i < n; i++) {
      state.clickRects.push({
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
  gl.bufferData(gl.ARRAY_BUFFER, state.cellsArray, gl.STREAM_DRAW);
  paint();
}

function recompute() {
  const cssW = Math.max(1, window.innerWidth);
  const cssH = Math.max(1, window.innerHeight);
  const dpr  = window.devicePixelRatio || 1;
  const backingW = Math.max(1, Math.round(cssW * dpr));
  const backingH = Math.max(1, Math.round(cssH * dpr));
  const cols = Math.max(20, Math.floor(backingW / CELL_W_DEV));
  const rows = Math.max(5,  Math.floor(backingH / CELL_H_DEV));
  const changed = (state.cssW !== cssW || state.cssH !== cssH
                || state.dpr !== dpr
                || state.backingW !== backingW || state.backingH !== backingH
                || state.cols !== cols || state.rows !== rows);
  state.cssW = cssW;
  state.cssH = cssH;
  state.dpr  = dpr;
  state.backingW = backingW;
  state.backingH = backingH;
  state.cols = cols;
  state.rows = rows;
  return changed;
}

function applyCanvas() {
  canvas.width  = state.backingW;
  canvas.height = state.backingH;
  canvas.style.width  = state.cssW + 'px';
  canvas.style.height = state.cssH + 'px';
}

function tellServer() {
  if (state.serverCols === state.cols && state.serverRows === state.rows) return;
  send('resize', { width: state.cols, height: state.rows });
}

function paint() {
  if (gl.isContextLost()) return;
  gl.viewport(0, 0, state.backingW, state.backingH);
  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  if (state.cellCount > 0) {
    gl.useProgram(program);
    gl.bindVertexArray(vao);
    gl.uniform2f(uViewport, state.backingW, state.backingH);
    gl.uniform2f(uCellSize, CELL_W_DEV, CELL_H_DEV);
    gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, state.cellCount);
  }
  drawImagePlacements();
  if (state.cursorStyle !== 0 && deferredProgramsReady) {
    gl.useProgram(cursorProgram);
    gl.bindVertexArray(cursorVao);
    gl.uniform2f(cuCell, state.cursorCol, state.cursorRow);
    gl.uniform2f(cuCellSize, CELL_W_DEV, CELL_H_DEV);
    gl.uniform2f(cuViewport, state.backingW, state.backingH);
    gl.uniform1i(cuStyle, state.cursorStyle);
    gl.uniform1f(cuAlpha, cursorAlpha());
    gl.uniform4f(cuColor, DEFAULT_FG[0], DEFAULT_FG[1], DEFAULT_FG[2], 1.0);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    gl.bindVertexArray(vao);
  }
  if (DEBUG) paintHud();
}

function cursorAlpha() {
  if (!state.cursorBlink) return 1.0;
  const t = (performance.now() % 1000) / 1000;
  return 0.5 + 0.5 * Math.cos(t * 2 * Math.PI);
}

function onWindow(reason) {
  const changed = recompute();
  if (!changed) return;
  applyCanvas();
  tellServer();
  paint();
  if (DEBUG) shipLog('info',
    `resize[${reason}] inner=${state.cssW}x${state.cssH} dpr=${state.dpr}`
    + ` backing=${state.backingW}x${state.backingH}`
    + ` grid=${state.cols}x${state.rows}`);
}

window.addEventListener('resize', () => onWindow('window.resize'));
window.addEventListener('orientationchange', () => onWindow('orientation'));
document.addEventListener('fullscreenchange', () => onWindow('fullscreen'));
if (window.visualViewport) {
  window.visualViewport.addEventListener('resize', () => onWindow('vv.resize'));
  window.visualViewport.addEventListener('scroll', () => onWindow('vv.scroll'));
}
if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(() => onWindow('ro')).observe(document.documentElement);
}
for (const t of [1.0, 1.25, 1.5, 1.75, 2.0, 3.0]) {
  try {
    window.matchMedia(`(resolution: ${t}dppx)`)
      .addEventListener('change', () => onWindow(`dpr=${t}`));
  } catch (_) { /* old browsers */ }
}

function blinkLoop() {
  if (state.cursorBlink && state.cursorStyle !== 0) paint();
  requestAnimationFrame(blinkLoop);
}
requestAnimationFrame(blinkLoop);

// ---- Debug HUD ----------------------------------------------------
//
// Painted directly on the canvas via Canvas2D in a separate offscreen
// layer that we composite as a textured quad would be overkill -- just
// overlay a DOM div instead.  Cheap, always on top, doesn't fight the
// WebGL state machine.

let hudEl = null;
if (DEBUG) {
  hudEl = document.createElement('div');
  hudEl.style.cssText =
    'position:fixed;top:4px;left:4px;z-index:1000;'
    + 'font:11px/1.3 ui-monospace,monospace;color:#0f0;background:rgba(0,0,0,0.7);'
    + 'padding:4px 6px;border:1px solid #0f0;pointer-events:none;white-space:pre';
  document.body.appendChild(hudEl);
}
function paintHud() {
  if (!hudEl) return;
  hudEl.textContent =
      `inner    = ${state.cssW}x${state.cssH}\n`
    + `dpr      = ${state.dpr}\n`
    + `backing  = ${state.backingW}x${state.backingH}\n`
    + `canvas   = ${canvas.width}x${canvas.height}\n`
    + `style    = ${canvas.style.width}x${canvas.style.height}\n`
    + `grid     = ${state.cols}x${state.rows}\n`
    + `server   = ${state.serverCols}x${state.serverRows}\n`
    + `cell     = ${CELL_W_DEV}x${CELL_H_DEV}\n`
    + `cells    = ${state.cellCount}\n`
    + `cursor   = ${state.cursorCol},${state.cursorRow} style=${state.cursorStyle}`;
}

// ---- Outbound shape -----------------------------------------------

function send(type, extra) {
  if (!window.webui || !webui.isConnected || !webui.isConnected()) return;
  const payload = Object.assign({ type, sent_ms: Date.now() }, extra);
  webui.call('input', JSON.stringify(payload)).catch(() => {});
}

function shipLog(level, text) {
  send('log', { level, text });
}

window.addEventListener('error', e => {
  const where = e.filename ? `${e.filename}:${e.lineno}:${e.colno} ` : '';
  try { shipLog('error', `${where}${e.message || e.error || 'unknown error'}`); }
  catch (_) {}
});
window.addEventListener('unhandledrejection', e => {
  const r = e.reason;
  const text = r && r.stack ? r.stack : (r && r.message ? r.message : String(r));
  try { shipLog('error', `unhandled rejection: ${text}`); }
  catch (_) {}
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

// ---- Input --------------------------------------------------------

function keySym(e) {
  if (e.key.length === 1) return e.key;
  const k = e.key.toLowerCase();
  if (k === 'arrowleft')  return 'left';
  if (k === 'arrowright') return 'right';
  if (k === 'arrowup')    return 'up';
  if (k === 'arrowdown')  return 'down';
  return k;
}

const MODIFIER_KEYS = new Set([
  'Shift', 'Control', 'Alt', 'Meta', 'CapsLock', 'NumLock', 'ScrollLock',
  'OS', 'AltGraph', 'ContextMenu',
]);

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
  // Browser auto-repeat sets e.repeat; engine's held-set timeout would
  // otherwise classify the second tap of the same key as a held
  // repeat and drop it.
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
  return {
    x: Math.floor(((e.clientX - rect.left) * state.dpr) / CELL_W_DEV),
    y: Math.floor(((e.clientY - rect.top)  * state.dpr) / CELL_H_DEV),
  };
}

const MOUSE_BTNS = ['left', 'middle', 'right'];
let mouseHeld = 'none';
let lastMove = { x: -1, y: -1 };

function anyClickableAt(x, y) {
  for (const r of state.clickRects) {
    if (x >= r.col && x < r.col + r.w &&
        y >= r.row && y < r.row + r.h) return true;
  }
  return false;
}

canvas.addEventListener('mousedown', (e) => {
  const { x, y } = cellPosFromMouseEvent(e);
  mouseHeld = MOUSE_BTNS[e.button] || 'left';
  if (mouseHeld === 'left') {
    const url = state.hyperlinks.get(linkKey(x, y));
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
  const overClickable = state.hyperlinks.has(linkKey(x, y)) || anyClickableAt(x, y);
  canvas.style.cursor = overClickable ? 'pointer' : 'default';
  if (x === lastMove.x && y === lastMove.y) return;
  lastMove = { x, y };
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

document.addEventListener('paste', (e) => {
  if (!e.clipboardData) return;
  const text = e.clipboardData.getData('text/plain');
  if (text) send('paste', { text });
});

// Click->focus.  Some webui-launched windows boot without document
// focus and miss the first round of keydowns otherwise.
canvas.addEventListener('mousedown', () => canvas.focus());
window.addEventListener('load',      () => canvas.focus());
document.addEventListener('visibilitychange',
  () => { if (document.visibilityState === 'visible') canvas.focus(); });

// ---- GL context-loss -----------------------------------------------

canvas.addEventListener('webglcontextlost', (e) => {
  e.preventDefault();
  shipLog('error', 'webgl context lost');
});
canvas.addEventListener('webglcontextrestored', () => {
  shipLog('info', 'webgl context restored, rebuilding GL state');
  buildAllGl();
  // Cells live in state.cellsArray (a JS-side TypedArray); the GL
  // buffer cellsBuf is fresh after buildAllGl.  If we already have
  // frame bytes, re-upload them and paint immediately — no server
  // round-trip, no flicker.  Only fall back to asking the server for
  // a fresh frame when we have nothing to paint.
  if (state.cellCount > 0 && state.cellsArray.length > 0) {
    gl.bindBuffer(gl.ARRAY_BUFFER, cellsBuf);
    gl.bufferData(gl.ARRAY_BUFFER, state.cellsArray, gl.STREAM_DRAW);
    if (atlasDirty) syncAtlas();
    paint();
  } else {
    state.serverCols = 0;
    state.serverRows = 0;
    recompute();
    applyCanvas();
    tellServer();
    send('ready', {});
  }
});

// ---- Boot ----------------------------------------------------------

function whenWebuiReady(cb) {
  if (window.webui && window.webui.isConnected && window.webui.isConnected()) {
    cb();
    return;
  }
  if (window.webui) {
    if (typeof webui.onConnect === 'function') { webui.onConnect(cb); return; }
    if (webui.event && typeof webui.event.addEventListener === 'function') {
      webui.event.addEventListener('connected', cb, { once: true });
      return;
    }
  }
  setTimeout(() => whenWebuiReady(cb), 32);
}

buildAllGl();
recompute();
applyCanvas();
// Apply the server-inlined initial frame so the canvas paints the
// moment the module finishes booting -- no WebSocket round-trip, no
// token handshake, no force-render request.  The server encodes the
// engine's first render into window.__canaryInitialFrame as base64
// during HTML generation; we decode it here and feed it through the
// same applyFrame path live frames use.
if (window.__canaryInitialFrame) {
  try {
    const bin = atob(window.__canaryInitialFrame);
    const len = bin.length;
    const buf = new Uint8Array(len);
    for (let i = 0; i < len; i++) buf[i] = bin.charCodeAt(i);
    applyFrame(buf);
  } catch (_) {}
  window.__canaryInitialFrame = null;
}
{
  const fq = window.__canaryFrameQueue || [];
  window.canaryFrame = applyFrame;
  window.__canaryFrameQueue = null;
  for (const buf of fq) try { applyFrame(buf); } catch (_) {}
  const iq = window.__canaryImageQueue || [];
  window.canaryImage = handleImage;
  window.__canaryImageQueue = null;
  for (const buf of iq) try { handleImage(buf); } catch (_) {}
}
// Compile cursor + image programs only after the first cell-grid
// paint is committed, so they're not on the show-to-paint critical
// path.  Double-rAF lets the browser actually present the first
// frame before we block on GL link.
requestAnimationFrame(() => requestAnimationFrame(() => {
  buildDeferredPrograms();
  // Paint again so the cursor (and any queued images) show up now
  // that their programs exist.
  if (state.cellCount > 0) paint();
}));
whenWebuiReady(() => {
  recompute();
  applyCanvas();
  tellServer();
  send('measured-cell', { cellW: CELL_W_DEV, cellH: CELL_H_DEV });
});
