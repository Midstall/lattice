const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const id = @import("../../id.zig");
const nev = @import("../../event.zig");
const libinput = @import("libinput");
const session = @import("session.zig");
const udev = @import("udev");
const backendMod = @import("../../backend.zig");
const options_mod = @import("../../options.zig");
const keyboard_mod = @import("../../keyboard.zig");

/// Map a lattice AccelProfile to the libinput filter.Profile tag.
/// Pure function, safe to call without hardware.
pub fn toLibinputProfile(p: options_mod.AccelProfile) libinput.filter.Profile {
    return switch (p) {
        .flat => .flat,
        .adaptive => .adaptive,
    };
}

/// Map a lattice ScrollMethod to the libinput pointer.ScrollMethod tag.
/// Pure function, safe to call without hardware.
pub fn toLibinputScrollMethod(m: options_mod.ScrollMethod) libinput.pointer.ScrollMethod {
    return switch (m) {
        .none => .none,
        .on_button_down => .on_button_down,
    };
}

/// Fold one probed device into the seat-wide answer. Anything that drives a
/// cursor counts as a pointer: a mouse and a trackpoint report relative motion,
/// a pen tablet reports absolute motion, and all three are fine pointing devices.
/// Touch comes from the libinput probe, which reports a touchscreen only for a
/// direct-input device, so a laptop touchpad stays a pointer and does not make
/// the seat look like a tablet.
pub fn foldSeatCapabilities(acc: nev.SeatCapabilities, caps: libinput.device.Caps) nev.SeatCapabilities {
    return .{
        .pointer = acc.pointer or caps.has_rel or caps.has_buttons or caps.is_tablet,
        .keyboard = acc.keyboard or caps.has_keys,
        .touch = acc.touch or caps.is_touchscreen,
    };
}

pub const Cursor = struct { x: f64 = 0, y: f64 = 0 };

/// Accumulate a relative delta into an absolute cursor, clamped to the output.
pub fn accumulate(c: Cursor, dx: f64, dy: f64, w: u32, h: u32) Cursor {
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    return .{
        .x = std.math.clamp(c.x + dx, 0, fw),
        .y = std.math.clamp(c.y + dy, 0, fh),
    };
}

fn mapButtonState(s: libinput.event.ButtonState) nev.ButtonState {
    return switch (s) {
        .pressed => .pressed,
        .released => .released,
    };
}

/// Extract the seat-global relative motion from a libinput pointer_motion.
/// Returns null for non-motion events.
pub fn relativeOf(ev: libinput.Event) ?nev.PointerRelative {
    return switch (ev) {
        .pointer_motion => |m| .{ .dx = m.dx, .dy = m.dy, .dx_unaccel = m.dx_unaccel, .dy_unaccel = m.dy_unaccel },
        else => null,
    };
}

