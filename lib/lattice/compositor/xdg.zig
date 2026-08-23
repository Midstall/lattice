//! Server-side xdg-shell handler: xdg_wm_base, xdg_surface, xdg_toplevel.
//!
//! Task 6 scope:
//! - Register xdg_wm_base global (called from Compositor.init via registerXdg).
//! - get_xdg_surface: create XdgSurface Object, link to the HostedEntry of the wl_surface.
//! - get_toplevel: create XdgToplevel Object, assign role=toplevel, send initial configure pair.
//! - ack_configure: clear pending serial if it matches.
//! - set_title / set_app_id: copy wire string into stable fixed buffers on HostedEntry.
//! - xdg_surface.destroy / xdg_toplevel.destroy: clear role + xdg resources on HostedEntry.
//! - mappable() pure predicate: role==toplevel and configure acked and has_buffer.
//! - AckTracker: pure struct for configure/ack serial bookkeeping (unit-tested).

const std = @import("std");
const wl = @import("wayland");
const xdg = @import("xdg_shell");

const Object = wl.Object;
const Client = wl.server_client.Client;

// Break the import cycle: Compositor is the parent, we reach it via an opaque back-pointer.
const CompositorOpaque = opaque {};

// ---------------------------------------------------------------------------
// XdgCtx: lives inside Compositor (stable pointer), shared across all xdg objects.
// ---------------------------------------------------------------------------

pub const XdgCtx = struct {
    wm_base_impl: xdg.XdgWmBase.Implementation,
    surface_impl: xdg.XdgSurface.Implementation,
    toplevel_impl: xdg.XdgToplevel.Implementation,
    positioner_impl: xdg.XdgPositioner.Implementation,
    /// Back-pointer to owning Compositor (set by Compositor.init after allocation).
    compositor: *CompositorOpaque = undefined,
};

pub fn makeXdgCtx() XdgCtx {
    return .{
        .wm_base_impl = .{
            .destroy = onWmBaseDestroy,
            .create_positioner = onCreatePositioner,
            .get_xdg_surface = onGetXdgSurface,
            .pong = onPong,
        },
        .surface_impl = .{
            .destroy = onXdgSurfaceDestroy,
            .get_toplevel = onGetToplevel,
            .get_popup = null,
            .set_window_geometry = null,
            .ack_configure = onAckConfigure,
        },
        .toplevel_impl = .{
            .destroy = onToplevelDestroy,
            .set_parent = null,
            .set_title = onSetTitle,
            .set_app_id = onSetAppId,
            .show_window_menu = null,
            .move = null,
            .resize = null,
            .set_max_size = null,
            .set_min_size = null,
            .set_maximized = null,
            .unset_maximized = null,
            .set_fullscreen = null,
            .unset_fullscreen = null,
            .set_minimized = null,
        },
        .positioner_impl = .{},
    };
}

/// Register the xdg_wm_base global on the display.
/// Called from globals.registerGlobals (or Compositor.init).
pub fn registerXdgGlobal(
    display: *wl.Display,
    ctx: *XdgCtx,
) !void {
    _ = try display.globalCreate(
        &xdg.XdgWmBase.interface,
        xdg.XdgWmBase.version,
        bindWmBase,
        ctx,
    );
}

// ---------------------------------------------------------------------------
// Internal helper: cast back to Compositor.
// ---------------------------------------------------------------------------

fn getCompositor(ctx: *XdgCtx) *@import("../compositor.zig").Compositor {
    return @ptrCast(@alignCast(ctx.compositor));
}

// ---------------------------------------------------------------------------
// xdg_wm_base bind
// ---------------------------------------------------------------------------

fn bindWmBase(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx: *XdgCtx = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &xdg.XdgWmBase.interface, version, id) catch return;
    xdg.XdgWmBase.setImplementation(resource, &ctx.wm_base_impl, ctx, null);
}

fn onWmBaseDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

fn onCreatePositioner(client_data: ?*anyopaque, resource: *Object, id_: u32) void {
    const ctx: *XdgCtx = @ptrCast(@alignCast(client_data.?));
    const positioner = Object.create(resource.client, &xdg.XdgPositioner.interface, resource.version, id_) catch return;
    xdg.XdgPositioner.setImplementation(positioner, &ctx.positioner_impl, ctx, null);
}

