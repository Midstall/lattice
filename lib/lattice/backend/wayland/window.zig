/// Window: per-surface state for a Wayland xdg_toplevel window.
///
/// Buffers and render target are added in Task 9. Fields are optional
/// placeholders here so the struct is already forward-compatible.
const std = @import("std");

const prism = @import("prism");

const id_mod = @import("../../id.zig");
const surface_mod = @import("../../surface.zig");
const shmbuffer_mod = @import("shmbuffer.zig");

pub const shmbuffer = shmbuffer_mod;
pub const ShmBuffer = shmbuffer_mod.ShmBuffer;
pub const SurfaceId = id_mod.SurfaceId;
pub const SurfaceDesc = surface_mod.SurfaceDesc;

/// Present mode: shm (software) or dmabuf (GPU zero-copy).
pub const PresentMode = enum { shm, dmabuf };

/// Per-slot dmabuf state: wl_buffer id and busy flag.
pub const DmabufSlot = struct {
    buffer_id: u32,
    busy: bool,
};

/// Tracks an in-flight async zwp_linux_buffer_params_v1.create request.
/// The buffer arrives later via the `created` event (or `failed` if rejected).
pub const PendingCreate = struct {
    /// The params object id used to issue the create request.
    params_id: u32,
    /// Which dmabuf_wl slot (0 or 1) the resulting buffer should occupy.
    slot: usize,
};

pub const Window = struct {
    id: SurfaceId,
    wl_surface_id: u32,
    xdg_surface_id: u32,
    xdg_toplevel_id: u32,
    width: u32,
    height: u32,
    configured: bool = false,
    pending_serial: ?u32 = null,
    desc: SurfaceDesc,
    /// Task 9: double-buffered shm buffers (none until first render).
    buffers: [2]?ShmBuffer = .{ null, null },
    /// Task 9: prism render-target resource (none until first render).
    target: ?*prism.Resource = null,
    /// wl_callback id for the pending frame callback (Task 8/9).
    /// Set when a frame callback is requested; cleared on wl_callback.done.
    frame_cb_id: ?u32 = null,
    /// Tracks the dimensions the current buffers/target were allocated for.
    /// Used to detect resize and trigger recreation.
    alloc_width: u32 = 0,
    alloc_height: u32 = 0,
    /// Task 2: present mode (shm or dmabuf).
    present_mode: PresentMode = .shm,
    /// Task 2: dmabuf render targets (GPU resources, ping-ponged).
    dmabuf_targets: [2]?*prism.Resource = .{ null, null },
    /// Task 2: dmabuf wl_buffer state (slot id and busy flag).
    dmabuf_wl: [2]?DmabufSlot = .{ null, null },
    /// Task 3: which dmabuf slot was picked for the current frame (set by
    /// surfaceRenderTarget, read by commitFrame).
    dmabuf_cur: usize = 0,
    /// In-flight async zwp_linux_buffer_params_v1.create request, if any.
    /// Set when create is sent; cleared when created/failed event arrives.
    pending_create: ?PendingCreate = null,
    /// Set to true when a dmabuf create fails; forces .shm permanently.
    /// Prevents re-selecting dmabuf after the compositor has rejected it once.
    dmabuf_failed: bool = false,
    /// wp_color_management_surface_v1 object id for an HDR surface, or 0 when
    /// the surface has no color-management surface. Must be destroyed on
    /// teardown so the client + compositor per-surface color state is freed.
    cm_surface_id: u32 = 0,
};

/// Return the index (0 or 1) of the first non-busy ShmBuffer slot, or null
/// if both are busy or unallocated.
/// Pure and allocation-free: safe to call on the hot present path.
pub fn pickFreeBuffer(buffers: [2]?ShmBuffer) ?usize {
    for (buffers, 0..) |slot, i| {
        if (slot) |buf| {
            if (!buf.busy) return i;
        }
    }
    return null;
}

/// Pure pacing predicate: returns true when a frame can be rendered.
///
/// Rules:
///   - Surface must be configured by the compositor.
///   - No frame callback must be in-flight (paces to compositor clock).
///   - At least one ShmBuffer must be free, OR no buffers have been
///     allocated yet (first frame: allocation happens in surfaceRenderTarget).
///
/// Factored out of the vtable renderAvailable for unit-testability.
pub fn canRender(configured: bool, any_free_buffer: bool, frame_in_flight: bool) bool {
    if (!configured) return false;
    if (frame_in_flight) return false;
    return any_free_buffer;
}

/// Task 2: Pure mode-selection helper.
/// Returns .dmabuf iff compositor advertised dmabuf AND offers ARGB8888/LINEAR
/// AND the device can export resources; otherwise returns .shm.
pub fn chooseDmabufMode(has_dmabuf: bool, fmt_ok: bool, can_export: bool) PresentMode {
    if (has_dmabuf and fmt_ok and can_export) {
        return .dmabuf;
    }
    return .shm;
}

/// HDR slice 2 Part 2b: Pure mode-selection helper for fp16 dma-buf path.
/// Returns .dmabuf iff compositor advertised dmabuf AND offers 0x48344241/LINEAR
/// (ABGR16161616F, modifier 0) AND the device can export resources; otherwise
/// returns .shm (fallback to proven 2a wl_shm fp16 path).
/// Structurally identical to chooseDmabufMode by design: kept separate to name
/// the distinct semantics (HDR ABGR16161616F fourcc vs SDR ARGB8888). Do not merge.
pub fn chooseHdrMode(has_dmabuf: bool, hdr_fmt_ok: bool, can_export: bool) PresentMode {
    if (has_dmabuf and hdr_fmt_ok and can_export) {
        return .dmabuf;
    }
    return .shm;
}

