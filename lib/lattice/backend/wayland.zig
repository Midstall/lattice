/// Wayland client backend for lattice.
///
/// Owns the wayland.zig connection, prism device/context, a list of outputs,
/// a list of surfaces (placeholder for Task 7), and a wakeup eventfd.
///
/// Tasks 7-9 fill in createSurface, destroySurface, surfaceRenderTarget,
/// commitFrame, renderAvailable, and pump. This task wires the skeleton and
/// the connection/globals/prism bring-up so the smoke test can connect and exit.
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const xdg = @import("xdg_shell");
const ld = @import("linux_dmabuf");
const cm = @import("color_management");
const prism = @import("prism");
const rp = @import("relative_pointer");
const pc = @import("pointer_constraints");
const tv2 = @import("tablet_v2");

const client = wl.client;

const lattice_backend = @import("../backend.zig");
const event_mod = @import("../event.zig");
const surface_mod = @import("../surface.zig");
const output_mod = @import("../output.zig");
const id_mod = @import("../id.zig");
const options_mod = @import("../options.zig");

const globals_mod = @import("wayland/globals.zig");
const keyboard_mod = @import("../keyboard.zig");
const outputs_mod = @import("wayland/outputs.zig");
const window_mod = @import("wayland/window.zig");
const dispatch_mod = @import("wayland/dispatch.zig");
const wl_input_mod = @import("wayland/input.zig");
const color_mod = @import("wayland/color.zig");
const render = @import("../render.zig");
const format_map = @import("../format_map.zig");

pub const Window = window_mod.Window;

/// A supported dmabuf format/modifier pair collected from the compositor.
pub const DmabufFormat = struct {
    fourcc: u32,
    modifier: u64,
};

/// Re-export prism's DmaBufDesc so callers that import this module can use the
/// canonical type from the prism HAL (fd, width, height, format fourcc, stride,
/// offset, modifier).
pub const DmaBufDesc = prism.hal.DmaBufDesc;

