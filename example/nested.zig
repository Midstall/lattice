//! Task 11: self-host milestone + slice 2 multi-client proof.
//!
//! Opens a shell window on the outer compositor (cosmic-comp), starts a nested
//! Wayland compositor sharing the same prism Device, spawns TWO lattice-window
//! children pointed at the nested socket, then composites each child's texture
//! side-by-side inside the shell window.
//!
//! Proves two concurrent hosted clients (distinct ClientIds, distinct
//! HostedSurfaceIds) both render without collision, and that one client exiting
//! cleanly leaves the other still rendering.
//!
//! Exits after ~180 rendered frames, both children exit, or outer close_requested.

const std = @import("std");
const linux = std.os.linux;
const lattice = @import("lattice");

const MAX_FRAMES: u32 = 180;
const MAX_SURFACES: usize = 4;
const NUM_CHILDREN: usize = 2;

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

const App = struct {
    // Outer client
    ctx: *lattice.Context,
    sid: lattice.SurfaceId,
    // Nested compositor
    comp: *lattice.Compositor,
    // Child processes (two concurrent hosted clients)
    children: [NUM_CHILDREN]std.process.Child,
    child_alive: [NUM_CHILDREN]bool,
    // io for child operations
    io: std.Io,
    // Render state
    frame_count: u32,
    done: bool,
    // Tracked mapped surfaces (fixed capacity, keyed by HostedSurfaceId).
    surfaces: [MAX_SURFACES]?lattice.HostedSurface,
    // Whether we have sent the synthetic input burst
    input_sent: bool,

    /// Insert or update the tracked HostedSurface for `id`. Updates the slot
    /// holding a matching id, otherwise fills the first empty slot. Logs and
    /// ignores overflow beyond capacity.
    fn upsertSurface(self: *App, id: lattice.compositor_types.HostedSurfaceId, surf: lattice.HostedSurface) void {
        var empty: ?usize = null;
        for (&self.surfaces, 0..) |*slot, i| {
            if (slot.*) |existing| {
                if (existing.id == id) {
                    slot.* = surf;
                    return;
                }
            } else if (empty == null) {
                empty = i;
            }
        }
        if (empty) |i| {
            self.surfaces[i] = surf;
        } else {
            std.debug.print("[nested] surface tracking overflow, ignoring id={d}\n", .{id.value()});
        }
    }

    /// Null the slot holding the surface with a matching id, if any.
    fn removeSurface(self: *App, id: lattice.compositor_types.HostedSurfaceId) void {
        for (&self.surfaces) |*slot| {
            if (slot.*) |existing| {
                if (existing.id == id) {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    /// Look up the current HostedSurface snapshot for `id` from the compositor
    /// view and upsert it into tracking. Mirrors the single-surface snapshot.
    fn snapshotSurface(self: *App, id: lattice.compositor_types.HostedSurfaceId) void {
        for (self.comp.surfaces()) |surf| {
            if (surf.id == id) {
                self.upsertSurface(id, surf);
                return;
            }
        }
    }

    // Called by ctx.poll for outer events.
    fn outerHandler(ptr: *anyopaque, ev: lattice.Event) void {
        const self: *App = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .close_requested => {
                std.debug.print("[nested] outer close_requested\n", .{});
                self.done = true;
                self.ctx.quit();
            },
            .redraw_requested => {
                // Render a frame if we can.
                self.renderFrame() catch |err| {
                    std.debug.print("[nested] render error: {}\n", .{err});
                };
            },
            .input => |input_ev| {
                // Forward input events from the outer compositor to nested clients.
                switch (input_ev) {
                    .pointer_relative => |rel| {
                        // Route seat-global relative motion to the focused hosted client.
                        self.comp.pointerRelative(rel.dx, rel.dy, rel.dx_unaccel, rel.dy_unaccel);
                    },
                    .pointer_motion => |m| {
                        self.comp.pointerMotion(m.x, m.y);
                    },
                    .pointer_button => |b| {
                        self.comp.pointerButton(b.button, b.state == .pressed);
                    },
                    .pointer_axis => |a| {
                        self.comp.pointerAxis(a.horizontal, a.vertical);
                    },
                    .key => |k| {
                        self.comp.key(k.keycode, k.state == .pressed);
                    },
                    .tablet_proximity => |t| {
                        self.comp.tabletProximity(t.in_prox);
                    },
                    .tablet_axis => |t| {
                        self.comp.tabletAxis(t.x, t.y, t.pressure);
                    },
                    .tablet_tip => |t| {
                        self.comp.tabletTip(t.down);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    // Called by comp.pump for compositor events.
    fn compHandler(ptr: *anyopaque, ev: lattice.CompositorEvent) void {
        const self: *App = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .surface_mapped => |id| {
                // Snapshot the HostedSurface and report which client owns it so
                // the two distinct clients are visibly distinguishable.
                self.snapshotSurface(id);
                var client_val: u32 = 0;
                for (self.comp.surfaces()) |surf| {
                    if (surf.id == id) {
                        client_val = surf.client.value();
                        break;
                    }
                }
                std.debug.print("[nested] hosted surface mapped id={d} client={d}\n", .{ id.value(), client_val });
            },
            .surface_committed => |id| {
                // Update our snapshot so the texture pointer stays current.
                self.snapshotSurface(id);
            },
            .surface_resized => |info| {
                std.debug.print("[nested] surface resized id={d} {d}x{d}\n", .{ info.id.value(), info.width, info.height });
            },
            .surface_unmapped => |id| {
                std.debug.print("[nested] surface unmapped id={d}\n", .{id.value()});
                self.removeSurface(id);
            },
            .client_disconnected => |id| {
                std.debug.print("[nested] client disconnected id={d}\n", .{id.value()});
            },
            .pointer_constraint => |req| {
                // Forward the pointer constraint to the parent compositor via the Context.
                // Task 8 wires this fully (App.ctx.applyPointerConstraint); here we just
                // propagate so the parent compositor can enforce lock/confine on the real pointer.
                self.ctx.applyPointerConstraint(req);
            },
        }
    }

    fn renderFrame(self: *App) !void {
        if (!self.ctx.renderAvailable(self.sid)) return;
        const rt = try self.ctx.renderTarget(self.sid);

        // Begin a command buffer on the render context, clear to dark gray.
        var cb = try rt.context.beginCommands();
        errdefer cb.deinit();
        try cb.setRenderTarget(rt.target);
        try cb.clear(.{ .r = 0.15, .g = 0.15, .b = 0.15, .a = 1.0 });
        try rt.context.submit(cb);
        cb.deinit();

        // Draw every tracked hosted surface tiled left-to-right so both
        // clients are visible side-by-side (no clobber).
        var col: f32 = 0;
        const half_w: f32 = @as(f32, @floatFromInt(rt.width)) / 2.0;
        for (self.surfaces) |maybe_surf| {
            const surf = maybe_surf orelse continue;
            if (!surf.mapped or surf.texture == null) continue;
            try self.comp.drawSurface(
                rt.target,
                rt.width,
                rt.height,
                surf.id,
                .{
                    .x = 100 + col * half_w,
                    .y = 100,
                    .w = @floatFromInt(surf.width),
                    .h = @floatFromInt(surf.height),
                },
            );
            col += 1;
        }

        try self.ctx.commit(self.sid);
        self.comp.endFrame();
        self.frame_count += 1;

        if (self.frame_count % 30 == 0) {
            std.debug.print("[nested] frame {d}\n", .{self.frame_count});
        }

        // Send synthetic input once, to the first mapped surface we find.
        if (!self.input_sent) {
            for (self.surfaces) |maybe_surf| {
                const surf = maybe_surf orelse continue;
                if (!surf.mapped) continue;
                self.comp.focus(surf.id);
                self.comp.pointerMotion(50, 50);
                self.comp.pointerButton(0x110, true);
                self.comp.pointerButton(0x110, false);
                self.comp.key(30, true);
                self.comp.key(30, false);
                self.input_sent = true;
                std.debug.print("[nested] synthetic input sent to surface id={d}\n", .{surf.id.value()});
                break;
            }
        }

        if (self.frame_count >= MAX_FRAMES) {
            std.debug.print("[nested] reached {d} frames, exiting\n", .{MAX_FRAMES});
            self.done = true;
            self.ctx.quit();
        }
    }

    // Non-blocking reap of any exited child using WNOHANG. Marks the exited
    // child's slot dead + consumes its id (so kill() is safe). Returns true
    // when ALL children have exited.
    fn reapChildren(self: *App) bool {
        for (&self.children, &self.child_alive, 0..) |*child, *alive, idx| {
            if (!alive.*) continue;
            const pid = child.id orelse {
                alive.* = false;
                continue;
            };
            var status: u32 = 0;
            const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
            const errno = linux.errno(rc);
            if (errno == .SUCCESS and rc == @as(usize, @intCast(pid))) {
                const exit_code: u8 = if (linux.W.IFEXITED(status))
                    linux.W.EXITSTATUS(status)
                else
                    255;
                std.debug.print("[nested] child {d} exited with code {d}\n", .{ idx, exit_code });
                alive.* = false;
                // Mark id consumed so child.kill() is safe.
                child.id = null;
            }
        }
        for (self.child_alive) |alive| {
            if (alive) return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    // 1. Create the outer client Context (shell window on cosmic-comp).
    var ctx = try lattice.Context.init(
        gpa,
        io,
        env,
        .{ .initial_width = 1280, .initial_height = 800, .driver = null },
    );
    defer ctx.deinit();

    const shell_surface = try ctx.createSurface(.{
        .title = "lattice-nested",
        .width = 1280,
        .height = 800,
        .color = lattice.ColorConfig.sdr(.xrgb8888),
    });
    defer ctx.destroySurface(shell_surface.id);

    // 2. Create the nested compositor sharing the outer device.
    const device = ctx.renderDevice() orelse {
        std.debug.print("[nested] error: renderDevice returned null (need a GPU backend)\n", .{});
        std.process.exit(1);
    };

    const runtime_dir = env.get("XDG_RUNTIME_DIR") orelse {
        std.debug.print("[nested] error: XDG_RUNTIME_DIR not set\n", .{});
        std.process.exit(1);
    };

    // Derive the XKB config root from the environment so the seat can build a
    // real us/evdev keymap. Prefer XKB_CONFIG_ROOT; otherwise derive it from
    // X11_BASE_RULES_XML (value = <root>/rules/base.xml or .../rules/evdev.xml)
    // by stripping everything from the LAST "/rules/" onward. The slice points
    // into init.environ_map, which outlives the compositor, so no dupe needed.
    const xkb_root: ?[]const u8 = blk: {
        if (env.get("XKB_CONFIG_ROOT")) |v| break :blk v;
        if (env.get("X11_BASE_RULES_XML")) |v| {
            if (std.mem.lastIndexOf(u8, v, "/rules/")) |idx| break :blk v[0..idx];
        }
        break :blk null;
    };
    std.debug.print("[nested] xkb_config_root = {?s}\n", .{xkb_root});

    const comp = try lattice.Compositor.init(gpa, io, device, .{
        .runtime_dir = runtime_dir,
        .xkb_config_root = xkb_root,
    });
    defer comp.deinit();

    const socket_name = comp.socketName();
    std.debug.print("[nested] compositor socket: {s}\n", .{socket_name});

    // 3. Build a child environment with WAYLAND_DISPLAY overridden.
    var child_env = std.process.Environ.Map.init(gpa);
    defer child_env.deinit();

    // Copy existing env vars from the parent map.
    const keys = env.keys();
    const vals = env.values();
    for (keys, vals) |k, v| {
        try child_env.put(k, v);
    }
    // Override WAYLAND_DISPLAY to point at our nested compositor.
    try child_env.put("WAYLAND_DISPLAY", socket_name);
    try child_env.put("XDG_RUNTIME_DIR", runtime_dir);
    // Base child env is SDR (LATTICE_HDR / LATTICE_HDR10 unset).
    // When parent runs with LATTICE_HDR=1: drive child 0 as fp16 rgba16_float HDR.
    // When parent runs with LATTICE_HDR10=1: drive child 0 as 10-bit argb2101010 HDR.
    // If both are set on the parent, fp16 (LATTICE_HDR) wins (mirrors window.zig precedence).
    // Child 1 always stays SDR so both paths are exercised concurrently.
    try child_env.put("LATTICE_HDR", "0");
    try child_env.put("LATTICE_HDR10", "0");
    const parent_hdr = env.get("LATTICE_HDR");
    const parent_hdr10 = env.get("LATTICE_HDR10");
    const drive_hdr = parent_hdr != null and std.mem.eql(u8, parent_hdr.?, "1");
    const drive_hdr10 = !drive_hdr and parent_hdr10 != null and std.mem.eql(u8, parent_hdr10.?, "1");

    // Dedicated env for the fp16 HDR child: same as child_env but LATTICE_HDR=1.
    var hdr_child_env = std.process.Environ.Map.init(gpa);
    defer hdr_child_env.deinit();
    for (child_env.keys(), child_env.values()) |k, v| {
        try hdr_child_env.put(k, v);
    }
    try hdr_child_env.put("LATTICE_HDR", "1");

    // Dedicated env for the 10-bit HDR child: same as child_env but LATTICE_HDR10=1.
    var hdr10_child_env = std.process.Environ.Map.init(gpa);
    defer hdr10_child_env.deinit();
    for (child_env.keys(), child_env.values()) |k, v| {
        try hdr10_child_env.put(k, v);
    }
    try hdr10_child_env.put("LATTICE_HDR10", "1");

    // 4. Spawn TWO lattice-window children with the overridden environment so
    // the nested compositor hosts two concurrent, distinct clients.
    var children: [NUM_CHILDREN]std.process.Child = undefined;
    var child_alive: [NUM_CHILDREN]bool = undefined;
    for (&children, &child_alive, 0..) |*child, *alive, idx| {
        // Child 0: fp16 HDR when drive_hdr; 10-bit HDR when drive_hdr10; else SDR.
        // Child 1: always SDR.
        const child_env_ptr = if (idx == 0 and drive_hdr)
            &hdr_child_env
        else if (idx == 0 and drive_hdr10)
            &hdr10_child_env
        else
            &child_env;
        child.* = try std.process.spawn(io, .{
            .argv = &.{"zig-out/bin/lattice-window"},
            .environ_map = child_env_ptr,
            .stderr = .inherit,
            .stdout = .inherit,
        });
        alive.* = true;
        std.debug.print("[nested] child {d} pid: {d} hdr={} hdr10={}\n", .{ idx, child.id orelse 0, drive_hdr and idx == 0, drive_hdr10 and idx == 0 });
    }

    // 5. Build app state.
    var app = App{
        .ctx = &ctx,
        .sid = shell_surface.id,
        .comp = comp,
        .children = children,
        .child_alive = child_alive,
        .io = io,
        .frame_count = 0,
        .done = false,
        .surfaces = .{ null, null, null, null },
        .input_sent = false,
    };

    // 6. Combined event loop: poll BOTH ctx.fd() and comp.fd() via std.posix.poll.
    ctx.running = true;
    while (!app.done and ctx.running) {
        // Reap any exited children (non-blocking). When ALL have exited we are
        // done; while at least one survives we keep rendering the rest.
        if (app.reapChildren()) {
            app.done = true;
            ctx.quit();
            break;
        }

        // Build poll set: outer fd + inner compositor fd.
        const ctx_fd = ctx.fd();
        const comp_fd = comp.fd();

        var fds: [2]std.posix.pollfd = undefined;
        var n_fds: usize = 0;

        if (ctx_fd) |cfd| {
            fds[n_fds] = .{
                .fd = cfd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            n_fds += 1;
        }

        fds[n_fds] = .{
            .fd = comp_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        n_fds += 1;

        // Poll with a 16ms timeout (roughly 60fps pace).
        _ = std.posix.poll(fds[0..n_fds], 16) catch |err| {
            std.debug.print("[nested] poll error: {}\n", .{err});
            break;
        };

        // Service the nested compositor (timeout=0 since we already polled).
        try comp.pump(0, App.compHandler, &app);

        // Service the outer client.
        try ctx.poll(0, App.outerHandler, &app);

        // If render is available but no redraw_requested fired, try rendering anyway.
        if (!app.done and ctx.renderAvailable(shell_surface.id)) {
            app.renderFrame() catch |err| {
                std.debug.print("[nested] render error: {}\n", .{err});
            };
        }
    }

    // 7. Kill any surviving children on exit; reap the rest to avoid zombies.
    for (&app.children, &app.child_alive, 0..) |*child, *alive, idx| {
        if (alive.*) {
            std.debug.print("[nested] killing child {d} pid={d}\n", .{ idx, child.id orelse 0 });
            child.kill(io);
        } else if (child.id != null) {
            // Child exited on its own but still needs a wait to reap it.
            _ = child.wait(io) catch {};
        }
    }

    std.debug.print("[nested] exit. frames={d}\n", .{app.frame_count});
}