fn onGetXdgSurface(client_data: ?*anyopaque, resource: *Object, id_: u32, surface_: *Object) void {
    const ctx: *XdgCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);

    // Create the XdgSurface Object.
    const xdg_surface_res = Object.create(resource.client, &xdg.XdgSurface.interface, resource.version, id_) catch return;
    xdg.XdgSurface.setImplementation(xdg_surface_res, &ctx.surface_impl, ctx, null);

    // Link to the HostedEntry for the associated wl_surface.
    const entry = comp.findSurface(surface_.client, surface_.id) orelse return;
    entry.xdg_surface_res = xdg_surface_res;
    entry.wl_surface_object_id = surface_.id;
}

fn onPong(client_data: ?*anyopaque, resource: *Object, serial_: u32) void {
    _ = client_data;
    _ = resource;
    _ = serial_;
    // no-op: we do not track ping liveness in this implementation.
}

// ---------------------------------------------------------------------------
// xdg_surface handlers
// ---------------------------------------------------------------------------

fn onXdgSurfaceDestroy(client_data: ?*anyopaque, resource: *Object) void {
    const ctx: *XdgCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);

    // Clear xdg_surface reference from the HostedEntry that links to this resource.
    for (comp.surface_entries.items) |*entry| {
        if (entry.xdg_surface_res == resource) {
            // FIX I1: if mapped, mark as unmapped and destroy texture.
            if (entry.surface.mapped) {
                entry.surface.mapped = false;
                entry.needs_unmapped_event = true;
                if (entry.surface.texture) |t| {
                    comp.device.destroyResource(t);
                    entry.surface.texture = null;
                }
                // FIX part of I4: clear focus.
                if (comp.seat_ctx.focus_tracker.focused) |fid| {
                    if (fid == entry.surface.id) {
                        comp.seat_ctx.focus_tracker.focused = null;
                    }
                }
            }
            entry.xdg_surface_res = null;
            entry.pending_configure_serial = null;
            entry.configure_acked = false;
            break;
        }
    }
    resource.destroy();
}

fn onGetToplevel(client_data: ?*anyopaque, resource: *Object, id_: u32) void {
    const ctx: *XdgCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);

    // Create XdgToplevel Object.
    const toplevel_res = Object.create(resource.client, &xdg.XdgToplevel.interface, resource.version, id_) catch return;
    xdg.XdgToplevel.setImplementation(toplevel_res, &ctx.toplevel_impl, ctx, null);

    // Find the HostedEntry that owns this xdg_surface.
    for (comp.surface_entries.items) |*entry| {
        if (entry.xdg_surface_res == resource) {
            entry.xdg_toplevel_res = toplevel_res;
            entry.state.role = .toplevel;
            entry.surface.role = .toplevel;

            // Send initial configure pair: toplevel.configure(0,0,[]) then xdg_surface.configure(serial).
            xdg.XdgToplevel.sendConfigure(toplevel_res, 0, 0, &.{});
            const serial = comp.display.nextSerial();
            xdg.XdgSurface.sendConfigure(resource, serial);
            entry.pending_configure_serial = serial;
            break;
        }
    }
}

