const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const id = @import("../id.zig");
const color = @import("../color.zig");
const surface = @import("../surface.zig");
const output = @import("../output.zig");
const event = @import("../event.zig");
const backendMod = @import("../backend.zig");
const options_mod = @import("../options.zig");
const format_map = @import("../format_map.zig");
const prism = @import("prism");

pub const device = @import("kms/device.zig");
pub const display = @import("kms/display.zig");
pub const enumerate = @import("kms/enumerate.zig");
pub const hdr = @import("kms/hdr.zig");
pub const scanout = @import("kms/scanout.zig");
pub const present = @import("kms/present.zig");
pub const session = @import("kms/session.zig");
pub const input = @import("kms/input.zig");

pub const Kms = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    session: *session.Session,
    dev: device.Device,
    device: prism.Device,
    virgl_dev: *prism.virgl.Device,
    ctx: prism.Context,
    disp: display.Display,
    chain: ?scanout.Chain = null,
    surf: ?surface.Surface = null,
    input: ?*input.Input = null,
    /// Input config captured from Options at init time, threaded to Input.open.
    input_config: options_mod.InputConfig = .{},
    front: u1 = 0,
    did_modeset: bool = false,
    pending_flip: bool = false,
    blobs: ?present.BlobIds = null,
    wake_fd: posix.fd_t,
    out_buf: [1]output.Output = undefined,
    next_surface_id: u32 = 1,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, device_path: []const u8, opts: options_mod.Options) !*Kms {
        // Resolve the card path: use the given one, or discover via udev if empty.
        const owned_path: ?[]const u8 = if (device_path.len == 0) try enumerate.pickDrmCard(gpa, io) else null;
        defer if (owned_path) |p| gpa.free(p);
        const path = owned_path orelse device_path;

        const sess = try session.Session.open(gpa, opts.vt_switch);
        errdefer sess.deinit();
        const drm_fd = try sess.openDevice(path);
        var dev = try device.Device.openWithFd(gpa, drm_fd);
        errdefer dev.deinit(); // no-op (owns_fd=false), harmless

        const pdev = try prism.virgl.createDevice(gpa, .{ .external_fd = drm_fd });
        errdefer pdev.deinit();

        const vdev = prism.virgl.deviceOf(pdev);

        const ctx = try pdev.createContext();
        errdefer ctx.deinit();

        const disp = try display.discover(&dev.node, gpa);

        // Create wakeup eventfd: use linux syscall directly (same pattern as wayland backend).
        const wakeup_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(wakeup_rc) != .SUCCESS) return error.EventfdFailed;
        const wake_fd: posix.fd_t = @intCast(wakeup_rc);
        errdefer _ = linux.close(wake_fd);

        const self = try gpa.create(Kms);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .session = sess,
            .dev = dev,
            .device = pdev,
            .virgl_dev = vdev,
            .ctx = ctx,
            .disp = disp,
            .wake_fd = wake_fd,
            .input_config = opts.input,
        };
        return self;
    }

    pub fn backend(self: *Kms) backendMod.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *Kms {
        return @ptrCast(@alignCast(ptr));
    }

    fn createSurface(ptr: *anyopaque, desc: surface.SurfaceDesc) anyerror!surface.Surface {
        const self = cast(ptr);

        // Pick a scanout-capable PixelFormat. virtio-gpu scanout is 4-byte-only, so
        // fp16 (rgba16_float, 8bpp) falls back to 10-bit argb2101010. Derive both the
        // prism format AND the DRM fourcc from the PixelFormat so the X-vs-A
        // distinction survives (a plain prism.Format round-trip would turn xrgb8888
        // into AR24, which KMS planes reject; xrgb8888 must scan out as XR24).
        const scan_pf: color.PixelFormat = if (desc.color.format == .rgba16_float) blk: {
            std.debug.print("kms: fp16 not scanout-capable on virtio-gpu, using 10-bit argb2101010 for scanout\n", .{});
            break :blk .argb2101010;
        } else desc.color.format;

        const scan_fmt = format_map.pixelFormatToPrism(scan_pf);
        const fourcc = format_map.pixelFormatToFourcc(scan_pf);

        self.chain = try scanout.allocChain(
            self.virgl_dev,
            &self.dev.node,
            self.disp.mode.hdisplay,
            self.disp.mode.vdisplay,
            scan_fmt,
            fourcc,
            0,
        );

        const sid = id.SurfaceId.from(self.next_surface_id);
        self.next_surface_id += 1;
        self.surf = .{ .id = sid, .desc = desc };

        if (self.input == null) {
            self.input = input.Input.open(
                self.gpa,
                self.io,
                self.session,
                sid,
                self.disp.mode.hdisplay,
                self.disp.mode.vdisplay,
                self.input_config,
            ) catch |e| blk: {
                std.log.warn("kms: input unavailable: {s}", .{@errorName(e)});
                break :blk null;
            };
        } else {
            self.input.?.setSurface(sid, self.disp.mode.hdisplay, self.disp.mode.vdisplay);
        }

        return self.surf.?;
    }

    fn destroySurface(_: *anyopaque, _: id.SurfaceId) void {}

    fn surfaceRenderTarget(ptr: *anyopaque, _: id.SurfaceId) anyerror!surface.RenderTarget {
        const self = cast(ptr);
        const back: u1 = 1 - self.front;
        const c = &self.chain.?;
        return .{
            .context = &self.ctx,
            .target = c.buffers[back].scanout.resource,
            .width = self.disp.mode.hdisplay,
            .height = self.disp.mode.vdisplay,
            .format = self.surf.?.desc.color.format,
        };
    }

    fn commitFrame(ptr: *anyopaque, _: id.SurfaceId) anyerror!void {
        const self = cast(ptr);
        if (!self.session.active) return;
        const back: u1 = 1 - self.front;
        const c = &self.chain.?;

        if (!self.did_modeset) {
            // A re-modeset (e.g. after a VT-switch resume) creates fresh mode/HDR
            // blobs; destroy the previous ones first so they don't leak in the DRM
            // object table on every resume.
            if (self.blobs) |b| {
                self.dev.node.destroyBlob(b.mode_blob) catch {};
                if (b.hdr_blob) |hb| self.dev.node.destroyBlob(hb) catch {};
                self.blobs = null;
            }
            const hdr_meta: ?hdr.HdrOutputMetadata = if (self.surf.?.desc.color.isHdr() and self.disp.hdr_caps.supported)
                hdr.buildMetadata(self.surf.?.desc.color)
            else
                null;
            self.blobs = try present.commitModeset(&self.dev.node, &self.disp, c.buffers[back].fb_id, hdr_meta);
            self.did_modeset = true;
            self.front = back;
        } else {
            try present.commitFlip(&self.dev.node, &self.disp, c.buffers[back].fb_id, back);
            self.pending_flip = true;
        }
    }

    fn renderAvailable(ptr: *anyopaque, _: id.SurfaceId) bool {
        return cast(ptr).session.active and !cast(ptr).pending_flip;
    }

    fn enumerateOutputs(ptr: *anyopaque) []const output.Output {
        const self = cast(ptr);
        self.out_buf[0] = .{
            .id = id.OutputId.from(1),
            .name = "kms-output",
            .width = self.disp.mode.hdisplay,
            .height = self.disp.mode.vdisplay,
            .refresh_mhz = self.disp.mode.vrefresh * 1000,
            .hdr = self.disp.hdr_caps,
        };
        return self.out_buf[0..1];
    }

    fn capabilities(ptr: *anyopaque) backendMod.Capabilities {
        const self = cast(ptr);
        return .{ .hdr = self.disp.hdr_caps.supported, .formats = &.{ .xrgb8888, .argb2101010 } };
    }

    /// Derived from the devices libinput has open. Before createSurface there is
    /// no Input yet, and a seat with nothing attached is a real state, so an empty
    /// answer is honest rather than a placeholder.
    fn seatCapabilities(ptr: *anyopaque) event.SeatCapabilities {
        const self = cast(ptr);
        const in = self.input orelse return .{};
        return in.seatCapabilities();
    }

    fn pump(ptr: *anyopaque, timeout_ms: ?u32, sink: backendMod.EventSink, sink_ctx: *anyopaque) anyerror!void {
        const self = cast(ptr);
        const timeout_i: i32 = if (timeout_ms) |t| @intCast(t) else -1;

        // Slot layout:
        //   0 = drm fd
        //   1 = session fd
        //   2 = wake eventfd
        //   3 = udev hotplug monitor fd (optional; only present when input != null
        //       and the monitor opened successfully)
        //   4+ = libinput device fds (up to 16)
        // A seat with more than 16 input devices is unusual; devices beyond 16 are
        // not polled this cycle (documented cap, not a silent truncation).
        var fds: [4 + 16]posix.pollfd = undefined;
        fds[0] = .{ .fd = self.dev.node.fd, .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = self.session.pollFd(), .events = linux.POLL.IN, .revents = 0 };
        fds[2] = .{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 };
        var nfds: usize = 3;
        var monitor_slot: ?usize = null;
        if (self.input) |in| {
            if (in.monitorFd()) |mfd| {
                fds[3] = .{ .fd = mfd, .events = linux.POLL.IN, .revents = 0 };
                monitor_slot = 3;
                nfds = 4;
            }
            nfds += in.pollFds(fds[nfds..]);
        }

        _ = try posix.poll(fds[0..nfds], timeout_i);

        if (fds[0].revents & linux.POLL.IN != 0) {
            if (present.drainEvents(&self.dev.node) catch null) |ud| {
                self.front = @intCast(ud & 1);
                self.pending_flip = false;
            }
        }

        if (fds[1].revents & linux.POLL.IN != 0) {
            const was_active = self.session.active;
            self.session.dispatch() catch {};
            if (was_active and !self.session.active) {
                self.pending_flip = false; // nothing in flight matters while paused
                sink(sink_ctx, .session_inactive);
            } else if (!was_active and self.session.active) {
                self.did_modeset = false; // force a fresh modeset on the next commitFrame
                sink(sink_ctx, .session_active);
            }
        }

        if (fds[2].revents & linux.POLL.IN != 0) {
            var discard: u64 = 0;
            const dbytes = std.mem.asBytes(&discard);
            _ = linux.read(self.wake_fd, dbytes.ptr, dbytes.len);
        }

        // Udev hotplug monitor: drain and open any newly added input devices.
        // A plugged-in mouse changes the seat, and nothing else in this pump would
        // tell the shell, so report the change here.
        if (self.input) |in| {
            if (monitor_slot) |ms| {
                if (fds[ms].revents & linux.POLL.IN != 0) {
                    const before = in.seatCapabilities();
                    in.handleHotplug();
                    const after = in.seatCapabilities();
                    if (!after.eql(before)) sink(sink_ctx, .{ .seat_capabilities = after });
                }
            }
        }

        // Input devices: drain if any input fd is readable.
        // Device fds start at slot 4 when the monitor is present, else at slot 3.
        if (self.input) |in| {
            const dev_start: usize = if (monitor_slot != null) 4 else 3;
            var any_input = false;
            var i: usize = dev_start;
            while (i < nfds) : (i += 1) {
                if (fds[i].revents & linux.POLL.IN != 0) any_input = true;
            }
            // An unplugged device is dropped inside drain (libinput sees ENODEV on
            // the read), so the seat is compared across the drain as well.
            if (any_input) {
                const before = in.seatCapabilities();
                in.drain(sink, sink_ctx);
                const after = in.seatCapabilities();
                if (!after.eql(before)) sink(sink_ctx, .{ .seat_capabilities = after });
            }
        }
    }

    fn wakeup(ptr: *anyopaque) void {
        const self = cast(ptr);
        const one: u64 = 1;
        const bytes = std.mem.asBytes(&one);
        _ = linux.write(self.wake_fd, bytes.ptr, bytes.len);
    }

    fn fd(ptr: *anyopaque) ?posix.fd_t {
        return cast(ptr).dev.node.fd;
    }

    fn renderDevice(ptr: *anyopaque) ?*prism.Device {
        return &cast(ptr).device;
    }

    fn applyPointerConstraint(_: *anyopaque, _: backendMod.PointerConstraintReq) void {}

    fn deinitVt(ptr: *anyopaque) void {
        const self = cast(ptr);
        // Teardown order: blobs and KMS FBs freed while fd is still valid and master.
        // virgl and drm node deinit before session.deinit which closes the fd last.
        if (self.blobs) |b| {
            self.dev.node.destroyBlob(b.mode_blob) catch {};
            if (b.hdr_blob) |hb| self.dev.node.destroyBlob(hb) catch {};
        }
        if (self.chain) |*c| scanout.destroyChain(&self.dev.node, self.device, c);
        self.ctx.deinit();
        self.device.deinit(); // virgl: does NOT close the fd
        self.dev.deinit(); // no-op now (session owns the fd + master)
        // Tear down input after drm node deinit but before session.deinit. The
        // session closes the fds last; libinput devices are non-owning so this
        // ordering ensures libinput stops using the fds before they close.
        if (self.input) |in| in.deinit();
        self.session.deinit(); // closeDevice (closes the DRM fd) + seat.close()
        _ = linux.close(self.wake_fd);
        self.gpa.destroy(self);
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

test {
    std.testing.refAllDecls(@This());
}
