// canary WebGL2 client.
//
// Mounts a fullscreen canvas, builds a font atlas in a hidden 2D
// canvas, uploads it as a texture, and renders the server-pushed cell
// grid as a single instanced draw call per frame.  Input events are
// shipped back through webui.call('input', json).
//
// The server pushes binary frames via webui_send_raw, which webui's
// bridge delivers as a call to window.canaryFrame with a Uint8Array.

const MAGIC = 0x59524E43; // "CNRY" little-endian.

const FONT_PX = 16;
const CELL_W  = 9;
const CELL_H  = 18;
const ATLAS_COLS = 16;
const ATLAS_ROWS = 16;

const canvas = document.getElementById('cv');
const gl = canvas.getContext('webgl2', { antialias: false, premultipliedAlpha: false });
if (!gl) throw new Error('webgl2 required');

// ---- Atlas (rasterised glyphs in a 2D canvas, uploaded as a texture)

const atlasCanvas = document.createElement('canvas');
atlasCanvas.width  = ATLAS_COLS * CELL_W;
atlasCanvas.height = ATLAS_ROWS * CELL_H;
const actx = atlasCanvas.getContext('2d');
actx.imageSmoothingEnabled = false;

const atlasMap = new Map(); // codepoint -> slot
let nextSlot = 0;
let atlasDirty = true;

function rasteriseGlyph(cp, slot) {
  const x = (slot % ATLAS_COLS) * CELL_W;
  const y = Math.floor(slot / ATLAS_COLS) * CELL_H;
  actx.fillStyle = '#000';
  actx.fillRect(x, y, CELL_W, CELL_H);
  actx.fillStyle = '#fff';
  actx.font = `${FONT_PX}px monospace`;
  actx.textBaseline = 'top';
  actx.fillText(String.fromCodePoint(cp || 32), x, y);
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

// Pre-rasterise printable ASCII.
for (let cp = 32; cp < 127; cp++) atlasIndexFor(cp);

const atlasTex = gl.createTexture();
gl.activeTexture(gl.TEXTURE0);
gl.bindTexture(gl.TEXTURE_2D, atlasTex);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

function syncAtlas() {
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, atlasTex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, atlasCanvas);
  atlasDirty = false;
}
syncAtlas();

// ---- Shaders + program

const VS = `#version 300 es
in vec2 a_quad;
in vec2 a_cell;
in float a_glyph;
in vec4 a_fg;
in vec4 a_bg;
uniform vec2 u_cellSize;
uniform vec2 u_viewport;
uniform vec2 u_atlasCells;
out vec2 v_uv;
out vec4 v_fg;
out vec4 v_bg;
void main() {
  vec2 px = (a_cell + a_quad) * u_cellSize;
  vec2 ndc = (px / u_viewport) * 2.0 - 1.0;
  ndc.y = -ndc.y;
  gl_Position = vec4(ndc, 0.0, 1.0);
  float slot = a_glyph;
  vec2 atlasIdx = vec2(mod(slot, u_atlasCells.x), floor(slot / u_atlasCells.x));
  v_uv = (atlasIdx + a_quad) / u_atlasCells;
  v_fg = a_fg;
  v_bg = a_bg;
}`;

