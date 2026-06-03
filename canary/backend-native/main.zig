//! canary backend-native — the C side of (canary backend-native).
//!
//! glfw owns the window + input + GL 3.3 core context.  freetype
//! rasterises glyphs.  libepoxy loads GL symbols.  Three GL programs:
//! cell-grid (instanced quads), cursor (uniform-driven quad), image-
//! overlay (per-placement uniforms).  Matches canary/backend-webui/
//! client/canary.js's WebGL2 client: 3-layer sampler2DArray atlas
//! (regular/bold/italic), 2x oversampled, LINEAR filter, on-demand
//! glyph rasterisation, instanced per-cell rendering with identical
//! fragment shader logic.
//!
//! Threading:
//!   - glfw runs on a dedicated POSIX thread spawned from Scheme via
//!     call-with-new-thread.  All GL calls, FreeType calls, and glfw
//!     callbacks fire on that thread.
//!   - Input events from glfw callbacks land in a mutex-protected ring
//!     and notify via an eventfd.  A Guile fiber on the main thread
//!     blocks on the eventfd and drains the ring, building <key> /
//!     <mouse> / <resize> records.  No SCM is touched from the glfw
//!     thread.
//!   - backend-draw on the main fiber hands raw cell bytes through a
//!     mutex-protected mailbox.  The glfw thread reads it at the top
//!     of each frame, ensures atlas slots exist for new codepoints,
//!     uploads cells, draws.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const glfw = @cImport({
    @cInclude("GLFW/glfw3.h");
});

const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

const gl = @cImport({
    @cInclude("epoxy/gl.h");
});

const guile = @cImport({
    @cInclude("libguile.h");
});

// libguile macros translate-c can't follow; live in wrappers.c.
extern fn cn_scm_undefined() guile.SCM;
extern fn cn_scm_unspecified() guile.SCM;
extern fn cn_scm_is_undefined(s: guile.SCM) c_int;

// ---- constants matching canary.js -------------------------------------

const CELL_W_DEV: i32 = 10;
const CELL_H_DEV: i32 = 20;
const ATLAS_OVERSAMPLE: i32 = 2;
const CELL_W: i32 = CELL_W_DEV * ATLAS_OVERSAMPLE;
const CELL_H: i32 = CELL_H_DEV * ATLAS_OVERSAMPLE;
const ATLAS_COLS: i32 = 16;
const ATLAS_ROWS: i32 = 16;
const ATLAS_LAYERS: i32 = 3;
const ATLAS_MAX_SLOTS: u16 = @intCast(ATLAS_COLS * ATLAS_ROWS);

// Per-cell vertex attribute layout (matches canary.js cellStride/FLOATS_PER_CELL).
const FLOATS_PER_CELL: usize = 12;
const CELL_STRIDE: usize = FLOATS_PER_CELL * @sizeOf(f32);

// canary wire cell layout (matches backend-webui.scm encode-frame).
const WIRE_CELL_SIZE: usize = 13;

const DEFAULT_FG = [4]f32{ 0.9, 0.9, 0.9, 1.0 };
const DEFAULT_BG = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
const COLOR_DEFAULT_SENTINEL: u32 = 0xFFFFFFFF;

// ---- POD types crossing thread / FFI boundary -------------------------

const InputKind = enum(u8) {
    key = 1,
    mouse = 2,
    resize = 3,
    paste = 4,
    scroll = 5,
};

const InputEvent = extern struct {
    kind: u8,
    key_sym: u32 = 0,
    mods: u8 = 0,
    action: u8 = 0, // 0=press 1=release 2=repeat
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_button: u8 = 0,
    width: u16 = 0,
    height: u16 = 0,
    scroll_dy: i8 = 0,
};

const ImagePlacement = extern struct {
    id: u32,
    col: u16,
    row: u16,
    w: u16,
    h: u16,
    sx: u16,
    sy: u16,
    sw: u16,
    sh: u16,
};

const ImageEntry = struct {
    tex: gl.GLuint,
    w: i32,
    h: i32,
};

// ---- the singleton backend instance -----------------------------------

