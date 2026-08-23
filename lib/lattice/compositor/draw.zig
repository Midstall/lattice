//! draw.zig: textured-quad helper for compositing a hosted surface.
//!
//! Provides:
//!   - Rect: pixel-space rect in the render target.
//!   - quadVertices(rect, rt_w, rt_h) -> [24]f32: 6 vertices (2 triangles),
//!     each vertex is (ndc_x, ndc_y, u, v). Pure function, unit-tested.
//!   - DrawCache: lazily-built pipeline + context cache (stored on Compositor).
//!
//! drawSurface is implemented as a method on Compositor in compositor.zig.
//!
//! Shader GLSL ES 1.00 (mirrors triangle.zig pattern):
//!   VS: attribute vec2 aPos; attribute vec2 aUv; varying vec2 vUv;
//!       void main() { gl_Position = vec4(aPos,0.0,1.0); vUv = aUv; }
//!   FS: precision mediump float; uniform sampler2D uTex; varying vec2 vUv;
//!       void main() { gl_FragColor = texture2D(uTex, vUv); }

const std = @import("std");
const prism = @import("prism");

// ---------------------------------------------------------------------------
// Rect
// ---------------------------------------------------------------------------

/// Axis-aligned rectangle in the render target's pixel space.
/// Origin at the top-left corner of the render target.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

// ---------------------------------------------------------------------------
// Vertex layout
// ---------------------------------------------------------------------------

/// One vertex for the textured quad: NDC position (x, y) + UV (u, v).
/// Laid out as 4 tightly-packed f32 values in the vertex buffer.
pub const QuadVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
};

// ---------------------------------------------------------------------------
// Pure helper: quadVertices
// ---------------------------------------------------------------------------

/// Produce 6 vertices (two triangles forming a quad) for a surface at `rect`
/// drawn into a render target of size `rt_w` x `rt_h`.
///
/// NDC mapping (y-flipped: pixel-top -> NDC-top):
///   ndc_x = (px / rt_w) * 2 - 1
///   ndc_y = 1 - (py / rt_h) * 2
///
/// UV mapping:
///   top-left  -> (0, 0)
///   top-right -> (1, 0)
///   bot-left  -> (0, 1)
///   bot-right -> (1, 1)
///
/// Triangle 0: TL, TR, BL
/// Triangle 1: TR, BR, BL
///
/// Returns 6 QuadVertex values as a flat [24]f32
/// (each vertex = [x, y, u, v] = 4 f32, 6 * 4 = 24).
pub fn quadVertices(rect: Rect, rt_w: f32, rt_h: f32) [24]f32 {
    const x0 = (rect.x / rt_w) * 2.0 - 1.0;
    const y0 = 1.0 - (rect.y / rt_h) * 2.0;
    const x1 = ((rect.x + rect.w) / rt_w) * 2.0 - 1.0;
    const y1 = 1.0 - ((rect.y + rect.h) / rt_h) * 2.0;

    // TL = (x0, y0, 0, 0)
    // TR = (x1, y0, 1, 0)
    // BL = (x0, y1, 0, 1)
    // BR = (x1, y1, 1, 1)
    return [24]f32{
        // Triangle 0: TL, TR, BL
        x0, y0, 0.0, 0.0, // TL
        x1, y0, 1.0, 0.0, // TR
        x0, y1, 0.0, 1.0, // BL
        // Triangle 1: TR, BR, BL
        x1, y0, 1.0, 0.0, // TR
        x1, y1, 1.0, 1.0, // BR
        x0, y1, 0.0, 1.0, // BL
    };
}

// ---------------------------------------------------------------------------
// GLSL ES 1.00 shaders
// ---------------------------------------------------------------------------

pub const vs_src =
    \\attribute vec2 aPos;
    \\attribute vec2 aUv;
    \\varying vec2 vUv;
    \\void main() { gl_Position = vec4(aPos, 0.0, 1.0); vUv = aUv; }