pub const Input = struct {
    surface: id.SurfaceId,
    bounds_w: u32,
    bounds_h: u32,
    cursor: Cursor = .{},
    gpa: std.mem.Allocator = undefined,
    ctx: libinput.Context = undefined,
    sess: ?*session.Session = null,
    /// Input configuration applied to each device on open. Defaults match
    /// libinput's built-in defaults.
    input_config: options_mod.InputConfig = .{},
    /// udev Context kept alive for the monitor's lifetime (Linux-only).
    udev_ctx: if (builtin.os.tag == .linux) ?udev.Context else void =
        if (builtin.os.tag == .linux) null else {},
    /// Netlink monitor for runtime input hotplug (Linux-only, optional).
    monitor: if (builtin.os.tag == .linux) ?udev.Monitor else void =
        if (builtin.os.tag == .linux) null else {},
    /// The keymap and modifier state that turns evdev keycodes into keysyms.
    /// A bare evdev device has no compositor to ask, so the map comes from the
    /// XKB database with the embedded US fallback. The environment is NOT read
    /// today: lattice does not thread environ into its backends yet, and reading
    /// the process environment inside a library is the global-state pattern the
    /// embedders asked us to remove. Threading environ is the follow-up.
    keyboard: keyboard_mod.KeyboardState = .{},

    /// Convenience constructor for the pure-core (no session, no udev).
    /// Does NOT allocate on the heap; caller owns the returned value directly.
    pub fn init(surface: id.SurfaceId, w: u32, h: u32) Input {
        return .{ .surface = surface, .bounds_w = w, .bounds_h = h };
    }

    pub fn setSurface(self: *Input, s: id.SurfaceId, w: u32, h: u32) void {
        self.surface = s;
        self.bounds_w = w;
        self.bounds_h = h;
    }

    /// Full acquisition path: udev-enumerate /dev/input/event*, open each
    /// no-root via the session, and feed the fds to a libinput Context.
    /// Linux-only. The caller (kms backend) owns the session; Input does NOT
    /// close it on deinit.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        sess: *session.Session,
        surface: id.SurfaceId,
        w: u32,
        h: u32,
        input_config: options_mod.InputConfig,
    ) !*Input {
        if (comptime builtin.os.tag != .linux) return error.InputUnsupportedOnThisOS;
        const self = try gpa.create(Input);
        errdefer gpa.destroy(self);
        self.* = .{
            .surface = surface,
            .bounds_w = w,
            .bounds_h = h,
            .gpa = gpa,
            .sess = sess,
            .input_config = input_config,
        };
        self.ctx = libinput.Context.init(gpa);
        errdefer self.ctx.deinit();

        // The keymap resolves from the XKB database with the embedded US map as
        // the fallback; it never fails. See the field comment for the environ
        // limitation.
        self.keyboard = keyboard_mod.KeyboardState.initFromEnv(gpa, io, null);
        errdefer self.keyboard.deinit();

        try enumerateAndOpen(self, gpa, io, sess);

        // Open a udev netlink monitor for runtime hotplug. Non-fatal: if it
        // fails, static devices (from enumerateAndOpen) still work; we just
        // will not detect devices plugged in after startup.
        openMonitor(self, gpa, io);

        return self;
    }

    /// Apply the stored InputConfig to a freshly-opened device handle.
    /// Called right after every successful ctx.addDeviceFd in both
    /// enumerateAndOpen and handleHotplug.
    fn applyConfig(self: *Input, h: *libinput.context.DeviceHandle) void {
        const cfg = self.input_config;
        h.setAccelProfile(toLibinputProfile(cfg.accel_profile));
        h.setAccelSpeed(cfg.accel_speed);
        h.setNaturalScroll(cfg.natural_scroll);
        h.setLeftHanded(cfg.left_handed);
        h.setMiddleEmulation(cfg.middle_emulation);
        h.setScrollMethod(toLibinputScrollMethod(cfg.scroll_method));
    }

    /// Test-only: heap-allocate an Input with a live libinput Context but no
    /// session or udev enumeration. Not `pub`: only this file's tests use it,
    /// so it stays off the public API surface.
    fn initForTest(gpa: std.mem.Allocator, surface: id.SurfaceId, w: u32, h: u32) !*Input {
        const self = try gpa.create(Input);
        self.* = .{
            .surface = surface,
            .bounds_w = w,
            .bounds_h = h,
            .gpa = gpa,
            .sess = null,
        };
        self.ctx = libinput.Context.init(gpa);
        return self;
    }

    fn deinitForTest(self: *Input) void {
        self.ctx.deinit();
        self.gpa.destroy(self);
    }

    /// Tear down the libinput Context. The session (and the fds it tracks) is
    /// owned by the kms backend; Input does not close them.
    pub fn deinit(self: *Input) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.monitor) |*mon| mon.deinit();
            if (self.udev_ctx) |*uctx| uctx.deinit();
        }
        self.keyboard.deinit();
        self.ctx.deinit();
        self.gpa.destroy(self);
    }

    /// Fill `buf` with POLL.IN pollfd entries for each libinput device fd.
    /// Returns the number of entries written.
    pub fn pollFds(self: *Input, buf: []posix.pollfd) usize {
        var n: usize = 0;
        for (self.ctx.handles.items) |hnd| {
            if (n >= buf.len) break;
            if (hnd.dev.fd()) |fd| {
                buf[n] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
                n += 1;
            }
        }
        return n;
    }

    /// The seat state derived from the devices libinput holds open right now.
    /// Recomputed per call, so a hotplug or an unplug needs no extra bookkeeping.
    pub fn seatCapabilities(self: *const Input) nev.SeatCapabilities {
        var acc: nev.SeatCapabilities = .{};
        for (self.ctx.handles.items) |h| acc = foldSeatCapabilities(acc, h.dev.caps);
        return acc;
    }

    /// Return the udev monitor's pollable fd, or null if no monitor is active.
    pub fn monitorFd(self: *const Input) ?posix.fd_t {
        if (comptime builtin.os.tag != .linux) return null;
        const mon = self.monitor orelse return null;
        return mon.fd();
    }

    /// Drain the udev netlink monitor and open any new input event devices.
    /// Calls `sess.openDevice` + `ctx.addDeviceFd` for each ACTION=add node
    /// whose sysname starts with "event". Errors per-device are logged and
    /// skipped; this function never fails fatally.
    ///
    /// ACTION=remove: libinput's own DeviceGone path removes the handle when
    /// the fd read returns ENODEV on the next dispatch. We do NOT explicitly
    /// close on remove. The session continues to track the fd until
    /// session.deinit -- a known minor fd-retention limitation acceptable for
    /// this slice (the fd count equals the number of ever-connected devices,
    /// not concurrent ones).
    pub fn handleHotplug(self: *Input) void {
        if (comptime builtin.os.tag != .linux) return;
        var mon = if (self.monitor != null) &self.monitor.? else return;
        const sess = self.sess orelse return;
        while (true) {
            var dev = mon.receiveDevice() catch |err| {
                std.log.warn("input: hotplug monitor recv error: {s}", .{@errorName(err)});
                return;
            } orelse return; // null = socket drained
            defer dev.deinit();

            const action = dev.getProperty("ACTION") orelse continue;
            if (!std.mem.eql(u8, action, "add")) continue;

            const subsystem = dev.getProperty("SUBSYSTEM") orelse continue;
            if (!std.mem.eql(u8, subsystem, "input")) continue;

            const sysname = dev.sysname();
            if (!std.mem.startsWith(u8, sysname, "event")) continue;

            const node = dev.devnode() orelse continue;

            const fd = sess.openDevice(node) catch |err| {
                std.log.warn("input: hotplug: openDevice {s} failed: {s}", .{ node, @errorName(err) });
                continue;
            };

            const h = self.ctx.addDeviceFd(fd) catch |err| {
                std.log.warn("input: hotplug: addDeviceFd {s} failed: {s}", .{ node, @errorName(err) });
                continue;
            };
            self.applyConfig(h);

            std.log.info("input: hotplugged device {s}", .{node});
        }
    }

    /// Dispatch libinput and translate each queued event into a neutral Event
    /// emitted via `sink`. Device add/remove events are swallowed (translate
    /// returns null for them). For pointer_motion events, BOTH an absolute
    /// pointer_motion AND a pointer_relative event are emitted.
    pub fn drain(self: *Input, sink: backendMod.EventSink, sink_ctx: *anyopaque) void {
        self.ctx.dispatch() catch {};
        while (self.ctx.next()) |lev| {
            if (self.translate(lev)) |iev| {
                sink(sink_ctx, .{ .input = iev });
            }
            if (relativeOf(lev)) |rel| {
                sink(sink_ctx, .{ .input = .{ .pointer_relative = rel } });
            }
        }
    }

    /// Pure translation of one libinput event into a neutral InputEvent.
    /// Returns null for events with no neutral counterpart (device add/remove).
    /// Relative pointer motion mutates the provider-owned cursor.
    pub fn translate(self: *Input, ev: libinput.Event) ?nev.InputEvent {
        switch (ev) {
            .pointer_motion => |m| {
                self.cursor = accumulate(self.cursor, m.dx, m.dy, self.bounds_w, self.bounds_h);
                return .{ .pointer_motion = .{ .surface = self.surface, .x = self.cursor.x, .y = self.cursor.y } };
            },
            .pointer_button => |b| return .{ .pointer_button = .{
                .surface = self.surface,
                .button = b.button,
                .state = mapButtonState(b.state),
            } },
            .pointer_axis => |a| return .{ .pointer_axis = .{
                .surface = self.surface,
                .horizontal = if (a.axis == .horizontal) a.value else 0,
                .vertical = if (a.axis == .vertical) a.value else 0,
            } },
            .key => |k| {
                var out = nev.KeyEvent{
                    .keycode = k.code,
                    .state = if (k.state == .pressed) .pressed else .released,
                };
                // An enrichment failure (the only one is OOM recording a held
                // modifier) must not drop the key: an unenriched key beats none.
                if (self.keyboard.translate(k.code, k.state == .pressed)) |t| {
                    out.keysym = t.keysym;
                    out.mods = t.mods;
                    out.text = t.text;
                } else |_| {}
                return .{ .key = out };
            },
            .tablet_proximity => |t| return .{ .tablet_proximity = .{
                .surface = self.surface,
                .in_prox = t.in_prox,
            } },
            .tablet_tip => |t| return .{ .tablet_tip = .{
                .surface = self.surface,
                .down = t.down,
            } },
            .tablet_axis => |t| return .{
                .tablet_axis = .{
                    .surface = self.surface,
                    // libinput tablet axes are normalized [0,1]; scale to surface-local pixels.
                    .x = t.x * @as(f64, @floatFromInt(self.bounds_w)),
                    .y = t.y * @as(f64, @floatFromInt(self.bounds_h)),
                    .pressure = t.pressure,
                },
            },
            .device_added, .device_removed => return null,
        }
    }
};

