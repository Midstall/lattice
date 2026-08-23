//! wl_seat global: pointer + keyboard input routing.
//!
//! Task 9 scope:
//! - Register wl_seat global (v7). Bind: sendCapabilities(pointer|keyboard), sendName("seat0").
//! - get_pointer: create WlPointer resource, store per-client.
//! - get_keyboard: create WlKeyboard resource, store per-client; send keymap.
//! - Compositor.focus/pointerMotion/pointerButton/pointerAxis/key/modifiers route methods.
//! - FocusTracker pure struct (TDD'd).
//!
//! KEYMAP APPROACH: xkbcommon.zig cannot be built as a transitive dep because its
//! `xcb` sub-dependency uses a `.path = "subprojects/xcb"` entry that is excluded
//! from the package `paths` list.  Rather than patching the upstream, we write a
//! minimal hardcoded XKB v1 keymap string directly to a memfd.  The string is a
//! valid XKB_V1 keymap (format 1) covering the standard US QWERTY layout; clients
//! parse it with libxkbcommon as usual.  This is functionally equivalent to what
//! xkbcommon.zig would produce; keymap quality is documented as a known limitation
//! (Task 9 deviation).
//!
//! TIME: a monotonically-increasing u32 counter on the compositor is used instead
//! of real wall-clock ms.  This is correct for protocol ordering.

const std = @import("std");
const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const xkb = @import("xkbcommon");
const posix = std.posix;
const linux = std.os.linux;

const Object = wl.Object;
const Client = wl.server_client.Client;

// Forward reference to break import cycle.
const CompositorOpaque = opaque {};
const HostedSurfaceId = @import("hosted.zig").HostedSurfaceId;
const constraints = @import("constraints.zig");
const rp = @import("relative_pointer");
const pc = @import("pointer_constraints");
const backend = @import("../backend.zig");
const tablet_input = @import("tablet_input.zig");

// wl_seat capability flags (wl_seat.capability enum).
const SEAT_CAP_POINTER: u32 = 1;
const SEAT_CAP_KEYBOARD: u32 = 2;

// wl_keyboard.keymap_format enum values.
const KEYMAP_FORMAT_NO_KEYMAP: u32 = 0;
const KEYMAP_FORMAT_XKB_V1: u32 = 1;

// wl_pointer button state.
const BTN_STATE_RELEASED: u32 = 0;
const BTN_STATE_PRESSED: u32 = 1;

// wl_keyboard key state.
const KEY_STATE_RELEASED: u32 = 0;
const KEY_STATE_PRESSED: u32 = 1;

