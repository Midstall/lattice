//! Server-side pointer-constraints + relative-pointer globals.
//!
//! Task 5 scope:
//! - Register zwp_relative_pointer_manager_v1 + zwp_pointer_constraints_v1 globals.
//! - Object lifecycle: get_relative_pointer (creates ZwpRelativePointerV1, stores on ClientSeat),
//!   lock_pointer / confine_pointer (creates locked/confined resource, appends Constraint;
//!   posts already_constrained error if surface already has a live constraint).
//! - onConstraintDestroy: marks dead + removes + destroys the resource.
//! - Per-surface constraint tracking via ConstraintsCtx.list.
//!
//! Enforcement and routing (send locked/unlocked, relative-motion) are Task 6.

const std = @import("std");
const wl = @import("wayland");
const rp = @import("relative_pointer");
const pc = @import("pointer_constraints");

const Object = wl.Object;
const Client = wl.server_client.Client;

const backend = @import("../backend.zig");
const seat_mod = @import("seat.zig");

// Forward reference: opaque so this file does not create a circular import
// at the type level. Resolved via getCompositor() at runtime.
const CompositorOpaque = opaque {};

// GlobalsCtx forward reference (opaque to break cycle).
const GlobalsCtx = @import("globals.zig").GlobalsCtx;

// ---------------------------------------------------------------------------
// Public constraint types
// ---------------------------------------------------------------------------

pub const ConstraintKind = enum { lock, confine };

pub const Lifetime = enum { oneshot, persistent };

/// A single pointer constraint request from a hosted client.
/// `obj_res` is optional so that the pure-testable tests can construct Constraint
/// values without a live wayland Object. In the real request handlers obj_res is
/// always non-null after creation; it is only null in the test helper below.
pub const Constraint = struct {
    kind: ConstraintKind,
    /// compositor-global HostedSurfaceId value (NOT the raw per-client wl_surface object id).
    surface: u32,
    region: ?backend.Region,
    lifetime: Lifetime,
    active: bool,
    dead: bool,
    /// The wp_locked_pointer_v1 or wp_confined_pointer_v1 resource. Optional so
    /// tests can build Constraint values without a live wayland Object. Real
    /// handlers always fill this after Object.create.
    obj_res: ?*Object = null,
    /// Cursor-position hint set via zwp_locked_pointer_v1.set_cursor_position_hint.
    /// Surface-local coordinates. Only meaningful for kind==lock.
    /// One-shot: reset to false when applied on lock deactivation.
    hint_x: f64 = 0,
    hint_y: f64 = 0,
    has_hint: bool = false,
};

// ---------------------------------------------------------------------------
// Task 6 pure helpers
// ---------------------------------------------------------------------------

/// Clamp (x, y) to the given region box, or to the surface bounds when region is null.
pub fn clampToRegion(x: f64, y: f64, region: ?backend.Region, surf_w: u32, surf_h: u32) struct { x: f64, y: f64 } {
    var lo_x: f64 = 0;
    var lo_y: f64 = 0;
    var hi_x: f64 = @floatFromInt(surf_w);
    var hi_y: f64 = @floatFromInt(surf_h);
    if (region) |r| {
        lo_x = @floatFromInt(r.x);
        lo_y = @floatFromInt(r.y);
        hi_x = @floatFromInt(r.x + @as(i32, @intCast(r.width)));
        hi_y = @floatFromInt(r.y + @as(i32, @intCast(r.height)));
    }
    return .{ .x = std.math.clamp(x, lo_x, hi_x), .y = std.math.clamp(y, lo_y, hi_y) };
}

/// Returns true when `c` is an active lock constraint (suppresses absolute wl_pointer.motion).
pub fn suppressesAbsolute(c: Constraint) bool {
    return c.active and c.kind == .lock;
}

/// Returns the warp target for a lock constraint that has a pending hint.
/// Returns non-null only when kind==lock AND has_hint==true.
/// Confine constraints have no cursor-position hint semantics.
///
/// Pure helper: testable without a live Wayland client.
pub fn warpTarget(c: Constraint) ?struct { x: f64, y: f64 } {
    if (c.kind != .lock) return null;
    if (!c.has_hint) return null;
    return .{ .x = c.hint_x, .y = c.hint_y };
}

/// Find the active (non-dead) constraint for `surface`, if any.
pub fn activeFor(list: []Constraint, surface: u32) ?*Constraint {
    for (list) |*c| {
        if (!c.dead and c.active and c.surface == surface) return c;
    }
    return null;
}