/// Open a udev netlink monitor for the "input" subsystem. Non-fatal: on any
/// error, logs std.log.warn and returns without setting self.monitor (static
/// devices from enumerateAndOpen still work). Uses .kernel source so this
/// functions in our microVM test environment where udevd is not running;
/// devtmpfs creates /dev nodes synchronously so ACTION=add events carry a
/// usable DEVNAME.
fn openMonitor(self: *Input, gpa: std.mem.Allocator, io: std.Io) void {
    if (comptime builtin.os.tag != .linux) return;
    // Store the Context on the heap-stable Input FIRST, then hand its stable
    // address to the Monitor. Monitor keeps a *Context, so it must not point at a
    // stack local that dies when this function returns.
    self.udev_ctx = udev.Context.init(gpa, io);
    var mon = udev.Monitor.initNetlink(&self.udev_ctx.?, .kernel) catch |err| {
        std.log.warn("input: hotplug monitor unavailable ({}), continuing without", .{err});
        self.udev_ctx.?.deinit();
        self.udev_ctx = null;
        return;
    };
    mon.addMatchSubsystemDevtype("input", null) catch |err| {
        std.log.warn("input: monitor filter failed ({}), continuing without hotplug", .{err});
        mon.deinit();
        self.udev_ctx.?.deinit();
        self.udev_ctx = null;
        return;
    };
    self.monitor = mon;
}

