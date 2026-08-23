const std = @import("std");
const drm = @import("drm");
const output = @import("../../output.zig");

// ---------------------------------------------------------------------------
// Public types (consumed verbatim by T5/T6/T7)
// ---------------------------------------------------------------------------

pub const PropIds = struct {
    conn_crtc_id: u32,
    conn_hdr_metadata: ?u32,
    conn_colorspace: ?u32,
    crtc_mode_id: u32,
    crtc_active: u32,
    plane_fb_id: u32,
    plane_crtc_id: u32,
    plane_src_x: u32,
    plane_src_y: u32,
    plane_src_w: u32,
    plane_src_h: u32,
    plane_crtc_x: u32,
    plane_crtc_y: u32,
    plane_crtc_w: u32,
    plane_crtc_h: u32,
};

pub const Display = struct {
    connector_id: u32,
    crtc_id: u32,
    plane_id: u32,
    mode: drm.types.ModeInfo,
    props: PropIds,
    hdr_caps: output.HdrCaps,
    colorspace_bt2020: ?u64,
};

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested below)
// ---------------------------------------------------------------------------

/// Return the preferred mode (type & 0x8), or the largest-area mode, or null.
pub fn pickMode(modes: []const drm.types.ModeInfo) ?drm.types.ModeInfo {
    for (modes) |m| if (m.type & 0x8 != 0) return m;
    var best: ?drm.types.ModeInfo = null;
    for (modes) |m| {
        const a = @as(u32, m.hdisplay) * m.vdisplay;
        if (best == null or a > @as(u32, best.?.hdisplay) * best.?.vdisplay) best = m;
    }
    return best;
}

/// Given a possibleCrtcs bitmask (bit i => crtc_ids[i]), return the id of the
/// first set bit, or null if mask is zero or all bits are beyond crtc_ids.
pub fn crtcFromPossible(mask: u32, crtc_ids: []const u32) ?u32 {
    var i: u5 = 0;
    while (i < crtc_ids.len and i < 32) : (i += 1) {
        if (mask & (@as(u32, 1) << i) != 0) return crtc_ids[i];
    }
    return null;
}

/// Compare a null-padded [32]u8 DRM name to a string slice.
fn propNameEq(name: [32]u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.sliceTo(&name, 0), want);
}

/// Look up a property id by name, reading each prop's name from the node.
fn findPropId(node: *const drm.Node, prop_ids: []const u32, want: []const u8) !?u32 {
    for (prop_ids) |pid| {
        var p = try node.getProperty(pid);
        defer p.deinit(node.allocator);
        if (propNameEq(p.name, want)) return pid;
    }
    return null;
}

/// Find a named property and require it (error.MissingProp if absent).
fn requirePropId(node: *const drm.Node, prop_ids: []const u32, want: []const u8) !u32 {
    return (try findPropId(node, prop_ids, want)) orelse error.MissingProp;
}

// ---------------------------------------------------------------------------
// Connector/CRTC/plane discovery (hardware glue, integration-tested via T8)
// ---------------------------------------------------------------------------

