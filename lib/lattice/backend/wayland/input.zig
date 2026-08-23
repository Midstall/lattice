/// input.zig: pure translation from LogicalEvent to neutral InputEvent.
///
/// inputFromLogical is pure (no I/O, no allocation) and is unit-tested here.
/// Wiring (focus tracking + emission) lives in dispatch.zig handleEvent.
const std = @import("std");
const wlp = @import("wayland_protocol");
const id = @import("../../id.zig");
const nev = @import("../../event.zig");
const dispatch = @import("dispatch.zig");

/// Decode a wl_seat.capabilities bitmask into the neutral struct. The mask comes
/// off the wire from a compositor, so only the three bits this version of the
/// protocol defines are read; any other bit is a capability we cannot use and is
/// dropped. Keeping the bit layout here is what stops it from reaching consumers.
pub fn seatCapabilitiesFromMask(mask: u32) nev.SeatCapabilities {
    return .{
        .pointer = mask & wlp.WlSeat.Capability.pointer != 0,
        .keyboard = mask & wlp.WlSeat.Capability.keyboard != 0,
        .touch = mask & wlp.WlSeat.Capability.touch != 0,
    };
}

/// Map a LogicalEvent to a neutral InputEvent given the focused surface.
/// Returns null for non-input events (e.g. .other) and for wl_pointer_enter
/// (which is a focus-tracking side-effect, not an InputEvent).
pub fn inputFromLogical(logical: dispatch.LogicalEvent, surface: id.SurfaceId) ?nev.InputEvent {
    return switch (logical) {
        .wl_pointer_motion => |m| .{ .pointer_motion = .{ .surface = surface, .x = m.x, .y = m.y } },
        .wl_pointer_button => |b| .{ .pointer_button = .{
            .surface = surface,
            .button = b.button,
            .state = if (b.state == 1) .pressed else .released,
        } },
        .wl_pointer_axis => |a| .{ .pointer_axis = .{
            .surface = surface,
            .horizontal = if (a.axis == 1) a.value else 0,
            .vertical = if (a.axis == 0) a.value else 0,
        } },
        .wl_keyboard_key => |k| .{ .key = .{
            .keycode = k.key,
            .state = if (k.state == 1) .pressed else .released,
        } },
        .wl_touch_down => |t| .{ .touch_down = .{
            .surface = surface,
            .id = @intCast(t.id),
            .x = t.x,
            .y = t.y,
        } },
        .wl_touch_up => |t| .{ .touch_up = .{
            .surface = surface,
            .id = @intCast(t.id),
            .x = 0,
            .y = 0,
        } },
        .wl_touch_motion => |t| .{ .touch_motion = .{
            .surface = surface,
            .id = @intCast(t.id),
            .x = t.x,
            .y = t.y,
        } },
        else => null,
    };
}

// -------------------------------------------------------------------------
// Unit tests
// -------------------------------------------------------------------------

test "seat capabilities mask 0 gives no devices and 7 gives all three" {
    const none = seatCapabilitiesFromMask(0);
    try std.testing.expectEqual(false, none.pointer);
    try std.testing.expectEqual(false, none.keyboard);
    try std.testing.expectEqual(false, none.touch);

    const all = seatCapabilitiesFromMask(7);
    try std.testing.expectEqual(true, all.pointer);
    try std.testing.expectEqual(true, all.keyboard);
    try std.testing.expectEqual(true, all.touch);
}

test "seat capabilities mask 1 gives pointer only and 5 gives pointer plus touch" {
    const pointer_only = seatCapabilitiesFromMask(1);
    try std.testing.expectEqual(true, pointer_only.pointer);
    try std.testing.expectEqual(false, pointer_only.keyboard);
    try std.testing.expectEqual(false, pointer_only.touch);

    const pointer_touch = seatCapabilitiesFromMask(5);
    try std.testing.expectEqual(true, pointer_touch.pointer);
    try std.testing.expectEqual(false, pointer_touch.keyboard);
    try std.testing.expectEqual(true, pointer_touch.touch);

    const keyboard_only = seatCapabilitiesFromMask(2);
    try std.testing.expectEqual(false, keyboard_only.pointer);
    try std.testing.expectEqual(true, keyboard_only.keyboard);
    try std.testing.expectEqual(false, keyboard_only.touch);
}

test "seat capabilities mask ignores unknown high bits and keeps the known flags" {
    // A compositor may advertise capabilities from a newer protocol version.
    // Unknown bits must not corrupt the three flags we understand.
    const unknown_only = seatCapabilitiesFromMask(0xF0);
    try std.testing.expectEqual(false, unknown_only.pointer);
    try std.testing.expectEqual(false, unknown_only.keyboard);
    try std.testing.expectEqual(false, unknown_only.touch);

    const unknown_plus_touch = seatCapabilitiesFromMask(0xF4);
    try std.testing.expectEqual(false, unknown_plus_touch.pointer);
    try std.testing.expectEqual(false, unknown_plus_touch.keyboard);
    try std.testing.expectEqual(true, unknown_plus_touch.touch);

    const every_bit = seatCapabilitiesFromMask(std.math.maxInt(u32));
    try std.testing.expectEqual(true, every_bit.pointer);
    try std.testing.expectEqual(true, every_bit.keyboard);
    try std.testing.expectEqual(true, every_bit.touch);
}

test "wl pointer motion -> neutral PointerMotion passthrough" {
    const out = inputFromLogical(.{ .wl_pointer_motion = .{ .x = 12.5, .y = 7.0 } }, id.SurfaceId.from(3)).?;
    try std.testing.expect(out == .pointer_motion);
    try std.testing.expectEqual(@as(f64, 12.5), out.pointer_motion.x);
    try std.testing.expectEqual(@as(u32, 3), out.pointer_motion.surface.value());
}

test "wl keyboard key -> neutral key (raw code, mapped state)" {
    const p = inputFromLogical(.{ .wl_keyboard_key = .{ .key = 30, .state = 1 } }, id.SurfaceId.from(1)).?;
    try std.testing.expect(p == .key);
    try std.testing.expectEqual(@as(u32, 30), p.key.keycode);
    try std.testing.expectEqual(nev.KeyState.pressed, p.key.state);
    const r = inputFromLogical(.{ .wl_keyboard_key = .{ .key = 30, .state = 0 } }, id.SurfaceId.from(1)).?;
    try std.testing.expectEqual(nev.KeyState.released, r.key.state);
}

test "wl pointer button + axis" {
    const b = inputFromLogical(.{ .wl_pointer_button = .{ .button = 0x110, .state = 1 } }, id.SurfaceId.from(1)).?;
    try std.testing.expect(b == .pointer_button);
    try std.testing.expectEqual(nev.ButtonState.pressed, b.pointer_button.state);
    const a = inputFromLogical(.{ .wl_pointer_axis = .{ .axis = 0, .value = 4.0 } }, id.SurfaceId.from(1)).?;
    try std.testing.expect(a == .pointer_axis);
    try std.testing.expectEqual(@as(f64, 4.0), a.pointer_axis.vertical);
}

test "wl touch down/up/motion" {
    const d = inputFromLogical(.{ .wl_touch_down = .{ .id = 2, .x = 1.0, .y = 2.0 } }, id.SurfaceId.from(1)).?;
    try std.testing.expect(d == .touch_down);
    try std.testing.expectEqual(@as(u32, 2), d.touch_down.id);
    const u = inputFromLogical(.{ .wl_touch_up = .{ .id = 2 } }, id.SurfaceId.from(1)).?;
    try std.testing.expect(u == .touch_up);
}