/// Enumerate /dev/input/event* nodes via udev and open each no-root through the
/// session. Mirrors enumerate.pickDrmCard for the "input" subsystem.
fn enumerateAndOpen(self: *Input, gpa: std.mem.Allocator, io: std.Io, sess: *session.Session) !void {
    var uctx = udev.Context.init(gpa, io);
    defer uctx.deinit();
    var en = udev.Enumerate.init(&uctx);
    defer en.deinit();
    try en.addMatchSubsystem("input");
    try en.scanDevices();

    var it = en.devices();
    while (it.next()) |syspath| {
        var dev = udev.Device.fromSyspath(&uctx, syspath) catch continue;
        defer dev.deinit();
        const sysname = dev.sysname();
        if (!std.mem.startsWith(u8, sysname, "event")) continue;
        const node = dev.devnode() orelse continue;
        const fd = sess.openDevice(node) catch |err| {
            std.log.warn("input: openDevice {s} failed: {s}", .{ node, @errorName(err) });
            continue;
        };
        // addDeviceFd is non-owning (owns_fd=false). If it rejects the fd
        // (not a char device, probe fail, etc.) the session still owns/tracks
        // it and will close it on sess.deinit - just skip this device. A probe
        // reads the kernel through ioctls, so a device that disappears mid-probe
        // must cost us that one device, not the whole enumeration.
        const h = self.ctx.addDeviceFd(fd) catch |err| {
            std.log.warn("input: addDeviceFd {s} failed: {s}", .{ node, @errorName(err) });
            continue;
        };
        self.applyConfig(h);
    }
}