;

pub const fs_src =
    \\precision mediump float;
    \\uniform sampler2D uTex;
    \\varying vec2 vUv;
    \\void main() { gl_FragColor = texture2D(uTex, vUv); }
;

// ---------------------------------------------------------------------------
// Vertex attribute helpers (mirroring triangle.zig)
// ---------------------------------------------------------------------------

fn attrFormat(n: u8) prism.hal.Format {
    return switch (n) {
        2 => .r32g32_float,
        else => .r32g32b32a32_float,
    };
}

fn attrOffset(name: []const u8) u32 {
    // aPos is at offset 0 (2 f32 = 8 bytes); aUv follows at offset 8.
    return if (std.mem.eql(u8, name, "aPos")) 0 else 8;
}

// ---------------------------------------------------------------------------
// Pipeline cache: lazily built and stored on the Compositor.
// ---------------------------------------------------------------------------

/// All GPU resources the drawSurface path needs, built once on first call.
pub const DrawCache = struct {
    vs: *prism.ShaderModule,
    fs: *prism.ShaderModule,
    /// Opaque pipeline used by drawSurface (no alpha blend; opaque surfaces).
    pipeline: *prism.Pipeline,
    /// Alpha-blend pipeline used by drawCursor (transparent pixels blend over scene).
    cursor_pipeline: *prism.Pipeline,
    vbuf: *prism.Resource,
    ctx: prism.Context,
    /// The texture binding slot for the sampler uniform (uTex).
    /// Determined by GLSL reflection at pipeline creation time.
    sampler_binding: u32,

    /// Build the draw cache from `device`.
    /// `gpa` is used for the temporary SPIR-V compilation buffers only.
    pub fn init(gpa: std.mem.Allocator, device: *prism.Device) !DrawCache {
        // Compile shaders with layout reflection to get attribute + sampler bindings.
        var cvs = try prism.glsl.compileForStageWithLayout(gpa, vs_src, .vertex);
        defer cvs.deinit(gpa);
        var cfs = try prism.glsl.compileForStageWithLayout(gpa, fs_src, .fragment);
        defer cfs.deinit(gpa);

        // Determine the sampler binding slot from reflection (default 2 if no samplers).
        const sampler_binding: u32 = if (cfs.samplers.len > 0) cfs.samplers[0].binding else 2;

        // Build shader modules (shared between both pipelines).
        const vs = try device.createShaderModule(.{ .stage = .vertex, .code = cvs.spirv });
        errdefer device.destroyShaderModule(vs);
        const fs = try device.createShaderModule(.{ .stage = .fragment, .code = cfs.spirv });
        errdefer device.destroyShaderModule(fs);

        // Build vertex layout from GLSL attribute reflection.
        var attrs: [4]prism.hal.VertexAttribute = undefined;
        const n_attrs = @min(cvs.attributes.len, attrs.len);
        for (cvs.attributes[0..n_attrs], 0..n_attrs) |a, i| {
            attrs[i] = .{
                .location = a.location,
                .format = attrFormat(a.components),
                .offset = attrOffset(a.name),
            };
        }

        const vertex_layout = prism.hal.VertexLayout{
            .stride = @sizeOf(QuadVertex),
            .attributes = attrs[0..n_attrs],
        };

        // Opaque pipeline: no blending (surfaces, solid background compositing).
        const pipeline = try device.createPipeline(.{
            .vertex = vs,
            .fragment = fs,
            .vertex_layout = vertex_layout,
            .color_format = .rgba8_unorm,
        });
        errdefer device.destroyPipeline(pipeline);

        // Cursor pipeline: standard src-alpha blend so transparent corners let the
        // composited scene show through.
        const cursor_pipeline = try device.createPipeline(.{
            .vertex = vs,
            .fragment = fs,
            .vertex_layout = vertex_layout,
            .color_format = .rgba8_unorm,
            .blend = .{
                .enable = true,
                .src_color = .src_alpha,
                .dst_color = .one_minus_src_alpha,
                .src_alpha = .one,
                .dst_alpha = .one_minus_src_alpha,
            },
        });
        errdefer device.destroyPipeline(cursor_pipeline);

        // Allocate a vertex buffer sized for 6 vertices (two triangles).
        const vbuf = try device.createResource(.{
            .buffer = .{
                .size = 6 * @sizeOf(QuadVertex),
                .usage = .{ .vertex = true },
            },
        });
        errdefer device.destroyResource(vbuf);

        const ctx = try device.createContext();
        errdefer ctx.deinit();

        return .{
            .vs = vs,
            .fs = fs,
            .pipeline = pipeline,
            .cursor_pipeline = cursor_pipeline,
            .vbuf = vbuf,
            .ctx = ctx,
            .sampler_binding = sampler_binding,
        };
    }

    pub fn deinit(self: *DrawCache, device: *prism.Device) void {
        self.ctx.deinit();
        device.destroyPipeline(self.cursor_pipeline);
        device.destroyPipeline(self.pipeline);
        device.destroyShaderModule(self.fs);
        device.destroyShaderModule(self.vs);
        device.destroyResource(self.vbuf);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Cursor size constant
// ---------------------------------------------------------------------------

/// Side length in pixels of the default arrow cursor sprite.
pub const CURSOR_SIZE: u32 = 24;

// ---------------------------------------------------------------------------
// buildArrowCursor: pure RGBA8 arrow sprite rasteriser
// ---------------------------------------------------------------------------

/// Fill `buf` (w*h*4 bytes, RGBA8) with a simple left-pointing arrow cursor.
/// The arrow tip is at the top-left corner (0, 0).
///
/// Shape: a filled triangle whose vertices (in pixel space) are:
///   - tip:         (0, 0)
///   - bottom-left: (0, h-1)
///   - right point: (w/2, h/2)   (approximately the mid-right edge)
///
/// Pixels inside the triangle are set to opaque white (R=255, G=255, B=255, A=255).
/// Pixels outside are set to transparent black (R=0, G=0, B=0, A=0).
/// `w` and `h` must be > 0 and satisfy w*h*4 <= buf.len.
pub fn buildArrowCursor(buf: []u8, w: u32, h: u32) void {
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);

    // Triangle vertices (float pixel space):
    //   A = tip    (0, 0)
    //   B = bottom (0, h-1)
    //   C = right  (w/2, h/2)
    const ax: f32 = 0;
    const ay: f32 = 0;
    const bx: f32 = 0;
    const by: f32 = fh - 1;
    const cx: f32 = fw / 2;
    const cy: f32 = fh / 2;

    // Pre-compute edge vectors for the sign test (2D cross product).
    // For a CCW winding order (A->B->C), a point P is inside when all three
    // cross products (edge x (P - vert)) have the same sign. We check >= 0
    // (inclusive boundary).
    var py: u32 = 0;
    while (py < h) : (py += 1) {
        var px: u32 = 0;
        while (px < w) : (px += 1) {
            const fpx: f32 = @floatFromInt(px);
            const fpy: f32 = @floatFromInt(py);

            // Edge A->B: cross = (B-A) x (P-A)
            // (bx-ax, by-ay) = (0, fh-1); (P-A) = (fpx, fpy)
            // cross = (bx-ax)*(fpy-ay) - (by-ay)*(fpx-ax)
            //       = 0*(fpy) - (fh-1)*(fpx)  = -(fh-1)*fpx
            const d0 = (bx - ax) * (fpy - ay) - (by - ay) * (fpx - ax);

            // Edge B->C: cross = (C-B) x (P-B)
            // (cx-bx, cy-by) = (fw/2, cy-by); P-B = (fpx, fpy-by)
            const d1 = (cx - bx) * (fpy - by) - (cy - by) * (fpx - bx);

            // Edge C->A: cross = (A-C) x (P-C)
            const d2 = (ax - cx) * (fpy - cy) - (ay - cy) * (fpx - cx);

            // CW winding (screen space, y-axis points down): inside when all three <= 0.
            const inside = (d0 <= 0) and (d1 <= 0) and (d2 <= 0);

            const base = (py * w + px) * 4;
            if (inside) {
                buf[base + 0] = 255; // R
                buf[base + 1] = 255; // G
                buf[base + 2] = 255; // B
                buf[base + 3] = 255; // A
            } else {
                buf[base + 0] = 0;
                buf[base + 1] = 0;
                buf[base + 2] = 0;
                buf[base + 3] = 0;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// isCursorHidden: pure lock-scan helper
// ---------------------------------------------------------------------------

const constraints_mod = @import("constraints.zig");

/// Returns true when any active, non-dead pointer LOCK constraint exists.
/// Confine constraints do NOT hide the cursor.
/// Called by drawCursor; extracted here for unit-testability.
pub fn isCursorHidden(list: []const constraints_mod.Constraint) bool {
    for (list) |c| {
        if (!c.dead and c.active and c.kind == .lock) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Unit tests: quadVertices (pure)
// ---------------------------------------------------------------------------

test "quadVertices: full RT maps to NDC corners" {
    const rt_w: f32 = 800;
    const rt_h: f32 = 600;
    const verts = quadVertices(.{ .x = 0, .y = 0, .w = rt_w, .h = rt_h }, rt_w, rt_h);

    // TL vertex (index 0): NDC (-1, 1), UV (0, 0)
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), verts[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[3], 1e-6);

    // TR vertex (index 1): NDC (1, 1), UV (1, 0)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts[4], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts[5], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts[6], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[7], 1e-6);

    // BL vertex (index 2): NDC (-1, -1), UV (0, 1)
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), verts[8], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), verts[9], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[10], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts[11], 1e-6);
}

test "quadVertices: half-RT bottom-right quadrant" {
    const rt_w: f32 = 800;
    const rt_h: f32 = 600;
    // Rect covering the bottom-right quarter: x=400, y=300, w=400, h=300
    const verts = quadVertices(.{ .x = 400, .y = 300, .w = 400, .h = 300 }, rt_w, rt_h);

    // TL: pixel (400, 300) -> NDC (0, 0)
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[3], 1e-6);

    // TR: pixel (800, 300) -> NDC (1, 0)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), verts[4], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[5], 1e-6);

    // BL: pixel (400, 600) -> NDC (0, -1)
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[8], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), verts[9], 1e-6);
}

