//! Atomic-commit property builders for the initial MODESET and each page-FLIP,
//! plus the commit + event-drain glue.
//!
//! Pure builders (buildModeset / buildFlip) are unit-tested here.
//! Hardware glue (commitModeset / commitFlip / drainEvents) is integration-
//! tested by T8; no unit test for them.
//!
//! IMPORTANT: mode and HDR blobs must OUTLIVE the modeset commit. The kernel
//! holds a reference while they are the active MODE_ID / HDR_OUTPUT_METADATA.
//! commitModeset therefore returns the blob ids; the caller (T7) destroys them
//! at teardown via node.destroyBlob.

const std = @import("std");
const drm = @import("drm");
const display = @import("display.zig");
const hdr = @import("hdr.zig");

// ---------------------------------------------------------------------------
// BlobIds: the return value of commitModeset
// ---------------------------------------------------------------------------

pub const BlobIds = struct {
    mode_blob: u32,
    hdr_blob: ?u32,
};

// ---------------------------------------------------------------------------
// Pure builders (unit-tested below)
// ---------------------------------------------------------------------------

/// Build the full property set for an atomic MODESET. Sets connector, CRTC,
/// and plane groups. SRC rects are 16.16 fixed-point; CRTC rects are raw pixels.
pub fn buildModeset(
    req: *drm.types.atomic.Request,
    d: *const display.Display,
    mode_blob_id: u32,
    fb_id: u32,
    hdr_blob_id: ?u32,
    colorspace: ?u64,
) !void {
    const p = d.props;

    // Connector group
    try req.addProperty(d.connector_id, p.conn_crtc_id, d.crtc_id);
    if (hdr_blob_id) |hb| if (p.conn_hdr_metadata) |pid| try req.addProperty(d.connector_id, pid, hb);
    if (colorspace) |cs| if (p.conn_colorspace) |pid| try req.addProperty(d.connector_id, pid, cs);

    // CRTC group
    try req.addProperty(d.crtc_id, p.crtc_mode_id, mode_blob_id);
    try req.addProperty(d.crtc_id, p.crtc_active, 1);

    // Plane group
    try planeProps(req, d, fb_id);
}

/// Build the property set for a page-FLIP. Only re-points the plane FB_ID.
pub fn buildFlip(req: *drm.types.atomic.Request, d: *const display.Display, fb_id: u32) !void {
    try req.addProperty(d.plane_id, d.props.plane_fb_id, fb_id);
}

// ---------------------------------------------------------------------------
// Private plane helper (shared by modeset)
// ---------------------------------------------------------------------------

fn planeProps(req: *drm.types.atomic.Request, d: *const display.Display, fb_id: u32) !void {
    const p = d.props;
    const w: u64 = d.mode.hdisplay;
    const h: u64 = d.mode.vdisplay;

    try req.addProperty(d.plane_id, p.plane_fb_id, fb_id);
    try req.addProperty(d.plane_id, p.plane_crtc_id, d.crtc_id);

    // SRC rects: 16.16 fixed-point (pixels << 16)
    try req.addProperty(d.plane_id, p.plane_src_x, 0);
    try req.addProperty(d.plane_id, p.plane_src_y, 0);
    try req.addProperty(d.plane_id, p.plane_src_w, w << 16);
    try req.addProperty(d.plane_id, p.plane_src_h, h << 16);

    // CRTC rects: raw pixels
    try req.addProperty(d.plane_id, p.plane_crtc_x, 0);
    try req.addProperty(d.plane_id, p.plane_crtc_y, 0);
    try req.addProperty(d.plane_id, p.plane_crtc_w, w);
    try req.addProperty(d.plane_id, p.plane_crtc_h, h);
}

// ---------------------------------------------------------------------------
// Hardware glue (integration-tested by T8)
// ---------------------------------------------------------------------------

/// Run the initial atomic MODESET. Creates mode and (optionally) HDR blobs,
/// runs the commit, then returns the blob ids so the caller can destroy them
/// at teardown (the kernel holds refs while they are the active MODE_ID /
/// HDR_OUTPUT_METADATA — destroying them mid-scanout is a use-after-free).
pub fn commitModeset(
    node: *drm.Node,
    d: *const display.Display,
    fb_id: u32,
    hdr_meta: ?hdr.HdrOutputMetadata,
) !BlobIds {
    var mode = d.mode;
    const mode_blob = try node.createBlob(std.mem.asBytes(&mode));
    errdefer node.destroyBlob(mode_blob) catch {};

    var hdr_blob: ?u32 = null;
    var cs: ?u64 = null;

    if (hdr_meta) |*m| {
        if (d.props.conn_hdr_metadata != null) {
            hdr_blob = try node.createBlob(std.mem.asBytes(m));
        }
        cs = d.colorspace_bt2020;
    }
    errdefer if (hdr_blob) |hb| node.destroyBlob(hb) catch {};

    var req = drm.types.atomic.Request.init(node.allocator);
    defer req.deinit();

    try buildModeset(&req, d, mode_blob, fb_id, hdr_blob, cs);
    try node.atomicCommit(&req, drm.types.atomic.FLAG_ALLOW_MODESET, 0);

    // NOTE: do NOT destroy mode_blob or hdr_blob here.
    // The kernel holds refs while they are the active MODE_ID / HDR metadata.
    // The caller (T7 backend surface) must call node.destroyBlob at teardown.
    return BlobIds{ .mode_blob = mode_blob, .hdr_blob = hdr_blob };
}