const Backend = struct {
    alloc: std.mem.Allocator,

    // window / GL
    window: ?*glfw.GLFWwindow = null,
    framebuffer_w: i32 = 800,
    framebuffer_h: i32 = 600,
    content_scale: f32 = 1.0,

    // freetype
    ft_lib: ft.FT_Library = null,
    fonts: [3]ft.FT_Face = .{ null, null, null },
    font_bytes: [3][]u8 = .{ &.{}, &.{}, &.{} },

    // atlas
    glyph_map: std.AutoHashMapUnmanaged(u32, u16) = .{},
    next_slot: u16 = 0,
    atlas_dirty: std.AutoHashMapUnmanaged(u16, void) = .{},
    atlas_tex: gl.GLuint = 0,
    atlas_sampler_unit: gl.GLint = 0,
    fallback_slot: u16 = 0,

    // pipelines
    cell_prog: gl.GLuint = 0,
    cursor_prog: gl.GLuint = 0,
    image_prog: gl.GLuint = 0,
    quad_buf: gl.GLuint = 0,
    cells_buf: gl.GLuint = 0,
    cell_vao: gl.GLuint = 0,
    cursor_vao: gl.GLuint = 0,
    image_vao: gl.GLuint = 0,
    cells_buf_capacity: usize = 0,

    // cell-program uniforms
    u_cellSize: gl.GLint = -1,
    u_viewport: gl.GLint = -1,
    u_atlasCells: gl.GLint = -1,
    u_atlas: gl.GLint = -1,
    // cursor-program uniforms
    cu_cell: gl.GLint = -1,
    cu_cellSize: gl.GLint = -1,
    cu_viewport: gl.GLint = -1,
    cu_style: gl.GLint = -1,
    cu_alpha: gl.GLint = -1,
    cu_color: gl.GLint = -1,
    // image-program uniforms
    iu_pos: gl.GLint = -1,
    iu_size: gl.GLint = -1,
    iu_uv: gl.GLint = -1,
    iu_cellSize: gl.GLint = -1,
    iu_viewport: gl.GLint = -1,
    iu_img: gl.GLint = -1,

    // images (uploaded RGBA8 textures keyed by canary's image id)
    images: std.AutoHashMapUnmanaged(u32, ImageEntry) = .{},

    // frame mailbox (main fiber -> glfw thread)
    mailbox_mu: std.Thread.Mutex = .{},
    mailbox_cells: std.ArrayListUnmanaged(u8) = .{},
    mailbox_width: u16 = 0,
    mailbox_height: u16 = 0,
    mailbox_cursor_col: u16 = 0,
    mailbox_cursor_row: u16 = 0,
    mailbox_cursor_style: u8 = 1,
    mailbox_cursor_blink: bool = false,
    mailbox_placements: std.ArrayListUnmanaged(ImagePlacement) = .{},
    mailbox_dirty: bool = false,

    // CPU-side per-instance vertex buffer (resized on grid change)
    cells_attribs: std.ArrayListUnmanaged(f32) = .{},

    // input ring (glfw thread -> main fiber)
    event_mu: std.Thread.Mutex = .{},
    events: std.ArrayListUnmanaged(InputEvent) = .{},
    eventfd: i32 = -1,

    // shutdown
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // last-mouse position for click coordinate computation
    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
};

var g_backend: ?*Backend = null;

// ---- GLSL sources (ports of canary.js shaders to GL 3.3 core) ---------

const CELL_VS =
    \\#version 330 core
    \\in vec2 a_quad;
    \\in vec2 a_cell;
    \\in float a_glyph;
    \\in vec4 a_fg;
    \\in vec4 a_bg;
    \\in float a_attrs;
    \\uniform vec2 u_cellSize;
    \\uniform vec2 u_viewport;
    \\uniform vec2 u_atlasCells;
    \\out vec2 v_uv;
    \\out vec2 v_cellUv;
    \\out vec4 v_fg;
    \\out vec4 v_bg;
    \\flat out int v_attrs;
    \\void main() {
    \\  vec2 px = (a_cell + a_quad) * u_cellSize;
    \\  vec2 ndc = (px / u_viewport) * 2.0 - 1.0;
    \\  ndc.y = -ndc.y;
    \\  gl_Position = vec4(ndc, 0.0, 1.0);
    \\  float slot = a_glyph;
    \\  vec2 atlasCell = vec2(mod(slot, u_atlasCells.x),
    \\                        floor(slot / u_atlasCells.x));
    \\  v_uv = (atlasCell + a_quad) / u_atlasCells;
    \\  v_cellUv = a_quad;
    \\  v_fg = a_fg;
    \\  v_bg = a_bg;
    \\  v_attrs = int(a_attrs);
    \\}
    \\
;

// Attr bit packing follows backend-webui.scm:932-950 face->attrs (the
// wire encoder is the authority):
//   bit 0  bold        -> atlas layer 1
//   bit 1  italic      -> atlas layer 2
//   bit 2  underline   -> bottom strip
//   bit 3  inverse     -> swap fg/bg
//   bit 4  crossed     -> middle strip
//   bit 5  faint       -> fg *= 0.5
//   bit 6  hyperlink   -> ignored by the renderer
// The canary.js client interprets a different ordering; fix that
// separately if visual parity matters.
const CELL_FS =
    \\#version 330 core
    \\in vec2 v_uv;
    \\in vec2 v_cellUv;
    \\in vec4 v_fg;
    \\in vec4 v_bg;
    \\flat in int v_attrs;
    \\uniform sampler2DArray u_atlas;
    \\out vec4 fragColor;
    \\void main() {
    \\  int layer = 0;
    \\  if ((v_attrs & 1) != 0) layer = 1;
    \\  else if ((v_attrs & 2) != 0) layer = 2;
    \\  float a = texture(u_atlas, vec3(v_uv, float(layer))).r;
    \\  vec4 fg = v_fg;
    \\  vec4 bg = v_bg;
    \\  if ((v_attrs & 8)  != 0) { vec4 t = fg; fg = bg; bg = t; }
    \\  if ((v_attrs & 32) != 0) fg.rgb *= 0.5;
    \\  vec4 col = mix(bg, fg, a);
    \\  if ((v_attrs & 4) != 0 && v_cellUv.y > 0.86) col = fg;
    \\  if ((v_attrs & 16) != 0 && v_cellUv.y > 0.46 && v_cellUv.y < 0.54) col = fg;
    \\  fragColor = col;
    \\}
    \\
;

const CURSOR_VS =
    \\#version 330 core
    \\in vec2 a_quad;
    \\uniform vec2 u_cursorCell;
    \\uniform vec2 u_cellSize;
    \\uniform vec2 u_viewport;
    \\out vec2 v_q;
    \\void main() {
    \\  vec2 px = (u_cursorCell + a_quad) * u_cellSize;
    \\  vec2 ndc = (px / u_viewport) * 2.0 - 1.0;
    \\  ndc.y = -ndc.y;
    \\  gl_Position = vec4(ndc, 0.0, 1.0);
    \\  v_q = a_quad;
    \\}
    \\
