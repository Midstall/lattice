const std = @import("std");
const output = @import("../../output.zig");
const id = @import("../../id.zig");

/// Accumulates wl_output events into a neutral Output.
/// Fields initialized to safe defaults; apply*() methods update them as events arrive.
pub const OutputAccum = struct {
    id: u32,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    refresh_mhz: u32 = 0,
    scale: u32 = 1,

    /// Apply a wl_output.mode event.
    /// Args: [0]=flags(uint), [1]=width(int), [2]=height(int), [3]=refresh_mHz(int).
    /// Only stores width/height/refresh when the "current" bit (0x1) is set in flags.
    /// Casts i32 -> u32; clamps negative values to 0.
    pub fn applyMode(self: *OutputAccum, width: i32, height: i32, refresh_mhz: i32, flags: u32) void {
        if (flags & 0x1 != 0) {
            self.width = if (width < 0) 0 else @intCast(width);
            self.height = if (height < 0) 0 else @intCast(height);
            self.refresh_mhz = if (refresh_mhz < 0) 0 else @intCast(refresh_mhz);
        }
    }

    /// Apply a wl_output.scale event.
    /// Arg[0] is a signed int; store as u32, minimum 1.
    pub fn applyScale(self: *OutputAccum, factor: i32) void {
        self.scale = if (factor <= 0) 1 else @intCast(factor);
    }

    /// Apply a wl_output.name event.
    /// Copies up to 64 bytes of name into name_buf, sets name_len.
    pub fn applyName(self: *OutputAccum, name: []const u8) void {
        const len = @min(name.len, 64);
        @memcpy(self.name_buf[0..len], name[0..len]);
        self.name_len = len;
    }

    /// Geometry event (stub). No-op; geometry is not needed for the neutral Output this plan.
    pub fn applyGeometry(self: *OutputAccum, x: i32, y: i32, physical_width: i32, physical_height: i32, subpixel: i32, make: []const u8, model: []const u8, transform: i32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = physical_width;
        _ = physical_height;
        _ = subpixel;
        _ = make;
        _ = model;
        _ = transform;
    }

    /// Convert the accumulated state to a neutral Output.
    /// Returns an SDR Output (supported=false) with the given lattice_id.
    pub fn toOutput(self: OutputAccum, lattice_id: u32) output.Output {
        return .{
            .id = id.OutputId.from(lattice_id),
            .name = self.name_buf[0..self.name_len],
            .width = self.width,
            .height = self.height,
            .refresh_mhz = self.refresh_mhz,
            .scale = @floatFromInt(self.scale),
            .hdr = .{},
        };
    }
};

test "applyMode with current flag sets fields" {
    var accum = OutputAccum{ .id = 1 };
    accum.applyMode(1920, 1080, 60000, 0x1);
    try std.testing.expectEqual(@as(u32, 1920), accum.width);
    try std.testing.expectEqual(@as(u32, 1080), accum.height);
    try std.testing.expectEqual(@as(u32, 60000), accum.refresh_mhz);
}

test "applyMode without current flag does not set fields" {
    var accum = OutputAccum{ .id = 1 };
    accum.applyMode(1920, 1080, 60000, 0x0);
    try std.testing.expectEqual(@as(u32, 0), accum.width);
    try std.testing.expectEqual(@as(u32, 0), accum.height);
    try std.testing.expectEqual(@as(u32, 0), accum.refresh_mhz);
}

test "applyMode clamps negative to 0" {
    var accum = OutputAccum{ .id = 1 };
    accum.applyMode(-100, -200, -30000, 0x1);
    try std.testing.expectEqual(@as(u32, 0), accum.width);
    try std.testing.expectEqual(@as(u32, 0), accum.height);
    try std.testing.expectEqual(@as(u32, 0), accum.refresh_mhz);
}

test "applyScale sets scale, min 1" {
    var accum = OutputAccum{ .id = 1 };
    accum.applyScale(2);
    try std.testing.expectEqual(@as(u32, 2), accum.scale);

    accum.applyScale(0);
    try std.testing.expectEqual(@as(u32, 1), accum.scale);

    accum.applyScale(-1);
    try std.testing.expectEqual(@as(u32, 1), accum.scale);
}

test "applyName copies up to 64 bytes" {
    var accum = OutputAccum{ .id = 1 };
    const name = "HDMI-1-test-output";
    accum.applyName(name);
    try std.testing.expectEqual(@as(usize, name.len), accum.name_len);
    try std.testing.expectEqualSlices(u8, name, accum.name_buf[0..accum.name_len]);
}

test "applyName truncates to 64 bytes" {
    var accum = OutputAccum{ .id = 1 };
    const long_name = "a" ** 100;
    accum.applyName(long_name);
    try std.testing.expectEqual(@as(usize, 64), accum.name_len);
}

test "toOutput creates neutral Output with current state" {
    var accum = OutputAccum{ .id = 1 };
    accum.applyMode(1920, 1080, 60000, 0x1);
    accum.applyScale(2);
    accum.applyName("HDMI-1");

    const out = accum.toOutput(42);
    try std.testing.expectEqual(id.OutputId.from(42), out.id);
    try std.testing.expectEqualSlices(u8, "HDMI-1", out.name);
    try std.testing.expectEqual(@as(u32, 1920), out.width);
    try std.testing.expectEqual(@as(u32, 1080), out.height);
    try std.testing.expectEqual(@as(u32, 60000), out.refresh_mhz);
    try std.testing.expectEqual(@as(f32, 2.0), out.scale);
    try std.testing.expect(!out.hdr.supported);
}
