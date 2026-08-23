//! ShmBuffer: memfd-backed wl_shm_pool + wl_buffer for a Wayland client.
//!
//! Usage:
//!   1. Call `create(conn, shm_id, imap, gpa, width, height)` to allocate.
//!   2. Write XRGB8888 pixels into `buf.data`.
//!   3. attach + damage + commit the buffer_id on the wl_surface.
//!   4. Set `busy = true` on commit; clear it when wl_buffer.release fires.
//!   5. Call `destroy(conn)` when the surface goes away.
//!
//! The fd is passed to the compositor via SCM_RIGHTS ancillary data using
//! `@import("wayland").shm.sendFd`. The generated `WlShm.createPool` writes a 0
//! placeholder word in the wire buffer and discards the fd arg (see
//! wayland_protocol.zig WlShm.createPool: `_ = fd;`), so we must call
//! `sendFd` ourselves instead of `conn.sendMessage`.
//!
//! NOTE: `std.posix.memfd_create` is used for the anonymous fd. `std.posix.close`
//! and ftruncate are done via `std.os.linux` syscalls (std.posix.close was
//! removed in 0.16).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const wl = @import("wayland");
const wlp = @import("wayland_protocol");

const client = wl.client;

/// DRM fourcc for a 64bpp RGBA half-float (fp16, ABGR16161616F) shm buffer.
/// wl_shm sends non-ARGB/XRGB formats as their raw DRM fourcc value, so this
/// is the `format` word passed to create_buffer for the HDR path.
pub const FOURCC_ABGR16161616F: u32 = 0x48344241;

// --------------------------------------------------------------------------
// Pure helpers (unit tested below)
// --------------------------------------------------------------------------

/// Bytes per row for a 32bpp (XRGB8888) image of `width` pixels.
pub fn strideFor(width: u32) u32 {
    return width * 4;
}

/// Bytes per row for a 64bpp (RGBA fp16, ABGR16161616F) image of `width` pixels.
pub fn strideForHdr(width: u32) u32 {
    return width * 8;
}

/// Total bytes needed for a pool backing a single XRGB8888 frame.
pub fn poolBytes(width: u32, height: u32) usize {
    return @as(usize, strideFor(width)) * @as(usize, height);
}

/// Total bytes needed for a pool backing a single RGBA fp16 (8bpp) frame.
pub fn poolBytesHdr(width: u32, height: u32) usize {
    return @as(usize, strideForHdr(width)) * @as(usize, height);
}

/// Pure f32 -> IEEE-754 half (fp16) bit pattern.
/// `f16` is a native Zig type, so the round-to-nearest conversion and the
/// 16-bit bit pattern come straight from the compiler. Returns the raw u16
/// which the caller writes little-endian into the buffer.
pub fn f32ToF16Bits(x: f32) u16 {
    return @bitCast(@as(f16, @floatCast(x)));
}

/// Write one RGBA fp16 texel (4 channels, little-endian u16 each = 8 bytes)
/// into `dst` at byte offset `off`. `dst.len` must be >= off + 8.
fn writeHdrTexel(dst: []u8, off: usize, r: f32, g: f32, b: f32, a: f32) void {
    std.mem.writeInt(u16, dst[off + 0 ..][0..2], f32ToF16Bits(r), .little);
    std.mem.writeInt(u16, dst[off + 2 ..][0..2], f32ToF16Bits(g), .little);
    std.mem.writeInt(u16, dst[off + 4 ..][0..2], f32ToF16Bits(b), .little);
    std.mem.writeInt(u16, dst[off + 6 ..][0..2], f32ToF16Bits(a), .little);
}

/// Pack one rgb10a2 texel (10/10/10/2) into a little-endian u32 dword:
/// R[9:0] G[19:10] B[29:20] A[31:30]. Inputs are treated as 10-bit (0..1023)
/// / 2-bit (0..3) integer channel values.
pub fn pack10bit(r: u32, g: u32, b: u32, a: u32) u32 {
    return (r & 0x3FF) | ((g & 0x3FF) << 10) | ((b & 0x3FF) << 20) | ((a & 0x3) << 30);
}

