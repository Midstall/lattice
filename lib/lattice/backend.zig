const std = @import("std");
const id = @import("id.zig");
const color = @import("color.zig");
const surface = @import("surface.zig");
const output = @import("output.zig");
const event = @import("event.zig");
const prism = @import("prism");

/// Coarse backend-wide capability hint. Per-output HDR truth lives in Output.hdr (HdrCaps);
/// a multi-output system may have HDR on some outputs only, so treat this hdr bool as advisory.
pub const Capabilities = struct {
    hdr: bool,
    formats: []const color.PixelFormat,
};

/// A single axis-aligned rectangle used to bound a pointer constraint region.
/// A null region passed in PointerConstraintReq means "use the full surface bounds".
pub const Region = struct { x: i32, y: i32, width: u32, height: u32 };

/// Request to apply or clear a pointer constraint on the real (backend) pointer.
/// kind=none clears any active constraint; lock/confine are forwarded by the nested
/// wayland backend to the parent compositor; KMS and headless no-op all of these.
pub const PointerConstraintReq = struct {
    kind: enum { none, lock, confine },
    region: ?Region,
};

/// Called by a backend for each ready event during `pump`. The pointer is the
/// opaque sink context passed through unchanged; no allocation happens on this path.
pub const EventSink = *const fn (ctx: *anyopaque, ev: event.Event) void;

pub const VTable = struct {
    createSurface: *const fn (self: *anyopaque, desc: surface.SurfaceDesc) anyerror!surface.Surface,
    destroySurface: *const fn (self: *anyopaque, s: id.SurfaceId) void,
    surfaceRenderTarget: *const fn (self: *anyopaque, s: id.SurfaceId) anyerror!surface.RenderTarget,
    commitFrame: *const fn (self: *anyopaque, s: id.SurfaceId) anyerror!void,
    renderAvailable: *const fn (self: *anyopaque, s: id.SurfaceId) bool,
    enumerateOutputs: *const fn (self: *anyopaque) []const output.Output,
    capabilities: *const fn (self: *anyopaque) Capabilities,
    /// The seat's device classes as of now. Must be answerable at any time,
    /// including before the first pump, because a shell picks its first layout
    /// from it. Backends with no seat concept report a fixed, documented value.
    seatCapabilities: *const fn (self: *anyopaque) event.SeatCapabilities,
    /// Dispatch ready events to the sink. Timeout contract every backend must honor:
    ///   timeout_ms == null  -> block until at least one event is dispatched or wakeup() fires
    ///   timeout_ms == 0     -> dispatch already-ready events and return immediately (the mock's mode)
    ///   timeout_ms == N      -> block up to N milliseconds, dispatching whatever arrives
    pump: *const fn (self: *anyopaque, timeout_ms: ?u32, sink: EventSink, sink_ctx: *anyopaque) anyerror!void,
    /// Interrupt a pump() that is blocked (timeout null or N). Must be safe to call while
    /// another thread is blocked inside pump(). For real backends this is an eventfd/pipe self-write.
    wakeup: *const fn (self: *anyopaque) void,
    /// The pollable fd a host event loop may watch to know when to call pump(), or null for
    /// backends with no single fd (headless/macOS/Android drive everything through pump()).
    fd: *const fn (self: *anyopaque) ?std.posix.fd_t,
    renderDevice: *const fn (self: *anyopaque) ?*prism.Device,
    /// Apply/clear a pointer constraint on the real (backend) pointer. Nested
    /// forwards to the parent (lock/confine/destroy); KMS + headless no-op.
    applyPointerConstraint: *const fn (self: *anyopaque, req: PointerConstraintReq) void,
    deinit: *const fn (self: *anyopaque) void,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn createSurface(self: Backend, desc: surface.SurfaceDesc) !surface.Surface {
        return self.vtable.createSurface(self.ptr, desc);
    }
    pub fn destroySurface(self: Backend, s: id.SurfaceId) void {
        self.vtable.destroySurface(self.ptr, s);
    }
    pub fn surfaceRenderTarget(self: Backend, s: id.SurfaceId) !surface.RenderTarget {
        return self.vtable.surfaceRenderTarget(self.ptr, s);
    }
    pub fn commitFrame(self: Backend, s: id.SurfaceId) !void {
        return self.vtable.commitFrame(self.ptr, s);
    }
    pub fn renderAvailable(self: Backend, s: id.SurfaceId) bool {
        return self.vtable.renderAvailable(self.ptr, s);
    }
    pub fn enumerateOutputs(self: Backend) []const output.Output {
        return self.vtable.enumerateOutputs(self.ptr);
    }
    pub fn capabilities(self: Backend) Capabilities {
        return self.vtable.capabilities(self.ptr);
    }
    pub fn seatCapabilities(self: Backend) event.SeatCapabilities {
        return self.vtable.seatCapabilities(self.ptr);
    }
    pub fn pump(self: Backend, timeout_ms: ?u32, sink: EventSink, sink_ctx: *anyopaque) !void {
        return self.vtable.pump(self.ptr, timeout_ms, sink, sink_ctx);
    }
    pub fn wakeup(self: Backend) void {
        self.vtable.wakeup(self.ptr);
    }
    pub fn fd(self: Backend) ?std.posix.fd_t {
        return self.vtable.fd(self.ptr);
    }
    pub fn renderDevice(self: Backend) ?*prism.Device {
        return self.vtable.renderDevice(self.ptr);
    }
    pub fn applyPointerConstraint(self: Backend, req: PointerConstraintReq) void {
        self.vtable.applyPointerConstraint(self.ptr, req);
    }
    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
};