pub const Wayland = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    conn: client.Connection,
    imap: client.InterfaceMap,
    registry_id: u32,
    compositor_id: u32,
    shm_id: u32,
    xdg_wm_base_id: u32,
    /// 0 if the compositor did not advertise zwp_linux_dmabuf_v1.
    zwp_linux_dmabuf_id: u32,
    /// 0 if the compositor did not advertise wp_color_manager_v1.
    wp_color_manager_id: u32,
    /// 0 if the parent compositor did not advertise wl_seat.
    seat_id: u32 = 0,
    /// 0 if wl_seat was not bound or pointer capability absent.
    pointer_id: u32 = 0,
    /// 0 if wl_seat was not bound or keyboard capability absent.
    keyboard_id: u32 = 0,
    /// Touch object id (deferred to Task 8; always 0 for now).
    touch_id: u32 = 0,
    /// The parent seat's device classes, as last advertised by wl_seat.capabilities.
    /// The first advertisement lands during the init roundtrip, so this is settled
    /// before the application can poll. dispatch.zig updates it on every change.
    seat_caps: event_mod.SeatCapabilities = .{},
    /// 0 if the parent compositor did not advertise zwp_relative_pointer_manager_v1,
    /// or if no wl_pointer exists to attach to.
    relative_pointer_id: u32 = 0,
    /// 0 if the parent compositor did not advertise zwp_pointer_constraints_v1.
    pointer_constraints_id: u32 = 0,
    /// 0 if the parent compositor did not advertise zwp_tablet_manager_v2.
    tablet_manager_id: u32 = 0,
    /// 0 if tablet_manager was not bound or seat was absent.
    tablet_seat_id: u32 = 0,
    /// Accumulated tablet tool axis state between frame events (frame-accumulate approach).
    /// x/y in surface-local wl.Fixed doubles; pressure in raw 0..65535 range.
    tablet_pending_x: f64 = 0,
    tablet_pending_y: f64 = 0,
    tablet_pending_pressure: f64 = 0,
    /// The active locked/confined pointer constraint object on the parent; 0 if none.
    active_constraint_id: u32 = 0,
    /// Which kind of constraint is active (.none, .lock, .confine). Used to call the
    /// correct destroy request when tearing down the active constraint.
    active_constraint_kind: enum { none, lock, confine } = .none,
    /// The surface the pointer is over, tracked from wl_pointer.enter.
    focus_surface: ?id_mod.SurfaceId = null,
    /// The surface holding KEYBOARD focus, tracked from wl_keyboard.enter. Key
    /// events go here, not to the pointer surface: the two foci are independent
    /// on every compositor.
    key_focus: ?id_mod.SurfaceId = null,
    /// The keymap and modifier state for the seat's keyboard. Starts empty; the
    /// compositor sends the keymap on wl_keyboard.keymap right after the
    /// keyboard object is bound, and dispatch.zig feeds it in.
    keyboard: keyboard_mod.KeyboardState,
    /// Format/modifier pairs advertised by the compositor during init roundtrip.
    dmabuf_formats: std.ArrayList(DmabufFormat),
    /// Accumulated neutral outputs from the initial roundtrip.
    outputs: std.ArrayList(output_mod.Output),
    /// Name buffers for outputs (stable storage so Output.name slices are valid).
    output_name_bufs: std.ArrayList([64]u8),
    device: prism.Device,
    ctx: prism.Context,
    /// The driver name chosen by createBestDevice or opts.driver (e.g. "nvidia", "software").
    driver_name: []const u8,
    surfaces: std.ArrayList(Window),
    wakeup_fd: posix.fd_t,
    next_surface_id: u32,
    /// Streaming output accumulators for hotplug events arriving during pump.
    /// Indexed by wl object id to apply wl_output events before the done burst.
    output_accums: std.ArrayList(outputs_mod.OutputAccum),

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        socket_path: []const u8,
        opts: options_mod.Options,
    ) !*Wayland {
        // 1. Connect.
        var conn = try client.connect(gpa, io, socket_path);
        errdefer conn.deinit();

        var imap = client.InterfaceMap.init(gpa);
        errdefer imap.deinit();

        // Register wl_display as object 1.
        try imap.set(1, &wlp.WlDisplay.interface);

        // 2. get_registry.
        const registry_id = try client.getRegistry(&conn);
        try imap.set(registry_id, &wlp.WlRegistry.interface);

        // 3. Roundtrip: collect globals.
        const raw_globals = try globals_mod.roundtripGlobals(&conn, &imap, registry_id, gpa);
        defer globals_mod.freeGlobals(gpa, raw_globals);

        // Debug: print what globals were advertised by the compositor.
        std.debug.print("[lattice] globals from compositor ({d}):\n", .{raw_globals.len});
        for (raw_globals) |g| {
            std.debug.print("  global name={d} interface={s} version={d}\n", .{ g.name, g.interface, g.version });
        }

        // 4. Bind standard globals.
        const bound = try globals_mod.bindStandards(&conn, &imap, registry_id, raw_globals, gpa);
        defer gpa.free(bound.output_ids);

        // 4b. If zwp_linux_dmabuf_v1 is bound (v4+), request default feedback to
        //     learn supported format+modifier pairs. Modern compositors (cosmic-comp 1.x
        //     on smithay) send NO legacy format/modifier events; feedback is the only path.
        //     We create the feedback object BEFORE the sync so its events arrive in the
        //     same roundtrip as output detail events.
        var feedback_id: u32 = 0;
        if (bound.zwp_linux_dmabuf_id != 0) {
            feedback_id = conn.objects.allocId();
            try ld.ZwpLinuxDmabufV1.getDefaultFeedback(&conn.wire_writer, gpa, bound.zwp_linux_dmabuf_id, feedback_id);
            try conn.sendMessage(conn.wire_writer.finish());
            try imap.set(feedback_id, &ld.ZwpLinuxDmabufFeedbackV1.interface);
        }

        // 5. Second roundtrip to collect output detail events (name/mode/scale)
        //    AND dmabuf format/modifier advertisements from the compositor.
        const cb2_id = try client.sync(&conn);
        try imap.set(cb2_id, &wlp.WlCallback.interface);

        // Accumulate output detail into OutputAccum per id.
        const accum_list = try gpa.alloc(outputs_mod.OutputAccum, bound.output_ids.len);
        defer gpa.free(accum_list);
        for (bound.output_ids, 0..) |oid, i| {
            accum_list[i] = .{ .id = oid };
        }

        // Collect dmabuf formats/modifiers here so they are ready before init returns.
        var dmabuf_formats_init: std.ArrayList(DmabufFormat) = .empty;
        errdefer dmabuf_formats_init.deinit(gpa);

        // Feedback state: format table is mmap-ed from the fd sent by the compositor.
        // Freed after we have populated dmabuf_formats_init from the tranche indices.
        var fmt_table_map: ?[]align(4096) const u8 = null;
        var fmt_table_len: usize = 0; // number of {u32,u32,u64} = 16-byte entries
        defer if (fmt_table_map) |m| posix.munmap(m);

        // wl_seat.capabilities arrives right after the seat is bound, so it lands in
        // this roundtrip, long before an application can install an event handler.
        // Capture it here or the first frame would lay itself out with no seat.
        var seat_caps_init: event_mod.SeatCapabilities = .{};

        var msg_buf2: [4096]u8 = undefined;
        var args2: [16]wl.Argument = undefined;
        var done2 = false;
        while (!done2) {
            // Use dispatchEvent for normal events. For ZwpLinuxDmabufFeedbackV1.format_table
            // the signature is "hu" (fd + uint). dispatchEvent passes null for conn to
            // demarshal, causing MissingFd. We detect that, take the fd from conn.recv_fds
            // (already queued by recvBytes/collectFds), and parse the size from msg_buf2.
            const ev_or_err = client.dispatchEvent(&conn, &imap, &msg_buf2, &args2);
            const maybe_ev: ?client.DecodedEvent = ev_or_err catch |err| blk: {
                if (err == error.MissingFd) {
                    // format_table event: fd arrived OOB, size is in the wire body.
                    // Wire layout: header(8) + size(u32=4) = 12 bytes total.
                    // The Reader pos is after the header; read the u32 directly from msg_buf2.
                    const ft_opcode = @intFromEnum(ld.ZwpLinuxDmabufFeedbackV1.EventOpcode.format_table);
                    const hdr_obj = std.mem.readInt(u32, msg_buf2[0..4], .little);
                    const hdr_w1 = std.mem.readInt(u32, msg_buf2[4..8], .little);
                    const hdr_op: u16 = @truncate(hdr_w1 & 0xffff);
                    if (hdr_obj == feedback_id and hdr_op == ft_opcode) {
                        // Read the format table fd (queued by collectFds during recvBytes).
                        const ft_fd = conn.takeFd() orelse {
                            std.debug.print("[lattice] format_table: expected fd in queue but got none\n", .{});
                            break :blk null;
                        };
                        defer _ = linux.close(ft_fd);
                        // Read the size from the wire body (bytes after the 8-byte header).
                        if (hdr_w1 >> 16 >= 12) {
                            const ft_size = std.mem.readInt(u32, msg_buf2[8..12], .little);
                            if (ft_size > 0 and ft_table_map_ref: {
                                const mapped = posix.mmap(null, ft_size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, ft_fd, 0) catch |e| {
                                    std.debug.print("[lattice] format_table mmap failed: {s}\n", .{@errorName(e)});
                                    break :ft_table_map_ref false;
                                };
                                // Release previous map if any (shouldn't happen, but be safe).
                                if (fmt_table_map) |old| posix.munmap(old);
                                fmt_table_map = mapped;
                                fmt_table_len = ft_size / 16; // each entry is 16 bytes
                                std.debug.print("[lattice] format_table: {d} entries\n", .{fmt_table_len});
                                break :ft_table_map_ref true;
                            } == false) {}
                        }
                    } else {
                        // Unexpected MissingFd on a different event: drain the fd.
                        if (conn.takeFd()) |fd| _ = linux.close(fd);
                    }
                    break :blk null;
                }
                return err;
            };
            const ev = maybe_ev orelse continue;
            if (ev.interface == &wlp.WlCallback.interface and ev.object_id == cb2_id) {
                if (ev.opcode == @intFromEnum(wlp.WlCallback.EventOpcode.done)) {
                    imap.remove(cb2_id);
                    done2 = true;
                }
                continue;
            }
            if (ev.interface == &wlp.WlDisplay.interface) {
                if (ev.opcode == @intFromEnum(wlp.WlDisplay.EventOpcode.@"error")) {
                    return error.ServerError;
                }
                continue;
            }
            if (ev.interface == &wlp.WlSeat.interface) {
                const logical = dispatch_mod.classify(ev.interface, ev.opcode, ev.args);
                if (logical == .wl_seat_capabilities) {
                    seat_caps_init = wl_input_mod.seatCapabilitiesFromMask(logical.wl_seat_capabilities.caps);
                }
                continue;
            }
            if (ev.interface == &wlp.WlOutput.interface) {
                for (accum_list) |*acc| {
                    if (acc.id == ev.object_id) {
                        applyOutputEvent(acc, ev);
                        break;
                    }
                }
                continue;
            }
            // Collect zwp_linux_dmabuf_v1 legacy format and modifier events (v3 compositors).
            if (ev.interface == &ld.ZwpLinuxDmabufV1.interface) {
                if (ev.opcode == @intFromEnum(ld.ZwpLinuxDmabufV1.EventOpcode.format)) {
                    // format event: arg[0] = fourcc u32; treat modifier as LINEAR (0).
                    const fourcc = ev.args[0].uint;
                    try dmabuf_formats_init.append(gpa, .{ .fourcc = fourcc, .modifier = 0 });
                } else if (ev.opcode == @intFromEnum(ld.ZwpLinuxDmabufV1.EventOpcode.modifier)) {
                    // modifier event: arg[0]=fourcc, arg[1]=modifier_hi, arg[2]=modifier_lo
                    const fourcc = ev.args[0].uint;
                    const mod_hi: u64 = ev.args[1].uint;
                    const mod_lo: u64 = ev.args[2].uint;
                    const modifier: u64 = (mod_hi << 32) | mod_lo;
                    try dmabuf_formats_init.append(gpa, .{ .fourcc = fourcc, .modifier = modifier });
                }
                continue;
            }
            // Handle zwp_linux_dmabuf_feedback_v1 events (v4+ compositors).
            // format_table is handled above (MissingFd path). Here we handle the rest:
            //   tranche_formats (opcode 5): wl_array of u16 indices into the format table.
            //   done (opcode 0): feedback sequence complete; clean up feedback object.
            //   Other events (main_device, tranche_target_device, tranche_done, tranche_flags): ignored.
            if (ev.interface == &ld.ZwpLinuxDmabufFeedbackV1.interface and ev.object_id == feedback_id) {
                if (ev.opcode == @intFromEnum(ld.ZwpLinuxDmabufFeedbackV1.EventOpcode.tranche_formats)) {
                    // ev.args[0] = array of bytes (u16 indices, little-endian)
                    const indices_bytes = ev.args[0].array orelse continue;
                    if (fmt_table_map) |ft| {
                        var idx_pos: usize = 0;
                        while (idx_pos + 2 <= indices_bytes.len) : (idx_pos += 2) {
                            const idx: u16 = std.mem.readInt(u16, indices_bytes[idx_pos..][0..2], .little);
                            const entry_off: usize = @as(usize, idx) * 16;
                            if (entry_off + 16 <= ft.len) {
                                const fourcc = std.mem.readInt(u32, ft[entry_off..][0..4], .little);
                                // bytes 4..8 are padding
                                const modifier = std.mem.readInt(u64, ft[entry_off + 8 ..][0..8], .little);
                                try dmabuf_formats_init.append(gpa, .{ .fourcc = fourcc, .modifier = modifier });
                            }
                        }
                    }
                } else if (ev.opcode == @intFromEnum(ld.ZwpLinuxDmabufFeedbackV1.EventOpcode.done)) {
                    // Feedback sequence complete. Destroy the feedback object and remove from imap.
                    const w2 = &conn.wire_writer;
                    ld.ZwpLinuxDmabufFeedbackV1.destroy(w2, gpa, feedback_id) catch {};
                    conn.sendMessage(w2.finish()) catch {};
                    imap.remove(feedback_id);
                    feedback_id = 0;
                    std.debug.print("[lattice] dmabuf feedback done: {d} format+modifier pairs collected\n", .{dmabuf_formats_init.items.len});
                }
                continue;
            }
        }
        // If feedback_id is still set (e.g. done event arrived after sync done in same roundtrip),
        // clean up. In practice the done event should always arrive before the sync.
        if (feedback_id != 0) {
            imap.remove(feedback_id);
            feedback_id = 0;
        }

        // Convert accumulators to neutral Outputs.
        // Use .empty + gpa pattern to match Zig 0.16.
        var out_list: std.ArrayList(output_mod.Output) = .empty;
        errdefer out_list.deinit(gpa);
        var name_bufs: std.ArrayList([64]u8) = .empty;
        errdefer name_bufs.deinit(gpa);

        // Pre-reserve capacity for both lists so neither reallocates during hotplug.
        // Max 32 outputs is plenty; this prevents dangling Output.name slices.
        try out_list.ensureTotalCapacity(gpa, 32);
        try name_bufs.ensureTotalCapacity(gpa, 32);

        for (accum_list, 0..) |acc, idx| {
            name_bufs.appendAssumeCapacity(acc.name_buf);
            var o = acc.toOutput(@intCast(idx + 1));
            // Point name at the stable name_buf in the list.
            o.name = name_bufs.items[name_bufs.items.len - 1][0..acc.name_len];
            try out_list.append(gpa, o);
        }

        // 6. Create prism device and context.
        const selected: prism.drivers.Selected = blk: {
            if (opts.driver) |dname| {
                const drv = prism.drivers.select(dname) orelse return error.UnknownDriver;
                const dev = try drv.createDevice(gpa);
                break :blk .{ .driver = drv, .device = dev };
            } else {
                break :blk prism.drivers.createBestDevice(gpa) orelse return error.NoWorkingDriver;
            }
        };
        errdefer selected.device.deinit();

        const ctx = try selected.device.createContext();
        errdefer ctx.deinit();

        // Print the selected driver so the operator can see which path is in use.
        std.debug.print("prism driver: {s} ({s})\n", .{ selected.driver.name, selected.device.caps().device_name });

        // 7. Create wakeup eventfd (EFD_CLOEXEC | EFD_NONBLOCK).
        const wakeup_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(wakeup_rc) != .SUCCESS) return error.EventfdFailed;
        const wakeup_fd: posix.fd_t = @intCast(wakeup_rc);
        errdefer _ = linux.close(wakeup_fd);

        // 8. Heap-allocate the struct so pointers remain stable.
        // 9. Build output_accums list for future hotplug wl_output events.
        var output_accums: std.ArrayList(outputs_mod.OutputAccum) = .empty;
        errdefer output_accums.deinit(gpa);
        for (bound.output_ids) |oid| {
            try output_accums.append(gpa, .{ .id = oid });
        }

        const self = try gpa.create(Wayland);
        self.* = .{
            .gpa = gpa,
            .io = io,
            // The keymap arrives on wl_keyboard.keymap, which is after this, so
            // the state starts empty. It still needs the two it cannot learn later.
            .keyboard = .{ .gpa = gpa, .io = io },
            .conn = conn,
            .imap = imap,
            .registry_id = registry_id,
            .compositor_id = bound.compositor_id,
            .shm_id = bound.shm_id,
            .xdg_wm_base_id = bound.xdg_wm_base_id,
            .zwp_linux_dmabuf_id = bound.zwp_linux_dmabuf_id,
            .wp_color_manager_id = bound.wp_color_manager_id,
            .dmabuf_formats = dmabuf_formats_init,
            .outputs = out_list,
            .output_name_bufs = name_bufs,
            .device = selected.device,
            .ctx = ctx,
            .driver_name = selected.driver.name,
            .surfaces = .empty,
            .wakeup_fd = wakeup_fd,
            .next_surface_id = 1,
            .output_accums = output_accums,
        };

        // 10. Bind wl_seat and create pointer + keyboard objects so input events arrive.
        self.seat_id = bound.wl_seat_id;
        self.seat_caps = seat_caps_init;
        if (self.seat_id != 0) {
            const w = &self.conn.wire_writer;

            self.pointer_id = self.conn.objects.allocId();
            try wlp.WlSeat.getPointer(w, gpa, self.seat_id, self.pointer_id);
            try self.conn.sendMessage(w.finish());
            try self.imap.set(self.pointer_id, &wlp.WlPointer.interface);

            self.keyboard_id = self.conn.objects.allocId();
            try wlp.WlSeat.getKeyboard(w, gpa, self.seat_id, self.keyboard_id);
            try self.conn.sendMessage(w.finish());
            try self.imap.set(self.keyboard_id, &wlp.WlKeyboard.interface);

            // Touch is created lazily on wl_seat.capabilities: get_touch on a seat
            // that never had the touch capability is a protocol violation that would
            // disconnect us, and most seats have no touchscreen. See dispatch.zig's
            // wl_seat_capabilities handling.
            std.log.info("lattice: wl_seat bound id={d} pointer_id={d} keyboard_id={d} caps: pointer={} keyboard={} touch={}", .{
                self.seat_id,
                self.pointer_id,
                self.keyboard_id,
                self.seat_caps.pointer,
                self.seat_caps.keyboard,
                self.seat_caps.touch,
            });
        }

        // 11. Store pointer_constraints_id and create an always-on zwp_relative_pointer_v1
        //     if both the manager and a pointer object exist.
        self.pointer_constraints_id = bound.pointer_constraints_id;
        if (bound.relative_pointer_manager_id != 0 and self.pointer_id != 0) {
            const w = &self.conn.wire_writer;
            const rp_id = self.conn.objects.allocId();
            try rp.ZwpRelativePointerManagerV1.getRelativePointer(w, gpa, bound.relative_pointer_manager_id, rp_id, self.pointer_id);
            try self.conn.sendMessage(w.finish());
            try self.imap.set(rp_id, &rp.ZwpRelativePointerV1.interface);
            self.relative_pointer_id = rp_id;
            std.log.info("lattice: relative_pointer_id={d} pointer_constraints_id={d}", .{ self.relative_pointer_id, self.pointer_constraints_id });
        }

        // 12. Bind tablet seat if the parent advertised zwp_tablet_manager_v2 and we have a seat.
        self.tablet_manager_id = bound.tablet_manager_id;
        if (self.tablet_manager_id != 0 and self.seat_id != 0) {
            const w = &self.conn.wire_writer;
            const ts_id = self.conn.objects.allocId();
            try tv2.ZwpTabletManagerV2.getTabletSeat(w, gpa, self.tablet_manager_id, ts_id, self.seat_id);
            try self.conn.sendMessage(w.finish());
            try self.imap.set(ts_id, &tv2.ZwpTabletSeatV2.interface);
            self.tablet_seat_id = ts_id;
            std.log.info("lattice: tablet_seat_id={d}", .{self.tablet_seat_id});
        }

        return self;
    }

    pub fn deinit(self: *Wayland) void {
        // Destroy any remaining surfaces (free prism targets, ShmBuffers, wl objects).
        while (self.surfaces.items.len > 0) {
            const sid = self.surfaces.items[0].id;
            self.destroySurfaceImpl(sid);
        }
        self.surfaces.deinit(self.gpa);
        self.dmabuf_formats.deinit(self.gpa);
        self.outputs.deinit(self.gpa);
        self.output_name_bufs.deinit(self.gpa);
        self.output_accums.deinit(self.gpa);
        self.keyboard.deinit();
        _ = linux.close(self.wakeup_fd);
        self.ctx.deinit();
        self.device.deinit();
        self.imap.deinit();
        self.conn.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Internal surface teardown shared by destroySurface vtable fn and deinit.
    fn destroySurfaceImpl(self: *Wayland, sid: id_mod.SurfaceId) void {
        const gpa = self.gpa;
        const w = &self.conn.wire_writer;

        var idx: ?usize = null;
        for (self.surfaces.items, 0..) |win, i| {
            if (win.id == sid) {
                idx = i;
                break;
            }
        }
        const i = idx orelse return;
        const win = self.surfaces.items[i];

        // Free the prism render-target Resource if any (shm path).
        if (win.target) |t| {
            self.device.destroyResource(t);
        }

        // Destroy ShmBuffers.
        for (&self.surfaces.items[i].buffers) |*slot| {
            if (slot.*) |*buf| {
                const bid = buf.buffer_id;
                const pid = buf.pool_id;
                buf.destroy(&self.conn, gpa) catch {};
                self.imap.remove(bid);
                self.imap.remove(pid);
                slot.* = null;
            }
        }

        // Destroy dmabuf wl_buffers BEFORE destroying the prism Resources.
        // The compositor holds a reference to each wl_buffer's dma-buf fd;
        // the fd is backed by the RT's prism export. Closing the RT while the
        // compositor still holds the fd causes UAF on the compositor side.
        for (&self.surfaces.items[i].dmabuf_wl) |*slot| {
            if (slot.*) |s| {
                wlp.WlBuffer.destroy(w, gpa, s.buffer_id) catch {};
                self.conn.sendMessage(w.finish()) catch {};
                self.imap.remove(s.buffer_id);
                slot.* = null;
            }
        }

        // Now destroy the dmabuf prism render targets.
        for (&self.surfaces.items[i].dmabuf_targets) |*slot| {
            if (slot.*) |t| {
                self.device.destroyResource(t);
                slot.* = null;
            }
        }

        // Destroy xdg/wl objects in reverse order.
        xdg.XdgToplevel.destroy(w, gpa, win.xdg_toplevel_id) catch {};
        self.conn.sendMessage(w.finish()) catch {};
        self.imap.remove(win.xdg_toplevel_id);

        xdg.XdgSurface.destroy(w, gpa, win.xdg_surface_id) catch {};
        self.conn.sendMessage(w.finish()) catch {};
        self.imap.remove(win.xdg_surface_id);

        // Destroy the wp_color_management_surface_v1 (HDR surfaces only).
        // Destroying it fires the compositor's surfaceResourceDestroyed hook,
        // which frees the server-side surface_states/managed_surfaces entries,
        // so this one destroy closes both the client and compositor leak.
        if (win.cm_surface_id != 0) {
            cm.WpColorManagementSurfaceV1.destroy(w, gpa, win.cm_surface_id) catch {};
            self.conn.sendMessage(w.finish()) catch {};
            self.imap.remove(win.cm_surface_id);
        }

        wlp.WlSurface.destroy(w, gpa, win.wl_surface_id) catch {};
        self.conn.sendMessage(w.finish()) catch {};
        self.imap.remove(win.wl_surface_id);

        // Remove the pending frame callback from imap if present.
        if (win.frame_cb_id) |cb_id| {
            self.imap.remove(cb_id);
        }

        // Remove any pending dmabuf params object from imap (in-flight async create).
        if (self.surfaces.items[i].pending_create) |pend_create| {
            self.imap.remove(pend_create.params_id);
        }

        _ = self.surfaces.orderedRemove(i);
    }

    /// Return true if the compositor advertised support for the given
    /// fourcc + modifier pair during the initial globals roundtrip.
    pub fn supportsFormat(self: *Wayland, fourcc: u32, modifier: u64) bool {
        for (self.dmabuf_formats.items) |fmt| {
            if (fmt.fourcc == fourcc and fmt.modifier == modifier) return true;
        }
        return false;
    }

    /// Send an async zwp_linux_buffer_params_v1.create request for one plane.
    ///
    /// Unlike the old create_immed path, this is NON-FATAL: if the compositor
    /// rejects the dmabuf it sends a `failed` event (not a connection-killing
    /// protocol error). The wl_buffer arrives later via the `created` event.
    ///
    /// The `add` message is built MANUALLY (fresh Writer, no fd payload word)
    /// because the generated ZwpLinuxBufferParamsV1.add writes a spurious 0
    /// placeholder before plane_idx, which would corrupt the wire stream.
    /// Mirror of the shmbuffer.zig wl_shm.create_pool workaround.
    ///
    /// Returns the params_id so the caller can record it as a pending create.
    pub fn startDmabufCreate(self: *Wayland, desc: DmaBufDesc) !u32 {
        const conn = &self.conn;
        const gpa = self.gpa;

        // 1. create_params -> new zwp_linux_buffer_params_v1 (no fd; generated fn ok)
        const params_id = conn.objects.allocId();
        {
            const w = &conn.wire_writer;
            try ld.ZwpLinuxDmabufV1.createParams(w, gpa, self.zwp_linux_dmabuf_id, params_id);
            try conn.sendMessage(w.finish());
        }
        try self.imap.set(params_id, &ld.ZwpLinuxBufferParamsV1.interface);

        // 2. add(fd, plane=0, offset, stride, mod_hi, mod_lo)
        //    BUILD MANUALLY: no fd payload word, fd travels via sendFd (SCM_RIGHTS).
        //    Wire layout: plane_idx(u32) offset(u32) stride(u32) mod_hi(u32) mod_lo(u32)
        {
            const wl_wire = wl.wire;
            var pw = wl_wire.Writer.init();
            defer pw.deinit(gpa);
            try pw.begin(gpa, params_id, @intFromEnum(ld.ZwpLinuxBufferParamsV1.RequestOpcode.add));
            try pw.writeUint(gpa, 0); // plane_idx = 0
            try pw.writeUint(gpa, desc.offset);
            try pw.writeUint(gpa, desc.stride);
            try pw.writeUint(gpa, @intCast(desc.modifier >> 32)); // modifier_hi
            try pw.writeUint(gpa, @intCast(desc.modifier & 0xffff_ffff)); // modifier_lo
            const msg = pw.finish();
            try wl.shm.sendFd(conn.stream.socket.handle, msg, desc.fd);
        }

        // 3. create(width, height, format, flags=0) -> ASYNC.
        //    The compositor sends a `created` event with the new wl_buffer id on success,
        //    or a `failed` event on failure. Both are NON-FATAL (no connection kill).
        //    Keep params_id in imap so the created/failed events dispatch correctly.
        {
            const w = &conn.wire_writer;
            try ld.ZwpLinuxBufferParamsV1.create(w, gpa, params_id, @intCast(desc.width), @intCast(desc.height), desc.format, 0);
            try conn.sendMessage(w.finish());
        }

        std.debug.print("[lattice] dmabuf: async create sent params_id={d} w={d} h={d} format=0x{x:08}\n", .{ params_id, desc.width, desc.height, desc.format });

        return params_id;
    }

    pub fn backend(self: *Wayland) lattice_backend.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ----- vtable implementations -----

    fn cast(ptr: *anyopaque) *Wayland {
        return @ptrCast(@alignCast(ptr));
    }

    fn capabilities(_: *anyopaque) lattice_backend.Capabilities {
        return .{ .hdr = false, .formats = &.{.xrgb8888} };
    }

    fn seatCapabilities(ptr: *anyopaque) event_mod.SeatCapabilities {
        return cast(ptr).seat_caps;
    }

    fn fdVt(ptr: *anyopaque) ?posix.fd_t {
        const self = cast(ptr);
        return self.conn.stream.socket.handle;
    }

    fn wakeupVt(ptr: *anyopaque) void {
        const self = cast(ptr);
        const val: u64 = 1;
        _ = linux.write(self.wakeup_fd, @ptrCast(&val), 8);
    }

    fn enumerateOutputs(ptr: *anyopaque) []const output_mod.Output {
        return cast(ptr).outputs.items;
    }

    fn deinitVt(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }

    fn createSurface(ptr: *anyopaque, desc: surface_mod.SurfaceDesc) anyerror!surface_mod.Surface {
        const self = cast(ptr);
        const gpa = self.gpa;
        const w = &self.conn.wire_writer;

        // Allocate object ids.
        const wl_surface_id = self.conn.objects.allocId();
        const xdg_surface_id = self.conn.objects.allocId();
        const xdg_toplevel_id = self.conn.objects.allocId();

        // wl_compositor.create_surface -> wl_surface
        try wlp.WlCompositor.createSurface(w, gpa, self.compositor_id, wl_surface_id);
        try self.conn.sendMessage(w.finish());
        try self.imap.set(wl_surface_id, &wlp.WlSurface.interface);

        // xdg_wm_base.get_xdg_surface(xdg_surface_id, wl_surface_id)
        try xdg.XdgWmBase.getXdgSurface(w, gpa, self.xdg_wm_base_id, xdg_surface_id, wl_surface_id);
        try self.conn.sendMessage(w.finish());
        try self.imap.set(xdg_surface_id, &xdg.XdgSurface.interface);

        // xdg_surface.get_toplevel(xdg_toplevel_id)
        try xdg.XdgSurface.getToplevel(w, gpa, xdg_surface_id, xdg_toplevel_id);
        try self.conn.sendMessage(w.finish());
        try self.imap.set(xdg_toplevel_id, &xdg.XdgToplevel.interface);

        // xdg_toplevel.set_title if non-empty
        if (desc.title.len > 0) {
            try xdg.XdgToplevel.setTitle(w, gpa, xdg_toplevel_id, desc.title);
            try self.conn.sendMessage(w.finish());
        }

        // wl_surface.commit (initial commit with no buffer triggers the first configure)
        try wlp.WlSurface.commit(w, gpa, wl_surface_id);
        try self.conn.sendMessage(w.finish());

        // Declare HDR color state via wp_color_management when the surface requests it.
        // Non-fatal: SDR surfaces are unaffected, and HDR declaration failure is logged
        // and skipped (the surface still works with compositor default sRGB handling).
        var cm_surface_id: u32 = 0;
        if (desc.color.isHdr()) {
            cm_surface_id = color_mod.declareSurfaceColor(
                &self.conn,
                &self.imap,
                gpa,
                self.wp_color_manager_id,
                wl_surface_id,
                desc.color,
            ) catch |e| blk: {
                std.log.warn("lattice: declareSurfaceColor failed: {s}", .{@errorName(e)});
                break :blk 0;
            };
        }

        // Build and store the Window.
        const sid = id_mod.SurfaceId.from(self.next_surface_id);
        self.next_surface_id += 1;

        const win = Window{
            .id = sid,
            .wl_surface_id = wl_surface_id,
            .xdg_surface_id = xdg_surface_id,
            .xdg_toplevel_id = xdg_toplevel_id,
            .width = desc.width,
            .height = desc.height,
            .desc = desc,
            .cm_surface_id = cm_surface_id,
        };
        try self.surfaces.append(gpa, win);

        return surface_mod.Surface{ .id = sid, .desc = desc };
    }

    fn destroySurface(ptr: *anyopaque, sid: id_mod.SurfaceId) void {
        cast(ptr).destroySurfaceImpl(sid);
    }

    /// Return a RenderTarget for the given surface, creating or recreating
    /// the prism Resource and ShmBuffers if this is the first call or the
    /// window has been resized since the last allocation.
    ///
    /// Consumer contract:
    ///   1. Call `rt.context.beginCommands()` to get a CommandBuffer.
    ///   2. `cb.setRenderTarget(rt.target)`, record draws/clears.
    ///   3. `rt.context.submit(cb)` to flush the GPU work.
    ///   4. Call `commitFrame(surface_id)` which maps the pixels, blits them
    ///      into an ShmBuffer, attaches + damages + requests a frame callback
    ///      and commits the wl_surface.
    ///
    /// NOTE on GPU sync: both the software and nvidia drivers' Context.submit are
    /// synchronous (each calls a blocking waitFence before returning). mapResource is
    /// therefore always safe to call right after submit. commitFrame calls
    /// device.unmapResource after the blit as the correct paired operation; for current
    /// drivers this is a no-op but is correct for any future driver that needs it.
    fn surfaceRenderTarget(ptr: *anyopaque, sid: id_mod.SurfaceId) anyerror!surface_mod.RenderTarget {
        const self = cast(ptr);
        const gpa = self.gpa;

        // Find the window.
        var win_ptr: ?*Window = null;
        for (self.surfaces.items) |*w| {
            if (w.id == sid) {
                win_ptr = w;
                break;
            }
        }
        const win = win_ptr orelse return error.SurfaceNotFound;

        const width = win.width;
        const height = win.height;

        // MODE SELECTION: on first use (nothing allocated yet), decide whether to
        // use dmabuf or shm. We check:
        //   - has_dmabuf: compositor advertised zwp_linux_dmabuf_v1
        //   - fmt_ok: compositor offers ARGB8888 (0x34325241) + LINEAR (modifier 0)
        //   - can_export: the HAL device has an exportResource vtable slot
        //   - NOT dmabuf_failed: if the surface already had a dmabuf create fail,
        //     force shm permanently.
        const is_first_use = (win.alloc_width == 0 and win.alloc_height == 0 and
            win.target == null and win.dmabuf_targets[0] == null);
        if (is_first_use) {
            if (win.dmabuf_failed) {
                // Surface previously had a dmabuf create failure; stick with shm.
                win.present_mode = .shm;
                std.debug.print("[lattice] present mode: shm (dmabuf previously failed)\n", .{});
            } else if (win.desc.color.format.isHdr()) {
                // HDR slice 2 Part 2b: fp16 OR 10-bit over a dma-buf via straight-
                // linear export. dmabuf only when the compositor advertises this
                // format's fourcc/LINEAR and the device can export; else the proven
                // Part 2a wl_shm HDR path.
                const pfmt = format_map.pixelFormatToPrism(win.desc.color.format);
                const hdr_fourcc = format_map.prismToFourcc(pfmt).?;
                const has_dmabuf = self.zwp_linux_dmabuf_id != 0;
                const hdr_fmt_ok = self.supportsFormat(hdr_fourcc, 0);
                const can_export = self.device.vtable.exportResource != null;
                win.present_mode = window_mod.chooseHdrMode(has_dmabuf, hdr_fmt_ok, can_export);
                if (win.present_mode == .dmabuf) {
                    std.debug.print("[lattice] present mode: dmabuf (HDR {s})\n", .{@tagName(win.desc.color.format)});
                } else {
                    std.debug.print("[lattice] present mode: shm (HDR {s}; dmabuf={} fmt_ok={} export={})\n", .{ @tagName(win.desc.color.format), has_dmabuf, hdr_fmt_ok, can_export });
                }
            } else {
                const has_dmabuf = self.zwp_linux_dmabuf_id != 0;
                const fmt_ok = self.supportsFormat(0x34325241, 0);
                const can_export = self.device.vtable.exportResource != null;
                std.debug.print("[lattice] mode-select: has_dmabuf={} fmt_ok={} can_export={} pairs={d}\n", .{ has_dmabuf, fmt_ok, can_export, self.dmabuf_formats.items.len });
                win.present_mode = window_mod.chooseDmabufMode(has_dmabuf, fmt_ok, can_export);
                if (win.present_mode == .dmabuf) {
                    std.debug.print("[lattice] present mode: dmabuf\n", .{});
                } else {
                    std.debug.print("[lattice] present mode: shm (fallback)\n", .{});
                }
            }
        }

        // Detect resize.
        const needs_recreate = (win.alloc_width != width or win.alloc_height != height) and
            (win.alloc_width != 0 or win.alloc_height != 0);

        switch (win.present_mode) {
            .dmabuf => {
                // On resize, destroy old targets and their cached wl_buffers.
                if (needs_recreate) {
                    self.destroyDmabufState(win);
                }

                const hdr = win.desc.color.format.isHdr();

                // Ensure both dmabuf render targets exist at current size.
                for (&win.dmabuf_targets) |*slot| {
                    if (slot.* == null) {
                        slot.* = try self.device.createResource(.{
                            .image = .{
                                .width = width,
                                .height = height,
                                .format = if (hdr) format_map.pixelFormatToPrism(win.desc.color.format) else .rgba8_unorm,
                                .usage = if (hdr) .{ .linear = true } else .{ .render_target = true },
                            },
                        });
                    }
                }

                // Record the alloc size.
                win.alloc_width = width;
                win.alloc_height = height;

                // Pick the free slot (null slot = target exists but no wl_buffer yet,
                // still renderable; prefer slot with no cached wl_buffer first).
                const idx = window_mod.pickFreeDmabuf(win.dmabuf_wl) orelse return error.NoFreeDmabufSlot;
                win.dmabuf_cur = idx;

                return surface_mod.RenderTarget{
                    .context = &self.ctx,
                    .target = win.dmabuf_targets[idx].?,
                    .width = width,
                    .height = height,
                    .format = if (hdr) win.desc.color.format else .xrgb8888,
                };
            },

            .shm => {
                // Detect resize: recreate shm resources if dimensions changed.
                if (needs_recreate) {
                    // Destroy old render-target Resource if any.
                    if (win.target) |old_target| {
                        self.device.destroyResource(old_target);
                        win.target = null;
                    }

                    // Destroy old ShmBuffers if any.
                    for (&win.buffers) |*slot| {
                        if (slot.*) |*buf| {
                            buf.destroy(&self.conn, gpa) catch {};
                            slot.* = null;
                        }
                    }
                }

                // Create prism render-target Resource if missing.
                if (win.target == null) {
                    const res = try self.device.createResource(.{
                        .image = .{
                            .width = width,
                            .height = height,
                            .format = .rgba8_unorm,
                            .usage = .{ .render_target = true },
                        },
                    });
                    win.target = res;
                }

                // Create ShmBuffers if missing. HDR surfaces allocate a format-
                // appropriate pool: fp16 (rgba16_float) gets ABGR16161616F / stride=w*8;
                // 10-bit (argb2101010/xrgb2101010) gets ABGR2101010 / stride=w*4;
                // SDR keeps the XRGB8888 / stride=w*4 path.
                const hdr_shm = win.desc.color.format.isHdr();
                for (&win.buffers) |*slot| {
                    if (slot.* == null) {
                        slot.* = if (hdr_shm) blk: {
                            const pfmt = format_map.pixelFormatToPrism(win.desc.color.format);
                            const hbpp = pfmt.bytesPerPixel();
                            const hfourcc = format_map.prismToFourcc(pfmt).?;
                            break :blk try window_mod.ShmBuffer.createWithFormat(
                                &self.conn,
                                self.shm_id,
                                &self.imap,
                                gpa,
                                width,
                                height,
                                hfourcc,
                                width * hbpp,
                            );
                        } else try window_mod.ShmBuffer.create(
                            &self.conn,
                            self.shm_id,
                            &self.imap,
                            gpa,
                            width,
                            height,
                        );
                    }
                }

                // Record the size we allocated at.
                win.alloc_width = width;
                win.alloc_height = height;

                return surface_mod.RenderTarget{
                    // Wayland is heap-allocated so &self.ctx is stable.
                    .context = &self.ctx,
                    .target = win.target.?,
                    .width = width,
                    .height = height,
                    // Report the surface's real pixel format. fp16 HDR surfaces present
                    // rgba16_float via CPU fill on commit; other HDR/SDR surfaces use
                    // xrgb8888 (the prism target is vestigial for CPU-filled HDR paths).
                    .format = if (win.desc.color.format == .rgba16_float) .rgba16_float else .xrgb8888,
                };
            },
        }
    }

    /// Destroy all dmabuf state for a window: cached wl_buffers first
    /// (wl destroy + imap remove), then the prism render targets.
    /// Safe to call at any point: skips null slots.
    pub fn destroyDmabufState(self: *Wayland, win: *Window) void {
        const gpa = self.gpa;
        const w = &self.conn.wire_writer;

        // Destroy cached wl_buffers BEFORE the prism Resources (the wl_buffer's
        // dma-buf fd is backed by the RT's prism export; closing the RT first
        // invalidates the fd that the compositor holds).
        for (&win.dmabuf_wl) |*slot| {
            if (slot.*) |s| {
                wlp.WlBuffer.destroy(w, gpa, s.buffer_id) catch {};
                self.conn.sendMessage(w.finish()) catch {};
                self.imap.remove(s.buffer_id);
                slot.* = null;
            }
        }

        // Now destroy the prism render targets.
        for (&win.dmabuf_targets) |*slot| {
            if (slot.*) |t| {
                self.device.destroyResource(t);
                slot.* = null;
            }
        }

        // Clear any in-flight pending create (the params object was already removed
        // from imap when we destroyed wl_buffers above, or it will be cleaned up
        // when the failed event arrives; either way, stop tracking it here).
        win.pending_create = null;

        // Reset alloc size so next surfaceRenderTarget recreates.
        win.alloc_width = 0;
        win.alloc_height = 0;
    }

    /// Present the rendered frame for the given surface.
    ///
    /// The consumer MUST have already called `rt.context.submit(cb)` before
    /// calling this function. Dispatches to the shm or dmabuf commit path
    /// depending on win.present_mode. Any dmabuf failure falls back to shm.
    fn commitFrame(ptr: *anyopaque, sid: id_mod.SurfaceId) anyerror!void {
        const self = cast(ptr);

        // Find the window.
        var win_ptr: ?*Window = null;
        for (self.surfaces.items) |*win| {
            if (win.id == sid) {
                win_ptr = win;
                break;
            }
        }
        const win = win_ptr orelse return error.SurfaceNotFound;

        switch (win.present_mode) {
            .dmabuf => {
                // Try the dmabuf commit path. On any failure, tear down dmabuf
                // state and switch to shm. We do NOT call commitFrameShm this
                // frame because shm resources (render target + ShmBuffers) do not
                // exist yet. The surface keeps its last-committed compositor content
                // untouched (no partial attach/commit). The next surfaceRenderTarget
                // call allocates shm resources, and the following commitFrame presents
                // normally. This self-heal-next-frame approach avoids sending a new
                // attach/commit with a destroyed or missing buffer (Fix I3).
                self.commitFrameDmabuf(win) catch |err| {
                    std.debug.print("[lattice] dmabuf commit failed ({s}), falling back to shm (next frame)\n", .{@errorName(err)});
                    self.destroyDmabufState(win);
                    win.present_mode = .shm;
                    // Mark dmabuf permanently failed for this surface: destroyDmabufState
                    // zeroes alloc_width/height so the next surfaceRenderTarget re-enters
                    // is_first_use and would otherwise re-select dmabuf via chooseHdrMode
                    // and retry the same failing export every frame (livelock). The
                    // dmabuf_failed gate forces shm permanently, self-healing to the
                    // proven Part 2a path. (A compositor `failed` event sets this too,
                    // but a LOCAL export/map throw -the HDR honest-wall trigger- does not.)
                    win.dmabuf_failed = true;
                    // Return cleanly; shm will present on the next frame cycle.
                };
            },
            .shm => {
                try self.commitFrameShm(win);
            },
        }
    }

    /// Dmabuf present path. Exports the current dmabuf_targets[cur] resource,
    /// kicks off an async wl_buffer create if needed, then attaches/damages/commits
    /// once the buffer is ready. Skips the attach/commit if a create is in-flight
    /// (the `created` event will make it ready for a later frame).
    fn commitFrameDmabuf(self: *Wayland, win: *Window) !void {
        const gpa = self.gpa;
        const w = &self.conn.wire_writer;
        const cur = win.dmabuf_cur;
        const width = win.alloc_width;
        const height = win.alloc_height;

        const target = win.dmabuf_targets[cur] orelse return error.RenderTargetNotReady;

        // Guard: re-attaching a wl_buffer the compositor still holds is a Wayland
        // protocol error. Normal flow gates this via renderAvailable/pickFreeDmabuf,
        // but reject misuse explicitly here (Fix I2).
        if (win.dmabuf_wl[cur]) |s| {
            if (s.busy) return error.DmabufSlotBusy;
        }

        // If no wl_buffer yet for this slot: kick off the async create (once only).
        if (win.dmabuf_wl[cur] == null) {
            // If there is already a pending create for this slot, skip this frame
            // and wait for the created/failed event to arrive.
            if (win.pending_create) |pend_create| {
                if (pend_create.slot == cur) {
                    std.debug.print("[lattice] dmabuf: create in-flight for slot={d}, skipping frame\n", .{cur});
                    return;
                }
            }

            // HDR dma-buf: the target is a system-linear CPU image.
            // Fill demo content before exporting (exportResource copies the
            // mapped bytes into the dma-buf backing at call time).
            if (win.desc.color.format.isHdr()) {
                const pfmt = format_map.pixelFormatToPrism(win.desc.color.format);
                const hbpp = pfmt.bytesPerPixel();
                const pixels = try self.device.mapResource(target);
                std.debug.assert(pixels.len >= @as(usize, width) * height * hbpp);
                switch (win.desc.color.format) {
                    .rgba16_float => window_mod.shmbuffer.fillHdrDemo(pixels, width, height, width * hbpp),
                    .argb2101010, .xrgb2101010 => window_mod.shmbuffer.fill10bitDemo(pixels, width, height, width * hbpp),
                    else => unreachable,
                }
                self.device.unmapResource(target);
            }

            // Export the resource and send the async create request.
            const desc = try self.device.exportResource(target);
            std.debug.print("[lattice] exportResource: fd={d} w={d} h={d} format=0x{x:08} stride={d} offset={d} modifier=0x{x}\n", .{ desc.fd, desc.width, desc.height, desc.format, desc.stride, desc.offset, desc.modifier });

            const params_id = try self.startDmabufCreate(desc);
            win.pending_create = .{ .params_id = params_id, .slot = cur };
            // Return without attaching this frame: wait for `created` event.
            return;
        }

        const slot = &win.dmabuf_wl[cur].?;

        // Attach + damage + frame callback + commit.
        try wlp.WlSurface.attach(w, gpa, win.wl_surface_id, slot.buffer_id, 0, 0);
        try self.conn.sendMessage(w.finish());

        try wlp.WlSurface.damageBuffer(w, gpa, win.wl_surface_id, 0, 0, @intCast(width), @intCast(height));
        try self.conn.sendMessage(w.finish());

        if (win.frame_cb_id) |old| self.imap.remove(old);
        const cb_id = self.conn.objects.allocId();
        try self.imap.set(cb_id, &wlp.WlCallback.interface);
        try wlp.WlSurface.frame(w, gpa, win.wl_surface_id, cb_id);
        try self.conn.sendMessage(w.finish());
        win.frame_cb_id = cb_id;

        try wlp.WlSurface.commit(w, gpa, win.wl_surface_id);
        try self.conn.sendMessage(w.finish());

        slot.busy = true;
    }

    /// Shm present path: map -> blit -> attach/damage/frame/commit.
    fn commitFrameShm(self: *Wayland, win: *Window) !void {
        const gpa = self.gpa;
        const w = &self.conn.wire_writer;

        const target = win.target orelse return error.RenderTargetNotReady;
        const width = win.alloc_width;
        const height = win.alloc_height;

        // HDR shm path: CPU-fill content directly into the format-appropriate pool.
        // fp16 (rgba16_float): fills ABGR16161616F (stride=w*8) with superwhite demo.
        // 10-bit (argb2101010/xrgb2101010): fills ABGR2101010 (stride=w*4) with 10-bit demo.
        // No prism GPU render / blit is used; the bytes flow verbatim to the compositor.
        if (win.desc.color.format.isHdr()) {
            const buf_idx = window_mod.pickFreeBuffer(win.buffers) orelse return error.NoFreeBuffer;
            const buf = &win.buffers[buf_idx].?;
            std.debug.assert(buf.data.len >= @as(usize, buf.stride) * height);
            switch (win.desc.color.format) {
                .rgba16_float => window_mod.shmbuffer.fillHdrDemo(buf.data, width, height, buf.stride),
                .argb2101010, .xrgb2101010 => window_mod.shmbuffer.fill10bitDemo(buf.data, width, height, buf.stride),
                else => unreachable,
            }

            try wlp.WlSurface.attach(w, gpa, win.wl_surface_id, buf.buffer_id, 0, 0);
            try self.conn.sendMessage(w.finish());
            try wlp.WlSurface.damageBuffer(w, gpa, win.wl_surface_id, 0, 0, @intCast(width), @intCast(height));
            try self.conn.sendMessage(w.finish());

            if (win.frame_cb_id) |old| self.imap.remove(old);
            const cb_id = self.conn.objects.allocId();
            try self.imap.set(cb_id, &wlp.WlCallback.interface);
            try wlp.WlSurface.frame(w, gpa, win.wl_surface_id, cb_id);
            try self.conn.sendMessage(w.finish());
            win.frame_cb_id = cb_id;

            try wlp.WlSurface.commit(w, gpa, win.wl_surface_id);
            try self.conn.sendMessage(w.finish());

            buf.busy = true;
            return;
        }

        // Map the render-target pixels.
        //
        // GPU SYNC NOTE: prism's Context.submit is synchronous for both the software and
        // the nvidia driver. Both call a blocking waitFence before returning from submit, so
        // by the time commitFrame is called the GPU work is complete and mapResource is safe.
        // No additional fence/waitIdle call is needed. If a future async driver is added,
        // it must fence inside its own submit implementation before this mapResource call.
        //
        // unmapResource: the HAL exposes device.unmapResource(res). For the software driver
        // it is a no-op (the mapping is the real backing). For the nvidia driver it is also
        // a no-op (the CPU mapping is kept alive until destroyResource). We call it here as
        // the correct paired operation so the code is correct for any future driver that does
        // need a real unmap (e.g. one that hands back a transient scratch buffer).
        const pixels = try self.device.mapResource(target);

        // Debug assert: mapped buffer must be large enough for the frame.
        std.debug.assert(pixels.len >= @as(usize, width) * height * 4);

        // Pick a free ShmBuffer.
        const buf_idx = window_mod.pickFreeBuffer(win.buffers) orelse return error.NoFreeBuffer;
        const buf = &win.buffers[buf_idx].?;

        // Blit rgba8_unorm -> XRGB8888.
        const src_stride: u32 = width * 4; // rgba8: 4 bytes per pixel, tightly packed
        render.blitRgba8ToXrgb8888(pixels, buf.data, width, height, src_stride, buf.stride);

        // Paired unmap after the blit. Currently a no-op for software and nvidia,
        // but correct to call for drivers that do release the scratch on unmap.
        self.device.unmapResource(target);

        // Wire up the wl_surface: attach, damage, frame callback, commit.
        try wlp.WlSurface.attach(w, gpa, win.wl_surface_id, buf.buffer_id, 0, 0);
        try self.conn.sendMessage(w.finish());

        try wlp.WlSurface.damageBuffer(w, gpa, win.wl_surface_id, 0, 0, @intCast(width), @intCast(height));
        try self.conn.sendMessage(w.finish());

        // Request a fresh frame callback for pacing.
        // Guard against stale frame_cb_id if commitFrame called twice before callback fires.
        if (win.frame_cb_id) |old| self.imap.remove(old);
        const cb_id = self.conn.objects.allocId();
        try self.imap.set(cb_id, &wlp.WlCallback.interface);
        try wlp.WlSurface.frame(w, gpa, win.wl_surface_id, cb_id);
        try self.conn.sendMessage(w.finish());
        win.frame_cb_id = cb_id;

        try wlp.WlSurface.commit(w, gpa, win.wl_surface_id);
        try self.conn.sendMessage(w.finish());

        // Mark the buffer as busy; compositor will release it when done.
        buf.busy = true;
    }

    /// True when the surface is ready for a new frame.
    /// Dispatches to shm or dmabuf readiness check depending on win.present_mode.
    /// Allocation-free: safe to call on every iteration of the run loop.
    fn renderAvailable(ptr: *anyopaque, sid: id_mod.SurfaceId) bool {
        const self = cast(ptr);

        // Find the window.
        var win_ptr: ?*const Window = null;
        for (self.surfaces.items) |*w| {
            if (w.id == sid) {
                win_ptr = w;
                break;
            }
        }
        const win = win_ptr orelse return false;

        const any_free: bool = switch (win.present_mode) {
            .dmabuf => blk: {
                // First frame (no targets created yet): allow through so
                // surfaceRenderTarget can allocate the resources.
                const any_allocated = (win.dmabuf_targets[0] != null or win.dmabuf_targets[1] != null);
                if (!any_allocated) break :blk true;
                // Otherwise a free slot = a null wl_buffer slot OR non-busy slot.
                break :blk window_mod.pickFreeDmabuf(win.dmabuf_wl) != null;
            },
            .shm => blk: {
                // First frame: shm buffers not yet allocated; let through.
                const any_allocated = (win.buffers[0] != null or win.buffers[1] != null);
                if (!any_allocated) break :blk true;
                break :blk window_mod.pickFreeBuffer(win.buffers) != null;
            },
        };

        return window_mod.canRender(
            win.configured,
            any_free,
            win.frame_cb_id != null,
        );
    }

    fn pump(ptr: *anyopaque, timeout_ms: ?u32, sink: lattice_backend.EventSink, sink_ctx: *anyopaque) anyerror!void {
        return dispatch_mod.pumpOnce(cast(ptr), timeout_ms, sink, sink_ctx);
    }

    fn renderDeviceVt(ptr: *anyopaque) ?*prism.Device {
        const self = cast(ptr);
        return &self.device;
    }

    /// Tear down the active parent pointer constraint (locked or confined) if any.
    /// Calls the correct destroy request based on active_constraint_kind, removes
    /// the object from imap, and clears active_constraint_id / active_constraint_kind.
    fn destroyActiveConstraint(self: *Wayland) void {
        if (self.active_constraint_id == 0) return;
        const gpa = self.gpa;
        const wire = &self.conn.wire_writer;
        switch (self.active_constraint_kind) {
            .lock => {
                pc.ZwpLockedPointerV1.destroy(wire, gpa, self.active_constraint_id) catch {};
                self.conn.sendMessage(wire.finish()) catch {};
            },
            .confine => {
                pc.ZwpConfinedPointerV1.destroy(wire, gpa, self.active_constraint_id) catch {};
                self.conn.sendMessage(wire.finish()) catch {};
            },
            .none => {},
        }
        self.imap.remove(self.active_constraint_id);
        self.active_constraint_id = 0;
        self.active_constraint_kind = .none;
    }

    /// Return the parent wl_surface object id for the focused (or first) window,
    /// or null if no windows exist.
    fn mainSurfaceWlId(self: *Wayland) ?u32 {
        if (self.focus_surface) |fid| {
            for (self.surfaces.items) |*win| {
                if (win.id == fid) return win.wl_surface_id;
            }
        }
        if (self.surfaces.items.len > 0) return self.surfaces.items[0].wl_surface_id;
        return null;
    }

    fn applyPointerConstraint(ptr: *anyopaque, req: lattice_backend.PointerConstraintReq) void {
        const self = cast(ptr);
        if (self.pointer_constraints_id == 0 or self.pointer_id == 0) return;

        const gpa = self.gpa;
        const wire = &self.conn.wire_writer;

        // Tear down any existing parent constraint first.
        self.destroyActiveConstraint();

        switch (req.kind) {
            .none => {},
            .lock, .confine => {
                // Find the nested window's parent wl_surface id.
                const surface_obj = self.mainSurfaceWlId() orelse return;
                const new_id = self.conn.objects.allocId();
                if (req.kind == .lock) {
                    pc.ZwpPointerConstraintsV1.lockPointer(
                        wire,
                        gpa,
                        self.pointer_constraints_id,
                        new_id,
                        surface_obj,
                        self.pointer_id,
                        null,
                        @intFromEnum(pc.ZwpPointerConstraintsV1.Lifetime.persistent),
                    ) catch return;
                    self.conn.sendMessage(wire.finish()) catch return;
                    self.imap.set(new_id, &pc.ZwpLockedPointerV1.interface) catch return;
                    self.active_constraint_kind = .lock;
                } else {
                    pc.ZwpPointerConstraintsV1.confinePointer(
                        wire,
                        gpa,
                        self.pointer_constraints_id,
                        new_id,
                        surface_obj,
                        self.pointer_id,
                        null,
                        @intFromEnum(pc.ZwpPointerConstraintsV1.Lifetime.persistent),
                    ) catch return;
                    self.conn.sendMessage(wire.finish()) catch return;
                    self.imap.set(new_id, &pc.ZwpConfinedPointerV1.interface) catch return;
                    self.active_constraint_kind = .confine;
                }
                self.active_constraint_id = new_id;
            },
        }
    }

    const vtable = lattice_backend.VTable{
        .capabilities = capabilities,
        .seatCapabilities = seatCapabilities,
        .fd = fdVt,
        .wakeup = wakeupVt,
        .enumerateOutputs = enumerateOutputs,
        .deinit = deinitVt,
        .createSurface = createSurface,
        .destroySurface = destroySurface,
        .surfaceRenderTarget = surfaceRenderTarget,
        .commitFrame = commitFrame,
        .renderAvailable = renderAvailable,
        .pump = pump,
        .renderDevice = renderDeviceVt,
        .applyPointerConstraint = applyPointerConstraint,
    };
};