/// CPU-fill a 10-bit HDR10 demo pattern into an rgb10a2 buffer, respecting
/// `stride` (bytes/row, = width*4). Left half BRIGHT R=1023 (max 10-bit, an
/// SDR rgba8 R could never exceed 255 - that >255 value is the HDR-format
/// proof); right half a dim (256,128,64). A=3 (opaque). Pure.
pub fn fill10bitDemo(dst: []u8, width: u32, height: u32, stride: u32) void {
    const half = width / 2;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = @as(usize, y) * @as(usize, stride);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const off = row + @as(usize, x) * 4;
            const dword: u32 = if (x < half) pack10bit(1023, 1023, 1023, 3) else pack10bit(256, 128, 64, 3);
            std.mem.writeInt(u32, dst[off..][0..4], dword, .little);
        }
    }
}

/// CPU-fill an HDR demo pattern into an RGBA fp16 buffer, respecting `stride`
/// (bytes per row). The left half is superwhite (4.0, 4.0, 4.0, 1.0) carrying
/// channel values > 1.0; the right half is a dim (0.5, 0.2, 0.1, 1.0). Pure:
/// operates only on the passed slice, no allocation or I/O.
pub fn fillHdrDemo(dst: []u8, width: u32, height: u32, stride: u32) void {
    const half = width / 2;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = @as(usize, y) * @as(usize, stride);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const off = row + @as(usize, x) * 8;
            if (x < half) {
                writeHdrTexel(dst, off, 4.0, 4.0, 4.0, 1.0);
            } else {
                writeHdrTexel(dst, off, 0.5, 0.2, 0.1, 1.0);
            }
        }
    }
}

// --------------------------------------------------------------------------
// ShmBuffer
// --------------------------------------------------------------------------