test "quadVertices: centre 1x1 pixel" {
    const rt_w: f32 = 4;
    const rt_h: f32 = 4;
    // Single pixel at (2, 2)
    const verts = quadVertices(.{ .x = 2, .y = 2, .w = 1, .h = 1 }, rt_w, rt_h);

    // TL pixel (2,2): ndc_x = (2/4)*2-1 = 0, ndc_y = 1-(2/4)*2 = 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[1], 1e-6);
    // TR pixel (3,2): ndc_x = (3/4)*2-1 = 0.5, ndc_y = 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), verts[4], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[5], 1e-6);
    // BL pixel (2,3): ndc_x = 0, ndc_y = 1-(3/4)*2 = -0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), verts[8], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), verts[9], 1e-6);
}

test "quadVertices: vertex count and stride" {
    const verts = quadVertices(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, 100, 100);
    // 6 vertices * 4 f32 each = 24 f32 total
    try std.testing.expectEqual(@as(usize, 24), verts.len);
}

// ---------------------------------------------------------------------------
// Unit tests: buildArrowCursor (pure)
// ---------------------------------------------------------------------------

test "buildArrowCursor: tip pixel is opaque white" {
    const w = CURSOR_SIZE;
    const h = CURSOR_SIZE;
    var buf: [w * h * 4]u8 = undefined;
    buildArrowCursor(&buf, w, h);

    // Pixel (0, 0) is the tip of the arrow - must be inside the triangle.
    const base = 0 * 4;
    try std.testing.expectEqual(@as(u8, 255), buf[base + 3]); // alpha
    try std.testing.expectEqual(@as(u8, 255), buf[base + 0]); // R
}

