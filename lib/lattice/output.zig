const std = @import("std");
const id = @import("id.zig");
const color = @import("color.zig");

pub const HdrCaps = struct {
    supported: bool = false,
    colorspaces: []const color.Colorspace = &.{},
    transfers: []const color.TransferFunction = &.{},
    max_nits: f32 = 0,
    min_nits: f32 = 0,
    bit_depth: u8 = 8,
};

pub const Output = struct {
    id: id.OutputId,
    name: []const u8,
    width: u32,
    height: u32,
    /// refresh rate in millihertz (60000 == 60 Hz)
    refresh_mhz: u32,
    scale: f32 = 1.0,
    hdr: HdrCaps = .{},

    pub fn supportsHdr(self: Output) bool {
        return self.hdr.supported;
    }
};

test "output reports hdr capability" {
    const sdr = Output{ .id = id.OutputId.from(1), .name = "HEADLESS-1", .width = 1920, .height = 1080, .refresh_mhz = 60000 };
    try std.testing.expect(!sdr.supportsHdr());

    const hdr = Output{
        .id = id.OutputId.from(2),
        .name = "DP-1",
        .width = 3840,
        .height = 2160,
        .refresh_mhz = 120000,
        .hdr = .{ .supported = true, .max_nits = 1000, .bit_depth = 10 },
    };
    try std.testing.expect(hdr.supportsHdr());
    try std.testing.expectEqual(@as(u8, 10), hdr.hdr.bit_depth);
}
