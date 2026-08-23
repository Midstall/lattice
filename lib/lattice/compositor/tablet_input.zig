//! Server-side zwp_tablet_manager_v2 global + tablet-seat advertisement.
//!
//! Task 2 scope (globals + object lifecycle + advertisement):
//! - Register zwp_tablet_manager_v2 global.
//! - bindManager: create a ZwpTabletManagerV2 resource + wire implementation.
//! - onGetTabletSeat: create ZwpTabletSeatV2; advertise ONE virtual tablet +
//!   ONE virtual tool to the requesting client.
//! - Destroy handlers: bookkeeping only (NEVER call resource.destroy() from
//!   a ResourceDestroyFn - Object.destroy() has no re-entry guard).
//! - Release request handlers call resource.destroy() as expected.
//!
//! Input routing (proximity-in, motion, pressure, frame) is Task 3 - IMPLEMENTED.

const std = @import("std");
const wl = @import("wayland");
const tv2 = @import("tablet_v2");

const Object = wl.Object;
const Client = wl.server_client.Client;

// Forward reference: opaque to break circular import at type level.
const CompositorOpaque = opaque {};

// HostedSurfaceId forward ref (used in routing fns).
const HostedSurfaceId = @import("hosted.zig").HostedSurfaceId;

// ---------------------------------------------------------------------------
// Per-client tablet resource tracking
// ---------------------------------------------------------------------------

/// All three tablet-protocol objects created for a single client's
/// get_tablet_seat call: the seat resource, the advertised tablet resource,
/// and the advertised tool resource.  Matched by the wl_seat client pointer.
pub const TabletClient = struct {
    /// The wl_client that owns these resources.
    wl_client: *Client,
    /// The zwp_tablet_seat_v2 resource for this client.
    seat_res: ?*Object,
    /// The zwp_tablet_v2 resource advertised to this client.
    tablet_res: ?*Object,
    /// The zwp_tablet_tool_v2 resource advertised to this client.
    tool_res: ?*Object,
    /// Proximity state machine: true when tool is currently in proximity on this client.
    prox_in: bool = false,
};

// ---------------------------------------------------------------------------
// TabletCtx: lives inline on Compositor (stable pointer)
// ---------------------------------------------------------------------------

pub const TabletCtx = struct {
    /// Per-interface server-side Implementation structs. Kept inline so
    /// setImplementation receives stable pointers.
    manager_impl: tv2.ZwpTabletManagerV2.Implementation,
    seat_impl: tv2.ZwpTabletSeatV2.Implementation,
    tablet_impl: tv2.ZwpTabletV2.Implementation,
    tool_impl: tv2.ZwpTabletToolV2.Implementation,

    /// Back-pointer to the owning Compositor. Typed as opaque to break the
    /// circular import at type level; cast back via getCompositor().
    compositor: *CompositorOpaque = undefined,

    /// Per-client tracking. One entry per get_tablet_seat call.
    clients: std.ArrayListUnmanaged(TabletClient) = .empty,
};

pub fn makeTabletCtx() TabletCtx {
    return .{
        .manager_impl = .{
            .get_tablet_seat = onGetTabletSeat,
            .destroy = onManagerDestroy,
        },
        .seat_impl = .{
            .destroy = onSeatDestroy,
        },
        .tablet_impl = .{
            .destroy = onTabletDestroy,
        },
        .tool_impl = .{
            .set_cursor = null,
            .destroy = onToolDestroy,
        },
    };
}

/// Register zwp_tablet_manager_v2 on the display.
pub fn registerTabletGlobals(display: *wl.Display, ctx: *TabletCtx) !void {
    _ = try display.globalCreate(
        &tv2.ZwpTabletManagerV2.interface,
        tv2.ZwpTabletManagerV2.version,
        bindManager,
        ctx,
    );
}