test "buildArrowCursor: bottom-right corner is transparent (outside arrow)" {
    const w = CURSOR_SIZE;
    const h = CURSOR_SIZE;
    var buf: [w * h * 4]u8 = undefined;
    buildArrowCursor(&buf, w, h);

    // The bottom-right corner (w-1, h-1) is outside the triangle.
    const base = ((h - 1) * w + (w - 1)) * 4;
    try std.testing.expectEqual(@as(u8, 0), buf[base + 3]); // alpha = 0
}

test "buildArrowCursor: pixel (1, 1) is inside arrow" {
    const w = CURSOR_SIZE;
    const h = CURSOR_SIZE;
    var buf: [w * h * 4]u8 = undefined;
    buildArrowCursor(&buf, w, h);

    // Pixel (1, 1) is well inside the top-left arrow region.
    const base = (1 * w + 1) * 4;
    try std.testing.expectEqual(@as(u8, 255), buf[base + 3]);
}

test "buildArrowCursor: buf size matches CURSOR_SIZE" {
    const w = CURSOR_SIZE;
    const h = CURSOR_SIZE;
    var buf: [w * h * 4]u8 = undefined;
    buildArrowCursor(&buf, w, h);
    // Confirm the buffer is fully written (no index out-of-bounds above).
    try std.testing.expectEqual(@as(usize, w * h * 4), buf.len);
}