// Minimal hardcoded XKB v1 keymap (US QWERTY, evdev keycodes 8..255).
// Written directly to a memfd; clients add 8 to the evdev keycode to get XKB keycode.
const MINIMAL_KEYMAP: [:0]const u8 =
    \\xkb_keymap {
    \\  xkb_keycodes "evdev" {
    \\    minimum = 8;
    \\    maximum = 255;
    \\    <ESC>   =  9;
    \\    <AE01>  = 10; <AE02> = 11; <AE03> = 12; <AE04> = 13; <AE05> = 14;
    \\    <AE06>  = 15; <AE07> = 16; <AE08> = 17; <AE09> = 18; <AE10> = 19;
    \\    <AE11>  = 20; <AE12> = 21;
    \\    <BKSP>  = 22;
    \\    <TAB>   = 23;
    \\    <AD01>  = 24; <AD02> = 25; <AD03> = 26; <AD04> = 27; <AD05> = 28;
    \\    <AD06>  = 29; <AD07> = 30; <AD08> = 31; <AD09> = 32; <AD10> = 33;
    \\    <AD11>  = 34; <AD12> = 35;
    \\    <RTRN>  = 36;
    \\    <LCTL>  = 37;
    \\    <AC01>  = 38; <AC02> = 39; <AC03> = 40; <AC04> = 41; <AC05> = 42;
    \\    <AC06>  = 43; <AC07> = 44; <AC08> = 45; <AC09> = 46; <AC10> = 47;
    \\    <AC11>  = 48;
    \\    <LFSH>  = 50;
    \\    <AB01>  = 52; <AB02> = 53; <AB03> = 54; <AB04> = 55; <AB05> = 56;
    \\    <AB06>  = 57; <AB07> = 58; <AB08> = 59; <AB09> = 60; <AB10> = 61;
    \\    <RTSH>  = 62;
    \\    <LALT>  = 64;
    \\    <SPCE>  = 65;
    \\    <CAPS>  = 66;
    \\  };
    \\  xkb_types "complete" {
    \\    type "ONE_LEVEL" {
    \\      modifiers = none;
    \\      level_name[Level1] = "Any";
    \\    };
    \\    type "TWO_LEVEL" {
    \\      modifiers = Shift;
    \\      map[Shift] = Level2;
    \\      level_name[Level1] = "Base";
    \\      level_name[Level2] = "Shift";
    \\    };
    \\    type "ALPHABETIC" {
    \\      modifiers = Shift+Lock;
    \\      map[Shift] = Level2;
    \\      map[Lock]  = Level2;
    \\      level_name[Level1] = "Base";
    \\      level_name[Level2] = "Caps";
    \\    };
    \\  };
    \\  xkb_compat "complete" {};
    \\  xkb_symbols "pc+us" {
    \\    name[group1] = "English (US)";
    \\    key <ESC>  { [ Escape ] };
    \\    key <AE01> { type="TWO_LEVEL", [ 1, exclam ] };
    \\    key <AE02> { type="TWO_LEVEL", [ 2, at ] };
    \\    key <AE03> { type="TWO_LEVEL", [ 3, numbersign ] };
    \\    key <AE04> { type="TWO_LEVEL", [ 4, dollar ] };
    \\    key <AE05> { type="TWO_LEVEL", [ 5, percent ] };
    \\    key <AE06> { type="TWO_LEVEL", [ 6, asciicircum ] };
    \\    key <AE07> { type="TWO_LEVEL", [ 7, ampersand ] };
    \\    key <AE08> { type="TWO_LEVEL", [ 8, asterisk ] };
    \\    key <AE09> { type="TWO_LEVEL", [ 9, parenleft ] };
    \\    key <AE10> { type="TWO_LEVEL", [ 0, parenright ] };
    \\    key <BKSP> { [ BackSpace ] };
    \\    key <TAB>  { [ Tab ] };
    \\    key <AD01> { type="ALPHABETIC", [ q, Q ] };
    \\    key <AD02> { type="ALPHABETIC", [ w, W ] };
    \\    key <AD03> { type="ALPHABETIC", [ e, E ] };
    \\    key <AD04> { type="ALPHABETIC", [ r, R ] };
    \\    key <AD05> { type="ALPHABETIC", [ t, T ] };
    \\    key <AD06> { type="ALPHABETIC", [ y, Y ] };
    \\    key <AD07> { type="ALPHABETIC", [ u, U ] };
    \\    key <AD08> { type="ALPHABETIC", [ i, I ] };
    \\    key <AD09> { type="ALPHABETIC", [ o, O ] };
    \\    key <AD10> { type="ALPHABETIC", [ p, P ] };
    \\    key <RTRN> { [ Return ] };
    \\    key <LCTL> { [ Control_L ] };
    \\    key <AC01> { type="ALPHABETIC", [ a, A ] };
    \\    key <AC02> { type="ALPHABETIC", [ s, S ] };
    \\    key <AC03> { type="ALPHABETIC", [ d, D ] };
    \\    key <AC04> { type="ALPHABETIC", [ f, F ] };
    \\    key <AC05> { type="ALPHABETIC", [ g, G ] };
    \\    key <AC06> { type="ALPHABETIC", [ h, H ] };
    \\    key <AC07> { type="ALPHABETIC", [ j, J ] };
    \\    key <AC08> { type="ALPHABETIC", [ k, K ] };
    \\    key <AC09> { type="ALPHABETIC", [ l, L ] };
    \\    key <AC10> { type="TWO_LEVEL", [ semicolon, colon ] };
    \\    key <AC11> { type="TWO_LEVEL", [ apostrophe, quotedbl ] };
    \\    key <LFSH> { [ Shift_L ] };
    \\    key <AB01> { type="ALPHABETIC", [ z, Z ] };
    \\    key <AB02> { type="ALPHABETIC", [ x, X ] };
    \\    key <AB03> { type="ALPHABETIC", [ c, C ] };
    \\    key <AB04> { type="ALPHABETIC", [ v, V ] };
    \\    key <AB05> { type="ALPHABETIC", [ b, B ] };
    \\    key <AB06> { type="ALPHABETIC", [ n, N ] };
    \\    key <AB07> { type="ALPHABETIC", [ m, M ] };
    \\    key <AB08> { type="TWO_LEVEL", [ comma, less ] };
    \\    key <AB09> { type="TWO_LEVEL", [ period, greater ] };
    \\    key <AB10> { type="TWO_LEVEL", [ slash, question ] };
    \\    key <RTSH> { [ Shift_R ] };
    \\    key <LALT> { [ Alt_L ] };
    \\    key <SPCE> { [ space ] };
    \\    key <CAPS> { [ Caps_Lock ] };
    \\    modifier_map Shift   { <LFSH>, <RTSH> };
    \\    modifier_map Lock    { <CAPS> };
    \\    modifier_map Mod1    { <LALT> };
    \\    modifier_map Control { <LCTL> };
    \\  };
    \\};
;

// ---------------------------------------------------------------------------
// FocusTracker: pure focus-transition bookkeeping.
// Callers get a Transition back describing what leave/enter to send.
// ---------------------------------------------------------------------------

pub const Transition = struct {
    leave: ?HostedSurfaceId,
    enter: ?HostedSurfaceId,
};

pub const FocusTracker = struct {
    focused: ?HostedSurfaceId = null,

    /// Focus a new surface (or null to clear focus).
    /// Returns the leave/enter pair the caller must send.
    /// Focusing the already-focused surface is a no-op (returns null/null).
    pub fn focus(self: *FocusTracker, new: ?HostedSurfaceId) Transition {
        if (self.focused == new) return .{ .leave = null, .enter = null };
        const old = self.focused;
        self.focused = new;
        return .{ .leave = old, .enter = new };
    }
};

// ---------------------------------------------------------------------------
// Per-client input resource tracking.
// ---------------------------------------------------------------------------