;

const CURSOR_FS =
    \\#version 330 core
    \\uniform int u_cursorStyle;
    \\uniform float u_cursorAlpha;
    \\uniform vec4 u_cursorColor;
    \\in vec2 v_q;
    \\out vec4 fragColor;
    \\void main() {
    \\  bool draw = false;
    \\  if (u_cursorStyle == 1) draw = true;
    \\  else if (u_cursorStyle == 2) draw = v_q.y > 0.86;
    \\  else if (u_cursorStyle == 3) draw = v_q.x < 0.12;
    \\  if (!draw) discard;
    \\  fragColor = vec4(u_cursorColor.rgb, u_cursorColor.a * u_cursorAlpha);
    \\}
    \\
;

const IMAGE_VS =
    \\#version 330 core
    \\in vec2 a_quad;
    \\uniform vec2 a_pos;
    \\uniform vec2 a_size;
    \\uniform vec4 a_uvRect;
    \\uniform vec2 u_cellSize;
    \\uniform vec2 u_viewport;
    \\out vec2 v_uv;
    \\void main() {
    \\  vec2 px = (a_pos + a_quad * a_size) * u_cellSize;
    \\  vec2 ndc = (px / u_viewport) * 2.0 - 1.0;
    \\  ndc.y = -ndc.y;
    \\  gl_Position = vec4(ndc, 0.0, 1.0);
    \\  v_uv = a_uvRect.xy + a_quad * a_uvRect.zw;
    \\}
    \\
;

const IMAGE_FS =
    \\#version 330 core
    \\uniform sampler2D u_img;
    \\in vec2 v_uv;
    \\out vec4 fragColor;
    \\void main() { fragColor = texture(u_img, v_uv); }
    \\
;

// ---- shader / pipeline construction -----------------------------------

fn compile_shader(kind: gl.GLenum, src: [*c]const u8) gl.GLuint {
    const sh = gl.glCreateShader(kind);
    gl.glShaderSource(sh, 1, &src, null);
    gl.glCompileShader(sh);
    var status: gl.GLint = 0;
    gl.glGetShaderiv(sh, gl.GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var log_len: gl.GLint = 0;
        gl.glGetShaderiv(sh, gl.GL_INFO_LOG_LENGTH, &log_len);
        var buf: [4096]u8 = undefined;
        gl.glGetShaderInfoLog(sh, @intCast(@min(log_len, buf.len)), null, &buf[0]);
        std.debug.print("canary-native shader compile fail: {s}\n", .{buf[0..@intCast(log_len)]});
        return 0;
    }
    return sh;
}

fn link_program(vs_src: [*c]const u8, fs_src: [*c]const u8) gl.GLuint {
    const vs = compile_shader(gl.GL_VERTEX_SHADER, vs_src);
    const fs = compile_shader(gl.GL_FRAGMENT_SHADER, fs_src);
    if (vs == 0 or fs == 0) return 0;
    const prog = gl.glCreateProgram();
    gl.glAttachShader(prog, vs);
    gl.glAttachShader(prog, fs);
    gl.glLinkProgram(prog);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(fs);
    var status: gl.GLint = 0;
    gl.glGetProgramiv(prog, gl.GL_LINK_STATUS, &status);
    if (status == 0) {
        var log_len: gl.GLint = 0;
        gl.glGetProgramiv(prog, gl.GL_INFO_LOG_LENGTH, &log_len);
        var buf: [4096]u8 = undefined;
        gl.glGetProgramInfoLog(prog, @intCast(@min(log_len, buf.len)), null, &buf[0]);
        std.debug.print("canary-native link fail: {s}\n", .{buf[0..@intCast(log_len)]});
        return 0;
    }
    return prog;
}