// ---------------------------------------------------------------------------
// Unit tests: isCursorHidden (pure)
// ---------------------------------------------------------------------------

test "isCursorHidden: empty list -> not hidden" {
    const list: []const constraints_mod.Constraint = &.{};
    try std.testing.expect(!isCursorHidden(list));
}

test "isCursorHidden: active lock -> hidden" {
    const list = [_]constraints_mod.Constraint{.{
        .kind = .lock,
        .surface = 1,
        .region = null,
        .lifetime = .persistent,
        .active = true,
        .dead = false,
    }};
    try std.testing.expect(isCursorHidden(&list));
}

test "isCursorHidden: active confine -> NOT hidden" {
    const list = [_]constraints_mod.Constraint{.{
        .kind = .confine,
        .surface = 1,
        .region = null,
        .lifetime = .persistent,
        .active = true,
        .dead = false,
    }};
    try std.testing.expect(!isCursorHidden(&list));
}

test "isCursorHidden: dead lock -> NOT hidden" {
    const list = [_]constraints_mod.Constraint{.{
        .kind = .lock,
        .surface = 1,
        .region = null,
        .lifetime = .oneshot,
        .active = true,
        .dead = true,
    }};
    try std.testing.expect(!isCursorHidden(&list));
}

test "isCursorHidden: inactive lock -> NOT hidden" {
    const list = [_]constraints_mod.Constraint{.{
        .kind = .lock,
        .surface = 1,
        .region = null,
        .lifetime = .persistent,
        .active = false,
        .dead = false,
    }};
    try std.testing.expect(!isCursorHidden(&list));
}

// ---------------------------------------------------------------------------
// pickCursor: pure cursor-selection helper
// ---------------------------------------------------------------------------

/// Which cursor image to draw, based on client state.
pub const CursorChoice = enum {
    /// Draw nothing: client requested cursor hide, or a pointer lock is active.
    none,
    /// Draw the client-supplied cursor surface texture at hotspot-adjusted position.
    client,
    /// Draw the default arrow cursor sprite.
    default,
};