/// Task 2: Pure free-slot picker for dmabuf.
/// Returns index of the first slot that is null (not yet created) OR has busy=false.
/// Returns null if both slots are present (allocated) and both busy.
pub fn pickFreeDmabuf(slots: [2]?DmabufSlot) ?usize {
    for (slots, 0..) |slot, i| {
        if (slot == null) {
            return i;
        }
        if (slot) |s| {
            if (!s.busy) {
                return i;
            }
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// Unit tests (pure)
// -------------------------------------------------------------------------

test "pickFreeBuffer: both free returns 0" {
    const free_buf = ShmBuffer{
        .fd = 0,
        .data = &.{},
        .pool_id = 1,
        .buffer_id = 2,
        .width = 4,
        .height = 4,
        .stride = 16,
        .busy = false,
    };
    const buffers = [2]?ShmBuffer{ free_buf, free_buf };
    try std.testing.expectEqual(@as(?usize, 0), pickFreeBuffer(buffers));
}

test "pickFreeBuffer: index 0 busy returns 1" {
    const free_buf = ShmBuffer{
        .fd = 0,
        .data = &.{},
        .pool_id = 1,
        .buffer_id = 2,
        .width = 4,
        .height = 4,
        .stride = 16,
        .busy = false,
    };
    var busy_buf = free_buf;
    busy_buf.busy = true;
    const buffers = [2]?ShmBuffer{ busy_buf, free_buf };
    try std.testing.expectEqual(@as(?usize, 1), pickFreeBuffer(buffers));
}

test "pickFreeBuffer: both busy returns null" {
    const busy_buf = ShmBuffer{
        .fd = 0,
        .data = &.{},
        .pool_id = 1,
        .buffer_id = 2,
        .width = 4,
        .height = 4,
        .stride = 16,
        .busy = true,
    };
    const buffers = [2]?ShmBuffer{ busy_buf, busy_buf };
    try std.testing.expectEqual(@as(?usize, null), pickFreeBuffer(buffers));
}

test "pickFreeBuffer: unallocated slots skipped" {
    const buffers = [2]?ShmBuffer{ null, null };
    try std.testing.expectEqual(@as(?usize, null), pickFreeBuffer(buffers));
}

test "canRender: not configured returns false" {
    try std.testing.expect(!canRender(false, true, false));
}

test "canRender: frame in flight returns false" {
    try std.testing.expect(!canRender(true, true, true));
}

test "canRender: configured + free buffer + no frame in flight returns true" {
    try std.testing.expect(canRender(true, true, false));
}

test "canRender: configured + no free buffer + no frame in flight returns false" {
    try std.testing.expect(!canRender(true, false, false));
}

test "canRender: not configured and frame in flight returns false" {
    try std.testing.expect(!canRender(false, true, true));
}

test "chooseDmabufMode: all true returns dmabuf" {
    try std.testing.expectEqual(PresentMode.dmabuf, chooseDmabufMode(true, true, true));
}

test "chooseDmabufMode: has_dmabuf=false returns shm" {
    try std.testing.expectEqual(PresentMode.shm, chooseDmabufMode(false, true, true));
}

test "chooseDmabufMode: fmt_ok=false returns shm" {
    try std.testing.expectEqual(PresentMode.shm, chooseDmabufMode(true, false, true));
}

test "chooseDmabufMode: can_export=false returns shm" {
    try std.testing.expectEqual(PresentMode.shm, chooseDmabufMode(true, true, false));
}

test "chooseDmabufMode: has_dmabuf and fmt_ok but not can_export returns shm" {
    try std.testing.expectEqual(PresentMode.shm, chooseDmabufMode(true, true, false));
}

test "chooseDmabufMode: all false returns shm" {
    try std.testing.expectEqual(PresentMode.shm, chooseDmabufMode(false, false, false));
}

test "pickFreeDmabuf: both null returns 0" {
    const slots: [2]?DmabufSlot = .{ null, null };
    try std.testing.expectEqual(@as(?usize, 0), pickFreeDmabuf(slots));
}

test "pickFreeDmabuf: slot0 busy slot1 null returns 1" {
    const slots: [2]?DmabufSlot = .{
        .{ .buffer_id = 1, .busy = true },
        null,
    };
    try std.testing.expectEqual(@as(?usize, 1), pickFreeDmabuf(slots));
}

test "pickFreeDmabuf: both busy returns null" {
    const slots: [2]?DmabufSlot = .{
        .{ .buffer_id = 1, .busy = true },
        .{ .buffer_id = 2, .busy = true },
    };
    try std.testing.expectEqual(@as(?usize, null), pickFreeDmabuf(slots));
}

test "pickFreeDmabuf: slot0 free returns 0" {
    const slots: [2]?DmabufSlot = .{
        .{ .buffer_id = 1, .busy = false },
        .{ .buffer_id = 2, .busy = true },
    };
    try std.testing.expectEqual(@as(?usize, 0), pickFreeDmabuf(slots));
}

test "chooseHdrMode: all true returns dmabuf" {
    try std.testing.expectEqual(PresentMode.dmabuf, chooseHdrMode(true, true, true));
}

test "chooseHdrMode: has_dmabuf=false returns shm" {
    try std.testing.expectEqual(PresentMode.shm, chooseHdrMode(false, true, true));
}

test "chooseHdrMode: hdr_fmt_ok=false returns shm" {
    try std.testing.expectEqual(PresentMode.shm, chooseHdrMode(true, false, true));
}

test "chooseHdrMode: can_export=false returns shm" {
    try std.testing.expectEqual(PresentMode.shm, chooseHdrMode(true, true, false));
}

test "chooseHdrMode: all false returns shm" {
    try std.testing.expectEqual(PresentMode.shm, chooseHdrMode(false, false, false));
}
