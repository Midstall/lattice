//! Pure format-mapping helpers: DRM fourccs <-> prism.hal.Format <-> lattice PixelFormat.
//! No allocation, no I/O. Import this module for format-mapping in the compositor and client.
const std = @import("std");
const prism = @import("prism");
const color = @import("color.zig");

/// DRM fourcc constants used by the lattice compositor and client.
pub const fourcc = struct {
    pub const argb8888: u32 = 0x34325241;
    pub const xrgb8888: u32 = 0x34325258;
    pub const abgr16161616f: u32 = 0x48344241;
    pub const abgr2101010: u32 = 0x30334241;
    pub const xbgr2101010: u32 = 0x30334258;
};

/// Map a DRM fourcc to a prism.hal.Format.
/// Returns null for unrecognised fourccs.
pub fn fourccToPrism(f: u32) ?prism.hal.Format {
    return switch (f) {
        fourcc.argb8888, fourcc.xrgb8888 => .rgba8_unorm,
        fourcc.abgr16161616f => .rgba16_float,
        fourcc.abgr2101010 => .rgb10a2,
        fourcc.xbgr2101010 => .rgb10x2,
        else => null,
    };
}

/// Map a prism.hal.Format back to a DRM fourcc.
/// Returns null for formats that have no DRM fourcc counterpart in this mapping.
/// Note: both argb8888 and xrgb8888 map to rgba8_unorm, so the inverse picks argb8888.
pub fn prismToFourcc(f: prism.hal.Format) ?u32 {
    return switch (f) {
        .rgba8_unorm => fourcc.argb8888,
        .rgba16_float => fourcc.abgr16161616f,
        .rgb10a2 => fourcc.abgr2101010,
        .rgb10x2 => fourcc.xbgr2101010,
        else => null,
    };
}

/// Map a lattice PixelFormat to the corresponding prism.hal.Format.
/// xrgb8888/argb8888 -> rgba8_unorm
/// rgba16_float -> rgba16_float
/// xrgb2101010 -> rgb10x2 (packed 10/10/10/2 dword, X=ignored MSB pair)
/// argb2101010 -> rgb10a2 (packed 10/10/10/2 dword, A=2-bit alpha)
pub fn pixelFormatToPrism(p: color.PixelFormat) prism.hal.Format {
    return switch (p) {
        .xrgb8888, .argb8888 => .rgba8_unorm,
        .rgba16_float => .rgba16_float,
        .xrgb2101010 => .rgb10x2,
        .argb2101010 => .rgb10a2,
    };
}

/// Map a lattice PixelFormat DIRECTLY to its DRM fourcc, preserving the X-vs-A
/// (opaque vs alpha) distinction that pixelFormatToPrism + prismToFourcc lose
/// (both xrgb8888 and argb8888 collapse to rgba8_unorm, whose inverse is always
/// argb8888). KMS scanout needs the exact fourcc a plane advertises: virtio-gpu
/// (and most KMS drivers) accept XR24 (XRGB8888) but not AR24 (ARGB8888) on the
/// primary plane, so an xrgb8888 surface MUST scan out as XR24.
pub fn pixelFormatToFourcc(p: color.PixelFormat) u32 {
    return switch (p) {
        .xrgb8888 => fourcc.xrgb8888,
        .argb8888 => fourcc.argb8888,
        .xrgb2101010 => fourcc.xbgr2101010,
        .argb2101010 => fourcc.abgr2101010,
        .rgba16_float => fourcc.abgr16161616f,
    };
}

test "pixelFormatToFourcc preserves X vs A (xrgb8888 -> XR24, not AR24)" {
    try std.testing.expectEqual(fourcc.xrgb8888, pixelFormatToFourcc(.xrgb8888)); // 0x34325258 XR24
    try std.testing.expectEqual(fourcc.argb8888, pixelFormatToFourcc(.argb8888)); // 0x34325241 AR24
    try std.testing.expectEqual(fourcc.abgr2101010, pixelFormatToFourcc(.argb2101010));
    try std.testing.expectEqual(fourcc.xbgr2101010, pixelFormatToFourcc(.xrgb2101010));
    try std.testing.expectEqual(fourcc.abgr16161616f, pixelFormatToFourcc(.rgba16_float));
}

test "fourccToPrism: HDR fourcc resolves to rgba16_float" {
    try std.testing.expectEqual(prism.hal.Format.rgba16_float, fourccToPrism(fourcc.abgr16161616f).?);
}