fn init_gl(b: *Backend) bool {
    // Atlas: 2D array texture, R8, 3 layers.
    gl.glGenTextures(1, &b.atlas_tex);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D_ARRAY, b.atlas_tex);
    gl.glTexParameteri(gl.GL_TEXTURE_2D_ARRAY, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D_ARRAY, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D_ARRAY, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D_ARRAY, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    gl.glTexStorage3D(
        gl.GL_TEXTURE_2D_ARRAY,
        1,
        gl.GL_R8,
        ATLAS_COLS * CELL_W,
        ATLAS_ROWS * CELL_H,
        ATLAS_LAYERS,
    );
    // GL_UNPACK_ALIGNMENT defaults to 4; our rows are CELL_W bytes which
    // may not be 4-aligned for sub-rect uploads.  Set to 1 so any width
    // works.
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);

    b.cell_prog = link_program(CELL_VS, CELL_FS);
    b.cursor_prog = link_program(CURSOR_VS, CURSOR_FS);
    b.image_prog = link_program(IMAGE_VS, IMAGE_FS);
    if (b.cell_prog == 0 or b.cursor_prog == 0 or b.image_prog == 0) return false;

    // Cell program uniform locations.
    b.u_cellSize = gl.glGetUniformLocation(b.cell_prog, "u_cellSize");
    b.u_viewport = gl.glGetUniformLocation(b.cell_prog, "u_viewport");
    b.u_atlasCells = gl.glGetUniformLocation(b.cell_prog, "u_atlasCells");
    b.u_atlas = gl.glGetUniformLocation(b.cell_prog, "u_atlas");

    gl.glUseProgram(b.cell_prog);
    gl.glUniform2f(b.u_atlasCells, @floatFromInt(ATLAS_COLS), @floatFromInt(ATLAS_ROWS));
    gl.glUniform1i(b.u_atlas, 0);

    // Cursor program uniform locations.
    b.cu_cell = gl.glGetUniformLocation(b.cursor_prog, "u_cursorCell");
    b.cu_cellSize = gl.glGetUniformLocation(b.cursor_prog, "u_cellSize");
    b.cu_viewport = gl.glGetUniformLocation(b.cursor_prog, "u_viewport");
    b.cu_style = gl.glGetUniformLocation(b.cursor_prog, "u_cursorStyle");
    b.cu_alpha = gl.glGetUniformLocation(b.cursor_prog, "u_cursorAlpha");
    b.cu_color = gl.glGetUniformLocation(b.cursor_prog, "u_cursorColor");

    // Image program uniform locations.
    b.iu_pos = gl.glGetUniformLocation(b.image_prog, "a_pos");
    b.iu_size = gl.glGetUniformLocation(b.image_prog, "a_size");
    b.iu_uv = gl.glGetUniformLocation(b.image_prog, "a_uvRect");
    b.iu_cellSize = gl.glGetUniformLocation(b.image_prog, "u_cellSize");
    b.iu_viewport = gl.glGetUniformLocation(b.image_prog, "u_viewport");
    b.iu_img = gl.glGetUniformLocation(b.image_prog, "u_img");

    // Static quad buffer (two triangles, unit square).
    gl.glGenBuffers(1, &b.quad_buf);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, b.quad_buf);
    const quad = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 1 };
    gl.glBufferData(
        gl.GL_ARRAY_BUFFER,
        @sizeOf(@TypeOf(quad)),
        &quad[0],
        gl.GL_STATIC_DRAW,
    );

    // Streaming per-instance cell buffer.
    gl.glGenBuffers(1, &b.cells_buf);

    // Cell VAO (instanced).
    gl.glGenVertexArrays(1, &b.cell_vao);
    gl.glBindVertexArray(b.cell_vao);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, b.quad_buf);
    const aQuad: gl.GLuint = @intCast(gl.glGetAttribLocation(b.cell_prog, "a_quad"));
    gl.glEnableVertexAttribArray(aQuad);
    gl.glVertexAttribPointer(aQuad, 2, gl.GL_FLOAT, gl.GL_FALSE, 0, null);

    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, b.cells_buf);
    const stride: gl.GLsizei = @intCast(CELL_STRIDE);
    setup_instance_attr(b.cell_prog, "a_cell", 2, stride, 0);
    setup_instance_attr(b.cell_prog, "a_glyph", 1, stride, 8);
    setup_instance_attr(b.cell_prog, "a_fg", 4, stride, 12);
    setup_instance_attr(b.cell_prog, "a_bg", 4, stride, 28);
    setup_instance_attr(b.cell_prog, "a_attrs", 1, stride, 44);

    // Cursor VAO (just the quad).
    gl.glGenVertexArrays(1, &b.cursor_vao);
    gl.glBindVertexArray(b.cursor_vao);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, b.quad_buf);
    const cuQuad: gl.GLuint = @intCast(gl.glGetAttribLocation(b.cursor_prog, "a_quad"));
    gl.glEnableVertexAttribArray(cuQuad);
    gl.glVertexAttribPointer(cuQuad, 2, gl.GL_FLOAT, gl.GL_FALSE, 0, null);

    // Image VAO (just the quad).
    gl.glGenVertexArrays(1, &b.image_vao);
    gl.glBindVertexArray(b.image_vao);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, b.quad_buf);
    const iaQuad: gl.GLuint = @intCast(gl.glGetAttribLocation(b.image_prog, "a_quad"));
    gl.glEnableVertexAttribArray(iaQuad);
    gl.glVertexAttribPointer(iaQuad, 2, gl.GL_FLOAT, gl.GL_FALSE, 0, null);

    gl.glBindVertexArray(0);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);
    return true;
}

fn setup_instance_attr(
    prog: gl.GLuint,
    name: [*c]const u8,
    count: gl.GLint,
    stride: gl.GLsizei,
    offset: usize,
) void {
    const loc = gl.glGetAttribLocation(prog, name);
    if (loc < 0) return;
    const uloc: gl.GLuint = @intCast(loc);
    gl.glEnableVertexAttribArray(uloc);
    gl.glVertexAttribPointer(
        uloc,
        count,
        gl.GL_FLOAT,
        gl.GL_FALSE,
        stride,
        @ptrFromInt(offset),
    );
    gl.glVertexAttribDivisor(uloc, 1);
}

// ---- font loading -----------------------------------------------------

fn font_dir_from_env() []const u8 {
    if (std.posix.getenv("CANARY_NATIVE_FONT_DIR")) |s| return s;
    if (build_options.default_font_dir.len > 0) return build_options.default_font_dir;
    // Dev fallback when neither the env var nor a Guix-baked store path
    // is available.  Works for systems that drop DejaVu in this canonical
    // /run path; otherwise the load_font call below reports the miss.
    return "/run/current-system/profile/share/fonts/truetype";
}

fn load_font(b: *Backend, layer: usize, name: []const u8) bool {
    const dir = font_dir_from_env();
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    var file = std.fs.openFileAbsolute(path, .{}) catch |e| {
        std.debug.print("canary-native font open {s}: {}\n", .{ path, e });
        return false;
    };
    defer file.close();
    const stat = file.stat() catch return false;
    const bytes = b.alloc.alloc(u8, stat.size) catch return false;
    _ = file.readAll(bytes) catch return false;
    b.font_bytes[layer] = bytes;
    const err = ft.FT_New_Memory_Face(
        b.ft_lib,
        bytes.ptr,
        @intCast(bytes.len),
        0,
        &b.fonts[layer],
    );
    if (err != 0) {
        std.debug.print("canary-native FT_New_Memory_Face {s}: 0x{x}\n", .{ path, err });
        return false;
    }
    _ = ft.FT_Set_Pixel_Sizes(b.fonts[layer], 0, @intCast(CELL_H));
    return true;
}