// ----- Output event helpers -----

fn applyOutputEvent(acc: *outputs_mod.OutputAccum, ev: client.DecodedEvent) void {
    switch (@as(wlp.WlOutput.EventOpcode, @enumFromInt(ev.opcode))) {
        .mode => acc.applyMode(
            ev.args[1].int,
            ev.args[2].int,
            ev.args[3].int,
            ev.args[0].uint,
        ),
        .scale => acc.applyScale(ev.args[0].int),
        .name => acc.applyName(ev.args[0].string orelse ""),
        .geometry => acc.applyGeometry(
            ev.args[0].int,
            ev.args[1].int,
            ev.args[2].int,
            ev.args[3].int,
            ev.args[4].int,
            ev.args[5].string orelse "",
            ev.args[6].string orelse "",
            ev.args[7].int,
        ),
        .done => {},
        .description => {},
    }
}

// -------------------------------------------------------------------------
// Unit tests
// -------------------------------------------------------------------------

// Helper to build a synthetic Wayland-like struct for testing supportsFormat
// without a live compositor connection. We only populate dmabuf_formats.
const TestFormatSet = struct {
    formats: std.ArrayList(DmabufFormat),

    fn supportsFormat(self: *TestFormatSet, fourcc: u32, modifier: u64) bool {
        for (self.formats.items) |fmt| {
            if (fmt.fourcc == fourcc and fmt.modifier == modifier) return true;
        }
        return false;
    }
};

