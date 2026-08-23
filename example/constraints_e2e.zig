//! End-to-end wire-level test for pointer-constraints enforcement.
//!
//! Proves that a real Wayland CLIENT connected to a live lattice Compositor
//! over a unix socket can lock the pointer, receives
//! zwp_relative_pointer_v1.relative_motion while NOT receiving
//! wl_pointer.motion (absolute pointer frozen under lock).
//!
//! Approach: FULL IN-PROCESS CLIENT.
//! The compositor and client live in the same process. Both loops are
//! driven by alternating non-blocking pumps so events deliver without
//! threads. The client side uses poll(fd, 0) before every dispatchEvent
//! to avoid blocking when no data is available.
//!
//! Expected output (last line): "PASS: ..."
//!
//! Run: XDG_RUNTIME_DIR=/run/user/1000 zig build example-constraints-e2e

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const prism = @import("prism");
const lattice = @import("lattice");

const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const xdg = @import("xdg_shell");
const rp = @import("relative_pointer");
const pc = @import("pointer_constraints");

const client_mod = wl.client;

// Small 1x1 pixel buffer for surface mapping. XRGB8888 = 4 bytes.
const SHM_WIDTH: i32 = 1;
const SHM_HEIGHT: i32 = 1;
const SHM_STRIDE: i32 = SHM_WIDTH * 4;
const SHM_SIZE: i32 = SHM_STRIDE * SHM_HEIGHT;

// ---------------------------------------------------------------------------
// Zero-timeout poll: returns true when fd has unread bytes.
// ---------------------------------------------------------------------------

fn fdReadable(fd: posix.fd_t) bool {
    var pfd = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&pfd, 0) catch return false;
    if (n == 0) return false;
    return (pfd[0].revents & posix.POLL.IN) != 0;
}

// ---------------------------------------------------------------------------
// Compositor-side event handler (records surface_mapped).
// ---------------------------------------------------------------------------

const CompState = struct {
    mapped: bool = false,
    mapped_id: lattice.compositor_types.HostedSurfaceId = undefined,
};

