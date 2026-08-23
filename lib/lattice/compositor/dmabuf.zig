//! Server-side zwp_linux_dmabuf_v1 v4 global handler.
//!
//! Task 1 scope:
//! - FormatTableEntry (16-byte extern struct) + size/offset tests.
//! - DmabufClientBuffer: a committed dma-buf buffer waiting to be imported.
//! - ParamsAccum: accumulates add() planes before create/create_immed.
//! - DmabufCtx: stable impl structs for the dmabuf global + params objects.
//! - bindDmabuf: bind handler (called by registerDmabufGlobal from globals.zig).
//! - onCreateParams: creates a ZwpLinuxBufferParamsV1 resource + ParamsAccum.
//! - Empty stubs: onGetDefaultFeedback, onAdd, onCreate, onCreateImmed (Tasks 2/3).

const std = @import("std");
const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const ld = @import("linux_dmabuf");
const posix = std.posix;
const linux = std.os.linux;

const Object = wl.Object;
const Client = wl.server_client.Client;

// Break the import cycle: the parent Compositor is reached via opaque back-pointer.
const CompositorOpaque = opaque {};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One entry in the format table sent to clients via get_default_feedback.
/// Layout matches the Linux DRM ABI: 4-byte format, 4-byte pad, 8-byte modifier.
pub const FormatTableEntry = extern struct {
    format: u32,
    pad: u32 = 0,
    modifier: u64,
};

/// A dma-buf buffer that a hosted client has successfully created.
/// Stored in Compositor.dmabuf_buffers keyed by wl_buffer object id.
/// fd is the dma-buf fd (owned; closed on buffer destroy).
/// mapping is a cached mmap slice (munmapped on buffer destroy), set lazily on commit.
pub const DmabufClientBuffer = struct {
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    modifier: u64,
    mapping: ?[]align(std.heap.page_size_min) u8 = null,
};

/// Accumulates planes sent by the client via zwp_linux_buffer_params_v1.add()
/// before a create or create_immed request finalises the buffer.
pub const ParamsAccum = struct {
    planes: [4]?struct {
        fd: std.posix.fd_t,
        offset: u32,
        stride: u32,
        modifier: u64,
    } = .{ null, null, null, null },
    count: usize = 0,
};

/// Internal wrapper stored as the params resource user_data so onParamsDestroy
/// can reach the compositor gpa without a global allocator.
const ParamsWrapper = struct {
    accum: ParamsAccum,
    gpa: std.mem.Allocator,
    /// Back-pointer to the DmabufCtx so create/create_immed handlers can reach
    /// the compositor without casting client_data (which is the wrapper itself).
    ctx: *DmabufCtx,
};

/// Close all non-null plane fds in accum and null out each slot.
fn closeAllPlaneFds(accum: *ParamsAccum) void {
    for (&accum.planes) |*p| {
        if (p.*) |plane| {
            _ = std.os.linux.close(plane.fd);
            p.* = null;
        }
    }
}

// ---------------------------------------------------------------------------
// DmabufCtx: lives inline inside the heap-allocated Compositor for stable ptrs.
// ---------------------------------------------------------------------------

pub const DmabufCtx = struct {
    /// Back-pointer to the owning Compositor (set by Compositor.init after alloc).
    compositor: *CompositorOpaque = undefined,

    /// Server-side Implementation structs (stable addresses; bound to each resource).
    dmabuf_impl: ld.ZwpLinuxDmabufV1.Implementation = .{},
    params_impl: ld.ZwpLinuxBufferParamsV1.Implementation = .{},
    buffer_impl: wlp.WlBuffer.Implementation = .{},
    feedback_impl: ld.ZwpLinuxDmabufFeedbackV1.Implementation = .{},
};

