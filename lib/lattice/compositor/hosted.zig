const std = @import("std");
const prism = @import("prism");
const color = @import("../color.zig");
const format_map = @import("../format_map.zig");
const lattice_backend = @import("../backend.zig");

// ---------------------------------------------------------------------------
// Buffer -> rgba8 pixel conversion helper
// ---------------------------------------------------------------------------

/// Convert a wl_shm row-strided buffer to a tightly-packed rgba8 destination.
///
/// `src` bytes use wl_shm LE packing:
///   format 1 (XRGB8888): bytes B, G, R, X  (ignore alpha, treat as 0xFF)
///   format 0 (ARGB8888): bytes B, G, R, A
///
/// `dst` bytes are rgba8: R, G, B, A, stride = width * 4.
///
/// `src_stride` is the number of bytes per source row (may include padding).
pub fn copyShmToRgba8(
    dst: []u8,
    src: []const u8,
    width: u32,
    height: u32,
    src_stride: u32,
    format: u32,
) void {
    const dst_stride = width * 4;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const srow = src[y * src_stride ..][0 .. width * 4];
        const drow = dst[y * dst_stride ..][0 .. width * 4];
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const s = srow[x * 4 ..][0..4];
            const d = drow[x * 4 ..][0..4];
            // wl_shm LE layout: byte0=B, byte1=G, byte2=R, byte3=A/X
            d[0] = s[2]; // R <- src[2]
            d[1] = s[1]; // G <- src[1]
            d[2] = s[0]; // B <- src[0]
            d[3] = if (format == 0) s[3] else 0xFF; // A: preserve for ARGB8888, opaque for XRGB8888
        }
    }
}

// ---------------------------------------------------------------------------
// Row-copy helper (pure, unit-testable)
// ---------------------------------------------------------------------------

/// Copy `height` rows of `width * bpp` real bytes from `src` to `dst`,
/// honouring independent source and destination strides (which may differ
/// from and exceed `width * bpp` due to padding). No swizzle, no conversion:
/// the bytes pass through verbatim. Used for the HDR (rgba16_float) upload
/// where the fp16 little-endian bytes must survive byte-exact.
pub fn copyRows(
    dst: []u8,
    src: []const u8,
    width: u32,
    height: u32,
    dst_stride: u32,
    src_stride: u32,
    bpp: u32,
) void {
    const row_bytes = width * bpp;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const srow = src[y * src_stride ..][0..row_bytes];
        const drow = dst[y * dst_stride ..][0..row_bytes];
        @memcpy(drow, srow);
    }
}

// ---------------------------------------------------------------------------
// Texture upload helper
// ---------------------------------------------------------------------------

/// A forward reference to HostedEntry (defined in compositor.zig).
/// We accept it as anytype to avoid a circular import.
///
/// uploadToTexture: create or resize the prism sampled texture on
/// entry.surface.texture as needed, then map + copy + unmap.
///
/// The texture's prism format is derived from the client buffer `format`
/// (DRM fourcc) via format_map.fourccToPrism, defaulting to rgba8_unorm for
/// unrecognised fourccs. The texture is (re)created when the size OR the
/// resolved format differs from the currently-cached texture. The upload
/// branches on the resolved format:
///   - HDR (rgba16_float): fp16 bytes are copied through verbatim row-by-row.
///   - SDR (rgba8_unorm):  the existing wl_shm -> rgba8 swizzle is applied.
///
/// `entry` must be a pointer to a HostedEntry (from compositor.zig).
/// `device` is the owning prism Device.
pub fn uploadToTexture(
    device: *prism.Device,
    entry: anytype, // *HostedEntry from compositor.zig
    src_pixels: []const u8,
    width: u32,
    height: u32,
    src_stride: u32,
    format: u32,
) !void {
    // Resolve the target prism format from the client buffer fourcc.
    const pfmt = format_map.fourccToPrism(format) orelse .rgba8_unorm;
    const bpp = pfmt.bytesPerPixel();

    // Destroy and recreate the texture if size OR format changed, or not yet created.
    const needs_recreate = entry.surface.texture == null or
        entry.surface.width != width or
        entry.surface.height != height or
        entry.surface.tex_format != pfmt;

    if (needs_recreate) {
        if (entry.surface.texture) |old_tex| {
            device.destroyResource(old_tex);
            entry.surface.texture = null;
        }
        const new_tex = try device.createResource(.{
            .image = .{
                .width = width,
                .height = height,
                .format = pfmt,
                .usage = .{ .sampled = true },
            },
        });
        entry.surface.texture = new_tex;
        entry.surface.width = width;
        entry.surface.height = height;
        entry.surface.tex_format = pfmt;
    }

    const tex = entry.surface.texture.?;
    const dst = try device.mapResource(tex);
    if (pfmt.isHdr()) {
        // HDR (rgba16_float): fp16 LE bytes pass through verbatim. The mapped
        // destination is tightly packed at width*bpp bytes/row.
        copyRows(dst, src_pixels, width, height, width * bpp, src_stride, bpp);
    } else {
        // SDR (rgba8_unorm): existing wl_shm -> rgba8 swizzle path, unchanged.
        copyShmToRgba8(dst, src_pixels, width, height, src_stride, format);
    }
    device.unmapResource(tex);
}

