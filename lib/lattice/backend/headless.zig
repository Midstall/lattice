const std = @import("std");
const id = @import("../id.zig");
const color = @import("../color.zig");
const surface = @import("../surface.zig");
const output = @import("../output.zig");
const event = @import("../event.zig");
const backendMod = @import("../backend.zig");
const prism = @import("prism");

pub const Headless = struct {
    alloc: std.mem.Allocator,
    next_id: u32 = 1,
    surfaces: std.ArrayList(surface.Surface),
    outputs: []const output.Output = &.{},
    events: std.ArrayList(event.Event),
    render_available: bool = true,
    /// No real seat exists here. Headless stands in for a desktop-shaped target
    /// (offscreen rendering, CI, unit tests), so it reports the desktop pair and
    /// no touch. Tests that need another combination call setSeatCapabilities.
    seat_caps: event.SeatCapabilities = .{ .pointer = true, .keyboard = true, .touch = false },
    device: prism.Device,
    ctx: prism.Context,
    target: ?*prism.Resource = null,
    tw: u32 = 0,
    th: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) !*Headless {
        const self = try alloc.create(Headless);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .surfaces = .empty,
            .events = .empty,
            .device = undefined,
            .ctx = undefined,
        };

        const selected = prism.drivers.createBestDevice(alloc) orelse return error.NoWorkingDriver;
        self.device = selected.device;
        errdefer self.device.deinit();

        self.ctx = try self.device.createContext();
        return self;
    }

    pub fn setOutputs(self: *Headless, outs: []const output.Output) void {
        self.outputs = outs;
    }

    pub fn pushEvent(self: *Headless, ev: event.Event) !void {
        try self.events.append(self.alloc, ev);
    }

    pub fn setRenderAvailable(self: *Headless, v: bool) void {
        self.render_available = v;
    }

    /// Script the seat state. Does NOT emit an event: push a `.seat_capabilities`
    /// event too when a test needs the notification as well as the new state.
    pub fn setSeatCapabilities(self: *Headless, caps: event.SeatCapabilities) void {
        self.seat_caps = caps;
    }

    pub fn backend(self: *Headless) backendMod.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *Headless {
        return @ptrCast(@alignCast(ptr));
    }

    fn createSurface(ptr: *anyopaque, desc: surface.SurfaceDesc) anyerror!surface.Surface {
        const self = cast(ptr);
        const s = surface.Surface{ .id = id.SurfaceId.from(self.next_id), .desc = desc };
        self.next_id += 1;
        try self.surfaces.append(self.alloc, s);

        const w: u32 = if (desc.width != 0) desc.width else 800;
        const h: u32 = if (desc.height != 0) desc.height else 600;

        // Null the target BEFORE the fallible createResource: if it errors, deinit
        // must not double-free the already-destroyed old target.
        if (self.target) |old| {
            self.device.destroyResource(old);
            self.target = null;
        }
        self.target = try self.device.createResource(.{ .image = .{
            .width = w,
            .height = h,
            .format = .rgba8_unorm,
            .usage = .{ .render_target = true },
        } });
        self.tw = w;
        self.th = h;

        return s;
    }

    fn destroySurface(ptr: *anyopaque, sid: id.SurfaceId) void {
        const self = cast(ptr);
        var i: usize = 0;
        while (i < self.surfaces.items.len) : (i += 1) {
            if (self.surfaces.items[i].id == sid) {
                _ = self.surfaces.orderedRemove(i);
                return;
            }
        }
    }

    fn surfaceRenderTarget(ptr: *anyopaque, _: id.SurfaceId) anyerror!surface.RenderTarget {
        const self = cast(ptr);
        return .{
            .context = &self.ctx,
            .target = self.target orelse return error.NoSurface,
            .width = self.tw,
            .height = self.th,
            .format = .xrgb8888,
        };
    }

    fn commitFrame(_: *anyopaque, _: id.SurfaceId) anyerror!void {}

    fn renderAvailable(ptr: *anyopaque, _: id.SurfaceId) bool {
        return cast(ptr).render_available;
    }

    fn enumerateOutputs(ptr: *anyopaque) []const output.Output {
        return cast(ptr).outputs;
    }

    fn capabilities(_: *anyopaque) backendMod.Capabilities {
        return .{ .hdr = true, .formats = &.{ .xrgb8888, .rgba16_float } };
    }

    fn seatCapabilities(ptr: *anyopaque) event.SeatCapabilities {
        return cast(ptr).seat_caps;
    }

    fn pump(ptr: *anyopaque, _: ?u32, sink: backendMod.EventSink, sink_ctx: *anyopaque) anyerror!void {
        const self = cast(ptr);
        for (self.events.items) |ev| sink(sink_ctx, ev);
        self.events.clearRetainingCapacity();
    }

    fn wakeup(_: *anyopaque) void {}

    fn fd(_: *anyopaque) ?std.posix.fd_t {
        return null;
    }

    fn renderDevice(ptr: *anyopaque) ?*prism.Device {
        return &cast(ptr).device;
    }

    fn applyPointerConstraint(_: *anyopaque, _: backendMod.PointerConstraintReq) void {}

    fn deinitVt(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.target) |t| self.device.destroyResource(t);
        self.ctx.deinit();
        self.device.deinit();
        self.surfaces.deinit(self.alloc);
        self.events.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    const vtable = backendMod.VTable{
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
        .deinit = deinitVt,
    };
};