pub const ShmBuffer = struct {
    fd: posix.fd_t,
    data: []align(std.heap.page_size_min) u8,
    pool_id: u32,
    buffer_id: u32,
    width: u32,
    height: u32,
    stride: u32,
    busy: bool,

    /// Create a wl_shm_pool + wl_buffer backed by a fresh memfd (SDR XRGB8888).
    ///
    /// `conn`   - live client.Connection (socket must be writable).
    /// `shm_id` - bound wl_shm object id.
    /// `imap`   - InterfaceMap to register pool_id and buffer_id.
    /// `gpa`    - allocator for the wire writer scratch buffers.
    /// `width`, `height` - frame dimensions in pixels.
    pub fn create(
        conn: *client.Connection,
        shm_id: u32,
        imap: *client.InterfaceMap,
        gpa: std.mem.Allocator,
        width: u32,
        height: u32,
    ) !ShmBuffer {
        return createWithFormat(
            conn,
            shm_id,
            imap,
            gpa,
            width,
            height,
            @intFromEnum(wlp.WlShm.Format.xrgb8888), // 1
            strideFor(width),
        );
    }

    /// Create an HDR RGBA fp16 (ABGR16161616F, 8bpp) wl_shm_pool + wl_buffer.
    /// The pool is sized to width*8 * height and the create_buffer format word
    /// carries the raw DRM fourcc 0x48344241 (wl_shm sends non-ARGB/XRGB
    /// formats as their fourcc). The caller CPU-fills fp16 pixels into `data`.
    pub fn createHdr(
        conn: *client.Connection,
        shm_id: u32,
        imap: *client.InterfaceMap,
        gpa: std.mem.Allocator,
        width: u32,
        height: u32,
    ) !ShmBuffer {
        return createWithFormat(
            conn,
            shm_id,
            imap,
            gpa,
            width,
            height,
            FOURCC_ABGR16161616F,
            strideForHdr(width),
        );
    }

    /// Create a wl_shm_pool + wl_buffer with an explicit wl_shm `format` word
    /// (fourcc) and `stride`. The pool memfd is sized to stride*height. This is
    /// the shared implementation behind `create` (SDR) and `createHdr` (fp16).
    pub fn createWithFormat(
        conn: *client.Connection,
        shm_id: u32,
        imap: *client.InterfaceMap,
        gpa: std.mem.Allocator,
        width: u32,
        height: u32,
        format: u32,
        stride: u32,
    ) !ShmBuffer {
        const size = @as(usize, stride) * @as(usize, height);

        // 1. Create an anonymous in-memory file.
        const fd = try posix.memfd_create("lattice-shm", 0);
        errdefer closeFd(fd);

        // 2. Set its size.
        try ftruncate(fd, @intCast(size));

        // 3. Map it read-write into our address space.
        const data = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);

        // 4. Send wl_shm.create_pool.
        //
        // The Wayland wire protocol says fd arguments are NOT written inline in the
        // message payload; they are sent ONLY as SCM_RIGHTS ancillary data. The
        // generated wlp.WlShm.createPool incorrectly writes a 4-byte placeholder
        // word for the fd, which corrupts the wire stream when talking to standard
        // libwayland-server compositors (cosmic-comp, sway, kwin, etc.).
        //
        // We build the message manually: header (via begin) + new_id (pool_id) +
        // int (size). No fd word in the payload. The real fd is sent out-of-band
        // via sendFd (SCM_RIGHTS). This matches what libwayland-client sends.
        const pool_id = conn.objects.allocId();
        try imap.set(pool_id, &wlp.WlShmPool.interface);

        const wl_wire = wl.wire;
        var pool_writer = wl_wire.Writer.init();
        defer pool_writer.deinit(gpa);
        try pool_writer.begin(gpa, shm_id, 0); // create_pool opcode = 0
        try pool_writer.writeNewId(gpa, pool_id);
        try pool_writer.writeInt(gpa, @intCast(size));
        const pool_msg = pool_writer.finish();

        // Send wire bytes + fd in one sendmsg call (SCM_RIGHTS).
        try wl.shm.sendFd(conn.stream.socket.handle, pool_msg, fd);

        // 5. Send wl_shm_pool.create_buffer using the connection's wire_writer.
        const buffer_id = conn.objects.allocId();
        try imap.set(buffer_id, &wlp.WlBuffer.interface);

        const cw = &conn.wire_writer;
        try wlp.WlShmPool.createBuffer(
            cw,
            gpa,
            pool_id,
            buffer_id,
            0, // offset
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            format,
        );
        try conn.sendMessage(cw.finish());

        return ShmBuffer{
            .fd = fd,
            .data = data,
            .pool_id = pool_id,
            .buffer_id = buffer_id,
            .width = width,
            .height = height,
            .stride = stride,
            .busy = false,
        };
    }

    /// Destroy the wl_buffer and wl_shm_pool, unmap and close the fd.
    pub fn destroy(self: *ShmBuffer, conn: *client.Connection, gpa: std.mem.Allocator) !void {
        var w = &conn.wire_writer;

        // Destroy the wl_buffer first.
        try wlp.WlBuffer.destroy(w, gpa, self.buffer_id);
        try conn.sendMessage(w.finish());

        // Destroy the wl_shm_pool.
        try wlp.WlShmPool.destroy(w, gpa, self.pool_id);
        try conn.sendMessage(w.finish());

        posix.munmap(self.data);
        closeFd(self.fd);
        self.* = undefined;
    }
};

// --------------------------------------------------------------------------
// Syscall helpers (std.posix.close / ftruncate removed in 0.16)
// --------------------------------------------------------------------------

fn closeFd(fd: posix.fd_t) void {
    _ = linux.close(fd);
}

fn ftruncate(fd: posix.fd_t, length: i64) !void {
    const rc = linux.ftruncate(fd, length);
    if (linux.errno(rc) != .SUCCESS) return error.TruncateFailed;
}

// --------------------------------------------------------------------------
// Tests (pure helpers only; create/destroy require a live compositor)
// --------------------------------------------------------------------------

test "strideFor: 4 bytes per pixel" {
    try std.testing.expectEqual(@as(u32, 0), strideFor(0));
    try std.testing.expectEqual(@as(u32, 4), strideFor(1));
    try std.testing.expectEqual(@as(u32, 400), strideFor(100));
    try std.testing.expectEqual(@as(u32, 3200), strideFor(800));
}