/// Unique identifier for a hosted surface within the compositor
pub const HostedSurfaceId = enum(u32) {
    _,
    pub fn from(v: u32) HostedSurfaceId {
        return @enumFromInt(v);
    }
    pub fn value(self: HostedSurfaceId) u32 {
        return @intFromEnum(self);
    }
};

/// Unique identifier for a client connected to the compositor
pub const ClientId = enum(u32) {
    _,
    pub fn from(v: u32) ClientId {
        return @enumFromInt(v);
    }
    pub fn value(self: ClientId) u32 {
        return @intFromEnum(self);
    }
};

/// Role of a hosted surface in the xdg-shell protocol
pub const Role = enum { none, toplevel, popup };

/// Neutral representation of a surface hosted by the compositor.
/// Contains metadata and the composited texture. No wayland.zig wire types cross this boundary.
pub const HostedSurface = struct {
    id: HostedSurfaceId,
    client: ClientId,
    role: Role = .none,
    title: []const u8 = "",
    app_id: []const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
    texture: ?*prism.Resource = null,
    /// The prism format the cached `texture` was created with. Tracked so the
    /// upload path recreates the texture when the client buffer's pixel format
    /// changes (e.g. SDR rgba8 -> HDR rgba16_float), not only on resize.
    tex_format: ?prism.hal.Format = null,
    mapped: bool = false,
    /// The declared color state of this surface. Defaults to SDR sRGB.
    /// Updated on each surface commit when the client has set a wp_color_management
    /// image description via the color manager.
    color: color.ColorConfig = color.ColorConfig.sdr(.xrgb8888),
};

/// Lightweight client entry (extended by the compositor with protocol state).
pub const Client = struct {
    id: ClientId,
};

/// Events emitted by the compositor to notify the shell of surface/client state changes.
pub const CompositorEvent = union(enum) {
    /// A surface has been mapped and is ready to display.
    surface_mapped: HostedSurfaceId,
    /// A surface has been committed; texture and metadata are updated.
    surface_committed: HostedSurfaceId,
    /// A surface has been resized.
    surface_resized: struct {
        id: HostedSurfaceId,
        width: u32,
        height: u32,
    },
    /// A surface has been unmapped.
    surface_unmapped: HostedSurfaceId,
    /// A client has disconnected.
    client_disconnected: ClientId,
    /// A pointer constraint was activated or deactivated on a focused surface.
    /// kind=none means the constraint was deactivated; lock/confine means activated.
    /// The App should forward this to Context.applyPointerConstraint() so the
    /// parent compositor (or KMS) can enforce the hardware pointer constraint.
    pointer_constraint: lattice_backend.PointerConstraintReq,
};

/// Function signature for compositor event handlers.
pub const CompositorHandler = *const fn (ctx: *anyopaque, ev: CompositorEvent) void;

test "HostedSurfaceId round-trip" {
    try std.testing.expectEqual(@as(u32, 5), HostedSurfaceId.from(5).value());
    try std.testing.expectEqual(@as(u32, 0), HostedSurfaceId.from(0).value());
}

test "ClientId round-trip" {
    try std.testing.expectEqual(@as(u32, 3), ClientId.from(3).value());
    try std.testing.expectEqual(@as(u32, 100), ClientId.from(100).value());
}

test "CompositorEvent surface_mapped" {
    const ev = CompositorEvent{ .surface_mapped = HostedSurfaceId.from(42) };
    try std.testing.expect(std.meta.activeTag(ev) == .surface_mapped);
    try std.testing.expectEqual(@as(u32, 42), ev.surface_mapped.value());
}