test "fourccToPrism: SDR fourccs resolve to rgba8_unorm" {
    try std.testing.expectEqual(prism.hal.Format.rgba8_unorm, fourccToPrism(fourcc.argb8888).?);
    try std.testing.expectEqual(prism.hal.Format.rgba8_unorm, fourccToPrism(fourcc.xrgb8888).?);
}

test "fourccToPrism: unknown fourcc returns null" {
    try std.testing.expectEqual(@as(?prism.hal.Format, null), fourccToPrism(0xdeadbeef));
}

test "prismToFourcc: rgba16_float -> abgr16161616f" {
    try std.testing.expectEqual(fourcc.abgr16161616f, prismToFourcc(.rgba16_float).?);
}

test "prismToFourcc: rgba8_unorm -> argb8888" {
    try std.testing.expectEqual(fourcc.argb8888, prismToFourcc(.rgba8_unorm).?);
}

test "fourcc round-trips for known mappings" {
    // argb8888: fourcc -> prism -> fourcc gives argb8888 (the canonical SDR inverse)
    try std.testing.expectEqual(fourcc.argb8888, prismToFourcc(fourccToPrism(fourcc.argb8888).?).?);
    // xrgb8888 also maps to rgba8_unorm whose inverse is argb8888 (not xrgb8888)
    try std.testing.expectEqual(fourcc.argb8888, prismToFourcc(fourccToPrism(fourcc.xrgb8888).?).?);
    // abgr16161616f round-trips to itself
    try std.testing.expectEqual(fourcc.abgr16161616f, prismToFourcc(fourccToPrism(fourcc.abgr16161616f).?).?);
}

test "pixelFormatToPrism: rgba16_float passthrough" {
    try std.testing.expectEqual(prism.hal.Format.rgba16_float, pixelFormatToPrism(.rgba16_float));
}

test "pixelFormatToPrism: 10-bit formats map to correct prism variants" {
    try std.testing.expectEqual(prism.hal.Format.rgb10x2, pixelFormatToPrism(.xrgb2101010));
    try std.testing.expectEqual(prism.hal.Format.rgb10a2, pixelFormatToPrism(.argb2101010));
}

test "prism HDR format sanity: rgba16_float bpp and isHdr" {
    try std.testing.expectEqual(@as(u32, 8), prism.hal.Format.rgba16_float.bytesPerPixel());
    try std.testing.expect(prism.hal.Format.rgba16_float.isHdr());
    try std.testing.expect(!prism.hal.Format.rgba8_unorm.isHdr());
}

test "fourcc constants: 10-bit HDR values" {
    try std.testing.expectEqual(@as(u32, 0x30334241), fourcc.abgr2101010);
    try std.testing.expectEqual(@as(u32, 0x30334258), fourcc.xbgr2101010);
}

test "fourccToPrism: 10-bit HDR fourccs resolve correctly" {
    try std.testing.expectEqual(prism.hal.Format.rgb10a2, fourccToPrism(fourcc.abgr2101010).?);
    try std.testing.expectEqual(prism.hal.Format.rgb10x2, fourccToPrism(fourcc.xbgr2101010).?);
}

test "prismToFourcc: rgb10a2 and rgb10x2 map to 10-bit fourccs" {
    try std.testing.expectEqual(fourcc.abgr2101010, prismToFourcc(.rgb10a2).?);
    try std.testing.expectEqual(fourcc.xbgr2101010, prismToFourcc(.rgb10x2).?);
}

test "10-bit fourcc round-trips" {
    try std.testing.expectEqual(fourcc.abgr2101010, prismToFourcc(fourccToPrism(fourcc.abgr2101010).?).?);
    try std.testing.expectEqual(fourcc.xbgr2101010, prismToFourcc(fourccToPrism(fourcc.xbgr2101010).?).?);
}

test "prism 10-bit HDR format sanity: rgb10a2/rgb10x2 bpp and isHdr" {
    try std.testing.expectEqual(@as(u32, 4), prism.hal.Format.rgb10a2.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 4), prism.hal.Format.rgb10x2.bytesPerPixel());
    try std.testing.expect(prism.hal.Format.rgb10a2.isHdr());
    try std.testing.expect(prism.hal.Format.rgb10x2.isHdr());
}