test "backend forwards calls to a trivial vtable impl" {
    const Stub = struct {
        var last_destroyed: u32 = 0;
        fn createSurface(_: *anyopaque, desc: surface.SurfaceDesc) anyerror!surface.Surface {
            return .{ .id = id.SurfaceId.from(42), .desc = desc };
        }
        fn destroySurface(_: *anyopaque, s: id.SurfaceId) void {
            last_destroyed = s.value();
        }
        fn surfaceRenderTarget(_: *anyopaque, _: id.SurfaceId) anyerror!surface.RenderTarget {
            return error.Unsupported;
        }
        fn commitFrame(_: *anyopaque, _: id.SurfaceId) anyerror!void {}
        fn renderAvailable(_: *anyopaque, _: id.SurfaceId) bool {
            return true;
        }
        fn enumerateOutputs(_: *anyopaque) []const output.Output {
            return &.{};
        }
        fn capabilities(_: *anyopaque) Capabilities {
            return .{ .hdr = false, .formats = &.{} };
        }
        fn seatCapabilities(_: *anyopaque) event.SeatCapabilities {
            return .{ .pointer = true, .keyboard = false, .touch = true };
        }
        fn pump(_: *anyopaque, _: ?u32, sink: EventSink, sink_ctx: *anyopaque) anyerror!void {
            sink(sink_ctx, .{ .close_requested = id.SurfaceId.from(99) });
        }
        fn wakeup(_: *anyopaque) void {}
        fn fd(_: *anyopaque) ?std.posix.fd_t {
            return null;
        }
        fn renderDevice(_: *anyopaque) ?*prism.Device {
            return null;
        }
        fn applyPointerConstraint(_: *anyopaque, _: PointerConstraintReq) void {}
        fn deinit(_: *anyopaque) void {}
        const vtable = VTable{
            .createSurface = createSurface,
            .destroySurface = destroySurface,
            .surfaceRenderTarget = surfaceRenderTarget,
            .commitFrame = commitFrame,
            .renderAvailable = renderAvailable,
            .enumerateOutputs = enumerateOutputs,
            .capabilities = capabilities,
            .seatCapabilities = seatCapabilities,
            .pump = pump,
            .wakeup = wakeup,
            .fd = fd,
            .renderDevice = renderDevice,
            .applyPointerConstraint = applyPointerConstraint,
            .deinit = deinit,
        };
    };

    const Collector = struct {
        var received_close_count: u32 = 0;
        var received_surface_id: u32 = 0;
        fn sink(_: *anyopaque, ev: event.Event) void {
            if (ev == .close_requested) {
                received_close_count += 1;
                received_surface_id = ev.close_requested.value();
            }
        }
    };

    var dummy: u8 = 0;
    const b = Backend{ .ptr = &dummy, .vtable = &Stub.vtable };
    const s = try b.createSurface(.{ .color = color.ColorConfig.sdr(.xrgb8888) });
    try std.testing.expectEqual(@as(u32, 42), s.id.value());
    try std.testing.expect(b.renderAvailable(s.id));
    b.destroySurface(s.id);
    try std.testing.expectEqual(@as(u32, 42), Stub.last_destroyed);

    Collector.received_close_count = 0;
    Collector.received_surface_id = 0;
    try b.pump(null, Collector.sink, &dummy);
    try std.testing.expectEqual(@as(u32, 1), Collector.received_close_count);
    try std.testing.expectEqual(@as(u32, 99), Collector.received_surface_id);

    b.wakeup();
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), b.fd());

    const seat = b.seatCapabilities();
    try std.testing.expectEqual(true, seat.pointer);
    try std.testing.expectEqual(false, seat.keyboard);
    try std.testing.expectEqual(true, seat.touch);
}