/// Fill in the implementation fn pointers on a freshly zero-valued DmabufCtx.
pub fn makeDmabufCtx() DmabufCtx {
    return .{
        .dmabuf_impl = .{
            .create_params = onCreateParams,
            .get_default_feedback = onGetDefaultFeedback,
            .get_surface_feedback = null,
            .destroy = null,
        },
        .params_impl = .{
            .add = onAdd,
            .create = onCreate,
            .create_immed = onCreateImmed,
            .destroy = null,
        },
        .buffer_impl = .{
            .destroy = onDmabufBufferDestroy,
        },
        .feedback_impl = .{
            .destroy = null,
        },
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn getCtx(data: ?*anyopaque) *DmabufCtx {
    return @ptrCast(@alignCast(data.?));
}

fn getCompositor(ctx: *DmabufCtx) *@import("../compositor.zig").Compositor {
    return @ptrCast(@alignCast(ctx.compositor));
}

// ---------------------------------------------------------------------------
// Global registration
// ---------------------------------------------------------------------------

/// Register the zwp_linux_dmabuf_v1 global (v4) on the display.
/// Called from Compositor.init alongside the other registerGlobals calls.
pub fn registerDmabufGlobal(display: *wl.Display, ctx: *DmabufCtx) !void {
    _ = try display.globalCreate(
        &ld.ZwpLinuxDmabufV1.interface,
        4,
        bindDmabuf,
        ctx,
    );
}

fn bindDmabuf(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx = getCtx(data);
    const res = Object.create(client, &ld.ZwpLinuxDmabufV1.interface, version, id) catch return;
    ld.ZwpLinuxDmabufV1.setImplementation(res, &ctx.dmabuf_impl, ctx, null);
}

// ---------------------------------------------------------------------------
// create_params handler
// ---------------------------------------------------------------------------

fn onCreateParams(client_data: ?*anyopaque, resource: *Object, params_id: u32) void {
    const ctx = getCtx(client_data);
    const comp = getCompositor(ctx);

    const params_res = Object.create(
        resource.client,
        &ld.ZwpLinuxBufferParamsV1.interface,
        resource.version,
        params_id,
    ) catch return;
    errdefer params_res.destroy();

    // Allocate a ParamsWrapper (accum + gpa back-ref) so onParamsDestroy can free itself
    // without needing a global allocator or a separate map lookup.
    const wrapper = comp.gpa.create(ParamsWrapper) catch return;
    wrapper.* = .{
        .accum = .{},
        .gpa = comp.gpa,
        .ctx = ctx,
    };

    ld.ZwpLinuxBufferParamsV1.setImplementation(params_res, &ctx.params_impl, wrapper, onParamsDestroy);
}

fn onParamsDestroy(res: *Object) void {
    const wrapper: *ParamsWrapper = @ptrCast(@alignCast(res.user_data orelse return));
    const gpa = wrapper.gpa;
    // Close any fds not yet consumed by a successful create (FIX I2).
    closeAllPlaneFds(&wrapper.accum);
    gpa.destroy(wrapper);
}

// ---------------------------------------------------------------------------
// TASK 2: format-table memfd builder + render-node device id
// ---------------------------------------------------------------------------

/// Build a format-table memfd containing five FormatTableEntry values:
///   ARGB8888/LINEAR, XRGB8888/LINEAR, ABGR16161616F/LINEAR (HDR fp16),
///   ABGR2101010/LINEAR (10-bit HDR rgb10a2), XBGR2101010/LINEAR (10-bit HDR rgb10x2).
/// Returns the fd (caller closes after sendFormatTable) and the byte size (80).
fn buildFormatTable(gpa: std.mem.Allocator) !struct { fd: posix.fd_t, size: u32 } {
    _ = gpa;
    const entries = [5]FormatTableEntry{
        .{ .format = 0x34325241, .modifier = 0 }, // ARGB8888, LINEAR
        .{ .format = 0x34325258, .modifier = 0 }, // XRGB8888, LINEAR
        .{ .format = 0x48344241, .modifier = 0 }, // ABGR16161616F (HDR fp16), LINEAR
        .{ .format = 0x30334241, .modifier = 0 }, // ABGR2101010 (10-bit HDR rgb10a2), LINEAR
        .{ .format = 0x30334258, .modifier = 0 }, // XBGR2101010 (10-bit HDR rgb10x2), LINEAR
    };
    const size: u32 = @intCast(@sizeOf(@TypeOf(entries)));

    const fd = try posix.memfd_create("dmabuf-format-table", 0);
    errdefer _ = linux.close(fd);

    const rc = linux.ftruncate(fd, @intCast(size));
    if (posix.errno(rc) != .SUCCESS) return error.FtruncateFailed;

    const map = try posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer posix.munmap(map);

    const bytes = std.mem.asBytes(&entries);
    @memcpy(map[0..bytes.len], bytes);

    return .{ .fd = fd, .size = size };
}

/// Return the dev_t (as a u64) for /dev/dri/renderD128, or 0 on failure.
/// Uses linux.statx to avoid the removed posix.stat on Linux.
fn renderNodeDevT() u64 {
    var stx: linux.Statx = undefined;
    const path = "/dev/dri/renderD128";
    const rc = linux.statx(
        linux.AT.FDCWD,
        path,
        0,
        @bitCast(linux.STATX{ .TYPE = true }),
        &stx,
    );
    if (posix.errno(rc) != .SUCCESS) return 0;
    // Reconstruct dev_t from major/minor the same way makedev(3) does it:
    //   dev = (major << 8) | minor  (simplified; real makedev uses bitfields but
    //   for feedback purposes any stable u64 is fine).
    const major: u64 = stx.rdev_major;
    const minor: u64 = stx.rdev_minor;
    return (major << 8) | (minor & 0xff) | ((minor & ~@as(u64, 0xff)) << 12);
}

// ---------------------------------------------------------------------------
// TASK 2: get_default_feedback (feedback sequence: format table + tranche events)
// ---------------------------------------------------------------------------

fn onGetDefaultFeedback(client_data: ?*anyopaque, resource: *Object, id: u32) void {
    const ctx = getCtx(client_data);
    const comp = getCompositor(ctx);

    const fb_res = Object.create(
        resource.client,
        &ld.ZwpLinuxDmabufFeedbackV1.interface,
        resource.version,
        id,
    ) catch return;
    ld.ZwpLinuxDmabufFeedbackV1.setImplementation(fb_res, &ctx.feedback_impl, ctx, null);

    const table = buildFormatTable(comp.gpa) catch return;
    ld.ZwpLinuxDmabufFeedbackV1.sendFormatTable(fb_res, table.fd, table.size);
    // Flush immediately so the fd is still open when sendmsg transmits it via
    // SCM_RIGHTS. queueMessage stores the raw fd integer; closing before flush
    // would cause the next sendmsg to fail with EBADF (silently dropped by
    // flushClients). After flush the kernel has dup'd the fd to the recipient.
    fb_res.client.flush() catch {};
    _ = linux.close(table.fd);

    const dev = renderNodeDevT();
    const dev_bytes = std.mem.asBytes(&dev);
    ld.ZwpLinuxDmabufFeedbackV1.sendMainDevice(fb_res, dev_bytes);
    ld.ZwpLinuxDmabufFeedbackV1.sendTrancheTargetDevice(fb_res, dev_bytes);

    const indices = [_]u16{ 0, 1, 2, 3, 4 };
    ld.ZwpLinuxDmabufFeedbackV1.sendTrancheFormats(fb_res, std.mem.sliceAsBytes(indices[0..]));
    ld.ZwpLinuxDmabufFeedbackV1.sendTrancheFlags(fb_res, 0);
    ld.ZwpLinuxDmabufFeedbackV1.sendTrancheDone(fb_res);
    ld.ZwpLinuxDmabufFeedbackV1.sendDone(fb_res);
}

// ---------------------------------------------------------------------------
// TASK 3: isSupportedFormat helper
// ---------------------------------------------------------------------------

/// Returns true only for the formats + LINEAR modifier we accept.
/// ARGB8888 = 0x34325241, XRGB8888 = 0x34325258,
/// ABGR16161616F (HDR fp16) = 0x48344241,
/// ABGR2101010 (10-bit HDR rgb10a2) = 0x30334241,
/// XBGR2101010 (10-bit HDR rgb10x2) = 0x30334258, LINEAR modifier = 0.
pub fn isSupportedFormat(fourcc: u32, modifier: u64) bool {
    return (fourcc == 0x34325241 or fourcc == 0x34325258 or fourcc == 0x48344241 or
        fourcc == 0x30334241 or fourcc == 0x30334258) and modifier == 0;
}

// ---------------------------------------------------------------------------
// TASK 3: add / create / create_immed -> DmabufClientBuffer
// ---------------------------------------------------------------------------

/// onAdd: the generated dispatch (linux_dmabuf.zig dispatch opcode 1) calls
/// wl.argument.demarshal which reads the fd from the SCM_RIGHTS queue and
/// places it in args_[0].fd, then passes it directly to this function.
/// No manual takeFd() call needed.
fn onAdd(
    client_data: ?*anyopaque,
    resource: *Object,
    fd: i32,
    plane_idx: u32,
    offset: u32,
    stride: u32,
    modifier_hi: u32,
    modifier_lo: u32,
) void {
    _ = client_data; // user_data is the ParamsWrapper; ctx is reached via wrapper.ctx
    if (plane_idx >= 4) return;
    const wrapper: *ParamsWrapper = @ptrCast(@alignCast(resource.user_data orelse return));
    const modifier: u64 = (@as(u64, modifier_hi) << 32) | @as(u64, modifier_lo);
    // FIX I1: if this plane slot already has an fd (re-add), close the old one first.
    if (wrapper.accum.planes[plane_idx]) |existing| {
        _ = std.os.linux.close(existing.fd);
    }
    wrapper.accum.planes[plane_idx] = .{
        .fd = fd,
        .offset = offset,
        .stride = stride,
        .modifier = modifier,
    };
    wrapper.accum.count += 1;
}

/// Shared logic for create and create_immed: validate, build DmabufClientBuffer,
/// register the wl_buffer object. Returns the buffer object id on success or 0.
/// On format/plane failure calls sendFailed and returns 0.
/// Ownership of plane0.fd transfers to the DmabufClientBuffer in the map;
/// the remaining plane fds (planes 1-3) are closed here to avoid leaks.
fn commitParams(
    params_res: *Object,
    buffer_object_id: u32,
    width: i32,
    height: i32,
    format: u32,
) bool {
    const wrapper: *ParamsWrapper = @ptrCast(@alignCast(params_res.user_data orelse {
        ld.ZwpLinuxBufferParamsV1.sendFailed(params_res);
        return false;
    }));
    const accum = &wrapper.accum;
    const gpa = wrapper.gpa;
    // Get ctx from wrapper (client_data in create/create_immed is the wrapper itself).
    const ctx = wrapper.ctx;
    const comp = getCompositor(ctx);

    const plane0 = accum.planes[0] orelse {
        // FIX I3: close any extra plane fds before rejecting.
        closeAllPlaneFds(accum);
        ld.ZwpLinuxBufferParamsV1.sendFailed(params_res);
        return false;
    };

    if (!isSupportedFormat(format, plane0.modifier)) {
        // FIX I3: close all accumulated fds on unsupported format/modifier.
        closeAllPlaneFds(accum);
        ld.ZwpLinuxBufferParamsV1.sendFailed(params_res);
        return false;
    }

    if (width <= 0 or height <= 0) {
        // FIX I3: close all accumulated fds on bad dimensions.
        closeAllPlaneFds(accum);
        ld.ZwpLinuxBufferParamsV1.sendFailed(params_res);
        return false;
    }

    const buf_res = Object.create(
        params_res.client,
        &wlp.WlBuffer.interface,
        params_res.version,
        buffer_object_id,
    ) catch {
        // FIX I3: close all fds when we can't create the buffer object.
        closeAllPlaneFds(accum);
        ld.ZwpLinuxBufferParamsV1.sendFailed(params_res);
        return false;
    };

    const dbuf = DmabufClientBuffer{
        .fd = plane0.fd,
        .width = @intCast(width),
        .height = @intCast(height),
        .stride = plane0.stride,
        .format = format,
        .modifier = plane0.modifier,
    };

    // Key by (owning client, wl_buffer object id): object ids are only unique
    // per client, so two hosted clients can register a wl_buffer at the same id
    // without colliding. buf_res is the wl_buffer we just created on this client.
    comp.dmabuf_buffers.put(gpa, .{ .client = buf_res.client, .id = buf_res.id }, dbuf) catch {
        // FIX C1: put() OOM -- fd not yet transferred to map, so close plane0 fd
        // then close any remaining plane fds, then destroy the buffer object.
        _ = std.os.linux.close(plane0.fd);
        accum.planes[0] = null;
        closeAllPlaneFds(accum);
        buf_res.destroy();
        ld.ZwpLinuxBufferParamsV1.sendFailed(params_res);
        return false;
    };

    wlp.WlBuffer.setImplementation(buf_res, &ctx.buffer_impl, ctx, dmabufBufferResourceDestroyed);

    // Null out plane0 fd in accum so onParamsDestroy does not double-close it.
    accum.planes[0] = null;

    // Close any extra plane fds that were accumulated but are not used.
    for (accum.planes[1..]) |*slot| {
        if (slot.*) |p| {
            _ = linux.close(p.fd);
            slot.* = null;
        }
    }

    return true;
}

/// Async create: server allocates a new server-side id for the wl_buffer,
/// creates it, then sends the id back to the client via sendCreated.
fn onCreate(
    client_data: ?*anyopaque,
    resource: *Object,
    width: i32,
    height: i32,
    format: u32,
    flags: u32,
) void {
    _ = flags;
    _ = client_data; // ctx reached via wrapper.ctx inside commitParams
    const buffer_object_id = resource.client.allocServerId();
    if (!commitParams(resource, buffer_object_id, width, height, format)) return;
    ld.ZwpLinuxBufferParamsV1.sendCreated(resource, buffer_object_id);
}

/// Immediate create: client supplies the buffer id inline in the request.
fn onCreateImmed(
    client_data: ?*anyopaque,
    resource: *Object,
    buffer_id: u32,
    width: i32,
    height: i32,
    format: u32,
    flags: u32,
) void {
    _ = flags;
    _ = client_data; // ctx reached via wrapper.ctx inside commitParams
    _ = commitParams(resource, buffer_id, width, height, format);
}

// ---------------------------------------------------------------------------
// wl_buffer destroy for a dma-buf backed buffer (Task 3 teardown, Task 4 mmap)
// ---------------------------------------------------------------------------

fn onDmabufBufferDestroy(client_data: ?*anyopaque, resource: *Object) void {
    _ = client_data;
    resource.destroy();
}

fn dmabufBufferResourceDestroyed(resource: *Object) void {
    const ctx = getCtx(resource.user_data);
    const comp = getCompositor(ctx);
    // Remove by the composite (client, id) key so a destroy on one client's
    // wl_buffer does not evict another client's buffer registered at the same id.
    if (comp.dmabuf_buffers.fetchRemove(.{ .client = resource.client, .id = resource.id })) |kv| {
        const dbuf = kv.value;
        // Munmap cached mapping if present (set lazily on commit in Task 4).
        if (dbuf.mapping) |m| {
            posix.munmap(m);
        }
        _ = linux.close(dbuf.fd);
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "FormatTableEntry: @sizeOf == 16" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 16), @sizeOf(FormatTableEntry));
}

test "FormatTableEntry: field offsets" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), @offsetOf(FormatTableEntry, "format"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(FormatTableEntry, "modifier"));
}

