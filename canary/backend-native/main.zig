//! Native renderer driven by (canary backend-native).  See that module
//! for threading model, defaults, and the FFI contract.

const std = @import("std");
const builtin = @import("builtin");

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

extern fn cn_scm_undefined() guile.SCM;
extern fn cn_scm_unspecified() guile.SCM;
extern fn cn_scm_is_undefined(s: guile.SCM) c_int;

const WIRE_CELL_SIZE: usize = 13;
const FLOATS_PER_CELL: usize = 12;
const CELL_STRIDE: usize = FLOATS_PER_CELL * @sizeOf(f32);
const COLOR_DEFAULT_SENTINEL: u32 = 0xFFFFFFFF;

const MAX_LAYERS: usize = 8;

const InputKind = enum(u8) {
    key = 1,
    mouse = 2,
    resize = 3,
    paste = 4,
    scroll = 5,
    quit = 6,
};

const InputEvent = extern struct {
    kind: u8,
    key_sym: u32 = 0,
    mods: u8 = 0,
    action: u8 = 0,
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

const FontConfig = extern struct {
    font_paths: [*]const [*:0]const u8,
    n_paths: u32,
    font_px: i32,
};

const NativeConfig = extern struct {
    cell_w_dev: i32,
    cell_h_dev: i32,
    font_px_dev: i32,
    atlas_oversample: i32,
    atlas_cols: i32,
    atlas_rows: i32,
    n_layers: u32,
    default_fg: u32,
    default_bg: u32,
    underline_y: f32,
    strike_y_min: f32,
    strike_y_max: f32,
    layer_for_bold: i32,
    layer_for_italic: i32,
};

const Backend = struct {
    alloc: std.mem.Allocator,

    cell_w_dev: i32 = 0,
    cell_h_dev: i32 = 0,
    font_px_dev: i32 = 0,
    atlas_oversample: i32 = 0,
    atlas_cols: i32 = 0,
    atlas_rows: i32 = 0,
    n_layers: u32 = 0,
    default_fg: u32 = COLOR_DEFAULT_SENTINEL,
    default_bg: u32 = COLOR_DEFAULT_SENTINEL,
    underline_y: f32 = 0,
    strike_y_min: f32 = 0,
    strike_y_max: f32 = 0,
    layer_for_bold: i32 = -1,
    layer_for_italic: i32 = -1,

    cell_w: i32 = 0,
    cell_h: i32 = 0,
    font_px: i32 = 0,
    atlas_max_slots: u16 = 0,

    ft_lib: ft.FT_Library = null,
    fonts: [MAX_LAYERS]ft.FT_Face = @splat(@as(ft.FT_Face, null)),
    font_bytes: [MAX_LAYERS][]u8 = @splat(@as([]u8, &.{})),

    window: ?*glfw.GLFWwindow = null,
    framebuffer_w: i32 = 800,
    framebuffer_h: i32 = 600,
    content_scale: f32 = 1.0,

    atlas_tex: gl.GLuint = 0,
    cell_prog: gl.GLuint = 0,
    cursor_prog: gl.GLuint = 0,
    image_prog: gl.GLuint = 0,
    quad_buf: gl.GLuint = 0,
    cells_buf: gl.GLuint = 0,
    cell_vao: gl.GLuint = 0,
    cursor_vao: gl.GLuint = 0,
    image_vao: gl.GLuint = 0,
    cells_buf_capacity: usize = 0,
    fallback_slot: u16 = 0,

    u_cellSize: gl.GLint = -1,
    u_viewport: gl.GLint = -1,
    u_atlasCells: gl.GLint = -1,
    u_atlas: gl.GLint = -1,
    u_layer_for_bold: gl.GLint = -1,
    u_layer_for_italic: gl.GLint = -1,
    u_underline_y: gl.GLint = -1,
    u_strike_y_min: gl.GLint = -1,
    u_strike_y_max: gl.GLint = -1,

    cu_cell: gl.GLint = -1,
    cu_cellSize: gl.GLint = -1,
    cu_viewport: gl.GLint = -1,
    cu_style: gl.GLint = -1,
    cu_alpha: gl.GLint = -1,
    cu_color: gl.GLint = -1,

    iu_pos: gl.GLint = -1,
    iu_size: gl.GLint = -1,
    iu_uv: gl.GLint = -1,
    iu_cellSize: gl.GLint = -1,
    iu_viewport: gl.GLint = -1,
    iu_img: gl.GLint = -1,

    glyph_map: std.AutoHashMapUnmanaged(u32, u16) = .{},
    next_slot: u16 = 0,
    atlas_dirty: std.AutoHashMapUnmanaged(u16, void) = .{},

    images: std.AutoHashMapUnmanaged(u32, ImageEntry) = .{},

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
    cells_attribs: std.ArrayListUnmanaged(f32) = .{},

    event_mu: std.Thread.Mutex = .{},
    events: std.ArrayListUnmanaged(InputEvent) = .{},
    eventfd: i32 = -1,

    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
};

var g_backend: ?*Backend = null;

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

const CELL_FS =
    \\#version 330 core
    \\in vec2 v_uv;
    \\in vec2 v_cellUv;
    \\in vec4 v_fg;
    \\in vec4 v_bg;
    \\flat in int v_attrs;
    \\uniform sampler2DArray u_atlas;
    \\uniform int u_layer_for_bold;
    \\uniform int u_layer_for_italic;
    \\uniform float u_underline_y;
    \\uniform float u_strike_y_min;
    \\uniform float u_strike_y_max;
    \\out vec4 fragColor;
    \\void main() {
    \\  int layer = 0;
    \\  if ((v_attrs & 1) != 0 && u_layer_for_bold >= 0) layer = u_layer_for_bold;
    \\  else if ((v_attrs & 2) != 0 && u_layer_for_italic >= 0) layer = u_layer_for_italic;
    \\  float a = texture(u_atlas, vec3(v_uv, float(layer))).r;
    \\  vec4 fg = v_fg;
    \\  vec4 bg = v_bg;
    \\  if ((v_attrs & 8)  != 0) { vec4 t = fg; fg = bg; bg = t; }
    \\  if ((v_attrs & 32) != 0) fg.rgb *= 0.5;
    \\  vec4 col = mix(bg, fg, a);
    \\  if ((v_attrs & 4) != 0 && v_cellUv.y > u_underline_y) col = fg;
    \\  if ((v_attrs & 16) != 0 && v_cellUv.y > u_strike_y_min && v_cellUv.y < u_strike_y_max) col = fg;
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
        std.debug.print("canary-native shader compile: {s}\n", .{buf[0..@intCast(log_len)]});
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
        std.debug.print("canary-native link: {s}\n", .{buf[0..@intCast(log_len)]});
        return 0;
    }
    return prog;
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

fn init_gl(b: *Backend) bool {
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
        b.atlas_cols * b.cell_w,
        b.atlas_rows * b.cell_h,
        @intCast(b.n_layers),
    );
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);

    b.cell_prog = link_program(CELL_VS, CELL_FS);
    b.cursor_prog = link_program(CURSOR_VS, CURSOR_FS);
    b.image_prog = link_program(IMAGE_VS, IMAGE_FS);
    if (b.cell_prog == 0 or b.cursor_prog == 0 or b.image_prog == 0) return false;

    b.u_cellSize = gl.glGetUniformLocation(b.cell_prog, "u_cellSize");
    b.u_viewport = gl.glGetUniformLocation(b.cell_prog, "u_viewport");
    b.u_atlasCells = gl.glGetUniformLocation(b.cell_prog, "u_atlasCells");
    b.u_atlas = gl.glGetUniformLocation(b.cell_prog, "u_atlas");
    b.u_layer_for_bold = gl.glGetUniformLocation(b.cell_prog, "u_layer_for_bold");
    b.u_layer_for_italic = gl.glGetUniformLocation(b.cell_prog, "u_layer_for_italic");
    b.u_underline_y = gl.glGetUniformLocation(b.cell_prog, "u_underline_y");
    b.u_strike_y_min = gl.glGetUniformLocation(b.cell_prog, "u_strike_y_min");
    b.u_strike_y_max = gl.glGetUniformLocation(b.cell_prog, "u_strike_y_max");

    gl.glUseProgram(b.cell_prog);
    gl.glUniform2f(b.u_atlasCells, @floatFromInt(b.atlas_cols), @floatFromInt(b.atlas_rows));
    gl.glUniform1i(b.u_atlas, 0);
    gl.glUniform1i(b.u_layer_for_bold, b.layer_for_bold);
    gl.glUniform1i(b.u_layer_for_italic, b.layer_for_italic);
    gl.glUniform1f(b.u_underline_y, b.underline_y);
    gl.glUniform1f(b.u_strike_y_min, b.strike_y_min);
    gl.glUniform1f(b.u_strike_y_max, b.strike_y_max);

    b.cu_cell = gl.glGetUniformLocation(b.cursor_prog, "u_cursorCell");
    b.cu_cellSize = gl.glGetUniformLocation(b.cursor_prog, "u_cellSize");
    b.cu_viewport = gl.glGetUniformLocation(b.cursor_prog, "u_viewport");
    b.cu_style = gl.glGetUniformLocation(b.cursor_prog, "u_cursorStyle");
    b.cu_alpha = gl.glGetUniformLocation(b.cursor_prog, "u_cursorAlpha");
    b.cu_color = gl.glGetUniformLocation(b.cursor_prog, "u_cursorColor");

    b.iu_pos = gl.glGetUniformLocation(b.image_prog, "a_pos");
    b.iu_size = gl.glGetUniformLocation(b.image_prog, "a_size");
    b.iu_uv = gl.glGetUniformLocation(b.image_prog, "a_uvRect");
    b.iu_cellSize = gl.glGetUniformLocation(b.image_prog, "u_cellSize");
    b.iu_viewport = gl.glGetUniformLocation(b.image_prog, "u_viewport");
    b.iu_img = gl.glGetUniformLocation(b.image_prog, "u_img");

    gl.glGenBuffers(1, &b.quad_buf);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, b.quad_buf);
    const quad = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 1 };
    gl.glBufferData(
        gl.GL_ARRAY_BUFFER,
        @sizeOf(@TypeOf(quad)),
        &quad[0],
        gl.GL_STATIC_DRAW,
    );

    gl.glGenBuffers(1, &b.cells_buf);

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

    gl.glGenVertexArrays(1, &b.cursor_vao);
    gl.glBindVertexArray(b.cursor_vao);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, b.quad_buf);
    const cuQuad: gl.GLuint = @intCast(gl.glGetAttribLocation(b.cursor_prog, "a_quad"));
    gl.glEnableVertexAttribArray(cuQuad);
    gl.glVertexAttribPointer(cuQuad, 2, gl.GL_FLOAT, gl.GL_FALSE, 0, null);

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