test "poolBytes: stride * height" {
    try std.testing.expectEqual(@as(usize, 0), poolBytes(0, 0));
    try std.testing.expectEqual(@as(usize, 4), poolBytes(1, 1));
    try std.testing.expectEqual(@as(usize, 800 * 4 * 600), poolBytes(800, 600));
    // 1920x1080 XRGB8888
    try std.testing.expectEqual(@as(usize, 1920 * 4 * 1080), poolBytes(1920, 1080));
}

test "strideForHdr: 8 bytes per pixel" {
    try std.testing.expectEqual(@as(u32, 0), strideForHdr(0));
    try std.testing.expectEqual(@as(u32, 8), strideForHdr(1));
    try std.testing.expectEqual(@as(u32, 800 * 8), strideForHdr(800));
}

test "poolBytesHdr: strideHdr * height" {
    try std.testing.expectEqual(@as(usize, 8), poolBytesHdr(1, 1));
    try std.testing.expectEqual(@as(usize, 800 * 8 * 600), poolBytesHdr(800, 600));
}

test "f32ToF16Bits: known IEEE-754 half bit patterns" {
    try std.testing.expectEqual(@as(u16, 0x4400), f32ToF16Bits(4.0));
    try std.testing.expectEqual(@as(u16, 0x3C00), f32ToF16Bits(1.0));
    try std.testing.expectEqual(@as(u16, 0x3800), f32ToF16Bits(0.5));
    try std.testing.expectEqual(@as(u16, 0x0000), f32ToF16Bits(0.0));
}

test "fillHdrDemo: superwhite left, dim right, LE fp16 verbatim" {
    // 2x1 image: x=0 is left half (superwhite 4.0), x=1 is right half (0.5,0.2,0.1).
    const width: u32 = 2;
    const height: u32 = 1;
    const stride: u32 = strideForHdr(width);
    var buf: [16]u8 = undefined;
    fillHdrDemo(&buf, width, height, stride);

    // Left texel (offset 0): R=G=B=4.0 (0x4400), A=1.0 (0x3C00), little-endian.
    try std.testing.expectEqual(@as(u16, 0x4400), std.mem.readInt(u16, buf[0..2], .little)); // R
    try std.testing.expectEqual(@as(u16, 0x4400), std.mem.readInt(u16, buf[2..4], .little)); // G
    try std.testing.expectEqual(@as(u16, 0x4400), std.mem.readInt(u16, buf[4..6], .little)); // B
    try std.testing.expectEqual(@as(u16, 0x3C00), std.mem.readInt(u16, buf[6..8], .little)); // A

    // Right texel (offset 8): R=0.5 (0x3800), A=1.0 (0x3C00).
    try std.testing.expectEqual(@as(u16, 0x3800), std.mem.readInt(u16, buf[8..10], .little)); // R
    try std.testing.expectEqual(@as(u16, 0x3C00), std.mem.readInt(u16, buf[14..16], .little)); // A
}

test "pack10bit: R-only" {
    try std.testing.expectEqual(@as(u32, 0x3FF), pack10bit(1023, 0, 0, 0));
}

test "pack10bit: G-only" {
    try std.testing.expectEqual(@as(u32, 1023 << 10), pack10bit(0, 1023, 0, 0));
}

test "pack10bit: A-only" {
    try std.testing.expectEqual(@as(u32, 3 << 30), pack10bit(0, 0, 0, 3));
}

test "pack10bit: all channels, B-only sanity" {
    try std.testing.expectEqual(@as(u32, 1023 << 20), pack10bit(0, 0, 1023, 0));
}

test "fill10bitDemo: left texel R=1023, right texel R=256" {
    // 4x1 image: left half = x<2, right half = x>=2.
    const width: u32 = 4;
    const height: u32 = 1;
    const stride: u32 = width * 4;
    var buf: [16]u8 = undefined;
    fill10bitDemo(&buf, width, height, stride);

    // Left texel (x=0): R=1023 in bits [9:0].
    const left_dword = std.mem.readInt(u32, buf[0..4], .little);
    try std.testing.expectEqual(@as(u32, 1023), left_dword & 0x3FF);

    // Right texel (x=2): R=256 in bits [9:0].
    const right_dword = std.mem.readInt(u32, buf[8..12], .little);
    try std.testing.expectEqual(@as(u32, 256), right_dword & 0x3FF);
}