fn init_freetype(b: *Backend) bool {
    if (ft.FT_Init_FreeType(&b.ft_lib) != 0) return false;
    if (!load_font(b, 0, "DejaVuSansMono.ttf")) return false;
    if (!load_font(b, 1, "DejaVuSansMono-Bold.ttf")) return false;
    if (!load_font(b, 2, "DejaVuSansMono-Oblique.ttf")) return false;
    return true;
}

fn ensure_slot(b: *Backend, cp: u32) u16 {
    if (b.glyph_map.get(cp)) |slot| return slot;
    if (b.next_slot >= ATLAS_MAX_SLOTS) return b.fallback_slot;
    const slot = b.next_slot;
    b.next_slot += 1;
    b.glyph_map.put(b.alloc, cp, slot) catch return b.fallback_slot;
    rasterise_glyph(b, cp, slot);
    b.atlas_dirty.put(b.alloc, slot, {}) catch {};
    return slot;
}

fn rasterise_glyph(b: *Backend, cp: u32, slot: u16) void {
    const slot_i: i32 = @intCast(slot);
    const slot_x: gl.GLint = @intCast(@rem(slot_i, ATLAS_COLS) * CELL_W);
    const slot_y: gl.GLint = @intCast(@divTrunc(slot_i, ATLAS_COLS) * CELL_H);

    var staging: [@intCast(CELL_W * CELL_H)]u8 = undefined;
    for (0..ATLAS_LAYERS) |layer| {
        @memset(&staging, 0);
        const face = b.fonts[layer];
        const err = ft.FT_Load_Char(face, cp, ft.FT_LOAD_RENDER | ft.FT_LOAD_TARGET_NORMAL);
        if (err == 0) {
            const bitmap = face.*.glyph.*.bitmap;
            const ascender: i32 = @intCast(face.*.size.*.metrics.ascender >> 6);
            const bm_w: i32 = @intCast(bitmap.width);
            const bm_h: i32 = @intCast(bitmap.rows);
            const bm_left: i32 = face.*.glyph.*.bitmap_left;
            const bm_top: i32 = face.*.glyph.*.bitmap_top;
            // Center horizontally in the cell; align top of glyph relative
            // to baseline at ascender.
            const dx_centre: i32 = @divFloor(CELL_W - bm_w, 2);
            const dx: i32 = if (bm_left > 0) bm_left else dx_centre;
            const dy: i32 = ascender - bm_top;
            blit_grayscale(&staging, CELL_W, CELL_H, bitmap.buffer, bm_w, bm_h, @intCast(bitmap.pitch), dx, dy);
        }
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D_ARRAY, b.atlas_tex);
        gl.glTexSubImage3D(
            gl.GL_TEXTURE_2D_ARRAY,
            0,
            slot_x,
            slot_y,
            @intCast(layer),
            CELL_W,
            CELL_H,
            1,
            gl.GL_RED,
            gl.GL_UNSIGNED_BYTE,
            &staging[0],
        );
    }
}

fn blit_grayscale(
    dst: [*]u8,
    dst_w: i32,
    dst_h: i32,
    src_buf: ?[*]u8,
    src_w: i32,
    src_h: i32,
    src_stride: i32,
    dx: i32,
    dy: i32,
) void {
    const src = src_buf orelse return;
    var y: i32 = 0;
    while (y < src_h) : (y += 1) {
        const yy = dy + y;
        if (yy < 0 or yy >= dst_h) continue;
        var x: i32 = 0;
        while (x < src_w) : (x += 1) {
            const xx = dx + x;
            if (xx < 0 or xx >= dst_w) continue;
            const sidx: usize = @intCast(y * src_stride + x);
            const didx: usize = @intCast(yy * dst_w + xx);
            dst[didx] = src[sidx];
        }
    }
}

// ---- glfw callbacks (fire on the glfw thread) -------------------------

fn push_event(b: *Backend, evt: InputEvent) void {
    b.event_mu.lock();
    defer b.event_mu.unlock();
    b.events.append(b.alloc, evt) catch return;
    var one: u64 = 1;
    _ = std.posix.write(b.eventfd, std.mem.asBytes(&one)) catch {};
}

fn key_callback(window: ?*glfw.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    _ = window;
    const b = g_backend orelse return;
    var act: u8 = 0;
    if (action == glfw.GLFW_RELEASE) act = 1 else if (action == glfw.GLFW_REPEAT) act = 2;
    push_event(b, .{
        .kind = @intFromEnum(InputKind.key),
        .key_sym = @intCast(key),
        .mods = @intCast(mods),
        .action = act,
    });
}

fn char_callback(window: ?*glfw.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    _ = window;
    const b = g_backend orelse return;
    push_event(b, .{
        .kind = @intFromEnum(InputKind.key),
        .key_sym = @intCast(codepoint),
        .action = 0,
        // Char events get mods=0; the corresponding keydown carried the
        // mods so the Scheme side can fold them if needed.
    });
}

