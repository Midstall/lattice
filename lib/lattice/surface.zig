const std = @import("std");
const id = @import("id.zig");
const color = @import("color.zig");
const prism = @import("prism");

pub const RenderTarget = struct {
    context: *prism.Context,
    target: *prism.Resource,
    width: u32,
    height: u32,
    format: color.PixelFormat,
};

pub const SurfaceDesc = struct {
    title: []const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
    color: color.ColorConfig,
};

pub const Surface = struct {
    id: id.SurfaceId,
    desc: SurfaceDesc,

    pub fn size(self: Surface) [2]u32 {
        return .{ self.desc.width, self.desc.height };
    }

    pub fn isHdr(self: Surface) bool {
        return self.desc.color.isHdr();
    }
};

test "surface exposes size and hdr" {
    const s = Surface{
        .id = id.SurfaceId.from(1),
        .desc = .{ .title = "main", .width = 1280, .height = 720, .color = color.ColorConfig.sdr(.xrgb8888) },
    };
    try std.testing.expectEqual([2]u32{ 1280, 720 }, s.size());
    try std.testing.expect(!s.isHdr());
    // RenderTarget now carries real prism pointers; no bare construction in tests.
}