pub fn discover(node: *drm.Node, alloc: std.mem.Allocator) !Display {
    // 1. Card resources
    var res = try node.getModeCardRes();
    defer res.deinit(alloc);

    const crtc_ids = res.crtcIds() orelse return error.NoCrtc;
    const conn_ids = res.connectorIds() orelse return error.NoConnector;

    // 2. Find first connected connector with modes
    var connector_id: u32 = 0;
    var chosen_mode: drm.types.ModeInfo = undefined;

    outer: for (conn_ids) |cid| {
        var conn = try node.getConnector(cid);
        defer conn.deinit(alloc);
        if (conn.connection != 1) continue;
        const modes = conn.modes() orelse continue;
        if (modes.len == 0) continue;
        if (pickMode(modes)) |m| {
            connector_id = cid;
            chosen_mode = m;
            break :outer;
        }
    }
    if (connector_id == 0) return error.NoConnectedConnector;

    // Re-open the connector to get its encoder ids and prop ids
    var conn = try node.getConnector(connector_id);
    defer conn.deinit(alloc);

    // 3. CRTC selection via encoder
    var crtc_id: u32 = 0;
    var crtc_index: u5 = 0;

    if (conn.encoderId != 0) {
        const enc = try node.getEncoder(conn.encoderId);
        // getEncoder has no allocations, no deinit needed
        if (crtcFromPossible(enc.possibleCrtcs, crtc_ids)) |cid| {
            crtc_id = cid;
            // find index
            for (crtc_ids, 0..) |id, i| {
                if (id == cid) {
                    crtc_index = @intCast(i);
                    break;
                }
            }
        }
    }

    if (crtc_id == 0) {
        // Try each encoder the connector advertises
        const enc_ids = conn.encoderIds() orelse return error.NoCrtc;
        for (enc_ids) |eid| {
            if (eid == 0) continue;
            const enc = try node.getEncoder(eid);
            if (crtcFromPossible(enc.possibleCrtcs, crtc_ids)) |cid| {
                crtc_id = cid;
                for (crtc_ids, 0..) |id, i| {
                    if (id == cid) {
                        crtc_index = @intCast(i);
                        break;
                    }
                }
                break;
            }
        }
    }

    if (crtc_id == 0) return error.NoCrtc;

    // 4. Find primary plane compatible with our CRTC
    var pres = try node.getPlaneRes();
    defer pres.deinit(alloc);

    const plane_ids = pres.planeIds() orelse return error.NoPlane;
    const crtc_bit = @as(u32, 1) << crtc_index;

    var plane_id: u32 = 0;
    for (plane_ids) |pid| {
        var gp = drm.types.ModeGetPlane{ .planeId = pid };
        try gp.getAllocated(node.fd, alloc);
        defer gp.deinit(alloc);

        if (gp.possibleCrtcs & crtc_bit == 0) continue;

        // Check if this is a primary plane by reading its "type" property
        var pobj = try node.objGetProperties(pid, drm.types.OBJECT_PLANE);
        defer pobj.deinit(alloc);

        const pids_slice = pobj.props() orelse continue;
        const pvals_slice = pobj.values() orelse continue;

        // Find "type" property id
        const type_prop_id = (try findPropId(node, pids_slice, "type")) orelse continue;

        // Find the current value of "type" for this plane
        var current_type_val: u64 = 0;
        for (pids_slice, 0..) |ppid, k| {
            if (ppid == type_prop_id) {
                current_type_val = pvals_slice[k];
                break;
            }
        }

        // Resolve by name: read the "type" property enums and find name "Primary"
        var type_prop = try node.getProperty(type_prop_id);
        defer type_prop.deinit(alloc);

        const enums = type_prop.enums() orelse continue;
        var is_primary = false;
        for (enums) |e| {
            if (propNameEq(e.name, "Primary") and e.value == current_type_val) {
                is_primary = true;
                break;
            }
        }
        if (!is_primary) continue;

        plane_id = pid;
        break;
    }
    if (plane_id == 0) return error.NoPlane;

    // 5. Cache property IDs
    // Connector properties
    var conn_props = try node.objGetProperties(connector_id, drm.types.OBJECT_CONNECTOR);
    defer conn_props.deinit(alloc);

    const cp_ids = conn_props.props() orelse return error.MissingProp;

    const conn_crtc_id_prop = try requirePropId(node, cp_ids, "CRTC_ID");
    const conn_hdr_metadata = try findPropId(node, cp_ids, "HDR_OUTPUT_METADATA");
    const conn_colorspace = try findPropId(node, cp_ids, "Colorspace");

    // Resolve BT2020_RGB enum value if Colorspace prop exists
    var colorspace_bt2020: ?u64 = null;
    if (conn_colorspace) |cs_id| {
        var cs_prop = try node.getProperty(cs_id);
        defer cs_prop.deinit(alloc);
        if (cs_prop.enums()) |enums| {
            for (enums) |e| {
                if (propNameEq(e.name, "BT2020_RGB")) {
                    colorspace_bt2020 = e.value;
                    break;
                }
            }
        }
    }

    // CRTC properties
    var crtc_props = try node.objGetProperties(crtc_id, drm.types.OBJECT_CRTC);
    defer crtc_props.deinit(alloc);

    const crp_ids = crtc_props.props() orelse return error.MissingProp;

    const crtc_mode_id = try requirePropId(node, crp_ids, "MODE_ID");
    const crtc_active = try requirePropId(node, crp_ids, "ACTIVE");

    // Plane properties
    var plane_props = try node.objGetProperties(plane_id, drm.types.OBJECT_PLANE);
    defer plane_props.deinit(alloc);

    const plp_ids = plane_props.props() orelse return error.MissingProp;

    const plane_fb_id = try requirePropId(node, plp_ids, "FB_ID");
    const plane_crtc_id = try requirePropId(node, plp_ids, "CRTC_ID");
    const plane_src_x = try requirePropId(node, plp_ids, "SRC_X");
    const plane_src_y = try requirePropId(node, plp_ids, "SRC_Y");
    const plane_src_w = try requirePropId(node, plp_ids, "SRC_W");
    const plane_src_h = try requirePropId(node, plp_ids, "SRC_H");
    const plane_crtc_x = try requirePropId(node, plp_ids, "CRTC_X");
    const plane_crtc_y = try requirePropId(node, plp_ids, "CRTC_Y");
    const plane_crtc_w = try requirePropId(node, plp_ids, "CRTC_W");
    const plane_crtc_h = try requirePropId(node, plp_ids, "CRTC_H");

    // 6. HDR caps
    const hdr_caps = output.HdrCaps{
        .supported = conn_hdr_metadata != null,
        .bit_depth = 8,
        .max_nits = 0,
        .min_nits = 0,
        .colorspaces = &.{},
        .transfers = &.{},
    };

    return Display{
        .connector_id = connector_id,
        .crtc_id = crtc_id,
        .plane_id = plane_id,
        .mode = chosen_mode,
        .props = PropIds{
            .conn_crtc_id = conn_crtc_id_prop,
            .conn_hdr_metadata = conn_hdr_metadata,
            .conn_colorspace = conn_colorspace,
            .crtc_mode_id = crtc_mode_id,
            .crtc_active = crtc_active,
            .plane_fb_id = plane_fb_id,
            .plane_crtc_id = plane_crtc_id,
            .plane_src_x = plane_src_x,
            .plane_src_y = plane_src_y,
            .plane_src_w = plane_src_w,
            .plane_src_h = plane_src_h,
            .plane_crtc_x = plane_crtc_x,
            .plane_crtc_y = plane_crtc_y,
            .plane_crtc_w = plane_crtc_w,
            .plane_crtc_h = plane_crtc_h,
        },
        .hdr_caps = hdr_caps,
        .colorspace_bt2020 = colorspace_bt2020,
    };
}