const FS = `#version 300 es
precision mediump float;
uniform sampler2D u_atlas;
in vec2 v_uv;
in vec4 v_fg;
in vec4 v_bg;
out vec4 fragColor;
void main() {
  float a = texture(u_atlas, v_uv).r;
  fragColor = mix(v_bg, v_fg, a);
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

const vao = gl.createVertexArray();
gl.bindVertexArray(vao);

gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
gl.enableVertexAttribArray(aQuad);
gl.vertexAttribPointer(aQuad, 2, gl.FLOAT, false, 0, 0);

const cellsBuf = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, cellsBuf);
const stride = 11 * 4; // floats per cell: 2 cell + 1 glyph + 4 fg + 4 bg
gl.enableVertexAttribArray(aCell);
gl.vertexAttribPointer(aCell, 2, gl.FLOAT, false, stride, 0);
gl.vertexAttribDivisor(aCell, 1);
gl.enableVertexAttribArray(aGlyph);
gl.vertexAttribPointer(aGlyph, 1, gl.FLOAT, false, stride, 8);
gl.vertexAttribDivisor(aGlyph, 1);
gl.enableVertexAttribArray(aFg);
gl.vertexAttribPointer(aFg, 4, gl.FLOAT, false, stride, 12);
gl.vertexAttribDivisor(aFg, 1);
gl.enableVertexAttribArray(aBg);
gl.vertexAttribPointer(aBg, 4, gl.FLOAT, false, stride, 28);
gl.vertexAttribDivisor(aBg, 1);

// ---- Frame application

let cellsArray = new Float32Array(0);
let cellCount = 0;
let gridW = 0;
let gridH = 0;

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

function applyFrame(buf) {
  const u8 = (buf instanceof Uint8Array) ? buf : new Uint8Array(buf);
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  if (dv.getUint32(0, true) !== MAGIC) return;
  const w = dv.getUint16(4, true);
  const h = dv.getUint16(6, true);
  const total = w * h;
  if (cellsArray.length !== total * 11) cellsArray = new Float32Array(total * 11);
  gridW = w; gridH = h;
  let p = 0;
  for (let i = 0; i < total; i++) {
    const off = 8 + i * 13;
    const cp = dv.getUint32(off, true);
    const fg = dv.getUint32(off + 4, true);
    const bg = dv.getUint32(off + 8, true);
    const col = i % w;
    const row = (i - col) / w;
    cellsArray[p++] = col;
    cellsArray[p++] = row;
    cellsArray[p++] = atlasIndexFor(cp);
    unpackColor(fg, cellsArray, p, DEFAULT_FG); p += 4;
    unpackColor(bg, cellsArray, p, DEFAULT_BG); p += 4;
  }
  cellCount = total;
  if (atlasDirty) syncAtlas();
  gl.bindBuffer(gl.ARRAY_BUFFER, cellsBuf);
  gl.bufferData(gl.ARRAY_BUFFER, cellsArray, gl.STREAM_DRAW);
  draw();
}

function draw() {
  gl.viewport(0, 0, canvas.width, canvas.height);
  gl.uniform2f(uViewport, canvas.width, canvas.height);
  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  if (cellCount > 0) gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, cellCount);
}

// ---- Resize / DPR handling

function send(type, extra) {
  if (!window.webui) return;
  // sent_ms is Date.now() (unix epoch ms) so the server's gettimeofday
  // sees the same epoch; otherwise the comparison is meaningless.
  // performance.now() is monotonic-from-navigation, do NOT use it here.
  const payload = Object.assign({ type, sent_ms: Date.now() }, extra);
  webui.call('input', JSON.stringify(payload));
}

// Browser-side diagnostics travel through the same input bind tagged
// type="log".  The server routes them into canary's engine-log!, and
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
  // Map a few DOM names to canary's conventions.
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

canvas.addEventListener('mousedown', (e) => {
  const { x, y } = cellPosFromMouseEvent(e);
  send('mouse', { x, y, button: MOUSE_BTNS[e.button] || 'left', action: 'press' });
});

canvas.addEventListener('mouseup', (e) => {
  const { x, y } = cellPosFromMouseEvent(e);
  send('mouse', { x, y, button: MOUSE_BTNS[e.button] || 'left', action: 'release' });
});

canvas.addEventListener('contextmenu', (e) => e.preventDefault());

// ---- Receive frames pushed by the server.
//
// webui_send_raw(window, "canaryFrame", bytes) routes through the
// bridge to a call on window.canaryFrame in the browser.
window.canaryFrame = applyFrame;

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