fn onAckConfigure(client_data: ?*anyopaque, resource: *Object, serial_: u32) void {
    const ctx: *XdgCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);

    for (comp.surface_entries.items) |*entry| {
        if (entry.xdg_surface_res == resource) {
            if (entry.pending_configure_serial) |pending| {
                if (pending == serial_) {
                    entry.pending_configure_serial = null;
                    entry.configure_acked = true;
                }
                // stale serial: no-op (spec allows acking old serials; just ignore)
            }
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// xdg_toplevel handlers
// ---------------------------------------------------------------------------

fn onToplevelDestroy(client_data: ?*anyopaque, resource: *Object) void {
    const ctx: *XdgCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);

    for (comp.surface_entries.items) |*entry| {
        if (entry.xdg_toplevel_res == resource) {
            entry.xdg_toplevel_res = null;
            entry.state.role = .none;
            entry.surface.role = .none;
            // FIX I1: if mapped, signal unmapped and destroy texture.
            if (entry.surface.mapped) {
                entry.surface.mapped = false;
                entry.needs_unmapped_event = true;
                if (entry.surface.texture) |t| {
                    comp.device.destroyResource(t);
                    entry.surface.texture = null;
                }
                // FIX part of I4: clear focus if this surface was focused.
                if (comp.seat_ctx.focus_tracker.focused) |fid| {
                    if (fid == entry.surface.id) {
                        comp.seat_ctx.focus_tracker.focused = null;
                    }
                }
            } else {
                entry.surface.mapped = false;
            }
            entry.configure_acked = false;
            entry.pending_configure_serial = null;
            break;
        }
    }
    resource.destroy();
}

fn onSetTitle(client_data: ?*anyopaque, resource: *Object, title_: []const u8) void {
    const ctx: *XdgCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);

    for (comp.surface_entries.items) |*entry| {
        if (entry.xdg_toplevel_res == resource) {
            const copy_len = @min(title_.len, entry.title_buf.len);
            @memcpy(entry.title_buf[0..copy_len], title_[0..copy_len]);
            entry.title_len = copy_len;
            entry.surface.title = entry.title_buf[0..copy_len];
            break;
        }
    }
}

fn onSetAppId(client_data: ?*anyopaque, resource: *Object, app_id_: []const u8) void {
    const ctx: *XdgCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);

    for (comp.surface_entries.items) |*entry| {
        if (entry.xdg_toplevel_res == resource) {
            const copy_len = @min(app_id_.len, entry.app_id_buf.len);
            @memcpy(entry.app_id_buf[0..copy_len], app_id_[0..copy_len]);
            entry.app_id_len = copy_len;
            entry.surface.app_id = entry.app_id_buf[0..copy_len];
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// mappable() pure predicate
// ---------------------------------------------------------------------------

/// Returns true when a surface is ready to be displayed.
/// Pure: no side effects, safe to call anywhere.
pub fn mappable(role: @import("surface_state.zig").Role, acked: bool, has_buffer: bool) bool {
    return role == .toplevel and acked and has_buffer;
}

// ---------------------------------------------------------------------------
// AckTracker: pure configure/ack serial bookkeeping (unit-tested).
// ---------------------------------------------------------------------------

pub const AckTracker = struct {
    pending_serial: ?u32 = null,

    /// Record that a configure with this serial was sent to the client.
    pub fn sendConfigure(self: *AckTracker, serial: u32) void {
        self.pending_serial = serial;
    }

    /// Returns true and clears the pending serial if the client acks correctly.
    /// Returns false on stale or double-ack.
    pub fn ack(self: *AckTracker, serial: u32) bool {
        if (self.pending_serial) |pending| {
            if (pending == serial) {
                self.pending_serial = null;
                return true;
            }
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "AckTracker: no pending serial -> ack returns false" {
    var tracker = AckTracker{};
    try testing.expect(!tracker.ack(1));
}

test "AckTracker: sendConfigure then ack matching serial returns true and clears" {
    var tracker = AckTracker{};
    tracker.sendConfigure(42);
    try testing.expect(tracker.ack(42));
    try testing.expect(tracker.pending_serial == null);
}

test "AckTracker: stale serial returns false" {
    var tracker = AckTracker{};
    tracker.sendConfigure(42);
    try testing.expect(!tracker.ack(99));
    // pending serial remains
    try testing.expectEqual(@as(?u32, 42), tracker.pending_serial);
}

test "AckTracker: double-ack after already acked returns false" {
    var tracker = AckTracker{};
    tracker.sendConfigure(10);
    try testing.expect(tracker.ack(10));
    // second ack of same serial: pending is already null
    try testing.expect(!tracker.ack(10));
}

test "mappable: all conditions met returns true" {
    try testing.expect(mappable(.toplevel, true, true));
}

test "mappable: wrong role returns false" {
    try testing.expect(!mappable(.none, true, true));
    try testing.expect(!mappable(.popup, true, true));
}

test "mappable: not acked returns false" {
    try testing.expect(!mappable(.toplevel, false, true));
}

test "mappable: no buffer returns false" {
    try testing.expect(!mappable(.toplevel, true, false));
}