test "a mouse folds to pointer only and a keyboard adds keyboard without touch" {
    const mouse = std.mem.zeroInit(libinput.device.Caps, .{ .has_rel = true, .has_buttons = true });
    const only_mouse = foldSeatCapabilities(.{}, mouse);
    try std.testing.expectEqual(true, only_mouse.pointer);
    try std.testing.expectEqual(false, only_mouse.keyboard);
    try std.testing.expectEqual(false, only_mouse.touch);

    const keyboard = std.mem.zeroInit(libinput.device.Caps, .{ .has_keys = true });
    const both = foldSeatCapabilities(only_mouse, keyboard);
    try std.testing.expectEqual(true, both.pointer);
    try std.testing.expectEqual(true, both.keyboard);
    try std.testing.expectEqual(false, both.touch);
}

test "a pen tablet counts as a pointer and a device with no bits changes nothing" {
    const tablet = std.mem.zeroInit(libinput.device.Caps, .{ .is_tablet = true });
    const from_tablet = foldSeatCapabilities(.{}, tablet);
    try std.testing.expectEqual(true, from_tablet.pointer);
    try std.testing.expectEqual(false, from_tablet.keyboard);

    const silent = std.mem.zeroInit(libinput.device.Caps, .{});
    const unchanged = foldSeatCapabilities(from_tablet, silent);
    try std.testing.expect(unchanged.eql(from_tablet));
}

test "a touchscreen sets seat touch while a touchpad leaves it false" {
    const touchscreen = std.mem.zeroInit(libinput.device.Caps, .{ .is_touchscreen = true });
    const from_touchscreen = foldSeatCapabilities(.{}, touchscreen);
    try std.testing.expectEqual(true, from_touchscreen.touch);

    // A touchpad probes as buttons plus relative motion, never is_touchscreen,
    // so a laptop keeps a pointer-only seat and the desktop layout.
    const touchpad = std.mem.zeroInit(libinput.device.Caps, .{ .has_rel = true, .has_buttons = true });
    const from_touchpad = foldSeatCapabilities(.{}, touchpad);
    try std.testing.expectEqual(true, from_touchpad.pointer);
    try std.testing.expectEqual(false, from_touchpad.touch);
}

test "seat touch stays set once any device reported it" {
    const touchscreen = std.mem.zeroInit(libinput.device.Caps, .{ .is_touchscreen = true });
    const keyboard = std.mem.zeroInit(libinput.device.Caps, .{ .has_keys = true });
    const acc = foldSeatCapabilities(foldSeatCapabilities(.{}, touchscreen), keyboard);
    try std.testing.expectEqual(true, acc.touch);
    try std.testing.expectEqual(true, acc.keyboard);
}