/// Deinit the tablet context (free the clients list). Call after display.destroy().
pub fn deinitTabletCtx(ctx: *TabletCtx, gpa: std.mem.Allocator) void {
    ctx.clients.deinit(gpa);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn getCtx(client_data: ?*anyopaque) *TabletCtx {
    return @ptrCast(@alignCast(client_data.?));
}

fn getCompositor(ctx: *TabletCtx) *@import("../compositor.zig").Compositor {
    return @ptrCast(@alignCast(ctx.compositor));
}

/// Find the TabletClient entry for a given wl.Object resource (by .client pointer).
fn findByClient(ctx: *TabletCtx, wl_client: *Client) ?*TabletClient {
    for (ctx.clients.items) |*tc| {
        if (tc.wl_client == wl_client) return tc;
    }
    return null;
}

// ---------------------------------------------------------------------------
// zwp_tablet_manager_v2 bind + handlers
// ---------------------------------------------------------------------------

fn bindManager(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx: *TabletCtx = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &tv2.ZwpTabletManagerV2.interface, version, id) catch return;
    tv2.ZwpTabletManagerV2.setImplementation(resource, &ctx.manager_impl, ctx, null);
}

/// destroy request on the manager: forward to Object.destroy (resource request handler).
fn onManagerDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

/// get_tablet_seat request: create a ZwpTabletSeatV2 resource, advertise ONE
/// virtual tablet and ONE virtual tool to the requesting client.
fn onGetTabletSeat(client_data: ?*anyopaque, resource: *Object, tablet_seat_id: u32, seat_: *wl.Object) void {
    _ = seat_;
    const ctx: *TabletCtx = getCtx(client_data);
    const comp = getCompositor(ctx);

    // Create the tablet seat resource.
    const seat_res = Object.create(
        resource.client,
        &tv2.ZwpTabletSeatV2.interface,
        resource.version,
        tablet_seat_id,
    ) catch {
        std.log.err("tablet: failed to create ZwpTabletSeatV2 resource", .{});
        return;
    };
    tv2.ZwpTabletSeatV2.setImplementation(seat_res, &ctx.seat_impl, ctx, onSeatResourceDestroyed);

    // Allocate a new object id for the virtual tablet (server-side id range).
    const tablet_id = resource.client.allocServerId();
    const tablet_res = Object.create(
        resource.client,
        &tv2.ZwpTabletV2.interface,
        resource.version,
        tablet_id,
    ) catch {
        std.log.err("tablet: failed to create ZwpTabletV2 resource", .{});
        return;
    };
    tv2.ZwpTabletV2.setImplementation(tablet_res, &ctx.tablet_impl, ctx, onTabletResourceDestroyed);

    // Advertise the tablet to the client.
    tv2.ZwpTabletSeatV2.sendTabletAdded(seat_res, tablet_id);
    tv2.ZwpTabletV2.sendName(tablet_res, "lattice-virtual-tablet");
    tv2.ZwpTabletV2.sendId(tablet_res, 0, 0); // dummy vendor/product
    tv2.ZwpTabletV2.sendPath(tablet_res, "");
    tv2.ZwpTabletV2.sendDone(tablet_res);

    // Allocate a new object id for the virtual tool (server-side id range).
    const tool_id = resource.client.allocServerId();
    const tool_res = Object.create(
        resource.client,
        &tv2.ZwpTabletToolV2.interface,
        resource.version,
        tool_id,
    ) catch {
        std.log.err("tablet: failed to create ZwpTabletToolV2 resource", .{});
        return;
    };
    tv2.ZwpTabletToolV2.setImplementation(tool_res, &ctx.tool_impl, ctx, onToolResourceDestroyed);

    // Advertise the tool to the client.
    tv2.ZwpTabletSeatV2.sendToolAdded(seat_res, tool_id);
    tv2.ZwpTabletToolV2.sendType(tool_res, @intFromEnum(tv2.ZwpTabletToolV2.Type.pen));
    tv2.ZwpTabletToolV2.sendCapability(tool_res, @intFromEnum(tv2.ZwpTabletToolV2.Capability.pressure));
    tv2.ZwpTabletToolV2.sendDone(tool_res);

    // Track the resources.
    ctx.clients.append(comp.gpa, .{
        .wl_client = resource.client,
        .seat_res = seat_res,
        .tablet_res = tablet_res,
        .tool_res = tool_res,
    }) catch |err| {
        std.log.err("tablet: failed to track TabletClient: {}", .{err});
    };

    std.log.info("tablet: seat advertised to client (seat={d} tablet={d} tool={d})", .{
        tablet_seat_id,
        tablet_id,
        tool_id,
    });
}