/// Determine which cursor to draw given the client's set_cursor state.
///
/// Called by drawCursor AFTER the pointer-lock check (isCursorHidden).
/// This function does not know about pointer locks; the caller handles that.
///
/// Arguments:
///   cursor_set    - true if the client has ever called set_cursor on this pointer.
///   cursor_hidden - true if the last set_cursor call had surface == null (hide).
///   has_texture   - true if the cursor wl_surface has an uploaded prism texture.
///
/// Decision table:
///   !cursor_set                           -> .default  (client never set a cursor)
///   cursor_set and cursor_hidden          -> .none     (client hid the cursor)
///   cursor_set and !cursor_hidden and has_texture  -> .client  (draw client image)
///   cursor_set and !cursor_hidden and !has_texture -> .default (texture not yet ready)
pub fn pickCursor(cursor_set: bool, cursor_hidden: bool, has_texture: bool) CursorChoice {
    if (!cursor_set) return .default;
    if (cursor_hidden) return .none;
    if (has_texture) return .client;
    return .default;
}

// ---------------------------------------------------------------------------
// Unit tests: pickCursor (pure)
// ---------------------------------------------------------------------------

test "pickCursor: not set -> default" {
    try std.testing.expectEqual(CursorChoice.default, pickCursor(false, false, false));
    try std.testing.expectEqual(CursorChoice.default, pickCursor(false, false, true));
    try std.testing.expectEqual(CursorChoice.default, pickCursor(false, true, false));
    try std.testing.expectEqual(CursorChoice.default, pickCursor(false, true, true));
}

test "pickCursor: set and hidden -> none regardless of texture" {
    try std.testing.expectEqual(CursorChoice.none, pickCursor(true, true, false));
    try std.testing.expectEqual(CursorChoice.none, pickCursor(true, true, true));
}

test "pickCursor: set, not hidden, has texture -> client" {
    try std.testing.expectEqual(CursorChoice.client, pickCursor(true, false, true));
}

test "pickCursor: set, not hidden, no texture -> default (fallback)" {
    try std.testing.expectEqual(CursorChoice.default, pickCursor(true, false, false));
}

// ---------------------------------------------------------------------------
// Unit tests: hotspot offset math (pure)
// ---------------------------------------------------------------------------

test "cursor hotspot: position adjusted by hotspot" {
    // cursor_pos = (100, 80), hotspot = (8, 4) -> top-left = (92, 76)
    const cursor_x: f32 = 100.0;
    const cursor_y: f32 = 80.0;
    const hotspot_x: i32 = 8;
    const hotspot_y: i32 = 4;
    const draw_x = cursor_x - @as(f32, @floatFromInt(hotspot_x));
    const draw_y = cursor_y - @as(f32, @floatFromInt(hotspot_y));
    try std.testing.expectApproxEqAbs(@as(f32, 92.0), draw_x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 76.0), draw_y, 1e-5);
}

test "cursor hotspot: zero hotspot -> same position as cursor" {
    const cursor_x: f32 = 50.0;
    const cursor_y: f32 = 30.0;
    const draw_x = cursor_x - @as(f32, @floatFromInt(@as(i32, 0)));
    const draw_y = cursor_y - @as(f32, @floatFromInt(@as(i32, 0)));
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), draw_x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), draw_y, 1e-5);
}

// ---------------------------------------------------------------------------
// DrawCache blend readback test
// ---------------------------------------------------------------------------
//
// Render a fully-opaque red background into a 4x4 render target, then draw a
// half-transparent (alpha=128/255 ~= 0.5) blue texture over the entire quad
// using cursor_pipeline (blend enabled).  Read back the centre pixel and
// assert it is a blend of red + blue, i.e.:
//   R channel: neither 0 (pure blue) nor 255 (pure red) => blending is active.
//   B channel: neither 0 (pure red) nor 255 (pure blue) => blending is active.
//
// If blend were disabled the cursor_pipeline would overwrite with pure blue:
//   R=0, G=0, B=255, A=128 -> the assert R>0 would fail.
// If the texture were not drawn at all the pixel stays red:
//   R=255, G=0, B=0, A=255 -> the assert R<240 would fail.

