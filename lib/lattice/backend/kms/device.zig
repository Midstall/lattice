const std = @import("std");
const drm = @import("drm");

pub const Device = struct {
    node: drm.Node,
    /// When true (the root `open` path) this Device owns the fd + DRM master and
    /// releases both in `deinit`. When false (the seat `openWithFd` path) the
    /// libseat session owns the fd (closed via closeDevice) and DRM master (held
    /// and toggled by the seat manager across VT switches), so `deinit` is a no-op.
    owns_fd: bool = true,

    /// Open the DRM primary node as ROOT: become master, enable atomic + universal
    /// planes. Used only without a session (explicit dev/testing). `path` like
    /// "/dev/dri/card0".
    pub fn open(gpa: std.mem.Allocator, path: []const u8) !Device {
        const minor = parseCardMinor(path) orelse 0;
        var node = try drm.Node.openMinor(gpa, minor, .primary);
        errdefer node.deinit();
        node.setMaster() catch return error.NotDrmMaster;
        errdefer node.dropMaster() catch {};
        node.setClientCap(drm.types.cap.UNIVERSAL_PLANES, 1) catch return error.PlanesUnsupported;
        node.setClientCap(drm.types.cap.ATOMIC, 1) catch return error.AtomicUnsupported;
        return .{ .node = node, .owns_fd = true };
    }

    /// Wrap a seat-provided DRM fd (from libseat `openDevice`) as a drm.Node and
    /// enable the atomic + universal-planes client caps. Does NOT setMaster: the
    /// session manager (seatd/logind) holds DRM master and toggles it on VT switch.
    /// The fd is owned by the session (closed via closeDevice), not by this Device.
    pub fn openWithFd(gpa: std.mem.Allocator, fd: std.posix.fd_t) !Device {
        var node = drm.Node{ .allocator = gpa, .fd = fd };
        node.setClientCap(drm.types.cap.UNIVERSAL_PLANES, 1) catch return error.PlanesUnsupported;
        node.setClientCap(drm.types.cap.ATOMIC, 1) catch return error.AtomicUnsupported;
        return .{ .node = node, .owns_fd = false };
    }

    pub fn deinit(self: *Device) void {
        if (!self.owns_fd) return; // the session owns the fd + master
        self.node.dropMaster() catch {};
        self.node.deinit();
    }
};

/// Parse the trailing integer of a "/dev/dri/cardN" path. Returns null if the
/// path is not a cardN primary node (e.g. a renderD* node).
pub fn parseCardMinor(path: []const u8) ?u8 {
    const marker = "card";
    const idx = std.mem.lastIndexOf(u8, path, marker) orelse return null;
    const digits = path[idx + marker.len ..];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u8, digits, 10) catch null;
}

test "parseCardMinor extracts the trailing card index" {
    try std.testing.expectEqual(@as(?u8, 0), parseCardMinor("/dev/dri/card0"));
    try std.testing.expectEqual(@as(?u8, 1), parseCardMinor("/dev/dri/card1"));
    try std.testing.expectEqual(@as(?u8, 12), parseCardMinor("/dev/dri/card12"));
    try std.testing.expectEqual(@as(?u8, null), parseCardMinor("/dev/dri/renderD128"));
}

test {
    std.testing.refAllDecls(@This());
}
