const std = @import("std");
const libseat = @import("libseat");

pub const Session = struct {
    gpa: std.mem.Allocator,
    seat: *libseat.Seat,
    active: bool = false,
    vt_switch: bool,
    devices: std.ArrayListUnmanaged(libseat.Device) = .empty,

    pub fn open(gpa: std.mem.Allocator, vt_switch: bool) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .seat = undefined, .vt_switch = vt_switch };
        self.seat = libseat.Seat.open(gpa, &seat_listener, self) catch |e| return switch (e) {
            error.NoBackend, error.ConnectionFailed => error.NoSession,
            error.Denied, error.SeatInUse => error.DeviceAccessDenied,
            else => e,
        };
        errdefer self.seat.close();
        // Pump until the first enable makes us active (seatd sends enable on connect).
        var tries: u32 = 0;
        while (!self.active and tries < 100) : (tries += 1) _ = self.seat.dispatch(1000) catch break;
        return self;
    }

    pub fn openDevice(self: *Session, path: []const u8) !std.posix.fd_t {
        const dev = self.seat.openDevice(path) catch |e| return switch (e) {
            error.Denied => error.DeviceAccessDenied,
            else => e,
        };
        // The seat already handed us the fd; if tracking it fails, close it via the
        // seat (seat.close only tears down the socket, not per-device fds).
        errdefer self.seat.closeDevice(dev) catch {};
        try self.devices.append(self.gpa, dev);
        return dev.fd;
    }

    pub fn pollFd(self: *Session) std.posix.fd_t {
        return @intCast(self.seat.pollFd());
    }

    pub fn dispatch(self: *Session) !void {
        _ = self.seat.dispatch(0) catch {};
    }

    pub fn deinit(self: *Session) void {
        for (self.devices.items) |d| self.seat.closeDevice(d) catch {};
        self.devices.deinit(self.gpa);
        self.seat.close();
        self.gpa.destroy(self);
    }
};

// Callbacks fire inline during dispatch; userdata is the *Session.
fn onEnable(seat: *libseat.Seat, ud: ?*anyopaque) void {
    _ = seat;
    const self: *Session = @ptrCast(@alignCast(ud.?));
    self.active = true;
}

fn onDisable(seat: *libseat.Seat, ud: ?*anyopaque) void {
    _ = seat;
    const self: *Session = @ptrCast(@alignCast(ud.?));
    self.active = false;
    // Must ack promptly or seatd will not grant the VT switch.
    self.seat.disable() catch {};
}

const seat_listener = libseat.Listener{
    .enable = onEnable,
    .disable = onDisable,
};

/// Returns true if VT switching is permitted by the session options.
/// Pure function; safe to call at any time including in unit tests.
pub fn allowSwitch(vt_switch: bool) bool {
    return vt_switch;
}

test "allowSwitch reflects the vt_switch option" {
    try std.testing.expect(allowSwitch(true));
    try std.testing.expect(!allowSwitch(false));
}
