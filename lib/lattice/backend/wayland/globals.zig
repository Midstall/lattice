/// Wayland registry roundtrip and standard-global binding.
///
/// roundtripGlobals: sends wl_display.sync, pumps dispatchEvent until the
/// wl_callback.done fires, collecting every wl_registry.global event.
/// Caller owns the returned slice (each Global.interface is a gpa dupe).
///
/// bindStandards: walks the collected globals, binds wl_compositor, wl_shm,
/// xdg_wm_base, and every wl_output, records ids in out params, registers
/// each in imap.
const std = @import("std");

const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const xdg = @import("xdg_shell");
const ld = @import("linux_dmabuf");
const cm = @import("color_management");
const rp = @import("relative_pointer");
const pc = @import("pointer_constraints");
const tv2 = @import("tablet_v2");

const client = wl.client;
const Argument = wl.Argument;

pub const Global = struct {
    name: u32,
    interface: []u8,
    version: u32,
};

/// Send wl_display.sync, pump dispatchEvent until the callback's done fires,
/// collecting wl_registry.global events into a heap-allocated slice.
///
/// `conn`        - live client connection
/// `imap`        - interface map (registry must already be registered)
/// `registry_id` - the id returned by client.getRegistry (unused here but
///                 passed for symmetry with bindStandards)
/// `gpa`         - allocator; caller frees the returned slice + each .interface
pub fn roundtripGlobals(
    conn: *client.Connection,
    imap: *client.InterfaceMap,
    registry_id: u32,
    gpa: std.mem.Allocator,
) ![]Global {
    // Issue wl_display.sync and register the callback id.
    const cb_id = try client.sync(conn);
    try imap.set(cb_id, &wlp.WlCallback.interface);

    var globals: std.ArrayList(Global) = .empty;
    errdefer {
        for (globals.items) |g| gpa.free(g.interface);
        globals.deinit(gpa);
    }

    var msg_buf: [4096]u8 = undefined;
    var args: [16]Argument = undefined;
    var done = false;

    while (!done) {
        const ev = (try client.dispatchEvent(conn, imap, &msg_buf, &args)) orelse continue;

        if (ev.interface == &wlp.WlCallback.interface and ev.object_id == cb_id) {
            if (ev.opcode == @intFromEnum(wlp.WlCallback.EventOpcode.done)) {
                imap.remove(cb_id);
                done = true;
            }
            continue;
        }

        if (ev.interface == &wlp.WlDisplay.interface) {
            if (ev.opcode == @intFromEnum(wlp.WlDisplay.EventOpcode.@"error")) {
                return error.ServerError;
            }
            continue;
        }

        if (ev.interface == &wlp.WlRegistry.interface) {
            if (ev.opcode == @intFromEnum(wlp.WlRegistry.EventOpcode.global)) {
                const gname = ev.args[0].uint;
                const ifc = ev.args[1].string orelse continue;
                const ver = ev.args[2].uint;
                const owned = try gpa.dupe(u8, ifc);
                try globals.append(gpa, .{ .name = gname, .interface = owned, .version = ver });
            }
            continue;
        }
        _ = registry_id;
        // Ignore unknown events during the initial roundtrip.
    }

    return globals.toOwnedSlice(gpa);
}

/// Result of bindStandards: holds bound object ids for the standard globals.
pub const BoundIds = struct {
    compositor_id: u32,
    shm_id: u32,
    xdg_wm_base_id: u32,
    /// Caller owns this slice (gpa-allocated); each element is the wl_output object id.
    output_ids: []u32,
    /// 0 if the compositor did not advertise zwp_linux_dmabuf_v1.
    zwp_linux_dmabuf_id: u32 = 0,
    /// 0 if the compositor did not advertise wp_color_manager_v1.
    wp_color_manager_id: u32 = 0,
    /// 0 if the compositor did not advertise wl_seat.
    wl_seat_id: u32 = 0,
    /// 0 if the compositor did not advertise zwp_relative_pointer_manager_v1.
    relative_pointer_manager_id: u32 = 0,
    /// 0 if the compositor did not advertise zwp_pointer_constraints_v1.
    pointer_constraints_id: u32 = 0,
    /// 0 if the compositor did not advertise zwp_tablet_manager_v2.
    tablet_manager_id: u32 = 0,
};

/// Find a global by interface name, or null.
pub fn findGlobal(globals: []const Global, iface: []const u8) ?Global {
    for (globals) |g| {
        if (std.mem.eql(u8, g.interface, iface)) return g;
    }
    return null;
}