test "an Input with no open device reports an empty seat" {
    var in = try Input.initForTest(std.testing.allocator, id.SurfaceId.from(1), 800, 600);
    defer in.deinitForTest();
    const caps = in.seatCapabilities();
    try std.testing.expectEqual(false, caps.pointer);
    try std.testing.expectEqual(false, caps.keyboard);
    try std.testing.expectEqual(false, caps.touch);
}

test "monitorFd returns null and handleHotplug is safe when no monitor is active" {
    // initForTest creates an Input with no session and no monitor.
    // monitorFd must return null, and handleHotplug must be a safe no-op.
    var in = try Input.initForTest(std.testing.allocator, id.SurfaceId.from(1), 800, 600);
    defer in.deinitForTest();
    try std.testing.expect(in.monitorFd() == null);
    in.handleHotplug(); // must not crash
}

test "accumulate clamps to bounds" {
    const c0 = Cursor{ .x = 5, .y = 5 };
    const left = accumulate(c0, -100, 0, 800, 600);
    try std.testing.expectEqual(@as(f64, 0), left.x);
    const right = accumulate(c0, 10_000, 0, 800, 600);
    try std.testing.expectEqual(@as(f64, 800), right.x);
    const mid = accumulate(c0, 3, -2, 800, 600);
    try std.testing.expectEqual(@as(f64, 8), mid.x);
    try std.testing.expectEqual(@as(f64, 3), mid.y);
}

test "translate relative motion -> absolute PointerMotion on the surface" {
    var in = Input.init(id.SurfaceId.from(1), 800, 600);
    const out = in.translate(.{ .pointer_motion = .{
        .time_ms = 0,
        .dx = 12,
        .dy = 7,
        .dx_unaccel = 12,
        .dy_unaccel = 7,
    } }).?;
    try std.testing.expect(out == .pointer_motion);
    try std.testing.expectEqual(@as(f64, 12), out.pointer_motion.x);
    try std.testing.expectEqual(@as(f64, 7), out.pointer_motion.y);
    try std.testing.expectEqual(@as(u32, 1), out.pointer_motion.surface.value());
}

test "translate button and key pass through raw" {
    var in = Input.init(id.SurfaceId.from(1), 800, 600);
    const b = in.translate(.{ .pointer_button = .{
        .time_ms = 0,
        .button = 0x110,
        .state = .pressed,
        .seat_button_count = 1,
    } }).?;
    try std.testing.expect(b == .pointer_button);
    try std.testing.expectEqual(@as(u32, 0x110), b.pointer_button.button);
    try std.testing.expectEqual(nev.ButtonState.pressed, b.pointer_button.state);

    const k = in.translate(.{ .key = .{ .time_ms = 0, .code = 30, .state = .pressed } }).?;
    try std.testing.expect(k == .key);
    try std.testing.expectEqual(@as(u32, 30), k.key.keycode);
    try std.testing.expectEqual(nev.KeyState.pressed, k.key.state);
    // The pure-core init has no keymap, so the enrichment fields stay empty.
    try std.testing.expectEqual(@as(u32, 0), k.key.keysym);
    try std.testing.expect(k.key.text == null);
}

test "translate enriches a key with the keysym, the modifiers and the text" {
    var in = Input.init(id.SurfaceId.from(1), 800, 600);
    in.keyboard = try keyboard_mod.KeyboardState.initFromString(
        std.testing.allocator,
        std.testing.io,
        keyboard_mod.minimal_keymap,
    );
    defer in.keyboard.deinit();

    const k = in.translate(.{ .key = .{ .time_ms = 0, .code = 30, .state = .pressed } }).?;
    try std.testing.expect(k == .key);
    try std.testing.expectEqual(@as(u32, 30), k.key.keycode);
    try std.testing.expectEqual(@as(u32, 'a'), k.key.keysym);
    try std.testing.expectEqualStrings("a", k.key.text.?);
    try std.testing.expect(k.key.mods.none());

    // A release reports the keysym and no text.
    const up = in.translate(.{ .key = .{ .time_ms = 1, .code = 30, .state = .released } }).?;
    try std.testing.expectEqual(@as(u32, 'a'), up.key.keysym);
    try std.testing.expect(up.key.text == null);
}