test "DrawCache.cursor_pipeline blends a half-transparent texture over a red background" {
    const gpa = std.testing.allocator;

    // Bring up the software prism device (always available; no GPU required).
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoWorkingDriver;
    var device = sel.device;
    defer device.deinit();

    // Render target: 4x4 rgba8_unorm.
    const W: u32 = 4;
    const H: u32 = 4;
    const rt = try device.createResource(.{ .image = .{
        .width = W,
        .height = H,
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
    } });
    defer device.destroyResource(rt);

    // Clear the render target to opaque red.
    var clear_ctx = try device.createContext();
    defer clear_ctx.deinit();
    var ccb = try clear_ctx.beginCommands();
    try ccb.setRenderTarget(rt);
    try ccb.clear(.{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 });
    try clear_ctx.submit(ccb);
    ccb.deinit();

    // Build the DrawCache (creates pipeline + cursor_pipeline + vbuf + ctx).
    var dc = try DrawCache.init(gpa, &device);
    defer dc.deinit(&device);

    // Create a 4x4 half-transparent blue texture (R=0, G=0, B=255, A=128).
    const blue_tex = try device.createResource(.{ .image = .{
        .width = W,
        .height = H,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    } });
    defer device.destroyResource(blue_tex);
    {
        const dst = try device.mapResource(blue_tex);
        var i: usize = 0;
        while (i < W * H * 4) : (i += 4) {
            dst[i + 0] = 0; // R
            dst[i + 1] = 0; // G
            dst[i + 2] = 255; // B
            dst[i + 3] = 128; // A  (~0.5)
        }
        device.unmapResource(blue_tex);
    }

    // Write a full-quad vertex buffer covering the entire 4x4 target.
    const verts = quadVertices(.{ .x = 0, .y = 0, .w = @floatFromInt(W), .h = @floatFromInt(H) }, @floatFromInt(W), @floatFromInt(H));
    const vbuf_bytes = try device.mapResource(dc.vbuf);
    @memcpy(vbuf_bytes[0 .. verts.len * 4], std.mem.asBytes(&verts));
    device.unmapResource(dc.vbuf);

    // Draw the blue texture via cursor_pipeline (blend enabled).
    const cb = try dc.ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(rt);
    try cb.bindPipeline(dc.cursor_pipeline);
    try cb.bindVertexBuffer(dc.vbuf);
    try cb.bindTexture(prism.hal.TextureBinding{
        .binding = dc.sampler_binding,
        .image = blue_tex,
        .filter = .nearest,
        .address_u = .clamp_to_edge,
        .address_v = .clamp_to_edge,
    });
    try cb.draw(6, 0);
    try dc.ctx.submit(cb);

    // Read back the centre pixel (1, 1).
    const px = try device.mapResource(rt);
    defer device.unmapResource(rt);
    const centre = (1 * W + 1) * 4;
    const r = px[centre + 0];
    const b = px[centre + 2];

    // With src_alpha blending and alpha=0.5:
    //   out_r = src_alpha * src_r + (1 - src_alpha) * dst_r
    //         = 0.5 * 0 + 0.5 * 255 ~= 127
    //   out_b = 0.5 * 255 + 0.5 * 0 ~= 127
    // So both R and B should be roughly mid-range (80..180 is a generous band).
    try std.testing.expect(r > 0); // not pure blue overwrite (blend disabled would give R=0)
    try std.testing.expect(r < 240); // not pure red (texture not drawn)
    try std.testing.expect(b > 0); // blue contribution present
    try std.testing.expect(b < 240); // not pure blue (red background mixing in)
}