test "CompositorEvent surface_committed" {
    const ev = CompositorEvent{ .surface_committed = HostedSurfaceId.from(10) };
    try std.testing.expect(std.meta.activeTag(ev) == .surface_committed);
    try std.testing.expectEqual(@as(u32, 10), ev.surface_committed.value());
}

test "CompositorEvent surface_resized" {
    const ev = CompositorEvent{ .surface_resized = .{
        .id = HostedSurfaceId.from(7),
        .width = 800,
        .height = 600,
    } };
    try std.testing.expect(std.meta.activeTag(ev) == .surface_resized);
    try std.testing.expectEqual(@as(u32, 7), ev.surface_resized.id.value());
    try std.testing.expectEqual(@as(u32, 800), ev.surface_resized.width);
    try std.testing.expectEqual(@as(u32, 600), ev.surface_resized.height);
}

test "CompositorEvent surface_unmapped" {
    const ev = CompositorEvent{ .surface_unmapped = HostedSurfaceId.from(15) };
    try std.testing.expect(std.meta.activeTag(ev) == .surface_unmapped);
    try std.testing.expectEqual(@as(u32, 15), ev.surface_unmapped.value());
}

test "CompositorEvent client_disconnected" {
    const ev = CompositorEvent{ .client_disconnected = ClientId.from(5) };
    try std.testing.expect(std.meta.activeTag(ev) == .client_disconnected);
    try std.testing.expectEqual(@as(u32, 5), ev.client_disconnected.value());
}

test "HostedSurface defaults" {
    const surf = HostedSurface{
        .id = HostedSurfaceId.from(1),
        .client = ClientId.from(2),
    };
    try std.testing.expectEqual(Role.none, surf.role);
    try std.testing.expect(surf.texture == null);
    try std.testing.expect(!surf.mapped);
    try std.testing.expectEqual(@as(u32, 0), surf.width);
    try std.testing.expectEqual(@as(u32, 0), surf.height);
    try std.testing.expectEqualStrings("", surf.title);
    try std.testing.expectEqualStrings("", surf.app_id);
    // Default color is SDR sRGB xrgb8888.
    try std.testing.expectEqual(color.PixelFormat.xrgb8888, surf.color.format);
    try std.testing.expectEqual(color.TransferFunction.srgb, surf.color.transfer);
    try std.testing.expectEqual(color.Colorspace.srgb, surf.color.colorspace);
    try std.testing.expect(surf.color.luminance == null);
    try std.testing.expect(!surf.color.isHdr());
}

test "HostedSurface with custom fields" {
    const surf = HostedSurface{
        .id = HostedSurfaceId.from(42),
        .client = ClientId.from(3),
        .role = Role.toplevel,
        .title = "Test Window",
        .app_id = "org.test.app",
        .width = 1024,
        .height = 768,
        .mapped = true,
    };
    try std.testing.expectEqual(Role.toplevel, surf.role);
    try std.testing.expect(surf.mapped);
    try std.testing.expectEqual(@as(u32, 1024), surf.width);
    try std.testing.expectEqual(@as(u32, 768), surf.height);
    try std.testing.expectEqualStrings("Test Window", surf.title);
    try std.testing.expectEqualStrings("org.test.app", surf.app_id);
}

test "Client construction" {
    const client = Client{
        .id = ClientId.from(7),
    };
    try std.testing.expectEqual(@as(u32, 7), client.id.value());
}

// ---------------------------------------------------------------------------
// copyShmToRgba8 unit tests
// ---------------------------------------------------------------------------

test "copyShmToRgba8: XRGB8888 2x1 -> rgba8" {
    // wl_shm XRGB8888 LE: bytes B,G,R,X
    // pixel0: B=30, G=20, R=10, X=0xFF -> rgba8 R=10,G=20,B=30,A=0xFF
    // pixel1: B=3,  G=2,  R=1,  X=0xFF -> rgba8 R=1, G=2, B=3, A=0xFF
    const src = [_]u8{ 30, 20, 10, 0xFF, 3, 2, 1, 0xFF };
    var dst = [_]u8{0} ** 8;
    copyShmToRgba8(&dst, &src, 2, 1, 8, 1); // format 1 = XRGB8888
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 0xFF, 1, 2, 3, 0xFF }, &dst);
}