fn mouse_button_callback(window: ?*glfw.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = window;
    const b = g_backend orelse return;
    push_event(b, .{
        .kind = @intFromEnum(InputKind.mouse),
        .mouse_button = @intCast(button),
        .action = if (action == glfw.GLFW_PRESS) 0 else 1,
        .mods = @intCast(mods),
        .mouse_x = @intFromFloat(b.mouse_x),
        .mouse_y = @intFromFloat(b.mouse_y),
    });
}

fn cursor_pos_callback(window: ?*glfw.GLFWwindow, x: f64, y: f64) callconv(.c) void {
    _ = window;
    const b = g_backend orelse return;
    b.mouse_x = x;
    b.mouse_y = y;
    push_event(b, .{
        .kind = @intFromEnum(InputKind.mouse),
        .action = 2,
        .mouse_x = @intFromFloat(x),
        .mouse_y = @intFromFloat(y),
    });
}

fn scroll_callback(window: ?*glfw.GLFWwindow, xoff: f64, yoff: f64) callconv(.c) void {
    _ = window;
    _ = xoff;
    const b = g_backend orelse return;
    push_event(b, .{
        .kind = @intFromEnum(InputKind.scroll),
        .scroll_dy = if (yoff > 0) 1 else -1,
        .mouse_x = @intFromFloat(b.mouse_x),
        .mouse_y = @intFromFloat(b.mouse_y),
    });
}

fn framebuffer_size_callback(window: ?*glfw.GLFWwindow, w: c_int, h: c_int) callconv(.c) void {
    _ = window;
    const b = g_backend orelse return;
    b.framebuffer_w = w;
    b.framebuffer_h = h;
    push_event(b, .{
        .kind = @intFromEnum(InputKind.resize),
        .width = @intCast(@max(0, w)),
        .height = @intCast(@max(0, h)),
    });
}

// ---- main loop --------------------------------------------------------

fn build_cells_attribs(b: *Backend) usize {
    b.mailbox_mu.lock();
    defer b.mailbox_mu.unlock();
    const w: usize = b.mailbox_width;
    const h: usize = b.mailbox_height;
    const cells_bytes = b.mailbox_cells.items;
    if (cells_bytes.len < w * h * WIRE_CELL_SIZE) return 0;

    b.cells_attribs.resize(b.alloc, w * h * FLOATS_PER_CELL) catch return 0;
    const out = b.cells_attribs.items;

    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        const off = i * WIRE_CELL_SIZE;
        const cp = std.mem.readInt(u32, cells_bytes[off..][0..4], .little);
        const fg = std.mem.readInt(u32, cells_bytes[off + 4 ..][0..4], .little);
        const bg = std.mem.readInt(u32, cells_bytes[off + 8 ..][0..4], .little);
        const attrs = cells_bytes[off + 12];
        const slot = ensure_slot(b, cp);
        const col: f32 = @floatFromInt(i % w);
        const row: f32 = @floatFromInt(i / w);
        const base = i * FLOATS_PER_CELL;
        out[base + 0] = col;
        out[base + 1] = row;
        out[base + 2] = @floatFromInt(slot);
        unpack_color(fg, out[base + 3 ..][0..4], DEFAULT_FG);
        unpack_color(bg, out[base + 7 ..][0..4], DEFAULT_BG);
        out[base + 11] = @floatFromInt(attrs);
    }
    return w * h;
}

fn unpack_color(packed_color: u32, dst: *[4]f32, fallback: [4]f32) void {
    if (packed_color == COLOR_DEFAULT_SENTINEL) {
        dst.* = fallback;
    } else {
        dst[0] = @as(f32, @floatFromInt((packed_color >> 16) & 0xFF)) / 255.0;
        dst[1] = @as(f32, @floatFromInt((packed_color >> 8) & 0xFF)) / 255.0;
        dst[2] = @as(f32, @floatFromInt(packed_color & 0xFF)) / 255.0;
        dst[3] = 1.0;
    }
}

fn cursor_alpha_now(b: *Backend) f32 {
    if (!b.mailbox_cursor_blink) return 1.0;
    const ms: u64 = @intCast(std.time.milliTimestamp());
    const t = @as(f32, @floatFromInt(ms % 1000)) / 1000.0;
    return 0.5 + 0.5 * @cos(t * 2.0 * std.math.pi);
}

