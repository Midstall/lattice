//! Double-buffered KMS scanout chain using prism-virgl adoptScanout targets.
//! Each Buffer is simultaneously a prism render target (scanout.resource) and a
//! KMS framebuffer (fb_id via ADDFB2). buildFb2 is a pure helper; allocChain and
//! destroyChain are hardware glue (integration-tested by the T8 demo, not here).
//! Teardown order: rmFb BEFORE destroyResource (release KMS ref before freeing bo).

const std = @import("std");
const drm = @import("drm");
const prism = @import("prism");

pub const Buffer = struct {
    scanout: prism.virgl.Scanout,
    fb_id: u32,
};

pub const Chain = struct {
    buffers: [2]Buffer,
    front: u1 = 0,
};

/// Build a ModeFbCmd2 for a single-plane buffer. Pure: no I/O or allocations.
/// The DRM_MODE_FB_MODIFIERS flag is set ONLY for a non-zero (non-LINEAR)
/// modifier: many drivers (virtio-gpu among them) reject an ADDFB2 that carries
/// the modifiers flag unless they advertise DRM_CAP_ADDFB2_MODIFIERS, so for a
/// plain LINEAR buffer (modifier 0) we submit a modifier-less ADDFB2. Fills
/// plane-0; planes 1..3 are zeroed.
pub fn buildFb2(bo_handle: u32, w: u32, h: u32, fourcc: u32, stride: u32, modifier: u64) drm.types.ModeFbCmd2 {
    const use_mod = modifier != 0;
    return .{
        .width = w,
        .height = h,
        .pixelFormat = fourcc,
        .flags = .{ .modifiers = if (use_mod) 1 else 0 },
        .handles = .{ bo_handle, 0, 0, 0 },
        .pitches = .{ stride, 0, 0, 0 },
        .offsets = .{ 0, 0, 0, 0 },
        .modifiers = .{ if (use_mod) modifier else 0, 0, 0, 0 },
    };
}

/// Allocate a double-buffered chain: adoptScanout x2 + ADDFB2 each.
/// Only 4-byte prism formats (rgba8, rgb10a2, rgb10x2) succeed; fp16 returns
/// error.Unsupported by design (T7 picks the format, not this function).
pub fn allocChain(
    virgl_dev: *prism.virgl.Device,
    node: *drm.Node,
    w: u32,
    h: u32,
    prism_fmt: prism.hal.Format,
    fourcc: u32,
    modifier: u64,
) !Chain {
    var chain = Chain{ .buffers = undefined, .front = 0 };
    var made: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < made) : (i += 1) {
            node.rmFb(chain.buffers[i].fb_id) catch {};
            // bo/resource reclaimed by the virgl device deinit on this error path;
            // thread hal_dev through if per-buffer resource free on error is needed.
        }
    }
    for (&chain.buffers) |*b| {
        const so = try virgl_dev.adoptScanout(w, h, prism_fmt);
        var fb = buildFb2(so.bo_handle, w, h, fourcc, so.stride, modifier);
        try node.addFb2(&fb);
        b.* = .{ .scanout = so, .fb_id = fb.fbId };
        made += 1;
    }
    return chain;
}

/// Release the chain. rmFb (drop KMS ref) FIRST, then destroyResource (free bo).
pub fn destroyChain(node: *drm.Node, hal_dev: prism.hal.Device, chain: *Chain) void {
    for (&chain.buffers) |*b| {
        node.rmFb(b.fb_id) catch {};
        hal_dev.destroyResource(b.scanout.resource);
    }
}

test "buildFb2 LINEAR (modifier 0): no modifiers flag (virtio-gpu rejects it otherwise)" {
    const fb = buildFb2(7, 800, 600, 0x30334241, 800 * 4, 0);
    try std.testing.expectEqual(@as(u32, 800), fb.width);
    try std.testing.expectEqual(@as(u32, 600), fb.height);
    try std.testing.expectEqual(@as(u32, 0x30334241), fb.pixelFormat);
    try std.testing.expectEqual(@as(u32, 7), fb.handles[0]);
    try std.testing.expectEqual(@as(u32, 800 * 4), fb.pitches[0]);
    try std.testing.expectEqual(@as(u32, 0), fb.offsets[0]);
    try std.testing.expectEqual(@as(u64, 0), fb.modifiers[0]);
    try std.testing.expectEqual(@as(u1, 0), fb.flags.modifiers); // LINEAR -> modifier-less ADDFB2
    // plane 1..3 unused
    try std.testing.expectEqual(@as(u32, 0), fb.handles[1]);
}

test "buildFb2 non-zero modifier: sets the modifiers flag + carries the modifier" {
    const fb = buildFb2(7, 800, 600, 0x30334241, 800 * 4, 0x0100000000000001);
    try std.testing.expectEqual(@as(u1, 1), fb.flags.modifiers);
    try std.testing.expectEqual(@as(u64, 0x0100000000000001), fb.modifiers[0]);
}