/// True if `surface` already has a live (not-dead) constraint in `list`.
pub fn surfaceHasConstraint(list: []const Constraint, surface: u32) bool {
    for (list) |c| {
        if (!c.dead and c.surface == surface) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// ConstraintsCtx: lives inline on the Compositor (stable pointer).
// ---------------------------------------------------------------------------

pub const ConstraintsCtx = struct {
    /// Implementations registered per bind call (stable pointers for setImplementation).
    rel_ptr_mgr_impl: rp.ZwpRelativePointerManagerV1.Implementation,
    rel_ptr_impl: rp.ZwpRelativePointerV1.Implementation,
    locked_impl: pc.ZwpLockedPointerV1.Implementation,
    confined_impl: pc.ZwpConfinedPointerV1.Implementation,
    constraints_impl: pc.ZwpPointerConstraintsV1.Implementation,

    /// Back-pointer to the owning Compositor (set by Compositor.init).
    /// Typed as opaque to break the circular import at type level.
    compositor: *CompositorOpaque = undefined,

    /// All live constraints (may contain dead entries pending GC).
    list: std.ArrayListUnmanaged(Constraint) = .empty,
};

pub fn makeConstraintsCtx() ConstraintsCtx {
    return .{
        .rel_ptr_mgr_impl = .{
            .destroy = onRelPtrMgrDestroy,
            .get_relative_pointer = onGetRelativePointer,
        },
        .rel_ptr_impl = .{
            .destroy = onRelPtrDestroy,
        },
        .locked_impl = .{
            .destroy = onLockedDestroy,
            .set_cursor_position_hint = onSetCursorPositionHint,
            .set_region = null,
        },
        .confined_impl = .{
            .destroy = onConfinedDestroy,
            .set_region = null,
        },
        .constraints_impl = .{
            .destroy = onConstraintsGlobalDestroy,
            .lock_pointer = onLockPointer,
            .confine_pointer = onConfinePointer,
        },
    };
}

/// Register both globals on the display.
pub fn registerConstraintGlobals(display: *wl.Display, ctx: *ConstraintsCtx) !void {
    _ = try display.globalCreate(
        &rp.ZwpRelativePointerManagerV1.interface,
        rp.ZwpRelativePointerManagerV1.version,
        bindRelativePointerManager,
        ctx,
    );
    _ = try display.globalCreate(
        &pc.ZwpPointerConstraintsV1.interface,
        pc.ZwpPointerConstraintsV1.version,
        bindPointerConstraints,
        ctx,
    );
}

/// Deinit the constraints context (free the list). Call after display.destroy().
pub fn deinitConstraintsCtx(ctx: *ConstraintsCtx, gpa: std.mem.Allocator) void {
    ctx.list.deinit(gpa);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn getCtx(client_data: ?*anyopaque) *ConstraintsCtx {
    return @ptrCast(@alignCast(client_data.?));
}

fn getCompositor(ctx: *ConstraintsCtx) *@import("../compositor.zig").Compositor {
    return @ptrCast(@alignCast(ctx.compositor));
}

// ---------------------------------------------------------------------------
// zwp_relative_pointer_manager_v1 bind + handlers
// ---------------------------------------------------------------------------

fn bindRelativePointerManager(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx: *ConstraintsCtx = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &rp.ZwpRelativePointerManagerV1.interface, version, id) catch return;
    rp.ZwpRelativePointerManagerV1.setImplementation(resource, &ctx.rel_ptr_mgr_impl, ctx, null);
}

fn onRelPtrMgrDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

/// get_relative_pointer: create a ZwpRelativePointerV1 resource, store it on
/// the matching ClientSeat so Task 6 can call sendRelativeMotion on it.
fn onGetRelativePointer(client_data: ?*anyopaque, resource: *Object, id_: u32, pointer_: *Object) void {
    _ = pointer_;
    const ctx: *ConstraintsCtx = getCtx(client_data);
    const comp = getCompositor(ctx);
    const rp_res = Object.create(resource.client, &rp.ZwpRelativePointerV1.interface, resource.version, id_) catch return;
    rp.ZwpRelativePointerV1.setImplementation(rp_res, &ctx.rel_ptr_impl, ctx, onRelPtrResourceDestroyed);

    // Store on the matching ClientSeat (matched by client pointer).
    for (comp.seat_ctx.clients.items) |*cs| {
        if (cs.seat_res.client == resource.client) {
            cs.relative_ptr_res = rp_res;
            return;
        }
    }
}

/// ResourceDestroyFn for relative_pointer resources. Clears the stored
/// relative_ptr_res on the matching ClientSeat.
/// NOTE: must NOT call resource.destroy() here - same re-entry reason as
/// onConstraintResourceDestroyed. The explicit destroy-REQUEST handler
/// (onRelPtrDestroy) is the correct caller of resource.destroy().
fn onRelPtrResourceDestroyed(resource: *Object) void {
    // Recover ConstraintsCtx from user_data to clear ClientSeat reference.
    const ctx: *ConstraintsCtx = @ptrCast(@alignCast(resource.user_data orelse return));
    const comp = getCompositor(ctx);
    for (comp.seat_ctx.clients.items) |*cs| {
        if (cs.relative_ptr_res == resource) {
            cs.relative_ptr_res = null;
            return;
        }
    }
}

fn onRelPtrDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

// ---------------------------------------------------------------------------
// zwp_pointer_constraints_v1 bind + handlers
// ---------------------------------------------------------------------------

fn bindPointerConstraints(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx: *ConstraintsCtx = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &pc.ZwpPointerConstraintsV1.interface, version, id) catch return;
    pc.ZwpPointerConstraintsV1.setImplementation(resource, &ctx.constraints_impl, ctx, null);
}

fn onConstraintsGlobalDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

/// Convert an optional wl_region Object to an optional backend.Region.
/// A null region means "full surface bounds" (Task 6 enforcement maps that to
/// no spatial restriction). A non-null wl_region also returns null (full
/// surface bounds) because the Object API does not expose the wl_region
/// rectangle list; returning {0,0,0,0} would wrongly clamp the cursor to the
/// origin. Task 6 will resolve the real region when the API is available.
fn regionFromWlRegion(region_res: ?*Object) ?backend.Region {
    if (region_res) |_| {
        return null;
    }
    return null;
}

/// Shared implementation for lock_pointer and confine_pointer.
fn createConstraint(
    client_data: ?*anyopaque,
    resource: *Object,
    id_: u32,
    surface_: *Object,
    region_: ?*Object,
    lifetime_: u32,
    kind: ConstraintKind,
    iface: *const wl.Interface,
) void {
    const ctx: *ConstraintsCtx = getCtx(client_data);
    const comp = getCompositor(ctx);
    const surf_entry = comp.findSurface(resource.client, surface_.id) orelse {
        return;
    };
    const surf_id = surf_entry.surface.id.value(); // compositor-global HostedSurfaceId

    // Check for existing live constraint on this surface.
    if (surfaceHasConstraint(ctx.list.items, surf_id)) {
        resource.postError(
            @intFromEnum(pc.ZwpPointerConstraintsV1.Error.already_constrained),
            "surface {d} already has an active constraint",
            .{surf_id},
        );
        return;
    }

    // Decode lifetime.
    const lifetime: Lifetime = switch (lifetime_) {
        @intFromEnum(pc.ZwpPointerConstraintsV1.Lifetime.oneshot) => .oneshot,
        @intFromEnum(pc.ZwpPointerConstraintsV1.Lifetime.persistent) => .persistent,
        else => .oneshot,
    };

    // Create the locked/confined resource.
    const obj_res = Object.create(resource.client, iface, resource.version, id_) catch return;

    // Wire implementation based on kind.
    switch (kind) {
        .lock => pc.ZwpLockedPointerV1.setImplementation(obj_res, &ctx.locked_impl, ctx, onConstraintResourceDestroyed),
        .confine => pc.ZwpConfinedPointerV1.setImplementation(obj_res, &ctx.confined_impl, ctx, onConstraintResourceDestroyed),
    }

    // Append constraint to the list.
    ctx.list.append(comp.gpa, .{
        .kind = kind,
        .surface = surf_id,
        .region = regionFromWlRegion(region_),
        .lifetime = lifetime,
        .active = false,
        .dead = false,
        .obj_res = obj_res,
    }) catch {
        obj_res.destroy();
        return;
    };
}

fn onLockPointer(
    client_data: ?*anyopaque,
    resource: *Object,
    id_: u32,
    surface_: *Object,
    pointer_: *Object,
    region_: ?*Object,
    lifetime_: u32,
) void {
    _ = pointer_;
    createConstraint(client_data, resource, id_, surface_, region_, lifetime_, .lock, &pc.ZwpLockedPointerV1.interface);
}

fn onConfinePointer(
    client_data: ?*anyopaque,
    resource: *Object,
    id_: u32,
    surface_: *Object,
    pointer_: *Object,
    region_: ?*Object,
    lifetime_: u32,
) void {
    _ = pointer_;
    createConstraint(client_data, resource, id_, surface_, region_, lifetime_, .confine, &pc.ZwpConfinedPointerV1.interface);
}

/// ResourceDestroyFn for locked/confined resources. Marks the matching
/// Constraint dead and removes it from the list.
/// NOTE: must NOT call resource.destroy() here - Object.destroy() does not
/// guard re-entry and would recurse infinitely back into this function.
/// The explicit destroy-REQUEST handlers (onLockedDestroy, onConfinedDestroy)
/// are the ones that call resource.destroy(), which then fires this fn once.
fn onConstraintResourceDestroyed(resource: *Object) void {
    // Recover ConstraintsCtx from user_data.
    const ctx: *ConstraintsCtx = @ptrCast(@alignCast(resource.user_data orelse return));
    const items = ctx.list.items;
    for (items, 0..) |*c, i| {
        if (c.obj_res == resource) {
            _ = ctx.list.orderedRemove(i);
            break;
        }
    }
}

/// zwp_locked_pointer_v1.set_cursor_position_hint request handler.
///
/// Finds the Constraint whose obj_res matches the locked_pointer resource and
/// stores the surface-local hint coordinates. The hint is applied (one-shot)
/// when the lock deactivates in routeFocus LEAVE (seat.zig).
///
/// Surface-local assumption: for a single fullscreen/maximized surface (the common
/// case in lattice) the compositor cursor coordinates equal surface-local coords.
/// If per-surface origin offsets are tracked in future, add them when applying the warp.
fn onSetCursorPositionHint(
    client_data: ?*anyopaque,
    resource: *Object,
    surface_x: wl.Fixed,
    surface_y: wl.Fixed,
) void {
    const ctx: *ConstraintsCtx = getCtx(client_data);
    for (ctx.list.items) |*c| {
        if (c.obj_res == resource) {
            c.hint_x = surface_x.toDouble();
            c.hint_y = surface_y.toDouble();
            c.has_hint = true;
            return;
        }
    }
    // No matching constraint found: no-op (resource may be mid-teardown).
}

fn onLockedDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

fn onConfinedDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

// ---------------------------------------------------------------------------
// Unit tests (pure logic, no live wayland client needed)
// ---------------------------------------------------------------------------

test "surfaceHasConstraint detects an existing live constraint" {
    var list = [_]Constraint{
        .{ .kind = .lock, .surface = 5, .region = null, .lifetime = .oneshot, .active = false, .dead = false },
        .{ .kind = .confine, .surface = 7, .region = null, .lifetime = .persistent, .active = false, .dead = true },
    };
    try std.testing.expect(surfaceHasConstraint(&list, 5));
    try std.testing.expect(!surfaceHasConstraint(&list, 7)); // dead
    try std.testing.expect(!surfaceHasConstraint(&list, 9));
}

test "surfaceHasConstraint: empty list returns false" {
    const list: []const Constraint = &.{};
    try std.testing.expect(!surfaceHasConstraint(list, 1));
}

test "lifecycle: second constraint on same surface is rejected" {
    // Simulate the list-append + guard path the request handlers use.
    // No live wayland Object needed: obj_res is optional.
    var list: std.ArrayListUnmanaged(Constraint) = .empty;
    defer list.deinit(std.testing.allocator);

    // First constraint appended (simulate lock_pointer handler on surface 3).
    try list.append(std.testing.allocator, .{
        .kind = .lock,
        .surface = 3,
        .region = null,
        .lifetime = .persistent,
        .active = false,
        .dead = false,
        .obj_res = null,
    });
    try std.testing.expectEqual(@as(usize, 1), list.items.len);

    // Second constraint on same surface: guard should reject it.
    if (!surfaceHasConstraint(list.items, 3)) {
        try list.append(std.testing.allocator, .{
            .kind = .confine,
            .surface = 3,
            .region = null,
            .lifetime = .oneshot,
            .active = false,
            .dead = false,
            .obj_res = null,
        });
    }
    // List must still have only 1 entry.
    try std.testing.expectEqual(@as(usize, 1), list.items.len);

    // Different surface is allowed.
    if (!surfaceHasConstraint(list.items, 7)) {
        try list.append(std.testing.allocator, .{
            .kind = .lock,
            .surface = 7,
            .region = null,
            .lifetime = .oneshot,
            .active = false,
            .dead = false,
            .obj_res = null,
        });
    }
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "regionFromWlRegion: null input yields null output" {
    const r = regionFromWlRegion(null);
    try std.testing.expect(r == null);
}

test "clampToRegion clamps a point to the region box" {
    // null region -> clamp to surface bounds
    const a = clampToRegion(1000, -5, null, 800, 600);
    try std.testing.expectEqual(@as(f64, 800), a.x);
    try std.testing.expectEqual(@as(f64, 0), a.y);
    // explicit region [100,300)x[100,300)
    const r = backend.Region{ .x = 100, .y = 100, .width = 200, .height = 200 };
    const b = clampToRegion(50, 250, r, 800, 600);
    try std.testing.expectEqual(@as(f64, 100), b.x);
    try std.testing.expectEqual(@as(f64, 250), b.y);
}

test "lock suppresses absolute motion; confine does not" {
    try std.testing.expect(suppressesAbsolute(.{ .kind = .lock, .surface = 1, .region = null, .lifetime = .persistent, .active = true, .dead = false }));
    try std.testing.expect(!suppressesAbsolute(.{ .kind = .confine, .surface = 1, .region = null, .lifetime = .persistent, .active = true, .dead = false }));
    // inactive lock does not suppress
    try std.testing.expect(!suppressesAbsolute(.{ .kind = .lock, .surface = 1, .region = null, .lifetime = .persistent, .active = false, .dead = false }));
}

test "focus activation: persistent reactivates; oneshot goes dead" {
    var list: std.ArrayListUnmanaged(Constraint) = .empty;
    defer list.deinit(std.testing.allocator);

    // Persistent constraint on surface 1
    try list.append(std.testing.allocator, .{
        .kind = .lock,
        .surface = 1,
        .region = null,
        .lifetime = .persistent,
        .active = false,
        .dead = false,
        .obj_res = null,
    });
    // Oneshot constraint on surface 2
    try list.append(std.testing.allocator, .{
        .kind = .confine,
        .surface = 2,
        .region = null,
        .lifetime = .oneshot,
        .active = false,
        .dead = false,
        .obj_res = null,
    });

    // Activate surface 1 persistent constraint
    if (activeFor(list.items, 1)) |_| {
        try std.testing.expect(false); // not active yet
    }
    list.items[0].active = true;
    const found1 = activeFor(list.items, 1);
    try std.testing.expect(found1 != null);

    // Deactivate surface 1 persistent: marks active=false, NOT dead
    list.items[0].active = false;
    try std.testing.expect(!list.items[0].dead);
    // Persistent can reactivate
    list.items[0].active = true;
    try std.testing.expect(activeFor(list.items, 1) != null);

    // Activate oneshot on surface 2
    list.items[1].active = true;
    try std.testing.expect(activeFor(list.items, 2) != null);
    // Deactivate oneshot: marks dead
    list.items[1].active = false;
    list.items[1].dead = true;
    // Dead constraint not found by activeFor
    try std.testing.expect(activeFor(list.items, 2) == null);
    // And should not reactivate
    list.items[1].active = true; // simulate spurious reactivation attempt
    // Still dead -> still not returned by activeFor
    try std.testing.expect(activeFor(list.items, 2) == null);
}

test "warpTarget: lock with hint returns target" {
    const c = Constraint{
        .kind = .lock,
        .surface = 1,
        .region = null,
        .lifetime = .persistent,
        .active = true,
        .dead = false,
        .hint_x = 123.5,
        .hint_y = 456.75,
        .has_hint = true,
    };
    const t = warpTarget(c);
    try std.testing.expect(t != null);
    try std.testing.expectApproxEqAbs(@as(f64, 123.5), t.?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 456.75), t.?.y, 0.001);
}

test "warpTarget: lock without hint returns null" {
    const c = Constraint{
        .kind = .lock,
        .surface = 1,
        .region = null,
        .lifetime = .persistent,
        .active = true,
        .dead = false,
        .has_hint = false,
    };
    try std.testing.expect(warpTarget(c) == null);
}

test "warpTarget: confine with hint returns null (confine has no hint semantics)" {
    const c = Constraint{
        .kind = .confine,
        .surface = 2,
        .region = null,
        .lifetime = .oneshot,
        .active = true,
        .dead = false,
        .hint_x = 10,
        .hint_y = 20,
        .has_hint = true,
    };
    try std.testing.expect(warpTarget(c) == null);
}

test "warpTarget: inactive lock with hint returns target (warpTarget is state-agnostic)" {
    // warpTarget only checks kind + has_hint, not active/dead.
    // The call site in routeFocus is responsible for checking active/dead before calling.
    const c = Constraint{
        .kind = .lock,
        .surface = 3,
        .region = null,
        .lifetime = .oneshot,
        .active = false,
        .dead = false,
        .hint_x = 0,
        .hint_y = 0,
        .has_hint = true,
    };
    const t = warpTarget(c);
    try std.testing.expect(t != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0), t.?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), t.?.y, 0.001);
}