test "isSupportedFormat: ARGB8888 + LINEAR -> true" {
    const testing = std.testing;
    try testing.expect(isSupportedFormat(0x34325241, 0)); // ARGB8888, LINEAR
    try testing.expect(isSupportedFormat(0x34325258, 0)); // XRGB8888, LINEAR
    try testing.expect(isSupportedFormat(0x48344241, 0)); // ABGR16161616F (HDR fp16), LINEAR
    try testing.expect(!isSupportedFormat(0x48344241, 1)); // ABGR16161616F, non-LINEAR
    try testing.expect(!isSupportedFormat(0x34325241, 1)); // ARGB8888, non-LINEAR
    try testing.expect(!isSupportedFormat(0x34325258, 0xDEADBEEF00000000)); // nonzero modifier
    try testing.expect(!isSupportedFormat(0x48344142, 0)); // AB4H fourcc, not supported
    try testing.expect(!isSupportedFormat(0, 0)); // unknown format
}

test "FormatTableEntry: three-entry byte layout (ARGB8888 + XRGB8888 + ABGR16161616F at modifier=0)" {
    const testing = std.testing;
    const entries = [3]FormatTableEntry{
        .{ .format = 0x34325241, .modifier = 0 }, // ARGB8888, LINEAR
        .{ .format = 0x34325258, .modifier = 0 }, // XRGB8888, LINEAR
        .{ .format = 0x48344241, .modifier = 0 }, // ABGR16161616F (HDR fp16), LINEAR
    };
    // Three 16-byte entries pack to exactly 48 bytes.
    try testing.expectEqual(@as(usize, 48), @sizeOf(@TypeOf(entries)));
    const bytes = std.mem.sliceAsBytes(entries[0..]);

    // Entry 0: format 0x34325241 in little-endian at bytes [0..4]
    try testing.expectEqual(@as(u8, 0x41), bytes[0]);
    try testing.expectEqual(@as(u8, 0x52), bytes[1]);
    try testing.expectEqual(@as(u8, 0x32), bytes[2]);
    try testing.expectEqual(@as(u8, 0x34), bytes[3]);
    // Entry 0: modifier 0 at bytes [8..16]
    for (bytes[8..16]) |b| try testing.expectEqual(@as(u8, 0), b);

    // Entry 1: format 0x34325258 in little-endian at bytes [16..20]
    try testing.expectEqual(@as(u8, 0x58), bytes[16]);
    try testing.expectEqual(@as(u8, 0x52), bytes[17]);
    try testing.expectEqual(@as(u8, 0x32), bytes[18]);
    try testing.expectEqual(@as(u8, 0x34), bytes[19]);
    // Entry 1: modifier 0 at bytes [24..32]
    for (bytes[24..32]) |b| try testing.expectEqual(@as(u8, 0), b);

    // Entry 2: format 0x48344241 (ABGR16161616F) in little-endian at bytes [32..36]
    try testing.expectEqual(@as(u8, 0x41), bytes[32]);
    try testing.expectEqual(@as(u8, 0x42), bytes[33]);
    try testing.expectEqual(@as(u8, 0x34), bytes[34]);
    try testing.expectEqual(@as(u8, 0x48), bytes[35]);
    // Entry 2: modifier 0 at bytes [40..48]
    for (bytes[40..48]) |b| try testing.expectEqual(@as(u8, 0), b);
}