fn load_font_file(b: *Backend, layer: usize, path: [*:0]const u8) bool {
    var file = std.fs.openFileAbsoluteZ(path, .{}) catch return false;
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
    return err == 0;
}

fn ensure_slot(b: *Backend, cp: u32) u16 {
    if (b.glyph_map.get(cp)) |slot| return slot;
    if (b.next_slot >= b.atlas_max_slots) return b.fallback_slot;
    const slot = b.next_slot;
    b.next_slot += 1;
    b.glyph_map.put(b.alloc, cp, slot) catch return b.fallback_slot;
    rasterise_glyph(b, cp, slot);
    b.atlas_dirty.put(b.alloc, slot, {}) catch {};
    return slot;
}

fn rasterise_glyph(b: *Backend, cp: u32, slot: u16) void {
    const slot_i: i32 = @intCast(slot);
    const slot_x: gl.GLint = @intCast(@rem(slot_i, b.atlas_cols) * b.cell_w);
    const slot_y: gl.GLint = @intCast(@divTrunc(slot_i, b.atlas_cols) * b.cell_h);

    const staging_len: usize = @intCast(b.cell_w * b.cell_h);
    const staging = b.alloc.alloc(u8, staging_len) catch return;
    defer b.alloc.free(staging);

    for (0..b.n_layers) |layer| {
        @memset(staging, 0);
        const face = b.fonts[layer];
        if (face == null) continue;
        const err = ft.FT_Load_Char(face, cp, ft.FT_LOAD_RENDER | ft.FT_LOAD_TARGET_NORMAL);
        if (err == 0) {
            const bitmap = face.*.glyph.*.bitmap;
            const ascender_px: i32 = @intCast(face.*.size.*.metrics.ascender >> 6);
            const descender_px: i32 = @intCast(-(face.*.size.*.metrics.descender >> 6));
            const bm_w: i32 = @intCast(bitmap.width);
            const bm_h: i32 = @intCast(bitmap.rows);
            const bm_left: i32 = face.*.glyph.*.bitmap_left;
            const bm_top: i32 = face.*.glyph.*.bitmap_top;
            // Baseline placement: centre the font's ascender+descender
            // span vertically inside the cell so descenders fit even when
            // the font's natural metrics exceed cell_h.
            _ = bm_left;
            const baseline: i32 = @divFloor(b.cell_h + ascender_px - descender_px, 2);
            const dx: i32 = @divFloor(b.cell_w - bm_w, 2);
            const dy: i32 = baseline - bm_top;
            blit_grayscale(staging.ptr, b.cell_w, b.cell_h, bitmap.buffer, bm_w, bm_h, @intCast(bitmap.pitch), dx, dy);
        }
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D_ARRAY, b.atlas_tex);
        gl.glTexSubImage3D(
            gl.GL_TEXTURE_2D_ARRAY,
            0,
            slot_x,
            slot_y,
            @intCast(layer),
            b.cell_w,
            b.cell_h,
            1,
            gl.GL_RED,
            gl.GL_UNSIGNED_BYTE,
            staging.ptr,
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
        unpack_color(fg, out[base + 3 ..][0..4], b.default_fg, .{ 1, 1, 1, 1 });
        unpack_color(bg, out[base + 7 ..][0..4], b.default_bg, .{ 0, 0, 0, 1 });
        out[base + 11] = @floatFromInt(attrs);
    }
    return w * h;
}