// ---------------------------------------------------------------------------
// Request destroy handlers (called on the protocol destroy REQUEST from client)
// These are the correct callers of resource.destroy().
// ---------------------------------------------------------------------------

fn onSeatDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

fn onTabletDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

fn onToolDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

// ---------------------------------------------------------------------------
// ResourceDestroyFns (fired by the wayland library when Object.destroy runs)
// BOOKKEEPING ONLY - must NOT call resource.destroy() here.
// Object.destroy() has no re-entry guard; self-destroy = infinite recursion.
// ---------------------------------------------------------------------------

fn onSeatResourceDestroyed(resource: *Object) void {
    const ctx: *TabletCtx = @ptrCast(@alignCast(resource.user_data orelse return));
    for (ctx.clients.items, 0..) |*tc, i| {
        if (tc.seat_res == resource) {
            tc.seat_res = null;
            // If all three resources are gone, remove the entry.
            if (tc.seat_res == null and tc.tablet_res == null and tc.tool_res == null) {
                _ = ctx.clients.orderedRemove(i);
            }
            return;
        }
    }
}

fn onTabletResourceDestroyed(resource: *Object) void {
    const ctx: *TabletCtx = @ptrCast(@alignCast(resource.user_data orelse return));
    for (ctx.clients.items, 0..) |*tc, i| {
        if (tc.tablet_res == resource) {
            tc.tablet_res = null;
            if (tc.seat_res == null and tc.tablet_res == null and tc.tool_res == null) {
                _ = ctx.clients.orderedRemove(i);
            }
            return;
        }
    }
}

