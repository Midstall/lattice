const std = @import("std");

pub const PixelFormat = enum {
    xrgb8888,
    argb8888,
    xrgb2101010,
    argb2101010,
    rgba16_float,

    pub fn bytesPerPixel(self: PixelFormat) u8 {
        return switch (self) {
            .xrgb8888, .argb8888, .xrgb2101010, .argb2101010 => 4,
            .rgba16_float => 8,
        };
    }

    pub fn isHdr(self: PixelFormat) bool {
        return switch (self) {
            .xrgb2101010, .argb2101010, .rgba16_float => true,
            .xrgb8888, .argb8888 => false,
        };
    }
};

pub const Colorspace = enum { srgb, display_p3, bt2020 };

/// Electro-optical transfer function. st2084_pq and hlg are the two HDR transfers;
/// srgb/gamma22/linear are SDR. Names map to the wp_color_management / DRM named transfers.
pub const TransferFunction = enum { srgb, gamma22, linear, st2084_pq, hlg };

/// HDR luminance metadata in nits (cd/m^2). min_nits/max_nits describe the display or content
/// range; max_cll (max content light level) and max_fall (max frame-average light level) are
/// per-content mastering metadata, not display capabilities.
pub const Luminance = struct {
    min_nits: f32,
    max_nits: f32,
    max_cll: f32,
    max_fall: f32,
};

pub const ColorConfig = struct {
    format: PixelFormat,
    colorspace: Colorspace = .srgb,
    transfer: TransferFunction = .srgb,
    luminance: ?Luminance = null,

    pub fn sdr(format: PixelFormat) ColorConfig {
        return .{ .format = format, .colorspace = .srgb, .transfer = .srgb };
    }

    pub fn isHdr(self: ColorConfig) bool {
        return self.format.isHdr() or self.transfer == .st2084_pq or self.transfer == .hlg;
    }
};

test "pixel format hdr classification and size" {
    try std.testing.expect(PixelFormat.rgba16_float.isHdr());
    try std.testing.expect(PixelFormat.xrgb2101010.isHdr());
    try std.testing.expect(!PixelFormat.xrgb8888.isHdr());
    try std.testing.expectEqual(@as(u8, 8), PixelFormat.rgba16_float.bytesPerPixel());
    try std.testing.expectEqual(@as(u8, 4), PixelFormat.argb8888.bytesPerPixel());
}

test "color config sdr helper and hdr detection" {
    const sdr = ColorConfig.sdr(.xrgb8888);
    try std.testing.expect(!sdr.isHdr());
    const hdr = ColorConfig{ .format = .rgba16_float, .colorspace = .bt2020, .transfer = .st2084_pq };
    try std.testing.expect(hdr.isHdr());
}