test "applyPointerConstraint is callable on a backend (no-op default)" {
    const Stub = struct {
        fn createSurface(_: *anyopaque, desc: surface.SurfaceDesc) anyerror!surface.Surface {
            return .{ .id = id.SurfaceId.from(1), .desc = desc };
        }
        fn destroySurface(_: *anyopaque, _: id.SurfaceId) void {}
        fn surfaceRenderTarget(_: *anyopaque, _: id.SurfaceId) anyerror!surface.RenderTarget {
            return error.Unsupported;
        }
        fn commitFrame(_: *anyopaque, _: id.SurfaceId) anyerror!void {}
        fn renderAvailable(_: *anyopaque, _: id.SurfaceId) bool {
            return false;
        }
        fn enumerateOutputs(_: *anyopaque) []const output.Output {
            return &.{};
        }
        fn capabilities(_: *anyopaque) Capabilities {
            return .{ .hdr = false, .formats = &.{} };
        }
        fn seatCapabilities(_: *anyopaque) event.SeatCapabilities {
            return .{};
        }
        fn pump(_: *anyopaque, _: ?u32, _: EventSink, _: *anyopaque) anyerror!void {}
        fn wakeup(_: *anyopaque) void {}
        fn fd(_: *anyopaque) ?std.posix.fd_t {
            return null;
        }
        fn renderDevice(_: *anyopaque) ?*prism.Device {
            return null;
        }
        fn applyPointerConstraint(_: *anyopaque, _: PointerConstraintReq) void {}
        fn deinit(_: *anyopaque) void {}
        const vtable = VTable{
            .createSurface = createSurface,
            .destroySurface = destroySurface,
            .surfaceRenderTarget = surfaceRenderTarget,
            .commitFrame = commitFrame,
            .renderAvailable = renderAvailable,
            .enumerateOutputs = enumerateOutputs,
            .capabilities = capabilities,
            .seatCapabilities = seatCapabilities,
            .pump = pump,
            .wakeup = wakeup,
            .fd = fd,
            .renderDevice = renderDevice,
            .applyPointerConstraint = applyPointerConstraint,
            .deinit = deinit,
        };
    };

    var dummy: u8 = 0;
    const b = Backend{ .ptr = &dummy, .vtable = &Stub.vtable };
    b.applyPointerConstraint(.{ .kind = .none, .region = null });
    b.applyPointerConstraint(.{ .kind = .lock, .region = .{ .x = 0, .y = 0, .width = 800, .height = 600 } });
}