test "headless backend creates surfaces and drains scripted events" {
    const h = try Headless.init(std.testing.allocator);
    defer h.backend().deinit();
    const b = h.backend();

    const s = try b.createSurface(.{ .width = 640, .height = 480, .color = color.ColorConfig.sdr(.xrgb8888) });
    try std.testing.expectEqual(@as(u32, 1), s.id.value());

    const rt = try b.surfaceRenderTarget(s.id);
    try std.testing.expectEqual(@as(u32, 640), rt.width);
    try std.testing.expectEqual(@as(u32, 480), rt.height);

    try h.pushEvent(.{ .close_requested = s.id });

    const Collector = struct {
        var count: u32 = 0;
        fn sink(_: *anyopaque, ev: event.Event) void {
            if (ev == .close_requested) count += 1;
        }
    };
    Collector.count = 0;
    var dummy: u8 = 0;
    try b.pump(null, Collector.sink, &dummy);
    try std.testing.expectEqual(@as(u32, 1), Collector.count);
}

test "headless reports pointer and keyboard but no touch until scripted otherwise" {
    const h = try Headless.init(std.testing.allocator);
    defer h.backend().deinit();
    const b = h.backend();

    const before = b.seatCapabilities();
    try std.testing.expectEqual(true, before.pointer);
    try std.testing.expectEqual(true, before.keyboard);
    try std.testing.expectEqual(false, before.touch);

    h.setSeatCapabilities(.{ .pointer = false, .keyboard = false, .touch = true });
    const after = b.seatCapabilities();
    try std.testing.expectEqual(false, after.pointer);
    try std.testing.expectEqual(true, after.touch);
}

test "headless backend renderDevice returns the prism device" {
    const h = try Headless.init(std.testing.allocator);
    defer h.backend().deinit();
    const b = h.backend();
    try std.testing.expect(b.renderDevice() != null);
}

test "headless renders a clear color into its offscreen target (readback)" {
    const h = try Headless.init(std.testing.allocator);
    defer h.backend().deinit();
    const b = h.backend();

    const s = try b.createSurface(.{ .width = 4, .height = 4, .color = color.ColorConfig.sdr(.xrgb8888) });
    const rt = try b.surfaceRenderTarget(s.id);

    var cb = try rt.context.beginCommands();
    try cb.setRenderTarget(rt.target);
    try cb.clear(.{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 });
    try rt.context.submit(cb);
    cb.deinit();

    const dev = b.renderDevice().?;
    const px = try dev.mapResource(rt.target);
    try std.testing.expect(px.len >= 4);
    // Software driver clears to red; assert non-zero bytes (byte-order agnostic).
    var any: u8 = 0;
    for (px[0..4]) |byte| any |= byte;
    try std.testing.expect(any != 0);
    dev.unmapResource(rt.target);
}
