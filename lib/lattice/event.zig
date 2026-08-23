const std = @import("std");
const id = @import("id.zig");

pub const KeyState = enum { pressed, released };
pub const ButtonState = enum { pressed, released };

pub const KeyEvent = struct { keycode: u32, state: KeyState };
pub const PointerMotion = struct { surface: id.SurfaceId, x: f64, y: f64 };
pub const PointerButton = struct { surface: id.SurfaceId, button: u32, state: ButtonState };
pub const PointerAxis = struct { surface: id.SurfaceId, horizontal: f64, vertical: f64 };
/// Seat-global relative pointer motion (no surface). dx/dy are accelerated,
/// dx_unaccel/dy_unaccel are raw. Fed to zwp_relative_pointer_v1.
pub const PointerRelative = struct { dx: f64, dy: f64, dx_unaccel: f64, dy_unaccel: f64 };
pub const TouchPoint = struct { surface: id.SurfaceId, id: u32, x: f64, y: f64 };

pub const TabletProximity = struct { surface: id.SurfaceId, in_prox: bool };
pub const TabletTip = struct { surface: id.SurfaceId, down: bool };
/// Tablet tool axis state in surface-local coordinates.
/// x/y are surface-local pixels; pressure is [0, 1].
pub const TabletAxis = struct { surface: id.SurfaceId, x: f64, y: f64, pressure: f64 };

pub const InputEvent = union(enum) {
    key: KeyEvent,
    pointer_motion: PointerMotion,
    pointer_button: PointerButton,
    pointer_axis: PointerAxis,
    pointer_relative: PointerRelative,
    touch_down: TouchPoint,
    touch_up: TouchPoint,
    touch_motion: TouchPoint,
    tablet_proximity: TabletProximity,
    tablet_tip: TabletTip,
    tablet_axis: TabletAxis,
};

pub const Resized = struct { surface: id.SurfaceId, width: u32, height: u32 };
pub const ScaleChanged = struct { surface: id.SurfaceId, scale: f32 };

/// Which classes of input device the seat offers right now. A convergent shell
/// reads this to pick a fine-pointer or coarse-touch layout, which window width
/// alone cannot decide. Each backend maps its own device model onto these three
/// fields, so no consumer ever sees a protocol bitmask. All false is a valid
/// state: a seat can exist with no device attached to it.
pub const SeatCapabilities = struct {
    pointer: bool = false,
    keyboard: bool = false,
    touch: bool = false,

    pub fn eql(a: SeatCapabilities, b: SeatCapabilities) bool {
        return a.pointer == b.pointer and a.keyboard == b.keyboard and a.touch == b.touch;
    }
};

pub const Event = union(enum) {
    resized: Resized,
    scale_changed: ScaleChanged,
    close_requested: id.SurfaceId,
    redraw_requested: id.SurfaceId,
    output_added: id.OutputId,
    output_removed: id.OutputId,
    input: InputEvent,
    /// The backend's session became active (e.g. a VT switch back to us): the
    /// compositor should resume rendering. Neutral across backends (KMS emits it
    /// from the seat's enable; a future Windows/macOS backend maps its own
    /// activation to it). Only backends with a session concept emit these.
    session_active: void,
    /// The session became inactive (VT switched away): pause rendering until a
    /// matching session_active.
    session_inactive: void,
    /// The seat's device set CHANGED after startup (a mouse was plugged in, a
    /// tablet was docked). The startup value is not delivered here because it is
    /// already settled before an application can install a handler; read it with
    /// `Context.seatCapabilities`. This mirrors outputs, where the initial set
    /// comes from `Context.outputs` and later changes come as output_added.
    seat_capabilities: SeatCapabilities,
};

test "SeatCapabilities defaults to no devices" {
    const c = SeatCapabilities{};
    try std.testing.expectEqual(false, c.pointer);
    try std.testing.expectEqual(false, c.keyboard);
    try std.testing.expectEqual(false, c.touch);
}

test "SeatCapabilities.eql separates a differing touch flag from an equal pair" {
    const a = SeatCapabilities{ .pointer = true, .keyboard = true, .touch = false };
    const b = SeatCapabilities{ .pointer = true, .keyboard = true, .touch = false };
    const c = SeatCapabilities{ .pointer = true, .keyboard = true, .touch = true };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "Event carries seat capabilities with the touch flag intact" {
    const e = Event{ .seat_capabilities = .{ .pointer = false, .keyboard = true, .touch = true } };
    try std.testing.expect(e == .seat_capabilities);
    try std.testing.expectEqual(false, e.seat_capabilities.pointer);
    try std.testing.expectEqual(true, e.seat_capabilities.keyboard);
    try std.testing.expectEqual(true, e.seat_capabilities.touch);
}

test "Event carries session activation" {
    const a: Event = .session_inactive;
    try std.testing.expect(a == .session_inactive);
    const b: Event = .session_active;
    try std.testing.expect(b == .session_active);
}

test "InputEvent carries seat-global relative motion" {
    const e = Event{ .input = .{ .pointer_relative = .{ .dx = 3.0, .dy = -2.0, .dx_unaccel = 3.0, .dy_unaccel = -2.0 } } };
    try std.testing.expect(e.input == .pointer_relative);
    try std.testing.expectEqual(@as(f64, 3.0), e.input.pointer_relative.dx);
    try std.testing.expectEqual(@as(f64, -2.0), e.input.pointer_relative.dy_unaccel);
}

test "tablet events construction and field inspection" {
    const prox = InputEvent{ .tablet_proximity = .{ .surface = id.SurfaceId.from(7), .in_prox = true } };
    try std.testing.expect(prox == .tablet_proximity);
    try std.testing.expectEqual(true, prox.tablet_proximity.in_prox);
    try std.testing.expectEqual(@as(u32, 7), prox.tablet_proximity.surface.value());

    const tip = InputEvent{ .tablet_tip = .{ .surface = id.SurfaceId.from(2), .down = false } };
    try std.testing.expect(tip == .tablet_tip);
    try std.testing.expectEqual(false, tip.tablet_tip.down);

    const axis = InputEvent{ .tablet_axis = .{ .surface = id.SurfaceId.from(3), .x = 100.5, .y = 200.0, .pressure = 0.75 } };
    try std.testing.expect(axis == .tablet_axis);
    try std.testing.expectEqual(@as(f64, 100.5), axis.tablet_axis.x);
    try std.testing.expectEqual(@as(f64, 0.75), axis.tablet_axis.pressure);
}

test "event construction and tag inspection" {
    const e = Event{ .resized = .{ .surface = id.SurfaceId.from(1), .width = 800, .height = 600 } };
    try std.testing.expect(e == .resized);
    try std.testing.expectEqual(@as(u32, 800), e.resized.width);

    const k = Event{ .input = .{ .key = .{ .keycode = 30, .state = .pressed } } };
    try std.testing.expect(k.input == .key);
    try std.testing.expectEqual(KeyState.pressed, k.input.key.state);
}