fn onToolResourceDestroyed(resource: *Object) void {
    const ctx: *TabletCtx = @ptrCast(@alignCast(resource.user_data orelse return));
    for (ctx.clients.items, 0..) |*tc, i| {
        if (tc.tool_res == resource) {
            tc.tool_res = null;
            if (tc.seat_res == null and tc.tablet_res == null and tc.tool_res == null) {
                _ = ctx.clients.orderedRemove(i);
            }
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Pure helper: convert normalised [0,1] pressure to u32 0..65535.
// Clamps out-of-range values rather than panicking.
// ---------------------------------------------------------------------------

pub fn pressureToU16(p: f64) u32 {
    const clamped = if (p < 0.0) 0.0 else if (p > 1.0) 1.0 else p;
    return @intFromFloat(@round(clamped * 65535.0));
}

// ---------------------------------------------------------------------------
// Internal routing helper: find the TabletClient for a surface's owning client.
// Mirrors findClientSeatForSurface in seat.zig.
// ---------------------------------------------------------------------------

fn findTabletClientForSurface(
    ctx: *TabletCtx,
    comp: *@import("../compositor.zig").Compositor,
    surface_id: HostedSurfaceId,
) ?*TabletClient {
    const entry = comp.findSurfaceById(surface_id) orelse return null;
    const surface_client = entry.wl_surface_res.client;
    return findByClient(ctx, surface_client);
}

// ---------------------------------------------------------------------------
// Input routing (Task 3): proximity, axis, tip.
// Called from Compositor.tabletProximity / tabletAxis / tabletTip.
// ---------------------------------------------------------------------------

/// Route a tablet proximity event to the client owning `surface_id`.
/// Sends sendProximityIn (with the tablet resource) when entering proximity,
/// or sendProximityOut when leaving.
pub fn routeTabletProximity(
    ctx: *TabletCtx,
    comp: *@import("../compositor.zig").Compositor,
    surface_id: HostedSurfaceId,
    in_prox: bool,
) void {
    const tc = findTabletClientForSurface(ctx, comp, surface_id) orelse return;
    const tool = tc.tool_res orelse return;
    const tablet = tc.tablet_res orelse return;

    if (in_prox and !tc.prox_in) {
        const entry = comp.findSurfaceById(surface_id) orelse return;
        const serial = comp.display.nextSerial();
        tv2.ZwpTabletToolV2.sendProximityIn(tool, serial, tablet, entry.wl_surface_res);
        tc.prox_in = true;
    } else if (!in_prox and tc.prox_in) {
        tv2.ZwpTabletToolV2.sendProximityOut(tool);
        tc.prox_in = false;
    }
}

/// Route tablet axis (motion + pressure) to the client owning `surface_id`.
/// Sends motion + pressure + frame. No-op when tool is not in proximity.
/// Auto-enters proximity on first axis while not yet in-prox (implicit proximity).
pub fn routeTabletAxis(
    ctx: *TabletCtx,
    comp: *@import("../compositor.zig").Compositor,
    surface_id: HostedSurfaceId,
    x: f64,
    y: f64,
    pressure: f64,
) void {
    const tc = findTabletClientForSurface(ctx, comp, surface_id) orelse return;
    const tool = tc.tool_res orelse return;

    // Auto-enter proximity if not yet in-prox (tablet may send axis without
    // an explicit proximity_in event from the input layer). tablet_res is only
    // needed for the proximity_in send, so bind it inside this branch.
    if (!tc.prox_in) {
        const tablet = tc.tablet_res orelse return;
        const entry = comp.findSurfaceById(surface_id) orelse return;
        const serial = comp.display.nextSerial();
        tv2.ZwpTabletToolV2.sendProximityIn(tool, serial, tablet, entry.wl_surface_res);
        tc.prox_in = true;
    }

    const time = comp.seat_ctx.time_counter +% 1;
    comp.seat_ctx.time_counter = time;

    tv2.ZwpTabletToolV2.sendMotion(tool, wl.Fixed.fromDouble(x), wl.Fixed.fromDouble(y));
    tv2.ZwpTabletToolV2.sendPressure(tool, pressureToU16(pressure));
    tv2.ZwpTabletToolV2.sendFrame(tool, time);
}

/// Route a tablet tip (down/up) event to the client owning `surface_id`.
/// Sends sendDown (with serial) or sendUp, then sendFrame. No-op when not in-prox.
pub fn routeTabletTip(
    ctx: *TabletCtx,
    comp: *@import("../compositor.zig").Compositor,
    surface_id: HostedSurfaceId,
    down: bool,
) void {
    const tc = findTabletClientForSurface(ctx, comp, surface_id) orelse return;
    const tool = tc.tool_res orelse return;
    if (!tc.prox_in) return;

    const time = comp.seat_ctx.time_counter +% 1;
    comp.seat_ctx.time_counter = time;

    if (down) {
        const serial = comp.display.nextSerial();
        tv2.ZwpTabletToolV2.sendDown(tool, serial);
    } else {
        tv2.ZwpTabletToolV2.sendUp(tool);
    }
    tv2.ZwpTabletToolV2.sendFrame(tool, time);
}

/// Called from routeFocus (seat.zig) when focus leaves a surface.
/// Sends proximity_out to that surface's TabletClient if the tool was in proximity.
pub fn clearProximityOnFocusLeave(
    ctx: *TabletCtx,
    comp: *@import("../compositor.zig").Compositor,
    surface_id: HostedSurfaceId,
) void {
    const tc = findTabletClientForSurface(ctx, comp, surface_id) orelse return;
    if (!tc.prox_in) return;
    const tool = tc.tool_res orelse return;
    tv2.ZwpTabletToolV2.sendProximityOut(tool);
    tc.prox_in = false;
}

// ---------------------------------------------------------------------------
// Unit tests (pure logic, no live wayland client needed)
// ---------------------------------------------------------------------------

test "pressureToU16: boundary and midpoint values" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0), pressureToU16(0.0));
    try testing.expectEqual(@as(u32, 65535), pressureToU16(1.0));
    // 0.5 * 65535 = 32767.5 -> rounds to 32768
    try testing.expectEqual(@as(u32, 32768), pressureToU16(0.5));
    // Clamp below 0
    try testing.expectEqual(@as(u32, 0), pressureToU16(-0.5));
    // Clamp above 1
    try testing.expectEqual(@as(u32, 65535), pressureToU16(2.0));
    // 0.25 * 65535 = 16383.75 -> rounds to 16384
    try testing.expectEqual(@as(u32, 16384), pressureToU16(0.25));
}