test "copyShmToRgba8: ARGB8888 preserves alpha" {
    // wl_shm ARGB8888 LE: bytes B,G,R,A
    // pixel0: B=50, G=40, R=30, A=200 -> rgba8 R=30,G=40,B=50,A=200
    const src = [_]u8{ 50, 40, 30, 200 };
    var dst = [_]u8{0} ** 4;
    copyShmToRgba8(&dst, &src, 1, 1, 4, 0); // format 0 = ARGB8888
    try std.testing.expectEqualSlices(u8, &[_]u8{ 30, 40, 50, 200 }, &dst);
}

test "copyShmToRgba8: strided source (src_stride > width*4)" {
    // 1x2 image, width=1, src_stride=8 (4 bytes data + 4 bytes padding per row)
    // row0: B=100,G=150,R=200,A=255 then 4 pad bytes
    // row1: B=10, G=20, R=30, A=128 then 4 pad bytes
    const src = [_]u8{
        100, 150, 200, 255, 0, 0, 0, 0, // row 0 + padding
        10, 20, 30, 128, 0, 0, 0, 0, // row 1 + padding
    };
    var dst = [_]u8{0} ** 8; // tight dst: 1x2, stride=4
    copyShmToRgba8(&dst, &src, 1, 2, 8, 0); // format 0 = ARGB8888
    // row0: R=200, G=150, B=100, A=255
    try std.testing.expectEqual(@as(u8, 200), dst[0]);
    try std.testing.expectEqual(@as(u8, 150), dst[1]);
    try std.testing.expectEqual(@as(u8, 100), dst[2]);
    try std.testing.expectEqual(@as(u8, 255), dst[3]);
    // row1: R=30, G=20, B=10, A=128
    try std.testing.expectEqual(@as(u8, 30), dst[4]);
    try std.testing.expectEqual(@as(u8, 20), dst[5]);
    try std.testing.expectEqual(@as(u8, 10), dst[6]);
    try std.testing.expectEqual(@as(u8, 128), dst[7]);
}

// ---------------------------------------------------------------------------
// copyRows (HDR fp16) unit test
// ---------------------------------------------------------------------------

test "copyRows: rgba16_float 2x2 fp16 byte-exact with differing strides" {
    // rgba16_float: bpp = 8, so 2 texels/row = 16 bytes of real data/row.
    // Texel (0,0) encodes R=4.0 -> fp16 bits 0x4400 -> LE bytes 0x00, 0x44.
    // Every other channel is a distinct byte so we catch any misplacement.
    const bpp: u32 = 8;
    const w: u32 = 2;
    const h: u32 = 2;
    const src_stride: u32 = 20; // padded: 16 data bytes + 4 pad bytes/row
    const dst_stride: u32 = 16; // tight

    // Build src: 2 rows of 16 data bytes + 4 pad bytes each.
    var src = [_]u8{0} ** (src_stride * h);
    // Row 0, texel 0: R=4.0 (0x00,0x44), G,B,A distinct.
    src[0] = 0x00; // R low
    src[1] = 0x44; // R high (fp16 4.0)
    src[2] = 0x11;
    src[3] = 0x22; // G
    src[4] = 0x33;
    src[5] = 0x44; // B
    src[6] = 0x55;
    src[7] = 0x66; // A
    // Row 0, texel 1: distinct bytes.
    var i: usize = 8;
    while (i < 16) : (i += 1) src[i] = @intCast(0x80 + i);
    // Padding bytes src[16..20] left 0.
    // Row 1: distinct bytes.
    i = src_stride;
    while (i < src_stride + 16) : (i += 1) src[i] = @intCast(0xA0 + (i - src_stride));
    // Row 1 padding src[36..40] left 0.

    var dst = [_]u8{0xEE} ** (dst_stride * h);
    copyRows(&dst, &src, w, h, dst_stride, src_stride, bpp);

    // Each destination row's first w*bpp bytes must equal the source row's
    // first w*bpp bytes (byte-exact, stride-correct).
    const row_bytes = w * bpp; // 16
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const drow = dst[y * dst_stride ..][0..row_bytes];
        const srow = src[y * src_stride ..][0..row_bytes];
        try std.testing.expectEqualSlices(u8, srow, drow);
    }
    // The fp16 0x4400 (R=4.0) survived at texel (0,0).
    try std.testing.expectEqual(@as(u8, 0x00), dst[0]);
    try std.testing.expectEqual(@as(u8, 0x44), dst[1]);
}