fn run_loop(b: *Backend) void {
    while (glfw.glfwWindowShouldClose(b.window) == 0 and !b.stop_flag.load(.monotonic)) {
        glfw.glfwWaitEventsTimeout(0.016);

        const cell_count = build_cells_attribs(b);
        if (cell_count == 0) continue;

        // Upload the per-instance cell buffer (resize-on-grow strategy).
        const need_bytes: usize = b.cells_attribs.items.len * @sizeOf(f32);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, b.cells_buf);
        if (need_bytes > b.cells_buf_capacity) {
            gl.glBufferData(
                gl.GL_ARRAY_BUFFER,
                @intCast(need_bytes),
                b.cells_attribs.items.ptr,
                gl.GL_STREAM_DRAW,
            );
            b.cells_buf_capacity = need_bytes;
        } else {
            gl.glBufferSubData(
                gl.GL_ARRAY_BUFFER,
                0,
                @intCast(need_bytes),
                b.cells_attribs.items.ptr,
            );
        }

        gl.glViewport(0, 0, b.framebuffer_w, b.framebuffer_h);
        gl.glClearColor(0, 0, 0, 1);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        // Cells.
        gl.glUseProgram(b.cell_prog);
        gl.glBindVertexArray(b.cell_vao);
        gl.glUniform2f(b.u_viewport, @floatFromInt(b.framebuffer_w), @floatFromInt(b.framebuffer_h));
        gl.glUniform2f(b.u_cellSize, @floatFromInt(CELL_W_DEV), @floatFromInt(CELL_H_DEV));
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D_ARRAY, b.atlas_tex);
        gl.glDrawArraysInstanced(gl.GL_TRIANGLES, 0, 6, @intCast(cell_count));

        // Cursor.
        b.mailbox_mu.lock();
        const cursor_style = b.mailbox_cursor_style;
        const cursor_col = b.mailbox_cursor_col;
        const cursor_row = b.mailbox_cursor_row;
        b.mailbox_mu.unlock();
        if (cursor_style != 0) {
            gl.glUseProgram(b.cursor_prog);
            gl.glBindVertexArray(b.cursor_vao);
            gl.glUniform2f(b.cu_cell, @floatFromInt(cursor_col), @floatFromInt(cursor_row));
            gl.glUniform2f(b.cu_cellSize, @floatFromInt(CELL_W_DEV), @floatFromInt(CELL_H_DEV));
            gl.glUniform2f(b.cu_viewport, @floatFromInt(b.framebuffer_w), @floatFromInt(b.framebuffer_h));
            gl.glUniform1i(b.cu_style, @intCast(cursor_style));
            gl.glUniform1f(b.cu_alpha, cursor_alpha_now(b));
            gl.glUniform4f(b.cu_color, DEFAULT_FG[0], DEFAULT_FG[1], DEFAULT_FG[2], 1.0);
            gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
        }

        // Images.
        gl.glUseProgram(b.image_prog);
        gl.glBindVertexArray(b.image_vao);
        gl.glUniform2f(b.iu_cellSize, @floatFromInt(CELL_W_DEV), @floatFromInt(CELL_H_DEV));
        gl.glUniform2f(b.iu_viewport, @floatFromInt(b.framebuffer_w), @floatFromInt(b.framebuffer_h));
        gl.glUniform1i(b.iu_img, 1);
        gl.glActiveTexture(gl.GL_TEXTURE1);
        b.mailbox_mu.lock();
        const placements_snapshot = b.mailbox_placements.clone(b.alloc) catch std.ArrayListUnmanaged(ImagePlacement){};
        b.mailbox_mu.unlock();
        defer {
            var snap = placements_snapshot;
            snap.deinit(b.alloc);
        }
        for (placements_snapshot.items) |p| {
            const entry = b.images.get(p.id) orelse continue;
            gl.glBindTexture(gl.GL_TEXTURE_2D, entry.tex);
            gl.glUniform2f(b.iu_pos, @floatFromInt(p.col), @floatFromInt(p.row));
            gl.glUniform2f(b.iu_size, @floatFromInt(p.w), @floatFromInt(p.h));
            gl.glUniform4f(
                b.iu_uv,
                @as(f32, @floatFromInt(p.sx)) / @as(f32, @floatFromInt(entry.w)),
                @as(f32, @floatFromInt(p.sy)) / @as(f32, @floatFromInt(entry.h)),
                @as(f32, @floatFromInt(p.sw)) / @as(f32, @floatFromInt(entry.w)),
                @as(f32, @floatFromInt(p.sh)) / @as(f32, @floatFromInt(entry.h)),
            );
            gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
        }

        gl.glBindVertexArray(0);
        glfw.glfwSwapBuffers(b.window);
    }
}

// ---- extern "C" Guile FFI surface -------------------------------------

export fn canary_native_create() ?*anyopaque {
    const alloc = std.heap.c_allocator;
    const b = alloc.create(Backend) catch return null;
    b.* = Backend{ .alloc = alloc };
    b.eventfd = blk: {
        const flags = std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC;
        break :blk @intCast(std.os.linux.eventfd(0, flags));
    };
    g_backend = b;
    return @ptrCast(b);
}

export fn canary_native_destroy(handle: ?*anyopaque) void {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    if (b.eventfd >= 0) std.posix.close(b.eventfd);
    b.glyph_map.deinit(b.alloc);
    b.atlas_dirty.deinit(b.alloc);
    b.mailbox_cells.deinit(b.alloc);
    b.mailbox_placements.deinit(b.alloc);
    b.events.deinit(b.alloc);
    b.cells_attribs.deinit(b.alloc);
    for (b.font_bytes) |fb| if (fb.len > 0) b.alloc.free(fb);
    b.alloc.destroy(b);
    g_backend = null;
}