/// Submit a page-FLIP atomic commit. The kernel will fire a flipComplete event
/// (readable via drainEvents) once the flip is on-screen.
pub fn commitFlip(node: *drm.Node, d: *const display.Display, fb_id: u32, user_data: u64) !void {
    var req = drm.types.atomic.Request.init(node.allocator);
    defer req.deinit();
    try buildFlip(&req, d, fb_id);
    try node.atomicCommit(&req, drm.types.atomic.FLAG_PAGE_FLIP_EVENT, user_data);
}

/// Read one DRM event from the node fd. Returns the flipComplete userData if
/// the event was a page-flip-complete, or null for any other event type.
pub fn drainEvents(node: *drm.Node) !?u64 {
    const ev = try node.getEvent();
    return switch (ev) {
        .flipComplete => |vb| vb.userData,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Unit tests (pure builders only)
// ---------------------------------------------------------------------------

fn fixtureDisplay(hdr_present: bool) display.Display {
    return .{
        .connector_id = 30,
        .crtc_id = 40,
        .plane_id = 50,
        .mode = .{ .hdisplay = 800, .vdisplay = 600 },
        .props = .{
            .conn_crtc_id = 1000,
            .conn_hdr_metadata = if (hdr_present) @as(?u32, 1001) else null,
            .conn_colorspace = if (hdr_present) @as(?u32, 1002) else null,
            .crtc_mode_id = 2000,
            .crtc_active = 2001,
            .plane_fb_id = 3000,
            .plane_crtc_id = 3001,
            .plane_src_x = 3002,
            .plane_src_y = 3003,
            .plane_src_w = 3004,
            .plane_src_h = 3005,
            .plane_crtc_x = 3006,
            .plane_crtc_y = 3007,
            .plane_crtc_w = 3008,
            .plane_crtc_h = 3009,
        },
        .hdr_caps = .{},
        .colorspace_bt2020 = if (hdr_present) @as(?u64, 9) else null,
    };
}

fn getProp(req: *const drm.types.atomic.Request, obj: u32, prop: u32) ?u64 {
    for (req.groups.items) |g| {
        if (g.objId == obj) {
            for (g.props.items, g.values.items) |p, v| {
                if (p == prop) return v;
            }
        }
    }
    return null;
}

test "buildModeset: connector/crtc/plane groups + 16.16 SRC rects + raw CRTC rects" {
    const a = std.testing.allocator;
    var req = drm.types.atomic.Request.init(a);
    defer req.deinit();
    const d = fixtureDisplay(false);
    try buildModeset(&req, &d, 99, 7, null, null);

    try std.testing.expectEqual(@as(usize, 3), req.groups.items.len);

    // Connector group
    try std.testing.expectEqual(@as(?u64, 40), getProp(&req, 30, 1000)); // conn CRTC_ID = d.crtc_id

    // CRTC group
    try std.testing.expectEqual(@as(?u64, 99), getProp(&req, 40, 2000)); // MODE_ID = mode_blob_id
    try std.testing.expectEqual(@as(?u64, 1), getProp(&req, 40, 2001)); // ACTIVE = 1

    // Plane group
    try std.testing.expectEqual(@as(?u64, 7), getProp(&req, 50, 3000)); // plane FB_ID
    try std.testing.expectEqual(@as(?u64, 40), getProp(&req, 50, 3001)); // plane CRTC_ID

    // SRC rects: 16.16 fixed-point
    try std.testing.expectEqual(@as(?u64, @as(u64, 800) << 16), getProp(&req, 50, 3004)); // SRC_W
    try std.testing.expectEqual(@as(?u64, @as(u64, 600) << 16), getProp(&req, 50, 3005)); // SRC_H
    try std.testing.expectEqual(@as(?u64, 0), getProp(&req, 50, 3002)); // SRC_X = 0
    try std.testing.expectEqual(@as(?u64, 0), getProp(&req, 50, 3003)); // SRC_Y = 0

    // CRTC rects: raw pixels
    try std.testing.expectEqual(@as(?u64, 800), getProp(&req, 50, 3008)); // CRTC_W raw
    try std.testing.expectEqual(@as(?u64, 600), getProp(&req, 50, 3009)); // CRTC_H raw
    try std.testing.expectEqual(@as(?u64, 0), getProp(&req, 50, 3006)); // CRTC_X = 0
    try std.testing.expectEqual(@as(?u64, 0), getProp(&req, 50, 3007)); // CRTC_Y = 0

    // HDR prop NOT present when not hdr_present
    try std.testing.expectEqual(@as(?u64, null), getProp(&req, 30, 1001));
}

test "buildModeset: HDR blob + colorspace attached when both prop id and value present" {
    const a = std.testing.allocator;
    var req = drm.types.atomic.Request.init(a);
    defer req.deinit();
    const d = fixtureDisplay(true);
    try buildModeset(&req, &d, 99, 7, 123, 9);

    try std.testing.expectEqual(@as(?u64, 123), getProp(&req, 30, 1001)); // HDR_OUTPUT_METADATA blob
    try std.testing.expectEqual(@as(?u64, 9), getProp(&req, 30, 1002)); // Colorspace = BT2020_RGB
}

test "buildFlip: only the plane FB_ID" {
    const a = std.testing.allocator;
    var req = drm.types.atomic.Request.init(a);
    defer req.deinit();
    const d = fixtureDisplay(false);
    try buildFlip(&req, &d, 8);

    try std.testing.expectEqual(@as(usize, 1), req.groups.items.len);
    try std.testing.expectEqual(@as(?u64, 8), getProp(&req, 50, 3000));
}