// ---------------------------------------------------------------------------
// Unit tests (pure helpers only)
// ---------------------------------------------------------------------------

fn tmode(w: u16, h: u16, t: u32) drm.types.ModeInfo {
    return .{ .hdisplay = w, .vdisplay = h, .type = t };
}

test "pickMode prefers DRM_MODE_TYPE_PREFERRED (0x8), else largest area, else null" {
    try std.testing.expectEqual(@as(u16, 1920), pickMode(&.{ tmode(640, 480, 0), tmode(1920, 1080, 0x8), tmode(3840, 2160, 0) }).?.hdisplay);
    try std.testing.expectEqual(@as(u16, 3840), pickMode(&.{ tmode(640, 480, 0), tmode(3840, 2160, 0) }).?.hdisplay);
    try std.testing.expectEqual(@as(?drm.types.ModeInfo, null), pickMode(&.{}));
}

test "crtcFromPossible picks the crtc id at the first set bit index" {
    try std.testing.expectEqual(@as(?u32, 21), crtcFromPossible(0b010, &.{ 20, 21, 22 }));
    try std.testing.expectEqual(@as(?u32, 20), crtcFromPossible(0b101, &.{ 20, 21, 22 }));
    try std.testing.expectEqual(@as(?u32, null), crtcFromPossible(0, &.{ 20, 21 }));
}

test "propNameEq compares a null-padded [32]u8 name to a string" {
    var buf: [32]u8 = [_]u8{0} ** 32;
    @memcpy(buf[0..7], "CRTC_ID");
    try std.testing.expect(propNameEq(buf, "CRTC_ID"));
    try std.testing.expect(!propNameEq(buf, "FB_ID"));
}