export fn canary_native_run(handle: ?*anyopaque) void {
    const b: *Backend = @ptrCast(@alignCast(handle.?));

    glfw.glfwInitHint(glfw.GLFW_PLATFORM, glfw.GLFW_PLATFORM_WAYLAND);
    if (glfw.glfwInit() == 0) {
        std.debug.print("canary-native glfwInit failed\n", .{});
        return;
    }

    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_FORWARD_COMPAT, gl.GL_TRUE);
    glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_TRUE);

    b.window = glfw.glfwCreateWindow(b.framebuffer_w, b.framebuffer_h, "canary", null, null);
    if (b.window == null) {
        std.debug.print("canary-native glfwCreateWindow failed\n", .{});
        glfw.glfwTerminate();
        return;
    }

    glfw.glfwMakeContextCurrent(b.window);
    glfw.glfwSwapInterval(1);

    glfw.glfwGetFramebufferSize(b.window, &b.framebuffer_w, &b.framebuffer_h);
    var sx: f32 = 1;
    var sy: f32 = 1;
    glfw.glfwGetWindowContentScale(b.window, &sx, &sy);
    b.content_scale = sx;

    _ = glfw.glfwSetKeyCallback(b.window, key_callback);
    _ = glfw.glfwSetCharCallback(b.window, char_callback);
    _ = glfw.glfwSetMouseButtonCallback(b.window, mouse_button_callback);
    _ = glfw.glfwSetCursorPosCallback(b.window, cursor_pos_callback);
    _ = glfw.glfwSetScrollCallback(b.window, scroll_callback);
    _ = glfw.glfwSetFramebufferSizeCallback(b.window, framebuffer_size_callback);

    if (!init_gl(b)) {
        std.debug.print("canary-native init_gl failed\n", .{});
        glfw.glfwDestroyWindow(b.window);
        glfw.glfwTerminate();
        return;
    }
    if (!init_freetype(b)) {
        std.debug.print("canary-native init_freetype failed\n", .{});
        glfw.glfwDestroyWindow(b.window);
        glfw.glfwTerminate();
        return;
    }
    b.fallback_slot = ensure_slot(b, '?');
    _ = ensure_slot(b, ' ');

    // Tell Scheme the initial size by faking a resize event.
    push_event(b, .{
        .kind = @intFromEnum(InputKind.resize),
        .width = @intCast(@max(0, b.framebuffer_w)),
        .height = @intCast(@max(0, b.framebuffer_h)),
    });

    run_loop(b);

    // Cleanup.
    for (b.fonts) |f| {
        if (f != null) _ = ft.FT_Done_Face(f);
    }
    if (b.ft_lib != null) _ = ft.FT_Done_FreeType(b.ft_lib);
    if (b.window != null) glfw.glfwDestroyWindow(b.window);
    glfw.glfwTerminate();
}

export fn canary_native_stop(handle: ?*anyopaque) void {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    b.stop_flag.store(true, .monotonic);
    glfw.glfwPostEmptyEvent();
}

export fn canary_native_eventfd(handle: ?*anyopaque) c_int {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    return b.eventfd;
}

// Returns next event by writing fields into the supplied out-params.
// Returns 1 if an event was drained, 0 if the queue is empty.
export fn canary_native_next_event(
    handle: ?*anyopaque,
    out_kind: *u8,
    out_sym: *u32,
    out_mods: *u8,
    out_action: *u8,
    out_x: *i32,
    out_y: *i32,
    out_button: *u8,
    out_w: *u16,
    out_h: *u16,
    out_scroll: *i8,
) c_int {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    b.event_mu.lock();
    defer b.event_mu.unlock();
    if (b.events.items.len == 0) return 0;
    const evt = b.events.orderedRemove(0);
    out_kind.* = evt.kind;
    out_sym.* = evt.key_sym;
    out_mods.* = evt.mods;
    out_action.* = evt.action;
    out_x.* = evt.mouse_x;
    out_y.* = evt.mouse_y;
    out_button.* = evt.mouse_button;
    out_w.* = evt.width;
    out_h.* = evt.height;
    out_scroll.* = evt.scroll_dy;
    return 1;
}

// Drain the eventfd counter (Scheme side calls after waking from poll).
export fn canary_native_drain_eventfd(handle: ?*anyopaque) void {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    var counter: u64 = 0;
    _ = std.posix.read(b.eventfd, std.mem.asBytes(&counter)) catch {};
}

// Blocking wait for the next eventfd notification.  The eventfd was
// created with EFD_NONBLOCK; this call uses ppoll to block until the
// fd is readable, then drains one counter via eventfd's atomic 8-byte
// read.  Returns 0 on shutdown (stop_flag set or read returns 0).
export fn canary_native_wait_event(handle: ?*anyopaque) c_int {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    var pfd = std.posix.pollfd{
        .fd = b.eventfd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };
    while (!b.stop_flag.load(.monotonic)) {
        const n = std.posix.poll(@as([*]std.posix.pollfd, @ptrCast(&pfd))[0..1], 250) catch {
            return 0;
        };
        if (n == 0) continue; // timeout; loop and check stop_flag
        if ((pfd.revents & std.posix.POLL.IN) != 0) {
            var counter: u64 = 0;
            _ = std.posix.read(b.eventfd, std.mem.asBytes(&counter)) catch return 0;
            return 1;
        }
    }
    return 0;
}

export fn canary_native_submit_frame(
    handle: ?*anyopaque,
    cells_ptr: [*]const u8,
    cells_len: usize,
    width: u16,
    height: u16,
    cursor_col: u16,
    cursor_row: u16,
    cursor_style: u8,
    cursor_blink: c_int,
) void {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    b.mailbox_mu.lock();
    defer b.mailbox_mu.unlock();
    b.mailbox_cells.resize(b.alloc, cells_len) catch return;
    @memcpy(b.mailbox_cells.items, cells_ptr[0..cells_len]);
    b.mailbox_width = width;
    b.mailbox_height = height;
    b.mailbox_cursor_col = cursor_col;
    b.mailbox_cursor_row = cursor_row;
    b.mailbox_cursor_style = cursor_style;
    b.mailbox_cursor_blink = cursor_blink != 0;
    b.mailbox_dirty = true;
    glfw.glfwPostEmptyEvent();
}

export fn canary_native_set_title(handle: ?*anyopaque, title: [*:0]const u8) void {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    if (b.window) |w| glfw.glfwSetWindowTitle(w, title);
}

export fn canary_native_cell_w_dev() c_int {
    return CELL_W_DEV;
}

export fn canary_native_cell_h_dev() c_int {
    return CELL_H_DEV;
}