test "supportsFormat: ARGB8888+LINEAR present -> true" {
    const gpa = std.testing.allocator;
    var set = TestFormatSet{ .formats = .empty };
    defer set.formats.deinit(gpa);
    // ARGB8888 fourcc = 0x34325241, LINEAR modifier = 0
    try set.formats.append(gpa, .{ .fourcc = 0x34325241, .modifier = 0 });
    try set.formats.append(gpa, .{ .fourcc = 0x34325258, .modifier = 0 });
    try std.testing.expect(set.supportsFormat(0x34325241, 0));
}

test "supportsFormat: missing fourcc -> false" {
    const gpa = std.testing.allocator;
    var set = TestFormatSet{ .formats = .empty };
    defer set.formats.deinit(gpa);
    try set.formats.append(gpa, .{ .fourcc = 0x34325258, .modifier = 0 });
    try std.testing.expect(!set.supportsFormat(0x34325241, 0));
}

test "supportsFormat: fourcc present with different modifier -> false" {
    const gpa = std.testing.allocator;
    var set = TestFormatSet{ .formats = .empty };
    defer set.formats.deinit(gpa);
    // Only ARGB8888 + some tiled modifier, not LINEAR
    try set.formats.append(gpa, .{ .fourcc = 0x34325241, .modifier = 0x100000000001 });
    // LINEAR (0) not present
    try std.testing.expect(!set.supportsFormat(0x34325241, 0));
    // The other modifier is present
    try std.testing.expect(set.supportsFormat(0x34325241, 0x100000000001));
}