test "translate axis folds vertical/horizontal" {
    var in = Input.init(id.SurfaceId.from(1), 800, 600);
    const v = in.translate(.{ .pointer_axis = .{
        .time_ms = 0,
        .axis = .vertical,
        .value = 3.5,
        .source = .continuous,
        .v120 = 0,
    } }).?;
    try std.testing.expect(v == .pointer_axis);
    try std.testing.expectEqual(@as(f64, 3.5), v.pointer_axis.vertical);
    try std.testing.expectEqual(@as(f64, 0), v.pointer_axis.horizontal);
}

test "translate swallows device add/remove" {
    var in = Input.init(id.SurfaceId.from(1), 800, 600);
    try std.testing.expect(in.translate(.{ .device_added = .{ .device_id = 1 } }) == null);
    try std.testing.expect(in.translate(.{ .device_removed = .{ .device_id = 1 } }) == null);
}

test "translate tablet: normalized axes scale to surface pixels; prox/tip pass through" {
    var in = Input.init(id.SurfaceId.from(1), 800, 600);
    const ax = in.translate(.{ .tablet_axis = .{ .time_ms = 0, .x = 0.5, .y = 0.25, .pressure = 0.75 } }).?;
    try std.testing.expect(ax == .tablet_axis);
    try std.testing.expectEqual(@as(f64, 400), ax.tablet_axis.x); // 0.5 * 800
    try std.testing.expectEqual(@as(f64, 150), ax.tablet_axis.y); // 0.25 * 600
    try std.testing.expectEqual(@as(f64, 0.75), ax.tablet_axis.pressure);
    try std.testing.expectEqual(@as(u32, 1), ax.tablet_axis.surface.value());

    const prox = in.translate(.{ .tablet_proximity = .{ .time_ms = 0, .in_prox = true } }).?;
    try std.testing.expect(prox == .tablet_proximity and prox.tablet_proximity.in_prox);
    const tip = in.translate(.{ .tablet_tip = .{ .time_ms = 0, .down = true } }).?;
    try std.testing.expect(tip == .tablet_tip and tip.tablet_tip.down);
}

const Collector = struct {
    var events: std.ArrayList(nev.Event) = undefined;
    var gpa: std.mem.Allocator = undefined;
    fn sink(_: *anyopaque, ev: nev.Event) void {
        events.append(gpa, ev) catch {};
    }
};

test "drain translates memory-device evdev frames to neutral input events" {
    const ev = libinput.evdev;
    const data = [_]libinput.evdev.InputEvent{
        .{ .time = .{ .sec = 0, .usec = 0 }, .type = ev.EV_REL, .code = ev.REL_X, .value = 9 },
        .{ .time = .{ .sec = 0, .usec = 0 }, .type = ev.EV_SYN, .code = ev.SYN_REPORT, .value = 0 },
    };
    const caps = libinput.device.Caps{
        .has_rel = true,
        .has_buttons = true,
        .has_wheel = true,
        .has_keys = false,
        .is_tablet = false,
        .id = .{ .bustype = 3, .vendor = 1, .product = 1, .version = 1 },
        .kind = .mouse,
        .name = undefined,
        .name_len = 0,
    };

    var in = try Input.initForTest(std.testing.allocator, id.SurfaceId.from(1), 800, 600);
    defer in.deinitForTest();
    const h = try in.ctx.addMemoryDevice(&data, caps);
    h.setAccelProfile(.flat);
    h.setAccelSpeed(0.0);

    Collector.events = std.ArrayList(nev.Event).empty;
    Collector.gpa = std.testing.allocator;
    defer Collector.events.deinit(std.testing.allocator);
    var dummy: u8 = 0;
    in.drain(Collector.sink, &dummy);

    // device_added is swallowed; one REL_X frame must produce BOTH a
    // pointer_motion (absolute accumulation) AND a pointer_relative (raw deltas).
    var saw_motion = false;
    var saw_relative = false;
    for (Collector.events.items) |e| {
        if (e == .input and e.input == .pointer_motion) {
            saw_motion = true;
            try std.testing.expectEqual(@as(f64, 9), e.input.pointer_motion.x);
        }
        if (e == .input and e.input == .pointer_relative) {
            saw_relative = true;
            // dx comes from the accel-filtered value; dx_unaccel from the raw.
            try std.testing.expect(e.input.pointer_relative.dx != 0 or
                e.input.pointer_relative.dx_unaccel != 0);
        }
    }
    try std.testing.expect(saw_motion);
    try std.testing.expect(saw_relative);
}