fn rgb_to_rgba(packed_color: u32, dst: *[4]f32) void {
    dst[0] = @as(f32, @floatFromInt((packed_color >> 16) & 0xFF)) / 255.0;
    dst[1] = @as(f32, @floatFromInt((packed_color >> 8) & 0xFF)) / 255.0;
    dst[2] = @as(f32, @floatFromInt(packed_color & 0xFF)) / 255.0;
    dst[3] = 1.0;
}

fn unpack_color(packed_color: u32, dst: *[4]f32, backend_default: u32, ultimate_fallback: [4]f32) void {
    if (packed_color != COLOR_DEFAULT_SENTINEL) {
        rgb_to_rgba(packed_color, dst);
    } else if (backend_default != COLOR_DEFAULT_SENTINEL) {
        rgb_to_rgba(backend_default, dst);
    } else {
        dst.* = ultimate_fallback;
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
        if (glfw.glfwWindowShouldClose(b.window) != 0) {
            push_event(b, .{ .kind = @intFromEnum(InputKind.quit) });
            break;
        }

        const cell_count = build_cells_attribs(b);
        if (cell_count == 0) continue;

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
        var clear_rgba: [4]f32 = .{ 0, 0, 0, 1 };
        if (b.default_bg != COLOR_DEFAULT_SENTINEL) rgb_to_rgba(b.default_bg, &clear_rgba);
        gl.glClearColor(clear_rgba[0], clear_rgba[1], clear_rgba[2], clear_rgba[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        gl.glUseProgram(b.cell_prog);
        gl.glBindVertexArray(b.cell_vao);
        gl.glUniform2f(b.u_viewport, @floatFromInt(b.framebuffer_w), @floatFromInt(b.framebuffer_h));
        gl.glUniform2f(b.u_cellSize, @floatFromInt(b.cell_w_dev), @floatFromInt(b.cell_h_dev));
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D_ARRAY, b.atlas_tex);
        gl.glDrawArraysInstanced(gl.GL_TRIANGLES, 0, 6, @intCast(cell_count));

        b.mailbox_mu.lock();
        const cursor_style = b.mailbox_cursor_style;
        const cursor_col = b.mailbox_cursor_col;
        const cursor_row = b.mailbox_cursor_row;
        b.mailbox_mu.unlock();
        if (cursor_style != 0) {
            gl.glUseProgram(b.cursor_prog);
            gl.glBindVertexArray(b.cursor_vao);
            gl.glUniform2f(b.cu_cell, @floatFromInt(cursor_col), @floatFromInt(cursor_row));
            gl.glUniform2f(b.cu_cellSize, @floatFromInt(b.cell_w_dev), @floatFromInt(b.cell_h_dev));
            gl.glUniform2f(b.cu_viewport, @floatFromInt(b.framebuffer_w), @floatFromInt(b.framebuffer_h));
            gl.glUniform1i(b.cu_style, @intCast(cursor_style));
            gl.glUniform1f(b.cu_alpha, cursor_alpha_now(b));
            var cursor_rgba: [4]f32 = .{ 1, 1, 1, 1 };
            if (b.default_fg != COLOR_DEFAULT_SENTINEL) rgb_to_rgba(b.default_fg, &cursor_rgba);
            gl.glUniform4f(b.cu_color, cursor_rgba[0], cursor_rgba[1], cursor_rgba[2], 1.0);
            gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
        }

        gl.glUseProgram(b.image_prog);
        gl.glBindVertexArray(b.image_vao);
        gl.glUniform2f(b.iu_cellSize, @floatFromInt(b.cell_w_dev), @floatFromInt(b.cell_h_dev));
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

// --- FFI exports ---------------------------------------------------------

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
    for (b.fonts) |f| {
        if (f != null) _ = ft.FT_Done_Face(f);
    }
    if (b.ft_lib != null) _ = ft.FT_Done_FreeType(b.ft_lib);
    for (b.font_bytes) |fb| {
        if (fb.len > 0) b.alloc.free(fb);
    }
    b.glyph_map.deinit(b.alloc);
    b.atlas_dirty.deinit(b.alloc);
    b.mailbox_cells.deinit(b.alloc);
    b.mailbox_placements.deinit(b.alloc);
    b.events.deinit(b.alloc);
    b.cells_attribs.deinit(b.alloc);
    b.alloc.destroy(b);
    g_backend = null;
}

export fn canary_native_configure_font(handle: ?*anyopaque, cfg: *const FontConfig) c_int {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    if (cfg.n_paths == 0 or cfg.n_paths > MAX_LAYERS) return -1;
    if (cfg.font_px <= 0) return -1;
    if (b.ft_lib == null) {
        if (ft.FT_Init_FreeType(&b.ft_lib) != 0) return -2;
    }
    const n: usize = cfg.n_paths;
    for (0..n) |i| {
        const path = cfg.font_paths[i];
        if (!load_font_file(b, i, path)) return -3;
        _ = ft.FT_Set_Pixel_Sizes(b.fonts[i], 0, @intCast(cfg.font_px));
    }
    b.font_px = cfg.font_px;
    b.n_layers = @intCast(n);
    return 0;
}

export fn canary_native_query_cell_size(
    handle: ?*anyopaque,
    out_cell_w: *i32,
    out_cell_h: *i32,
) c_int {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    if (b.fonts[0] == null) return -1;
    const face = b.fonts[0];
    const advance: i32 = @intCast(face.*.size.*.metrics.max_advance >> 6);
    const ascender: i32 = @intCast(face.*.size.*.metrics.ascender >> 6);
    const descender: i32 = @intCast(-(face.*.size.*.metrics.descender >> 6));
    out_cell_w.* = advance;
    out_cell_h.* = ascender + descender;
    return 0;
}

export fn canary_native_configure(handle: ?*anyopaque, cfg: *const NativeConfig) c_int {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    if (cfg.cell_w_dev <= 0 or cfg.cell_h_dev <= 0) return -1;
    if (cfg.font_px_dev <= 0) return -1;
    if (cfg.atlas_oversample < 1) return -1;
    if (cfg.atlas_cols <= 0 or cfg.atlas_rows <= 0) return -1;
    if (cfg.n_layers == 0 or cfg.n_layers > MAX_LAYERS) return -1;
    if (cfg.n_layers != b.n_layers) return -1;
    if (cfg.underline_y < 0 or cfg.underline_y > 1) return -1;
    if (cfg.strike_y_min < 0 or cfg.strike_y_min > 1) return -1;
    if (cfg.strike_y_max < 0 or cfg.strike_y_max > 1) return -1;

    b.cell_w_dev = cfg.cell_w_dev;
    b.cell_h_dev = cfg.cell_h_dev;
    b.font_px_dev = cfg.font_px_dev;
    b.atlas_oversample = cfg.atlas_oversample;
    b.atlas_cols = cfg.atlas_cols;
    b.atlas_rows = cfg.atlas_rows;
    b.default_fg = cfg.default_fg;
    b.default_bg = cfg.default_bg;
    b.underline_y = cfg.underline_y;
    b.strike_y_min = cfg.strike_y_min;
    b.strike_y_max = cfg.strike_y_max;
    b.layer_for_bold = cfg.layer_for_bold;
    b.layer_for_italic = cfg.layer_for_italic;

    b.cell_w = cfg.cell_w_dev * cfg.atlas_oversample;
    b.cell_h = cfg.cell_h_dev * cfg.atlas_oversample;
    b.font_px = cfg.font_px_dev * cfg.atlas_oversample;
    b.atlas_max_slots = @intCast(cfg.atlas_cols * cfg.atlas_rows);
    // FreeType pixel size for atlas rasterization sits at the
    // oversampled px; LINEAR downsample restores cell-pixel size.
    for (0..b.n_layers) |i| {
        if (b.fonts[i] == null) continue;
        _ = ft.FT_Set_Pixel_Sizes(b.fonts[i], 0, @intCast(b.font_px));
    }

    b.framebuffer_w = cfg.cell_w_dev * 80;
    b.framebuffer_h = cfg.cell_h_dev * 24;
    return 0;
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
        glfw.glfwDestroyWindow(b.window);
        glfw.glfwTerminate();
        return;
    }
    b.fallback_slot = ensure_slot(b, '?');
    _ = ensure_slot(b, ' ');

    push_event(b, .{
        .kind = @intFromEnum(InputKind.resize),
        .width = @intCast(@max(0, b.framebuffer_w)),
        .height = @intCast(@max(0, b.framebuffer_h)),
    });

    run_loop(b);

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

export fn canary_native_wait_event(handle: ?*anyopaque) c_int {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    var pfd = std.posix.pollfd{
        .fd = b.eventfd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };
    while (!b.stop_flag.load(.monotonic)) {
        const n = std.posix.poll(@as([*]std.posix.pollfd, @ptrCast(&pfd))[0..1], 250) catch return 0;
        if (n == 0) continue;
        if ((pfd.revents & std.posix.POLL.IN) != 0) {
            var counter: u64 = 0;
            _ = std.posix.read(b.eventfd, std.mem.asBytes(&counter)) catch return 0;
            return 1;
        }
    }
    return 0;
}

export fn canary_native_drain_eventfd(handle: ?*anyopaque) void {
    const b: *Backend = @ptrCast(@alignCast(handle.?));
    var counter: u64 = 0;
    _ = std.posix.read(b.eventfd, std.mem.asBytes(&counter)) catch {};
}

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