test "makeTabletCtx: builds with non-null handler fields" {
    const ctx = makeTabletCtx();
    try std.testing.expect(ctx.manager_impl.get_tablet_seat != null);
    try std.testing.expect(ctx.manager_impl.destroy != null);
    try std.testing.expect(ctx.seat_impl.destroy != null);
    try std.testing.expect(ctx.tablet_impl.destroy != null);
    try std.testing.expect(ctx.tool_impl.destroy != null);
}

test "TabletClient list: append + findByClient + clear" {
    var ctx = makeTabletCtx();
    defer ctx.clients.deinit(std.testing.allocator);

    const client_a = sentinelClient(0x1000);
    const client_b = sentinelClient(0x2000);

    try ctx.clients.append(std.testing.allocator, .{
        .wl_client = client_a,
        .seat_res = null,
        .tablet_res = null,
        .tool_res = null,
    });
    try ctx.clients.append(std.testing.allocator, .{
        .wl_client = client_b,
        .seat_res = null,
        .tablet_res = null,
        .tool_res = null,
    });

    try std.testing.expectEqual(@as(usize, 2), ctx.clients.items.len);

    const found_a = findByClient(&ctx, client_a);
    const found_b = findByClient(&ctx, client_b);
    try std.testing.expect(found_a != null);
    try std.testing.expect(found_b != null);
    try std.testing.expect(found_a.?.wl_client == client_a);
    try std.testing.expect(found_b.?.wl_client == client_b);

    // Unknown client returns null.
    try std.testing.expect(findByClient(&ctx, sentinelClient(0x3000)) == null);
}

test "TabletClient list: orderedRemove by seat_res clears entry" {
    var ctx = makeTabletCtx();
    defer ctx.clients.deinit(std.testing.allocator);

    const client_a = sentinelClient(0x4000);

    try ctx.clients.append(std.testing.allocator, .{
        .wl_client = client_a,
        .seat_res = null,
        .tablet_res = null,
        .tool_res = null,
    });
    try std.testing.expectEqual(@as(usize, 1), ctx.clients.items.len);

    _ = ctx.clients.orderedRemove(0);
    try std.testing.expectEqual(@as(usize, 0), ctx.clients.items.len);

    try std.testing.expect(findByClient(&ctx, client_a) == null);
}

test "TabletClient: two clients with same-structured entries are distinct" {
    var ctx = makeTabletCtx();
    defer ctx.clients.deinit(std.testing.allocator);

    const client_a = sentinelClient(0x5000);
    const client_b = sentinelClient(0x6000);

    try ctx.clients.append(std.testing.allocator, .{
        .wl_client = client_a,
        .seat_res = null,
        .tablet_res = null,
        .tool_res = null,
    });
    try ctx.clients.append(std.testing.allocator, .{
        .wl_client = client_b,
        .seat_res = null,
        .tablet_res = null,
        .tool_res = null,
    });

    // Remove client_a; client_b must still be findable.
    _ = ctx.clients.orderedRemove(0);
    try std.testing.expectEqual(@as(usize, 1), ctx.clients.items.len);
    try std.testing.expect(findByClient(&ctx, client_a) == null);
    try std.testing.expect(findByClient(&ctx, client_b) != null);
}

fn sentinelClient(addr: usize) *Client {
    const alignment = @alignOf(Client);
    return @ptrFromInt(std.mem.alignForward(usize, addr, alignment));
}