test "relativeOf extracts raw + accel deltas from a libinput motion" {
    const rel = relativeOf(.{ .pointer_motion = .{
        .time_ms = 0,
        .dx = 5,
        .dy = -3,
        .dx_unaccel = 6,
        .dy_unaccel = -4,
    } }).?;
    try std.testing.expectEqual(@as(f64, 5), rel.dx);
    try std.testing.expectEqual(@as(f64, -3), rel.dy);
    try std.testing.expectEqual(@as(f64, 6), rel.dx_unaccel);
    try std.testing.expectEqual(@as(f64, -4), rel.dy_unaccel);
    // Non-motion events have no relative component.
    try std.testing.expect(relativeOf(.{ .key = .{ .time_ms = 0, .code = 30, .state = .pressed } }) == null);
}

test "toLibinputProfile maps lattice AccelProfile to libinput filter.Profile" {
    try std.testing.expectEqual(libinput.filter.Profile.flat, toLibinputProfile(.flat));
    try std.testing.expectEqual(libinput.filter.Profile.adaptive, toLibinputProfile(.adaptive));
}

test "toLibinputScrollMethod maps lattice ScrollMethod to libinput pointer.ScrollMethod" {
    try std.testing.expectEqual(libinput.pointer.ScrollMethod.none, toLibinputScrollMethod(.none));
    try std.testing.expectEqual(libinput.pointer.ScrollMethod.on_button_down, toLibinputScrollMethod(.on_button_down));
}

test "applyConfig applies all InputConfig fields to a memory device" {
    const ev = libinput.evdev;
    const data = [_]libinput.evdev.InputEvent{
        .{ .time = .{ .sec = 0, .usec = 0 }, .type = ev.EV_SYN, .code = ev.SYN_REPORT, .value = 0 },
    };
    const caps = libinput.device.Caps{
        .has_rel = true,
        .has_buttons = true,
        .has_wheel = true,
        .has_keys = false,
        .is_tablet = false,
        .id = .{ .bustype = 3, .vendor = 1, .product = 1, .version = 1 },
        .kind = .mouse,
        .name = undefined,
        .name_len = 0,
    };

    var in = try Input.initForTest(std.testing.allocator, id.SurfaceId.from(1), 800, 600);
    in.input_config = .{
        .accel_profile = .flat,
        .accel_speed = 0.5,
        .natural_scroll = true,
        .left_handed = true,
        .middle_emulation = true,
        .scroll_method = .on_button_down,
    };
    defer in.deinitForTest();

    const h = try in.ctx.addMemoryDevice(&data, caps);
    // Apply the config through the same applyConfig path used on real device open.
    in.applyConfig(h);
    // Verify the settings were applied by reading back through the device config
    // (filter profile and scroll method are readable from the device structs).
    try std.testing.expectEqual(libinput.filter.Profile.flat, h.dev.filterPtr().profile);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), h.dev.filterPtr().speed, 1e-12);
    try std.testing.expect(h.dev.config().natural_scroll);
    try std.testing.expect(h.dev.config().left_handed);
    try std.testing.expect(h.dev.config().middle_emulation);
    try std.testing.expectEqual(libinput.pointer.ScrollMethod.on_button_down, h.dev.config().scroll_method);
}