/// Walk the collected globals, bind wl_compositor, wl_shm, xdg_wm_base, and
/// all wl_output objects. Registers each in imap with the matching interface.
pub fn bindStandards(
    conn: *client.Connection,
    imap: *client.InterfaceMap,
    registry_id: u32,
    globals: []const Global,
    gpa: std.mem.Allocator,
) !BoundIds {
    var compositor_id: u32 = 0;
    var shm_id: u32 = 0;
    var xdg_wm_base_id: u32 = 0;
    var zwp_linux_dmabuf_id: u32 = 0;
    var wp_color_manager_id: u32 = 0;
    var wl_seat_id: u32 = 0;
    var relative_pointer_manager_id: u32 = 0;
    var pointer_constraints_id: u32 = 0;
    var tablet_manager_id: u32 = 0;
    var output_ids: std.ArrayList(u32) = .empty;
    errdefer output_ids.deinit(gpa);

    for (globals) |g| {
        if (std.mem.eql(u8, g.interface, "wl_compositor")) {
            const ver = @min(g.version, wlp.WlCompositor.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "wl_compositor", ver);
            try imap.set(oid, &wlp.WlCompositor.interface);
            compositor_id = oid;
        } else if (std.mem.eql(u8, g.interface, "wl_shm")) {
            const ver = @min(g.version, wlp.WlShm.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "wl_shm", ver);
            try imap.set(oid, &wlp.WlShm.interface);
            shm_id = oid;
        } else if (std.mem.eql(u8, g.interface, "xdg_wm_base")) {
            const ver = @min(g.version, xdg.XdgWmBase.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "xdg_wm_base", ver);
            try imap.set(oid, &xdg.XdgWmBase.interface);
            xdg_wm_base_id = oid;
        } else if (std.mem.eql(u8, g.interface, "wl_output")) {
            const ver = @min(g.version, wlp.WlOutput.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "wl_output", ver);
            try imap.set(oid, &wlp.WlOutput.interface);
            try output_ids.append(gpa, oid);
        } else if (std.mem.eql(u8, g.interface, "zwp_linux_dmabuf_v1")) {
            const ver = @min(g.version, ld.ZwpLinuxDmabufV1.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "zwp_linux_dmabuf_v1", ver);
            try imap.set(oid, &ld.ZwpLinuxDmabufV1.interface);
            zwp_linux_dmabuf_id = oid;
        } else if (std.mem.eql(u8, g.interface, "wp_color_manager_v1")) {
            const ver = @min(g.version, cm.WpColorManagerV1.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "wp_color_manager_v1", ver);
            try imap.set(oid, &cm.WpColorManagerV1.interface);
            wp_color_manager_id = oid;
        } else if (std.mem.eql(u8, g.interface, "wl_seat")) {
            const ver = @min(g.version, wlp.WlSeat.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "wl_seat", ver);
            try imap.set(oid, &wlp.WlSeat.interface);
            wl_seat_id = oid;
        } else if (std.mem.eql(u8, g.interface, "zwp_relative_pointer_manager_v1")) {
            const ver = @min(g.version, rp.ZwpRelativePointerManagerV1.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "zwp_relative_pointer_manager_v1", ver);
            try imap.set(oid, &rp.ZwpRelativePointerManagerV1.interface);
            relative_pointer_manager_id = oid;
        } else if (std.mem.eql(u8, g.interface, "zwp_pointer_constraints_v1")) {
            const ver = @min(g.version, pc.ZwpPointerConstraintsV1.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "zwp_pointer_constraints_v1", ver);
            try imap.set(oid, &pc.ZwpPointerConstraintsV1.interface);
            pointer_constraints_id = oid;
        } else if (std.mem.eql(u8, g.interface, "zwp_tablet_manager_v2")) {
            const ver = @min(g.version, tv2.ZwpTabletManagerV2.version);
            const oid = try client.bindGlobal(conn, registry_id, g.name, "zwp_tablet_manager_v2", ver);
            try imap.set(oid, &tv2.ZwpTabletManagerV2.interface);
            tablet_manager_id = oid;
        }
    }

    if (compositor_id == 0) return error.MissingWlCompositor;
    if (shm_id == 0) return error.MissingWlShm;
    if (xdg_wm_base_id == 0) return error.MissingXdgWmBase;

    return BoundIds{
        .compositor_id = compositor_id,
        .shm_id = shm_id,
        .xdg_wm_base_id = xdg_wm_base_id,
        .output_ids = try output_ids.toOwnedSlice(gpa),
        .zwp_linux_dmabuf_id = zwp_linux_dmabuf_id,
        .wp_color_manager_id = wp_color_manager_id,
        .wl_seat_id = wl_seat_id,
        .relative_pointer_manager_id = relative_pointer_manager_id,
        .pointer_constraints_id = pointer_constraints_id,
        .tablet_manager_id = tablet_manager_id,
    };
}

/// Free the Global slice returned by roundtripGlobals.
pub fn freeGlobals(gpa: std.mem.Allocator, globals: []Global) void {
    for (globals) |g| gpa.free(g.interface);
    gpa.free(globals);
}

test "findGlobal locates wl_seat by interface" {
    const gs = [_]Global{
        .{ .name = 1, .interface = @constCast("wl_compositor"), .version = 4 },
        .{ .name = 7, .interface = @constCast("wl_seat"), .version = 9 },
    };
    const found = findGlobal(&gs, "wl_seat").?;
    try std.testing.expectEqual(@as(u32, 7), found.name);
    try std.testing.expect(findGlobal(&gs, "wl_touch") == null);
}