/// One client's seat resources. Stored in an ArrayList on the SeatCtx.
pub const ClientSeat = struct {
    /// The wl_seat object (needed to match clients).
    seat_res: *Object,
    /// The wl_pointer resource, if the client called get_pointer.
    pointer_res: ?*Object = null,
    /// The wl_keyboard resource, if the client called get_keyboard.
    keyboard_res: ?*Object = null,
    /// The zwp_relative_pointer_v1 resource, if the client called get_relative_pointer.
    relative_ptr_res: ?*Object = null,

    // --- cursor state (set via wl_pointer.set_cursor) ---
    /// True once the client has called set_cursor at least once.
    cursor_set: bool = false,
    /// True when the client explicitly hid the cursor (surface == null in set_cursor).
    cursor_hidden: bool = false,
    /// The wl_surface object id the client wants as cursor image.
    /// 0 when cursor_hidden is true or no surface was provided.
    cursor_surface_id: u32 = 0,
    /// Hotspot relative to the cursor surface top-left (positive = inside the surface).
    cursor_hotspot_x: i32 = 0,
    cursor_hotspot_y: i32 = 0,
};

// ---------------------------------------------------------------------------
// SeatCtx: lives inline on the Compositor (stable pointer).
// ---------------------------------------------------------------------------

pub const SeatCtx = struct {
    seat_impl: wlp.WlSeat.Implementation,
    pointer_impl: wlp.WlPointer.Implementation,
    keyboard_impl: wlp.WlKeyboard.Implementation,

    /// Back-pointer to the owning Compositor (set by Compositor.init).
    compositor: *CompositorOpaque = undefined,

    /// Per-client seat resources.
    clients: std.ArrayList(ClientSeat) = .empty,

    /// Focus tracker (keyboard + pointer share the same focused surface).
    focus_tracker: FocusTracker = .{},

    /// Monotonic time counter (ms ticks). Incremented by each routed event.
    time_counter: u32 = 0,

    /// The XKB v1 keymap text sent to every wl_keyboard (built once at init).
    /// Points either at a gpa-owned buffer (real keymap) or the static
    /// MINIMAL_KEYMAP constant (fallback). `keymap_owned` says which.
    keymap_text: []const u8 = MINIMAL_KEYMAP,
    /// True when `keymap_text` is a gpa-owned buffer that deinit must free.
    /// False when it aliases the static MINIMAL_KEYMAP fallback.
    keymap_owned: bool = false,
    /// True when the keymap was built from the real XKB database (not the
    /// MINIMAL fallback). Informational; used for logging / e2e assertions.
    keymap_is_real: bool = false,
};