fn compHandler(ctx: *anyopaque, ev: lattice.CompositorEvent) void {
    const st: *CompState = @ptrCast(@alignCast(ctx));
    switch (ev) {
        .surface_mapped => |id| {
            if (!st.mapped) {
                st.mapped = true;
                st.mapped_id = id;
                std.debug.print("[e2e] surface_mapped id={d}\n", .{id.value()});
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Client-side observation state.
// ---------------------------------------------------------------------------

const TestState = struct {
    got_motion: bool = false,
    got_relative: bool = false,
    rel_dx: f64 = 0,
    rel_dy: f64 = 0,
    got_locked: bool = false,
};

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &w.interface;

    // XDG_RUNTIME_DIR required.
    const runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse {
        try out.writeAll("FAIL: XDG_RUNTIME_DIR not set\n");
        try out.flush();
        std.process.exit(1);
    };

    // Best available prism device (nvidia -> virgl -> software).
    const sel = prism.drivers.createBestDevice(gpa) orelse {
        try out.writeAll("FAIL: no prism driver available\n");
        try out.flush();
        std.process.exit(1);
    };
    defer sel.device.deinit();
    var dev = sel.device;

    // Bring up the nested compositor.
    const comp = try lattice.Compositor.init(gpa, io, &dev, .{ .runtime_dir = runtime_dir });
    defer comp.deinit();

    const socket_name = comp.socketName();
    std.debug.print("[e2e] compositor socket: {s}\n", .{socket_name});

    // Build full socket path.
    var path_buf: [300]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ runtime_dir, socket_name });

    // Connect a client.
    var conn = try client_mod.connect(gpa, io, socket_path);
    defer conn.deinit();

    var imap = client_mod.InterfaceMap.init(gpa);
    defer imap.deinit();

    // wl_display is always object id 1.
    try imap.set(1, &wlp.WlDisplay.interface);

    // get_registry.
    const registry_id = try client_mod.getRegistry(&conn);
    try imap.set(registry_id, &wlp.WlRegistry.interface);

    // Shared message + args buffers.
    var msg_buf: [4096]u8 = undefined;
    var args_buf: [16]wl.Argument = undefined;

    // Pump the compositor so it processes the new connection + registry request.
    {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            var dummy = CompState{};
            try comp.pump(1, compHandler, &dummy);
        }
    }

    // -------------------------------------------------------------------------
    // Globals roundtrip: send wl_display.sync, collect wl_registry.global events.
    // -------------------------------------------------------------------------

    const sync_cb_id = try client_mod.sync(&conn);
    try imap.set(sync_cb_id, &wlp.WlCallback.interface);

    var compositor_gname: u32 = 0;
    var compositor_gver: u32 = 0;
    var shm_gname: u32 = 0;
    var shm_gver: u32 = 0;
    var seat_gname: u32 = 0;
    var seat_gver: u32 = 0;
    var xdg_wm_base_gname: u32 = 0;
    var xdg_wm_base_gver: u32 = 0;
    var rel_ptr_mgr_gname: u32 = 0;
    var rel_ptr_mgr_gver: u32 = 0;
    var ptr_constraints_gname: u32 = 0;
    var ptr_constraints_gver: u32 = 0;

    var globals_done = false;
    var comp_state = CompState{};
    var iter: usize = 0;

    while (!globals_done and iter < 300) : (iter += 1) {
        // Service the compositor.
        try comp.pump(1, compHandler, &comp_state);

        // Drain client events.
        const cfd = conn.stream.socket.handle;
        while (fdReadable(cfd)) {
            const maybe_ev = client_mod.dispatchEvent(&conn, &imap, &msg_buf, &args_buf) catch |err| switch (err) {
                error.UnknownOpcode => break,
                error.MissingFd => {
                    if (conn.takeFd()) |kfd| _ = linux.close(kfd);
                    continue;
                },
                else => return err,
            };
            const ev = maybe_ev orelse continue;

            if (ev.interface == &wlp.WlCallback.interface and ev.object_id == sync_cb_id) {
                if (ev.opcode == @intFromEnum(wlp.WlCallback.EventOpcode.done)) {
                    imap.remove(sync_cb_id);
                    globals_done = true;
                    break;
                }
            }

            if (ev.interface == &wlp.WlRegistry.interface) {
                if (ev.opcode == @intFromEnum(wlp.WlRegistry.EventOpcode.global)) {
                    const gname = ev.args[0].uint;
                    const ifc = ev.args[1].string orelse continue;
                    const ver = ev.args[2].uint;
                    std.debug.print("[e2e] global: {s} name={d} ver={d}\n", .{ ifc, gname, ver });
                    if (std.mem.eql(u8, ifc, "wl_compositor")) {
                        compositor_gname = gname;
                        compositor_gver = ver;
                    } else if (std.mem.eql(u8, ifc, "wl_shm")) {
                        shm_gname = gname;
                        shm_gver = ver;
                    } else if (std.mem.eql(u8, ifc, "wl_seat")) {
                        seat_gname = gname;
                        seat_gver = ver;
                    } else if (std.mem.eql(u8, ifc, "xdg_wm_base")) {
                        xdg_wm_base_gname = gname;
                        xdg_wm_base_gver = ver;
                    } else if (std.mem.eql(u8, ifc, "zwp_relative_pointer_manager_v1")) {
                        rel_ptr_mgr_gname = gname;
                        rel_ptr_mgr_gver = ver;
                    } else if (std.mem.eql(u8, ifc, "zwp_pointer_constraints_v1")) {
                        ptr_constraints_gname = gname;
                        ptr_constraints_gver = ver;
                    }
                }
            }
        }
    }

    if (!globals_done) {
        try out.writeAll("FAIL: globals roundtrip timed out\n");
        try out.flush();
        std.process.exit(1);
    }

    // Verify required globals.
    if (compositor_gname == 0) {
        try out.writeAll("FAIL: wl_compositor not advertised\n");
        try out.flush();
        std.process.exit(1);
    }
    if (shm_gname == 0) {
        try out.writeAll("FAIL: wl_shm not advertised\n");
        try out.flush();
        std.process.exit(1);
    }
    if (seat_gname == 0) {
        try out.writeAll("FAIL: wl_seat not advertised\n");
        try out.flush();
        std.process.exit(1);
    }
    if (xdg_wm_base_gname == 0) {
        try out.writeAll("FAIL: xdg_wm_base not advertised\n");
        try out.flush();
        std.process.exit(1);
    }
    if (rel_ptr_mgr_gname == 0) {
        try out.writeAll("FAIL: zwp_relative_pointer_manager_v1 not advertised\n");
        try out.flush();
        std.process.exit(1);
    }
    if (ptr_constraints_gname == 0) {
        try out.writeAll("FAIL: zwp_pointer_constraints_v1 not advertised\n");
        try out.flush();
        std.process.exit(1);
    }

    std.debug.print("[e2e] all required globals present\n", .{});

    // -------------------------------------------------------------------------
    // Bind globals.
    // -------------------------------------------------------------------------

    const wl_compositor_id = try client_mod.bindGlobal(
        &conn,
        registry_id,
        compositor_gname,
        "wl_compositor",
        @min(compositor_gver, wlp.WlCompositor.version),
    );
    try imap.set(wl_compositor_id, &wlp.WlCompositor.interface);

    const wl_shm_id = try client_mod.bindGlobal(
        &conn,
        registry_id,
        shm_gname,
        "wl_shm",
        @min(shm_gver, wlp.WlShm.version),
    );
    try imap.set(wl_shm_id, &wlp.WlShm.interface);

    const wl_seat_id = try client_mod.bindGlobal(
        &conn,
        registry_id,
        seat_gname,
        "wl_seat",
        @min(seat_gver, wlp.WlSeat.version),
    );
    try imap.set(wl_seat_id, &wlp.WlSeat.interface);

    const xdg_wm_base_id = try client_mod.bindGlobal(
        &conn,
        registry_id,
        xdg_wm_base_gname,
        "xdg_wm_base",
        @min(xdg_wm_base_gver, xdg.XdgWmBase.version),
    );
    try imap.set(xdg_wm_base_id, &xdg.XdgWmBase.interface);

    const rel_ptr_mgr_id = try client_mod.bindGlobal(
        &conn,
        registry_id,
        rel_ptr_mgr_gname,
        "zwp_relative_pointer_manager_v1",
        @min(rel_ptr_mgr_gver, rp.ZwpRelativePointerManagerV1.version),
    );
    try imap.set(rel_ptr_mgr_id, &rp.ZwpRelativePointerManagerV1.interface);

    const ptr_constraints_id = try client_mod.bindGlobal(
        &conn,
        registry_id,
        ptr_constraints_gname,
        "zwp_pointer_constraints_v1",
        @min(ptr_constraints_gver, pc.ZwpPointerConstraintsV1.version),
    );
    try imap.set(ptr_constraints_id, &pc.ZwpPointerConstraintsV1.interface);

    // Pump to process all the bind requests server-side.
    {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            try comp.pump(1, compHandler, &comp_state);
        }
    }

    // -------------------------------------------------------------------------
    // Create a minimal SHM buffer pool (1x1 pixel, XRGB8888).
    // The compositor requires a real committed buffer to mark the surface mapped.
    // -------------------------------------------------------------------------

    // Allocate a memfd with one pixel of data.
    var shm_pool_data = try wl.shm.ShmPool.create(@intCast(SHM_SIZE));
    defer shm_pool_data.deinit();

    // Fill with an opaque white pixel.
    shm_pool_data.data[0] = 0xFF; // B
    shm_pool_data.data[1] = 0xFF; // G
    shm_pool_data.data[2] = 0xFF; // R
    shm_pool_data.data[3] = 0xFF; // X/A

    // Create the wl_shm_pool object.
    // NOTE: wlp.WlShm.createPool writes a bogus 4-byte inline fd placeholder which
    // corrupts the wire stream. Build the message manually WITHOUT the fd word:
    //   header + new_id(pool) + int(size)
    // Then send the actual fd out-of-band via sendFd (SCM_RIGHTS).
    const shm_pool_id = conn.objects.allocId();
    {
        const wl_wire = wl.wire;
        var pool_writer = wl_wire.Writer.init();
        defer pool_writer.deinit(gpa);
        try pool_writer.begin(gpa, wl_shm_id, 0); // create_pool opcode = 0
        try pool_writer.writeNewId(gpa, shm_pool_id);
        try pool_writer.writeInt(gpa, SHM_SIZE);
        const pool_msg = pool_writer.finish();
        try wl.shm.sendFd(conn.stream.socket.handle, pool_msg, shm_pool_data.fd);
    }
    try imap.set(shm_pool_id, &wlp.WlShmPool.interface);

    // Create the wl_buffer from the pool.
    const shm_buffer_id = conn.objects.allocId();
    try wlp.WlShmPool.createBuffer(
        &conn.wire_writer,
        gpa,
        shm_pool_id,
        shm_buffer_id,
        0, // offset
        SHM_WIDTH,
        SHM_HEIGHT,
        SHM_STRIDE,
        wl.shm.FORMAT_XRGB8888,
    );
    try conn.sendMessage(conn.wire_writer.finish());
    try imap.set(shm_buffer_id, &wlp.WlBuffer.interface);

    std.debug.print("[e2e] shm pool={d} buffer={d} created\n", .{ shm_pool_id, shm_buffer_id });

    // -------------------------------------------------------------------------
    // Create protocol objects: surface, xdg_surface, xdg_toplevel.
    // -------------------------------------------------------------------------

    // wl_surface.
    const surface_id = conn.objects.allocId();
    try wlp.WlCompositor.createSurface(&conn.wire_writer, gpa, wl_compositor_id, surface_id);
    try conn.sendMessage(conn.wire_writer.finish());
    try imap.set(surface_id, &wlp.WlSurface.interface);

    // xdg_surface.
    const xdg_surface_id = conn.objects.allocId();
    try xdg.XdgWmBase.getXdgSurface(&conn.wire_writer, gpa, xdg_wm_base_id, xdg_surface_id, surface_id);
    try conn.sendMessage(conn.wire_writer.finish());
    try imap.set(xdg_surface_id, &xdg.XdgSurface.interface);

    // xdg_toplevel.
    const xdg_toplevel_id = conn.objects.allocId();
    try xdg.XdgSurface.getToplevel(&conn.wire_writer, gpa, xdg_surface_id, xdg_toplevel_id);
    try conn.sendMessage(conn.wire_writer.finish());
    try imap.set(xdg_toplevel_id, &xdg.XdgToplevel.interface);

    // Initial commit to trigger configure.
    try wlp.WlSurface.commit(&conn.wire_writer, gpa, surface_id);
    try conn.sendMessage(conn.wire_writer.finish());

    // -------------------------------------------------------------------------
    // Create input objects.
    // -------------------------------------------------------------------------

    // wl_seat.get_pointer.
    const pointer_id = conn.objects.allocId();
    try wlp.WlSeat.getPointer(&conn.wire_writer, gpa, wl_seat_id, pointer_id);
    try conn.sendMessage(conn.wire_writer.finish());
    try imap.set(pointer_id, &wlp.WlPointer.interface);

    // zwp_relative_pointer_manager.get_relative_pointer.
    const rel_pointer_id = conn.objects.allocId();
    try rp.ZwpRelativePointerManagerV1.getRelativePointer(
        &conn.wire_writer,
        gpa,
        rel_ptr_mgr_id,
        rel_pointer_id,
        pointer_id,
    );
    try conn.sendMessage(conn.wire_writer.finish());
    try imap.set(rel_pointer_id, &rp.ZwpRelativePointerV1.interface);

    // zwp_pointer_constraints.lock_pointer (persistent, null region = full surface).
    const locked_pointer_id = conn.objects.allocId();
    try pc.ZwpPointerConstraintsV1.lockPointer(
        &conn.wire_writer,
        gpa,
        ptr_constraints_id,
        locked_pointer_id,
        surface_id,
        pointer_id,
        null,
        @intFromEnum(pc.ZwpPointerConstraintsV1.Lifetime.persistent),
    );
    try conn.sendMessage(conn.wire_writer.finish());
    try imap.set(locked_pointer_id, &pc.ZwpLockedPointerV1.interface);

    std.debug.print("[e2e] objects: wl_surf={d} xdg_surf={d} xdg_top={d} ptr={d} rel_ptr={d} locked={d}\n", .{
        surface_id, xdg_surface_id, xdg_toplevel_id,
        pointer_id, rel_pointer_id, locked_pointer_id,
    });

    // -------------------------------------------------------------------------
    // Main pump loop.
    //
    // Drive both compositor and client until:
    //   - surface is mapped (compositor fires surface_mapped)
    //   - focus + input is sent and relative_motion is received
    //   - OR timeout.
    // -------------------------------------------------------------------------

    var test_state = TestState{};
    var xdg_configure_done = false;
    var input_sent = false;
    var main_iter: usize = 0;
    const MAX_MAIN_ITERS: usize = 1000;

    while (main_iter < MAX_MAIN_ITERS) : (main_iter += 1) {
        // Service the compositor (pump 0ms = non-blocking dispatch only).
        try comp.pump(0, compHandler, &comp_state);

        // Drain client events.
        const cfd = conn.stream.socket.handle;
        while (fdReadable(cfd)) {
            const maybe_ev = client_mod.dispatchEvent(&conn, &imap, &msg_buf, &args_buf) catch |err| switch (err) {
                error.UnknownOpcode => break,
                error.MissingFd => {
                    // wl_keyboard.keymap sends an fd OOB - drain and skip.
                    if (conn.takeFd()) |kfd| _ = linux.close(kfd);
                    continue;
                },
                else => return err,
            };
            const ev = maybe_ev orelse continue;

            // xdg_wm_base.ping - pong is required.
            if (ev.interface == &xdg.XdgWmBase.interface) {
                if (ev.opcode == @intFromEnum(xdg.XdgWmBase.EventOpcode.ping)) {
                    try xdg.XdgWmBase.pong(&conn.wire_writer, gpa, xdg_wm_base_id, ev.args[0].uint);
                    try conn.sendMessage(conn.wire_writer.finish());
                }
                continue;
            }

            // xdg_toplevel.configure - ignore (size 0x0 means compositor chooses).
            if (ev.interface == &xdg.XdgToplevel.interface) {
                continue;
            }

            // xdg_surface.configure - must ack_configure then attach buffer + commit.
            if (ev.interface == &xdg.XdgSurface.interface and ev.object_id == xdg_surface_id) {
                if (ev.opcode == @intFromEnum(xdg.XdgSurface.EventOpcode.configure)) {
                    const serial = ev.args[0].uint;
                    std.debug.print("[e2e] xdg_surface configure serial={d}\n", .{serial});
                    // ack_configure.
                    try xdg.XdgSurface.ackConfigure(&conn.wire_writer, gpa, xdg_surface_id, serial);
                    try conn.sendMessage(conn.wire_writer.finish());
                    // Attach the shm buffer.
                    try wlp.WlSurface.attach(&conn.wire_writer, gpa, surface_id, shm_buffer_id, 0, 0);
                    try conn.sendMessage(conn.wire_writer.finish());
                    // Commit to complete mapping (compositor needs a buffer to mark mapped).
                    try wlp.WlSurface.commit(&conn.wire_writer, gpa, surface_id);
                    try conn.sendMessage(conn.wire_writer.finish());
                    xdg_configure_done = true;
                }
                continue;
            }

            // wl_pointer.motion - must NOT arrive while locked.
            if (ev.interface == &wlp.WlPointer.interface and ev.object_id == pointer_id) {
                if (ev.opcode == @intFromEnum(wlp.WlPointer.EventOpcode.motion)) {
                    test_state.got_motion = true;
                    std.debug.print("[e2e] UNEXPECTED wl_pointer.motion received!\n", .{});
                }
                continue;
            }

            // zwp_relative_pointer_v1.relative_motion - the event we want.
            if (ev.interface == &rp.ZwpRelativePointerV1.interface and ev.object_id == rel_pointer_id) {
                if (ev.opcode == @intFromEnum(rp.ZwpRelativePointerV1.EventOpcode.relative_motion)) {
                    if (ev.args.len >= 6) {
                        test_state.got_relative = true;
                        // args[2]=dx, args[3]=dy (fixed-point)
                        test_state.rel_dx = ev.args[2].fixed.toDouble();
                        test_state.rel_dy = ev.args[3].fixed.toDouble();
                        std.debug.print("[e2e] relative_motion dx={d:.3} dy={d:.3}\n", .{
                            test_state.rel_dx, test_state.rel_dy,
                        });
                    }
                }
                continue;
            }

            // zwp_locked_pointer_v1.locked - confirms constraint is active.
            if (ev.interface == &pc.ZwpLockedPointerV1.interface and ev.object_id == locked_pointer_id) {
                if (ev.opcode == @intFromEnum(pc.ZwpLockedPointerV1.EventOpcode.locked)) {
                    test_state.got_locked = true;
                    std.debug.print("[e2e] zwp_locked_pointer_v1.locked received\n", .{});
                }
                continue;
            }
        }

        // Once the compositor knows about the surface, drive input.
        // Re-send every iteration until we get relative_motion (handles delivery timing).
        if (comp_state.mapped and !test_state.got_relative) {
            if (!input_sent or main_iter % 10 == 0) {
                input_sent = true;
                // Focus activates the pointer lock constraint.
                comp.focus(comp_state.mapped_id);
                // pointerMotion should be suppressed (lock active).
                comp.pointerMotion(100, 100);
                // pointerRelative routes to relative_pointer.
                comp.pointerRelative(7, -3, 7, -3);
            }
        }

        // Done when relative_motion received.
        if (test_state.got_relative) break;

        // Small sleep to avoid busy-spinning 1000 iterations instantly.
        if (main_iter % 10 == 9) {
            const ts = linux.timespec{ .sec = 0, .nsec = 1_000_000 }; // 1ms
            _ = linux.nanosleep(&ts, null);
        }
    }

    // -------------------------------------------------------------------------
    // Assert + report.
    // -------------------------------------------------------------------------

    if (test_state.got_relative and !test_state.got_motion) {
        const dx_ok = @abs(test_state.rel_dx - 7.0) < 0.01;
        const dy_ok = @abs(test_state.rel_dy - (-3.0)) < 0.01;
        if (dx_ok and dy_ok) {
            try out.print(
                "PASS: relative_motion received (dx={d:.1} dy={d:.1}), wl_pointer.motion NOT received under lock\n",
                .{ test_state.rel_dx, test_state.rel_dy },
            );
            try out.flush();
            std.process.exit(0);
        } else {
            try out.print(
                "FAIL: relative_motion received but wrong values (dx={d:.3} dy={d:.3}, expected dx=7.000 dy=-3.000)\n",
                .{ test_state.rel_dx, test_state.rel_dy },
            );
            try out.flush();
            std.process.exit(1);
        }
    } else if (test_state.got_motion) {
        try out.writeAll("FAIL: wl_pointer.motion was received while pointer was locked\n");
        try out.flush();
        std.process.exit(1);
    } else if (!comp_state.mapped) {
        try out.writeAll("FAIL: surface was never mapped by the compositor\n");
        try out.flush();
        std.process.exit(1);
    } else {
        try out.print(
            "FAIL: relative_motion not received after {d} iterations (got_locked={}, mapped={}, xdg_configure_done={})\n",
            .{ main_iter, test_state.got_locked, comp_state.mapped, xdg_configure_done },
        );
        try out.flush();
        std.process.exit(1);
    }
}
