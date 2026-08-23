const std = @import("std");
const color = @import("../../color.zig");

pub const Chroma = extern struct {
    x: u16,
    y: u16,
};

pub const HdrMetadataInfoframe = extern struct {
    eotf: u8,
    metadata_type: u8,
    display_primaries: [3]Chroma,
    white_point: Chroma,
    max_display_mastering_luminance: u16,
    min_display_mastering_luminance: u16,
    max_cll: u16,
    max_fall: u16,
};

pub const HdrOutputMetadata = extern struct {
    metadata_type: u32,
    infoframe: HdrMetadataInfoframe,
};

pub fn eotfFor(tf: color.TransferFunction) u8 {
    return switch (tf) {
        .srgb, .gamma22, .linear => 0,
        .st2084_pq => 2,
        .hlg => 3,
    };
}

pub fn buildMetadata(cfg: color.ColorConfig) HdrOutputMetadata {
    var result: HdrOutputMetadata = undefined;
    result.metadata_type = 0;
    result.infoframe.eotf = eotfFor(cfg.transfer);
    result.infoframe.metadata_type = 0;

    // bt2020 primaries (in 0.00002 unit = CIE xy * 50000)
    result.infoframe.display_primaries[0] = .{ .x = 35400, .y = 14600 }; // R
    result.infoframe.display_primaries[1] = .{ .x = 8500, .y = 39850 }; // G
    result.infoframe.display_primaries[2] = .{ .x = 6550, .y = 2300 }; // B
    result.infoframe.white_point = .{ .x = 15635, .y = 16450 }; // D65

    // Luminance fields
    if (cfg.luminance) |lum| {
        result.infoframe.max_display_mastering_luminance = @intFromFloat(lum.max_nits);
        result.infoframe.min_display_mastering_luminance = @intFromFloat(lum.min_nits * 10000);
        result.infoframe.max_cll = @intFromFloat(lum.max_cll);
        result.infoframe.max_fall = @intFromFloat(lum.max_fall);
    } else {
        result.infoframe.max_display_mastering_luminance = 0;
        result.infoframe.min_display_mastering_luminance = 0;
        result.infoframe.max_cll = 0;
        result.infoframe.max_fall = 0;
    }

    return result;
}

test "HdrOutputMetadata C-ABI layout: offsets + size match the kernel struct" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(HdrOutputMetadata, "metadata_type"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(HdrOutputMetadata, "infoframe"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(HdrMetadataInfoframe, "eotf"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(HdrMetadataInfoframe, "display_primaries"));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(HdrMetadataInfoframe, "white_point"));
    try std.testing.expectEqual(@as(usize, 18), @offsetOf(HdrMetadataInfoframe, "max_display_mastering_luminance"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(HdrMetadataInfoframe, "max_fall"));
    try std.testing.expectEqual(@as(usize, 26), @sizeOf(HdrMetadataInfoframe));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(HdrOutputMetadata));
}

test "eotfFor maps transfer functions" {
    try std.testing.expectEqual(@as(u8, 0), eotfFor(.srgb));
    try std.testing.expectEqual(@as(u8, 2), eotfFor(.st2084_pq));
    try std.testing.expectEqual(@as(u8, 3), eotfFor(.hlg));
}

test "buildMetadata: PQ + bt2020 + 1000-nit mastering encodes correctly" {
    const cfg = color.ColorConfig{
        .format = .rgba16_float,
        .colorspace = .bt2020,
        .transfer = .st2084_pq,
        .luminance = .{ .min_nits = 0.005, .max_nits = 1000, .max_cll = 1000, .max_fall = 400 },
    };
    const m = buildMetadata(cfg);
    try std.testing.expectEqual(@as(u32, 0), m.metadata_type);
    try std.testing.expectEqual(@as(u8, 2), m.infoframe.eotf);
    try std.testing.expectEqual(@as(u8, 0), m.infoframe.metadata_type);
    try std.testing.expectEqual(@as(u16, 35400), m.infoframe.display_primaries[0].x);
    try std.testing.expectEqual(@as(u16, 14600), m.infoframe.display_primaries[0].y);
    try std.testing.expectEqual(@as(u16, 8500), m.infoframe.display_primaries[1].x);
    try std.testing.expectEqual(@as(u16, 6550), m.infoframe.display_primaries[2].x);
    try std.testing.expectEqual(@as(u16, 15635), m.infoframe.white_point.x);
    try std.testing.expectEqual(@as(u16, 16450), m.infoframe.white_point.y);
    try std.testing.expectEqual(@as(u16, 1000), m.infoframe.max_display_mastering_luminance);
    try std.testing.expectEqual(@as(u16, 50), m.infoframe.min_display_mastering_luminance);
    try std.testing.expectEqual(@as(u16, 1000), m.infoframe.max_cll);
    try std.testing.expectEqual(@as(u16, 400), m.infoframe.max_fall);
}

test "buildMetadata: null luminance -> zero mastering fields, still SDR-safe eotf" {
    const cfg = color.ColorConfig{
        .format = .rgba16_float,
        .colorspace = .bt2020,
        .transfer = .st2084_pq,
        .luminance = null,
    };
    const m = buildMetadata(cfg);
    try std.testing.expectEqual(@as(u16, 0), m.infoframe.max_display_mastering_luminance);
    try std.testing.expectEqual(@as(u16, 2), m.infoframe.eotf);
}