pub fn makeSeatCtx() SeatCtx {
    return .{
        .seat_impl = .{
            .get_pointer = onGetPointer,
            .get_keyboard = onGetKeyboard,
            .get_touch = null,
            .release = onSeatRelease,
        },
        .pointer_impl = .{
            .release = onPointerRelease,
            .set_cursor = onSetCursor,
        },
        .keyboard_impl = .{
            .release = onKeyboardRelease,
        },
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn getCompositor(ctx: *SeatCtx) *@import("../compositor.zig").Compositor {
    return @ptrCast(@alignCast(ctx.compositor));
}

fn getSeatCtx(client_data: ?*anyopaque) *SeatCtx {
    return @ptrCast(@alignCast(client_data.?));
}

/// Build a REAL us/evdev XKB v1 keymap and return its text as a gpa-owned
/// buffer. The caller owns the result and frees it with `gpa.free`.
///
/// Ownership: `km.getAsString(.text_v1)` returns `ctx.allocator.dupe(...)`,
/// i.e. a fresh buffer allocated with the SAME `gpa` passed to Context.create.
/// That buffer survives both `km.destroy()` and `ctx.destroy()`, so we can
/// return it directly with no extra dupe.
///
/// Any failure (missing/incomplete XKB DB, allocation, parse) returns an error;
/// the caller selects the MINIMAL_KEYMAP fallback on error.
fn buildRealKeymap(gpa: std.mem.Allocator, io: std.Io, root: ?[]const u8) ![]u8 {
    const ctx = try xkb.Context.create(gpa, io, .{ .no_default_includes = true }, null);
    defer ctx.destroy();
    if (root) |r| try ctx.includePathAppend(r);
    const km = try xkb.Keymap.newFromNames(ctx, .{ .rules = "evdev", .layout = "us" }, .text_v1);
    defer km.destroy();
    return try km.getAsString(.text_v1); // gpa-owned, survives ctx/km destroy
}

/// Apply a build result/error to the SeatCtx keymap cache. Factored out so the
/// bookkeeping (which slice + owned/is_real flags) can be unit-tested without a
/// live xkbcommon build (see tests below).
fn selectKeymap(ctx: *SeatCtx, result: anyerror![]u8) void {
    if (result) |txt| {
        ctx.keymap_text = txt;
        ctx.keymap_owned = true;
        ctx.keymap_is_real = true;
    } else |_| {
        ctx.keymap_text = MINIMAL_KEYMAP;
        ctx.keymap_owned = false;
        ctx.keymap_is_real = false;
    }
}

/// Build + cache the seat keymap ONCE at Compositor.init. On success caches the
/// gpa-owned real keymap; on any failure caches the static MINIMAL_KEYMAP.
pub fn initSeatKeymap(ctx: *SeatCtx, gpa: std.mem.Allocator, io: std.Io, root: ?[]const u8) void {
    const result = buildRealKeymap(gpa, io, root);
    selectKeymap(ctx, result);
    if (ctx.keymap_is_real) {
        std.log.info("seat: real xkb keymap us/evdev ({d} bytes)", .{ctx.keymap_text.len});
    } else if (result) |_| {
        // unreachable: selectKeymap sets is_real on success. Kept for clarity.
    } else |err| {
        std.log.warn("seat: xkb keymap build failed ({}), using MINIMAL fallback", .{err});
    }
}

/// Write the seat's cached XKB keymap to a memfd and send it to a wl_keyboard
/// resource. Reads `ctx.keymap_text` (real keymap or MINIMAL fallback, chosen
/// once at init). Falls back to NO_KEYMAP if memfd/ftruncate/mmap fails.
/// Note: std.posix.close was removed in Zig 0.16; use linux.close directly.
fn sendKeymapToResource(ctx: *SeatCtx, kbd_res: *Object) void {
    const text = ctx.keymap_text;
    // size includes the null terminator.
    const size: u32 = @intCast(text.len + 1);

    const fd = posix.memfd_create("xkb-keymap", 0) catch {
        std.log.warn("seat: memfd_create failed, NO_KEYMAP fallback", .{});
        return;
    };
    // linux.close is the correct way to close an fd in Zig 0.16 (std.posix.close removed).
    defer _ = linux.close(fd);

    const rc = linux.ftruncate(fd, @intCast(size));
    if (posix.errno(rc) != .SUCCESS) {
        std.log.warn("seat: ftruncate failed, NO_KEYMAP fallback", .{});
        return;
    }

    const map = std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch {
        std.log.warn("seat: mmap failed, NO_KEYMAP fallback", .{});
        return;
    };
    @memcpy(map[0..text.len], text);
    map[text.len] = 0;
    std.posix.munmap(map);

    wlp.WlKeyboard.sendKeymap(kbd_res, KEYMAP_FORMAT_XKB_V1, fd, size);
}

// ---------------------------------------------------------------------------
// wl_seat bind + request handlers
// ---------------------------------------------------------------------------

pub fn bindSeat(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx: *SeatCtx = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &wlp.WlSeat.interface, version, id) catch return;
    wlp.WlSeat.sendCapabilities(resource, SEAT_CAP_POINTER | SEAT_CAP_KEYBOARD);
    if (version >= 2) wlp.WlSeat.sendName(resource, "seat0");
    wlp.WlSeat.setImplementation(resource, &ctx.seat_impl, ctx, onSeatDestroy);

    const comp = getCompositor(ctx);
    comp.seat_ctx.clients.append(comp.gpa, .{ .seat_res = resource }) catch |err| {
        std.log.err("seat: failed to track client seat: {}", .{err});
    };
}

fn onSeatDestroy(resource: *Object) void {
    // Retrieve ctx from the resource's user_data (set by setImplementation).
    const ctx: *SeatCtx = @ptrCast(@alignCast(resource.user_data.?));
    const items = ctx.clients.items;
    for (items, 0..) |*cs, i| {
        if (cs.seat_res == resource) {
            _ = ctx.clients.orderedRemove(i);
            return;
        }
    }
    // NOTE: a ResourceDestroyFn must NOT call resource.destroy() - the framework's
    // Object.destroy() has no re-entry guard, so self-destroying here would recurse
    // infinitely. The not-found path just returns; the framework does the cleanup.
}

fn onGetPointer(client_data: ?*anyopaque, resource: *Object, id: u32) void {
    const ctx: *SeatCtx = getSeatCtx(client_data);
    const ptr_res = Object.create(resource.client, &wlp.WlPointer.interface, resource.version, id) catch return;
    wlp.WlPointer.setImplementation(ptr_res, &ctx.pointer_impl, ctx, onPointerDestroy);

    for (ctx.clients.items) |*cs| {
        if (cs.seat_res == resource) {
            cs.pointer_res = ptr_res;
            return;
        }
    }
}

fn onGetKeyboard(client_data: ?*anyopaque, resource: *Object, id: u32) void {
    const ctx: *SeatCtx = getSeatCtx(client_data);
    const kbd_res = Object.create(resource.client, &wlp.WlKeyboard.interface, resource.version, id) catch return;
    wlp.WlKeyboard.setImplementation(kbd_res, &ctx.keyboard_impl, ctx, onKeyboardDestroy);

    sendKeymapToResource(ctx, kbd_res);

    for (ctx.clients.items) |*cs| {
        if (cs.seat_res == resource) {
            cs.keyboard_res = kbd_res;
            return;
        }
    }
}

fn onSeatRelease(client_data: ?*anyopaque, resource: *Object) void {
    // FIX: the release REQUEST requires us to both remove the entry AND destroy
    // the resource. onSeatDestroy (the destroy callback) removes but returns without
    // destroying because wayland.zig handles that on the destructor path. Here we
    // are on the explicit request path so we must destroy it ourselves.
    const ctx: *SeatCtx = @ptrCast(@alignCast(client_data.?));
    const items = ctx.clients.items;
    for (items, 0..) |*cs, i| {
        if (cs.seat_res == resource) {
            _ = ctx.clients.orderedRemove(i);
            break;
        }
    }
    resource.destroy();
}

fn onPointerRelease(_: ?*anyopaque, resource: *Object) void {
    // wl_pointer.release is the explicit destructor request from the client.
    // We call resource.destroy() here, which fires onPointerDestroy (bookkeeping)
    // once, then framework does sendDeleteId + removeObject. This is the correct
    // place to call destroy on the explicit-request path.
    resource.destroy();
}

fn onPointerDestroy(resource: *Object) void {
    // ResourceDestroyFn: called by Object.destroy() before sendDeleteId/removeObject.
    // Object.destroy() has NO re-entry guard: calling resource.destroy() here would
    // re-enter Object.destroy() -> call this fn again -> infinite recursion / stack
    // overflow. Do bookkeeping ONLY; the framework handles the rest.
    const ctx: *SeatCtx = @ptrCast(@alignCast(resource.user_data.?));
    for (ctx.clients.items) |*cs| {
        if (cs.pointer_res == resource) {
            cs.pointer_res = null;
            return;
        }
    }
}

/// wl_pointer.set_cursor request handler.
///
/// Protocol note: only the currently focused client is permitted to call
/// set_cursor; the serial must match the most recent pointer-enter. For this
/// slice we accept and store the request unconditionally (no serial check) to
/// keep implementation minimal. A strict implementation would verify that
/// `serial` matches the last enter serial before updating cursor state.
///
/// surface == null means "hide the cursor". Otherwise the surface object id
/// is stored so drawCursor can look up its texture.
fn onSetCursor(
    client_data: ?*anyopaque,
    resource: *Object,
    _: u32, // serial (not validated in this slice; see note above)
    surface: ?*Object,
    hotspot_x: i32,
    hotspot_y: i32,
) void {
    const ctx: *SeatCtx = getSeatCtx(client_data);
    // Find the ClientSeat whose pointer_res matches this resource.
    for (ctx.clients.items) |*cs| {
        if (cs.pointer_res == resource) {
            if (surface == null) {
                cs.cursor_hidden = true;
                cs.cursor_set = true;
                cs.cursor_surface_id = 0;
                cs.cursor_hotspot_x = 0;
                cs.cursor_hotspot_y = 0;
            } else {
                cs.cursor_hidden = false;
                cs.cursor_set = true;
                cs.cursor_surface_id = surface.?.id;
                cs.cursor_hotspot_x = hotspot_x;
                cs.cursor_hotspot_y = hotspot_y;
            }
            return;
        }
    }
    // No matching ClientSeat found - ignore (client may not have a get_pointer yet,
    // or the resource is being torn down). Protocol allows this to be a no-op.
}

fn onKeyboardRelease(_: ?*anyopaque, resource: *Object) void {
    // wl_keyboard.release is the explicit destructor request from the client.
    // We call resource.destroy() here, which fires onKeyboardDestroy (bookkeeping)
    // once, then framework does sendDeleteId + removeObject. This is the correct
    // place to call destroy on the explicit-request path.
    resource.destroy();
}

fn onKeyboardDestroy(resource: *Object) void {
    // ResourceDestroyFn: called by Object.destroy() before sendDeleteId/removeObject.
    // Object.destroy() has NO re-entry guard: calling resource.destroy() here would
    // re-enter Object.destroy() -> call this fn again -> infinite recursion / stack
    // overflow. Do bookkeeping ONLY; the framework handles the rest.
    const ctx: *SeatCtx = @ptrCast(@alignCast(resource.user_data.?));
    for (ctx.clients.items) |*cs| {
        if (cs.keyboard_res == resource) {
            cs.keyboard_res = null;
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Route helpers: called from Compositor.focus / pointer* / key / modifiers.
// ---------------------------------------------------------------------------

/// Find the seat client entry whose wl_surface resource belongs to the same client.
/// Pub so compositor.zig can call it to look up cursor state for drawCursor.
pub fn findClientSeatForSurface(
    ctx: *SeatCtx,
    comp: *@import("../compositor.zig").Compositor,
    surface_id: HostedSurfaceId,
) ?*ClientSeat {
    const entry = comp.findSurfaceById(surface_id) orelse return null;
    const surface_client = entry.wl_surface_res.client;
    for (ctx.clients.items) |*cs| {
        if (cs.seat_res.client == surface_client) return cs;
    }
    return null;
}

/// Advance the monotonic time counter and return the new value.
fn tick(ctx: *SeatCtx) u32 {
    ctx.time_counter +%= 1;
    return ctx.time_counter;
}

/// Send keyboard leave to old focus, enter to new focus.
/// Task 6: also activates/deactivates pointer constraints on focus transitions.
pub fn routeFocus(
    ctx: *SeatCtx,
    comp: *@import("../compositor.zig").Compositor,
    new_id: ?HostedSurfaceId,
) void {
    const transition = ctx.focus_tracker.focus(new_id);

    // --- LEAVE: deactivate constraint on the old surface ---
    if (transition.leave) |old_id| {
        if (findClientSeatForSurface(ctx, comp, old_id)) |cs| {
            if (cs.keyboard_res) |kbd| {
                const serial = comp.display.nextSerial();
                if (comp.findSurfaceById(old_id)) |e| {
                    wlp.WlKeyboard.sendLeave(kbd, serial, e.wl_surface_res);
                }
            }
            if (cs.pointer_res) |ptr| {
                const serial2 = comp.display.nextSerial();
                if (comp.findSurfaceById(old_id)) |e| {
                    wlp.WlPointer.sendLeave(ptr, serial2, e.wl_surface_res);
                }
                wlp.WlPointer.sendFrame(ptr);
            }
        }

        // Clear tablet proximity on the old surface (tool leaves with focus).
        tablet_input.clearProximityOnFocusLeave(&comp.tablet_ctx, comp, old_id);

        // Deactivate any active constraint on the old surface.
        for (comp.constraints_ctx.list.items) |*c| {
            if (!c.dead and c.active and c.surface == old_id.value()) {
                c.active = false;
                // WARP-ON-UNLOCK (D7.2 Task 3): for lock constraints with a pending
                // cursor-position hint (set via zwp_locked_pointer_v1.set_cursor_position_hint),
                // warp the compositor cursor to the surface-local hint position.
                // Assumption: single fullscreen/maximized surface, so surface-local == compositor-global.
                // If per-surface origin offsets are added in future, adjust here.
                // One-shot: clear has_hint after applying so repeated deactivations skip the warp.
                if (constraints.warpTarget(c.*)) |target| {
                    comp.cursor_x = target.x;
                    comp.cursor_y = target.y;
                    c.has_hint = false;
                    std.log.info("constraints: warp-on-unlock applied ({d:.2},{d:.2})", .{ target.x, target.y });
                }
                // Send protocol event to client.
                if (c.obj_res) |obj| {
                    switch (c.kind) {
                        .lock => pc.ZwpLockedPointerV1.sendUnlocked(obj),
                        .confine => pc.ZwpConfinedPointerV1.sendUnconfined(obj),
                    }
                }
                // Oneshot: mark dead after first deactivation.
                if (c.lifetime == .oneshot) c.dead = true;
                // Emit linkage event: kind=none clears the backend constraint.
                emitConstraintEvent(comp, .{ .kind = .none, .region = null });
                break;
            }
        }
    }

    // --- ENTER: activate constraint on the new surface ---
    if (transition.enter) |new_id2| {
        if (findClientSeatForSurface(ctx, comp, new_id2)) |cs| {
            if (comp.findSurfaceById(new_id2)) |entry| {
                if (cs.keyboard_res) |kbd| {
                    const serial = comp.display.nextSerial();
                    // keys currently held = empty array.
                    wlp.WlKeyboard.sendEnter(kbd, serial, entry.wl_surface_res, "");
                }
                if (cs.pointer_res) |ptr| {
                    const serial2 = comp.display.nextSerial();
                    // Position 0,0; caller should follow with a motion if needed.
                    wlp.WlPointer.sendEnter(
                        ptr,
                        serial2,
                        entry.wl_surface_res,
                        wl.Fixed.fromDouble(0.0),
                        wl.Fixed.fromDouble(0.0),
                    );
                    wlp.WlPointer.sendFrame(ptr);
                }
            }
        }

        // Activate a live (non-dead) constraint on the new surface.
        // Keyed by compositor-global HostedSurfaceId value; runs unconditionally
        // so a failed entry lookup cannot silently skip constraint activation.
        for (comp.constraints_ctx.list.items) |*c| {
            if (!c.dead and !c.active and c.surface == new_id2.value()) {
                c.active = true;
                // Send protocol event to client.
                if (c.obj_res) |obj| {
                    switch (c.kind) {
                        .lock => pc.ZwpLockedPointerV1.sendLocked(obj),
                        .confine => pc.ZwpConfinedPointerV1.sendConfined(obj),
                    }
                }
                // Emit linkage event with the constraint kind and region.
                const req_kind: backend.PointerConstraintReq = switch (c.kind) {
                    .lock => .{ .kind = .lock, .region = c.region },
                    .confine => .{ .kind = .confine, .region = c.region },
                };
                emitConstraintEvent(comp, req_kind);
                break;
            }
        }
    }
}

/// Emit a pointer_constraint CompositorEvent via the compositor's handler if set.
fn emitConstraintEvent(comp: *@import("../compositor.zig").Compositor, req: backend.PointerConstraintReq) void {
    if (comp.handler) |h| {
        h(comp.handler_ctx, .{ .pointer_constraint = req });
    }
}

pub fn routePointerMotion(
    ctx: *SeatCtx,
    comp: *@import("../compositor.zig").Compositor,
    x: f64,
    y: f64,
) void {
    const focused = ctx.focus_tracker.focused orelse return;
    const cs = findClientSeatForSurface(ctx, comp, focused) orelse return;
    const ptr = cs.pointer_res orelse return;

    // Task 6: enforce lock/confine constraints before sending absolute motion.
    const focused_entry = comp.findSurfaceById(focused);

    if (constraints.activeFor(comp.constraints_ctx.list.items, focused.value())) |c| {
        if (constraints.suppressesAbsolute(c.*)) {
            // Active lock: suppress absolute motion entirely (pointer is frozen).
            return;
        }
        // Active confine: clamp the coordinates to the region.
        if (c.active and c.kind == .confine) {
            const surf_w = if (focused_entry) |e| e.surface.width else 0;
            const surf_h = if (focused_entry) |e| e.surface.height else 0;
            const clamped = constraints.clampToRegion(x, y, c.region, surf_w, surf_h);
            const time = tick(ctx);
            wlp.WlPointer.sendMotion(ptr, time, wl.Fixed.fromDouble(clamped.x), wl.Fixed.fromDouble(clamped.y));
            wlp.WlPointer.sendFrame(ptr);
            return;
        }
    }

    const time = tick(ctx);
    wlp.WlPointer.sendMotion(ptr, time, wl.Fixed.fromDouble(x), wl.Fixed.fromDouble(y));
    wlp.WlPointer.sendFrame(ptr);
}

pub fn routePointerButton(
    ctx: *SeatCtx,
    comp: *@import("../compositor.zig").Compositor,
    button: u32,
    pressed: bool,
) void {
    const focused = ctx.focus_tracker.focused orelse return;
    const cs = findClientSeatForSurface(ctx, comp, focused) orelse return;
    const ptr = cs.pointer_res orelse return;
    const serial = comp.display.nextSerial();
    const time = tick(ctx);
    const state: u32 = if (pressed) BTN_STATE_PRESSED else BTN_STATE_RELEASED;
    wlp.WlPointer.sendButton(ptr, serial, time, button, state);
    wlp.WlPointer.sendFrame(ptr);
}

pub fn routePointerAxis(
    ctx: *SeatCtx,
    comp: *@import("../compositor.zig").Compositor,
    horizontal: f64,
    vertical: f64,
) void {
    const focused = ctx.focus_tracker.focused orelse return;
    const cs = findClientSeatForSurface(ctx, comp, focused) orelse return;
    const ptr = cs.pointer_res orelse return;
    const time = tick(ctx);
    // axis: 0 = vertical_scroll, 1 = horizontal_scroll.
    if (vertical != 0.0) {
        wlp.WlPointer.sendAxis(ptr, time, 0, wl.Fixed.fromDouble(vertical));
    }
    if (horizontal != 0.0) {
        wlp.WlPointer.sendAxis(ptr, time, 1, wl.Fixed.fromDouble(horizontal));
    }
    wlp.WlPointer.sendFrame(ptr);
}

/// Route seat-global relative motion to the focused client's zwp_relative_pointer_v1.
/// Sent whenever the client has a relative pointer resource (not gated on lock/confine).
/// Uses hi=0, lo=tick as the split 64-bit microsecond timestamp (monotonic ordering).
pub fn routePointerRelative(
    ctx: *SeatCtx,
    comp: *@import("../compositor.zig").Compositor,
    dx: f64,
    dy: f64,
    dx_unaccel: f64,
    dy_unaccel: f64,
) void {
    const focused = ctx.focus_tracker.focused orelse return;
    const cs = findClientSeatForSurface(ctx, comp, focused) orelse return;
    const rp_res = cs.relative_ptr_res orelse return;
    const lo = tick(ctx);
    rp.ZwpRelativePointerV1.sendRelativeMotion(
        rp_res,
        0, // utime_hi (hi word of 64-bit us timestamp, use 0)
        lo, // utime_lo (monotonic tick as lo word)
        wl.Fixed.fromDouble(dx),
        wl.Fixed.fromDouble(dy),
        wl.Fixed.fromDouble(dx_unaccel),
        wl.Fixed.fromDouble(dy_unaccel),
    );
}

pub fn routeKey(
    ctx: *SeatCtx,
    comp: *@import("../compositor.zig").Compositor,
    keycode: u32,
    pressed: bool,
) void {
    const focused = ctx.focus_tracker.focused orelse return;
    const cs = findClientSeatForSurface(ctx, comp, focused) orelse return;
    const kbd = cs.keyboard_res orelse return;
    const serial = comp.display.nextSerial();
    const time = tick(ctx);
    const state: u32 = if (pressed) KEY_STATE_PRESSED else KEY_STATE_RELEASED;
    wlp.WlKeyboard.sendKey(kbd, serial, time, keycode, state);
}

pub fn routeModifiers(
    ctx: *SeatCtx,
    comp: *@import("../compositor.zig").Compositor,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) void {
    const focused = ctx.focus_tracker.focused orelse return;
    const cs = findClientSeatForSurface(ctx, comp, focused) orelse return;
    const kbd = cs.keyboard_res orelse return;
    const serial = comp.display.nextSerial();
    wlp.WlKeyboard.sendModifiers(kbd, serial, mods_depressed, mods_latched, mods_locked, group);
}

// ---------------------------------------------------------------------------
// Deinit helpers for SeatCtx (called from Compositor.deinit).
// ---------------------------------------------------------------------------

pub fn deinitSeatCtx(ctx: *SeatCtx, gpa: std.mem.Allocator) void {
    // Free the real keymap buffer if we own one (the MINIMAL fallback is static).
    if (ctx.keymap_owned) gpa.free(ctx.keymap_text);
    ctx.clients.deinit(gpa);
}

// ---------------------------------------------------------------------------
// Unit tests (pure pieces)
// ---------------------------------------------------------------------------

test "FocusTracker: focus A emits enter A, no leave" {
    const Id = HostedSurfaceId;
    var tracker = FocusTracker{};
    const t = tracker.focus(Id.from(1));
    try std.testing.expectEqual(@as(?Id, null), t.leave);
    try std.testing.expectEqual(@as(?Id, Id.from(1)), t.enter);
    try std.testing.expectEqual(@as(?Id, Id.from(1)), tracker.focused);
}

test "FocusTracker: focus B after A emits leave A, enter B" {
    const Id = HostedSurfaceId;
    var tracker = FocusTracker{};
    _ = tracker.focus(Id.from(1));
    const t = tracker.focus(Id.from(2));
    try std.testing.expectEqual(@as(?Id, Id.from(1)), t.leave);
    try std.testing.expectEqual(@as(?Id, Id.from(2)), t.enter);
}

test "FocusTracker: focus null emits leave, no enter" {
    const Id = HostedSurfaceId;
    var tracker = FocusTracker{};
    _ = tracker.focus(Id.from(1));
    const t = tracker.focus(null);
    try std.testing.expectEqual(@as(?Id, Id.from(1)), t.leave);
    try std.testing.expectEqual(@as(?Id, null), t.enter);
    try std.testing.expectEqual(@as(?Id, null), tracker.focused);
}

test "FocusTracker: focus same surface is a no-op" {
    const Id = HostedSurfaceId;
    var tracker = FocusTracker{};
    _ = tracker.focus(Id.from(5));
    const t = tracker.focus(Id.from(5));
    try std.testing.expectEqual(@as(?Id, null), t.leave);
    try std.testing.expectEqual(@as(?Id, null), t.enter);
}

// ---------------------------------------------------------------------------
// Keymap cache tests.
//
// What is tested here (unit level):
//  - selectKeymap bookkeeping: a build SUCCESS caches the gpa-owned real
//    keymap (owned=true, is_real=true); a build ERROR selects the static
//    MINIMAL_KEYMAP (owned=false, is_real=false). This is the exact logic
//    initSeatKeymap runs, exercised without a live xkbcommon build.
//  - buildRealKeymap against a nonexistent XKB root returns an error (proving
//    the fallback branch is selected), using a single-threaded std.Io. No
//    buffer is produced so nothing is freed.
//
// What the e2e (Task 3) covers instead: a SUCCESSFUL real build from the
// system XKB database (env-derived root) producing a keymap much larger than
// MINIMAL_KEYMAP, sent to a real hosted wl_keyboard without protocol error.
// The positive build needs an XKB DB path (getenv unavailable in unit tests),
// so it is deferred to the e2e rather than hardcoded here.
// ---------------------------------------------------------------------------

test "selectKeymap: success caches owned real keymap" {
    const testing = std.testing;
    var ctx: SeatCtx = undefined;
    ctx.keymap_text = MINIMAL_KEYMAP;
    ctx.keymap_owned = false;
    ctx.keymap_is_real = false;

    const owned = try testing.allocator.dupe(u8, "xkb_keymap { fake };");
    selectKeymap(&ctx, owned);
    try testing.expect(ctx.keymap_owned);
    try testing.expect(ctx.keymap_is_real);
    try testing.expectEqualStrings("xkb_keymap { fake };", ctx.keymap_text);
    // Mirror deinit's free path so the owned buffer does not leak.
    if (ctx.keymap_owned) testing.allocator.free(ctx.keymap_text);
}

test "selectKeymap: error selects static MINIMAL fallback" {
    const testing = std.testing;
    var ctx: SeatCtx = undefined;
    ctx.keymap_text = "";
    ctx.keymap_owned = true;
    ctx.keymap_is_real = true;

    selectKeymap(&ctx, error.KeymapCompilationFailed);
    try testing.expect(!ctx.keymap_owned);
    try testing.expect(!ctx.keymap_is_real);
    // Aliases the static constant; nothing to free.
    try testing.expect(ctx.keymap_text.ptr == MINIMAL_KEYMAP.ptr);
}

test "buildRealKeymap: nonexistent XKB root returns error (fallback path)" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    // The exact error tag depends on xkbcommon internals (missing rules file,
    // include resolution, or parse); we only assert it FAILS so init selects
    // the MINIMAL fallback. No buffer is returned on error, nothing to free.
    if (buildRealKeymap(testing.allocator, io, "/nonexistent/xkb/path")) |txt| {
        testing.allocator.free(txt);
        try testing.expect(false); // should not have built a keymap
    } else |_| {
        // expected: fell through to the error branch.
    }
}

test "wl.Fixed: f64 to Fixed encoding round-trip" {
    const f = wl.Fixed.fromDouble(1.5);
    // 1.5 * 256 = 384 = 0x180
    try std.testing.expectEqual(@as(i32, 384), f.raw);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), f.toDouble(), 0.004);
}

test "wl.Fixed: known encoding - 1.0 = 256" {
    const f = wl.Fixed.fromDouble(1.0);
    try std.testing.expectEqual(@as(i32, 256), f.raw);
}

test "wl.Fixed: negative value" {
    const f = wl.Fixed.fromDouble(-2.5);
    // -2.5 * 256 = -640
    try std.testing.expectEqual(@as(i32, -640), f.raw);
    try std.testing.expectApproxEqAbs(@as(f64, -2.5), f.toDouble(), 0.004);
}
