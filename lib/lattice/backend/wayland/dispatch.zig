/// dispatch.zig: pump loop and event translation for the Wayland backend.
///
/// Key design:
///   classify(interface, opcode, args) -> LogicalEvent
///     Pure function - maps a decoded wire event to a LogicalEvent variant.
///     Unit-testable without a live connection (takes only the raw parts).
///
///   pumpOnce(w, timeout_ms, sink, sink_ctx) !void
///     Calls std.posix.poll on [wayland_fd, wakeup_fd] with the given
///     timeout (null -> -1, else N ms). If wayland fd is readable, calls
///     client.dispatchEvent in a bounded loop (up to MAX_DRAIN per poll
///     notification) to drain available messages without blocking.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const xdg = @import("xdg_shell");
const ld = @import("linux_dmabuf");
const rp = @import("relative_pointer");
const tv2 = @import("tablet_v2");

const input_mod = @import("input.zig");

const client = wl.client;

const lattice_backend = @import("../../backend.zig");
const event_mod = @import("../../event.zig");
const id_mod = @import("../../id.zig");
const keyboard_mod = @import("../../keyboard.zig");
const outputs_mod = @import("outputs.zig");
const window_mod = @import("window.zig");

const wayland_mod = @import("../wayland.zig");
const Wayland = wayland_mod.Wayland;

/// Maximum decode iterations per readable poll notification.
/// Keeps pumpOnce from blocking if a burst of events arrives.
const MAX_DRAIN = 64;

// -------------------------------------------------------------------------
// LogicalEvent: the classify() output
// -------------------------------------------------------------------------

pub const LogicalEvent = union(enum) {
    xdg_surface_configure: struct { serial: u32 },
    xdg_toplevel_configure: struct { width: i32, height: i32 },
    xdg_toplevel_close: void,
    frame_done: void,
    wl_buffer_release: void,
    wl_output_mode: struct { flags: u32, width: i32, height: i32, refresh_mhz: i32 },
    wl_output_scale: struct { factor: i32 },
    wl_output_name: struct { name: []const u8 },
    wl_output_done: void,
    xdg_ping: struct { serial: u32 },
    wl_output_geometry: struct {
        x: i32,
        y: i32,
        physical_width: i32,
        physical_height: i32,
        subpixel: i32,
        make: []const u8,
        model: []const u8,
        transform: i32,
    },
    /// zwp_linux_buffer_params_v1.failed: the compositor rejected the dmabuf params.
    zwp_linux_buffer_params_failed: void,
    /// zwp_linux_buffer_params_v1.created: async create succeeded; buffer_id is the new wl_buffer.
    zwp_linux_buffer_params_created: struct { buffer_id: u32 },
    /// Input: wl_pointer.enter - pointer entered a surface; used for focus tracking only.
    wl_pointer_enter: struct { surface_obj: u32 },
    /// Input: wl_pointer.motion - cursor moved over the focused surface.
    wl_pointer_motion: struct { x: f64, y: f64 },
    /// Input: wl_pointer.button - mouse button pressed or released.
    wl_pointer_button: struct { button: u32, state: u32 },
    /// Input: wl_pointer.axis - scroll wheel or other axis event.
    wl_pointer_axis: struct { axis: u32, value: f64 },
    /// Input: wl_keyboard.key - keyboard key pressed or released.
    wl_keyboard_key: struct { key: u32, state: u32 },
    /// Input: wl_keyboard.keymap - the compositor's keymap, as an fd and a size.
    /// format 1 is XKB v1 text; format 0 means the compositor supplies nothing.
    wl_keyboard_keymap: struct { format: u32, fd: i32, size: u32 },
    /// Input: wl_keyboard.enter - a surface gained the keyboard focus.
    wl_keyboard_enter: struct { surface_obj: u32 },
    /// Input: wl_keyboard.leave - a surface lost the keyboard focus.
    wl_keyboard_leave: struct { surface_obj: u32 },
    /// Input: wl_keyboard.modifiers - the serialized modifier and group state.
    wl_keyboard_modifiers: struct { depressed: u32, latched: u32, locked: u32, group: u32 },
    wl_seat_capabilities: struct { caps: u32 },
    /// Input: wl_touch.down - a touch contact started.
    wl_touch_down: struct { id: i32, x: f64, y: f64 },
    /// Input: wl_touch.up - a touch contact ended.
    wl_touch_up: struct { id: i32 },
    /// Input: wl_touch.motion - a touch contact moved.
    wl_touch_motion: struct { id: i32, x: f64, y: f64 },
    /// Input: zwp_relative_pointer_v1.relative_motion - raw pointer delta from the parent.
    wl_relative_motion: struct { dx: f64, dy: f64, dx_unaccel: f64, dy_unaccel: f64 },
    /// zwp_tablet_seat_v2.tablet_added: parent advertises a new tablet; new_id is the object id.
    tablet_seat_tablet_added: struct { new_id: u32 },
    /// zwp_tablet_seat_v2.tool_added: parent advertises a new tool; new_id is the object id.
    tablet_seat_tool_added: struct { new_id: u32 },
    /// zwp_tablet_tool_v2.proximity_in: tool entered proximity.
    tablet_tool_proximity_in: void,
    /// zwp_tablet_tool_v2.proximity_out: tool left proximity.
    tablet_tool_proximity_out: void,
    /// zwp_tablet_tool_v2.motion: tool moved in surface-local coords (wl.Fixed).
    tablet_tool_motion: struct { x: f64, y: f64 },
    /// zwp_tablet_tool_v2.pressure: tool pressure update (raw 0..65535).
    tablet_tool_pressure: struct { pressure: u32 },
    /// zwp_tablet_tool_v2.down: tool tip touched the surface.
    tablet_tool_down: void,
    /// zwp_tablet_tool_v2.up: tool tip lifted from the surface.
    tablet_tool_up: void,
    /// zwp_tablet_tool_v2.frame: end of a hardware event group; emit accumulated state.
    tablet_tool_frame: void,
    other: void,
};

/// Safe opcode -> enum helper. Returns null when opcode is not a valid enum value.
/// Zig 0.16 has no std.meta.intToEnum; we implement it by scanning tag values.
fn toOpcode(comptime E: type, raw: u16) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| {
        if (f.value == raw) return @field(E, f.name);
    }
    return null;
}

/// Pure classification of a decoded event by its interface pointer and opcode.
/// Takes the interface pointer from DecodedEvent, the raw opcode, and the args
/// slice. Uses toOpcode() to safely handle unknown opcodes (returns .other).
pub fn classify(
    interface: *const wl.Interface,
    opcode: u16,
    args: []const wl.Argument,
) LogicalEvent {
    if (interface == &xdg.XdgSurface.interface) {
        const op = toOpcode(xdg.XdgSurface.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            .configure => .{ .xdg_surface_configure = .{
                .serial = args[0].uint,
            } },
        };
    }

    if (interface == &xdg.XdgToplevel.interface) {
        const op = toOpcode(xdg.XdgToplevel.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            .configure => .{
                .xdg_toplevel_configure = .{
                    .width = args[0].int,
                    .height = args[1].int,
                    // args[2] is the states array; ignored here
                },
            },
            .close => .{ .xdg_toplevel_close = {} },
            // configure_bounds and wm_capabilities: present in the enum but not
            // relevant to this plan - ignore safely.
            .configure_bounds, .wm_capabilities => .other,
        };
    }

    if (interface == &wlp.WlCallback.interface) {
        const op = toOpcode(wlp.WlCallback.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            .done => .{ .frame_done = {} },
        };
    }

    if (interface == &wlp.WlBuffer.interface) {
        const op = toOpcode(wlp.WlBuffer.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            .release => .{ .wl_buffer_release = {} },
        };
    }

    if (interface == &wlp.WlOutput.interface) {
        const op = toOpcode(wlp.WlOutput.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            .mode => .{ .wl_output_mode = .{
                .flags = args[0].uint,
                .width = args[1].int,
                .height = args[2].int,
                .refresh_mhz = args[3].int,
            } },
            .scale => .{ .wl_output_scale = .{ .factor = args[0].int } },
            .name => .{ .wl_output_name = .{ .name = args[0].string orelse "" } },
            .done => .{ .wl_output_done = {} },
            .geometry => .{ .wl_output_geometry = .{
                .x = args[0].int,
                .y = args[1].int,
                .physical_width = args[2].int,
                .physical_height = args[3].int,
                .subpixel = args[4].int,
                .make = args[5].string orelse "",
                .model = args[6].string orelse "",
                .transform = args[7].int,
            } },
            .description => .other,
        };
    }

    if (interface == &xdg.XdgWmBase.interface) {
        const op = toOpcode(xdg.XdgWmBase.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            .ping => .{ .xdg_ping = .{ .serial = args[0].uint } },
        };
    }

    if (interface == &ld.ZwpLinuxBufferParamsV1.interface) {
        const op = toOpcode(ld.ZwpLinuxBufferParamsV1.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            .failed => .{ .zwp_linux_buffer_params_failed = {} },
            // created carries the new wl_buffer id in args[0].new_id.
            .created => .{ .zwp_linux_buffer_params_created = .{ .buffer_id = args[0].new_id } },
        };
    }

    if (interface == &wlp.WlPointer.interface) {
        const op = toOpcode(wlp.WlPointer.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            // enter: args = [serial(u), surface(o), x(f), y(f)]
            .enter => .{ .wl_pointer_enter = .{ .surface_obj = args[1].object orelse 0 } },
            // motion: args = [time(u), x(f), y(f)]
            .motion => .{ .wl_pointer_motion = .{ .x = args[1].fixed.toDouble(), .y = args[2].fixed.toDouble() } },
            // button: args = [serial(u), time(u), button(u), state(u)]
            .button => .{ .wl_pointer_button = .{ .button = args[2].uint, .state = args[3].uint } },
            // axis: args = [time(u), axis(u), value(f)]
            .axis => .{ .wl_pointer_axis = .{ .axis = args[1].uint, .value = args[2].fixed.toDouble() } },
            else => .other,
        };
    }

    if (interface == &wlp.WlKeyboard.interface) {
        const op = toOpcode(wlp.WlKeyboard.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            // key: args = [serial(u), time(u), key(u), state(u)]
            .key => .{ .wl_keyboard_key = .{ .key = args[2].uint, .state = args[3].uint } },
            // keymap: args = [format(u), fd(h), size(u)]
            .keymap => .{ .wl_keyboard_keymap = .{ .format = args[0].uint, .fd = args[1].fd, .size = args[2].uint } },
            // enter: args = [serial(u), surface(o), keys(a)]
            .enter => .{ .wl_keyboard_enter = .{ .surface_obj = args[1].object orelse 0 } },
            // leave: args = [serial(u), surface(o)]
            .leave => .{ .wl_keyboard_leave = .{ .surface_obj = args[1].object orelse 0 } },
            // modifiers: args = [serial(u), depressed(u), latched(u), locked(u), group(u)]
            .modifiers => .{ .wl_keyboard_modifiers = .{
                .depressed = args[1].uint,
                .latched = args[2].uint,
                .locked = args[3].uint,
                .group = args[4].uint,
            } },
            // repeat_info is client-side key repeat timing, which nothing consumes
            // yet. The neutral event has no repeat action until then.
            else => .other,
        };
    }

    if (interface == &wlp.WlTouch.interface) {
        const op = toOpcode(wlp.WlTouch.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            // down: args = [serial(u), time(u), surface(o), id(i), x(f), y(f)]
            .down => .{ .wl_touch_down = .{ .id = args[3].int, .x = args[4].fixed.toDouble(), .y = args[5].fixed.toDouble() } },
            // up: args = [serial(u), time(u), id(i)]
            .up => .{ .wl_touch_up = .{ .id = args[2].int } },
            // motion: args = [time(u), id(i), x(f), y(f)]
            .motion => .{ .wl_touch_motion = .{ .id = args[1].int, .x = args[2].fixed.toDouble(), .y = args[3].fixed.toDouble() } },
            else => .other,
        };
    }

    if (interface == &wlp.WlSeat.interface) {
        const op = toOpcode(wlp.WlSeat.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            // capabilities: args = [capabilities(u)] bitmask (pointer=1, keyboard=2, touch=4)
            .capabilities => .{ .wl_seat_capabilities = .{ .caps = args[0].uint } },
            else => .other, // .name
        };
    }

    if (interface == &rp.ZwpRelativePointerV1.interface) {
        const op = toOpcode(rp.ZwpRelativePointerV1.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            // relative_motion: args = [utime_hi(u), utime_lo(u), dx(f), dy(f), dx_unaccel(f), dy_unaccel(f)]
            .relative_motion => .{ .wl_relative_motion = .{
                .dx = args[2].fixed.toDouble(),
                .dy = args[3].fixed.toDouble(),
                .dx_unaccel = args[4].fixed.toDouble(),
                .dy_unaccel = args[5].fixed.toDouble(),
            } },
        };
    }

    if (interface == &tv2.ZwpTabletSeatV2.interface) {
        const op = toOpcode(tv2.ZwpTabletSeatV2.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            // tablet_added: args = [new_id(n)] - compositor sends a new ZwpTabletV2 object id.
            .tablet_added => .{ .tablet_seat_tablet_added = .{ .new_id = args[0].new_id } },
            // tool_added: args = [new_id(n)] - compositor sends a new ZwpTabletToolV2 object id.
            .tool_added => .{ .tablet_seat_tool_added = .{ .new_id = args[0].new_id } },
            // pad_added: not handled; ignore safely.
            .pad_added => .other,
        };
    }

    if (interface == &tv2.ZwpTabletToolV2.interface) {
        const op = toOpcode(tv2.ZwpTabletToolV2.EventOpcode, opcode) orelse return .other;
        return switch (op) {
            // proximity_in: args = [serial(u), tablet(o), surface(o)]
            .proximity_in => .tablet_tool_proximity_in,
            // proximity_out: no args
            .proximity_out => .tablet_tool_proximity_out,
            // down: args = [serial(u)]
            .down => .tablet_tool_down,
            // up: no args
            .up => .tablet_tool_up,
            // motion: args = [x(f), y(f)]
            .motion => .{ .tablet_tool_motion = .{
                .x = args[0].fixed.toDouble(),
                .y = args[1].fixed.toDouble(),
            } },
            // pressure: args = [pressure(u)] - raw 0..65535
            .pressure => .{ .tablet_tool_pressure = .{ .pressure = args[0].uint } },
            // frame: args = [time(u)] - end of event group; we emit accumulated state
            .frame => .tablet_tool_frame,
            // All other tool events (type, hardware_serial, capability, done, removed, etc.) ignored.
            else => .other,
        };
    }

    return .other;
}

// -------------------------------------------------------------------------
// translate: DecodedEvent + Wayland state -> optional neutral Event
// -------------------------------------------------------------------------

/// Translate a decoded wire event into a neutral lattice Event given the
/// current backend state. Returns null for events that do not produce a
/// neutral Event (e.g. ping, buffer release, output geometry - handled as
/// side effects in pumpOnce).
///
/// NOTE: this is intentionally kept pure at the classify() level. The
/// side-effect path (ackConfigure, pong, etc.) lives in pumpOnce.
pub fn translate(
    ev: client.DecodedEvent,
    w: *Wayland,
) ?event_mod.Event {
    const logical = classify(ev.interface, ev.opcode, ev.args);

    switch (logical) {
        .xdg_toplevel_configure => |cfg| {
            if (cfg.width > 0 and cfg.height > 0) {
                // Find the window with a matching xdg_toplevel_id.
                for (w.surfaces.items) |*win| {
                    if (win.xdg_toplevel_id == ev.object_id) {
                        win.width = @intCast(cfg.width);
                        win.height = @intCast(cfg.height);
                        return event_mod.Event{ .resized = .{
                            .surface = win.id,
                            .width = @intCast(cfg.width),
                            .height = @intCast(cfg.height),
                        } };
                    }
                }
            }
            return null;
        },

        .xdg_toplevel_close => {
            for (w.surfaces.items) |*win| {
                if (win.xdg_toplevel_id == ev.object_id) {
                    return event_mod.Event{ .close_requested = win.id };
                }
            }
            return null;
        },

        // xdg_surface.configure is handled entirely in pumpOnce (ackConfigure
        // side effect + redraw_requested emission after configure); translate
        // returns null here. pumpOnce calls this after doing the side effects.
        // Input events are emitted from handleEvent (focus resolution + emission);
        // translate returns null for all of them.
        .xdg_surface_configure,
        .frame_done,
        .wl_buffer_release,
        .wl_output_mode,
        .wl_output_scale,
        .wl_output_name,
        .wl_output_done,
        .wl_output_geometry,
        .xdg_ping,
        .zwp_linux_buffer_params_failed,
        .zwp_linux_buffer_params_created,
        .wl_pointer_enter,
        .wl_pointer_motion,
        .wl_pointer_button,
        .wl_pointer_axis,
        .wl_keyboard_key,
        .wl_keyboard_keymap,
        .wl_keyboard_enter,
        .wl_keyboard_leave,
        .wl_keyboard_modifiers,
        .wl_touch_down,
        .wl_touch_up,
        .wl_touch_motion,
        .wl_seat_capabilities,
        .wl_relative_motion,
        .tablet_seat_tablet_added,
        .tablet_seat_tool_added,
        .tablet_tool_proximity_in,
        .tablet_tool_proximity_out,
        .tablet_tool_motion,
        .tablet_tool_pressure,
        .tablet_tool_down,
        .tablet_tool_up,
        .tablet_tool_frame,
        .other,
        => return null,
    }
}

// -------------------------------------------------------------------------
// pumpOnce: poll + drain + translate + emit
// -------------------------------------------------------------------------

/// Look up a Window by its xdg_surface_id.
fn findWindowByXdgSurface(w: *Wayland, xdg_surface_id: u32) ?*window_mod.Window {
    for (w.surfaces.items) |*win| {
        if (win.xdg_surface_id == xdg_surface_id) return win;
    }
    return null;
}

/// Look up a Window by its xdg_toplevel_id.
fn findWindowByXdgToplevel(w: *Wayland, xdg_toplevel_id: u32) ?*window_mod.Window {
    for (w.surfaces.items) |*win| {
        if (win.xdg_toplevel_id == xdg_toplevel_id) return win;
    }
    return null;
}

/// Look up a Window by its frame_cb_id (wl_callback for frame pacing).
fn findWindowByFrameCb(w: *Wayland, cb_id: u32) ?*window_mod.Window {
    for (w.surfaces.items) |*win| {
        if (win.frame_cb_id) |fid| {
            if (fid == cb_id) return win;
        }
    }
    return null;
}

/// Look up an OutputAccum (in the per-poll accum list) by wl object id.
/// We store the accum list on the Wayland struct for streaming output events.
fn findOutputAccum(w: *Wayland, oid: u32) ?*outputs_mod.OutputAccum {
    for (w.output_accums.items) |*acc| {
        if (acc.id == oid) return acc;
    }
    return null;
}

/// Process a single decoded event: apply side effects and emit to sink.
fn handleEvent(
    w: *Wayland,
    ev: client.DecodedEvent,
    sink: lattice_backend.EventSink,
    sink_ctx: *anyopaque,
) !void {
    const logical = classify(ev.interface, ev.opcode, ev.args);
    const gpa = w.gpa;
    const wire = &w.conn.wire_writer;

    switch (logical) {
        .xdg_surface_configure => |cfg| {
            if (findWindowByXdgSurface(w, ev.object_id)) |win| {
                // Send ack_configure.
                try xdg.XdgSurface.ackConfigure(wire, gpa, ev.object_id, cfg.serial);
                try w.conn.sendMessage(wire.finish());

                win.configured = true;
                win.pending_serial = cfg.serial;

                sink(sink_ctx, event_mod.Event{ .redraw_requested = win.id });
            }
        },

        .xdg_toplevel_configure => |cfg| {
            if (findWindowByXdgToplevel(w, ev.object_id)) |win| {
                if (cfg.width > 0 and cfg.height > 0) {
                    win.width = @intCast(cfg.width);
                    win.height = @intCast(cfg.height);
                    sink(sink_ctx, event_mod.Event{ .resized = .{
                        .surface = win.id,
                        .width = @intCast(cfg.width),
                        .height = @intCast(cfg.height),
                    } });
                }
                // 0x0 means "you choose" - no event emitted.
            }
        },

        .xdg_toplevel_close => {
            if (findWindowByXdgToplevel(w, ev.object_id)) |win| {
                sink(sink_ctx, event_mod.Event{ .close_requested = win.id });
            }
        },

        .frame_done => {
            if (findWindowByFrameCb(w, ev.object_id)) |win| {
                win.frame_cb_id = null;
                // Remove the callback from imap since it fired.
                w.imap.remove(ev.object_id);
                sink(sink_ctx, event_mod.Event{ .redraw_requested = win.id });
            }
        },

        .wl_buffer_release => {
            // Mark the matching ShmBuffer OR dmabuf slot as not busy.
            for (w.surfaces.items) |*win| {
                // Check shm buffers first.
                for (&win.buffers) |*slot| {
                    if (slot.*) |*buf| {
                        if (buf.buffer_id == ev.object_id) {
                            buf.busy = false;
                        }
                    }
                }
                // Also check dmabuf wl_buffer slots.
                for (&win.dmabuf_wl) |*slot| {
                    if (slot.*) |*s| {
                        if (s.buffer_id == ev.object_id) {
                            s.busy = false;
                        }
                    }
                }
            }
        },

        .zwp_linux_buffer_params_created => |info| {
            // Async create succeeded: the compositor sends us the new wl_buffer id.
            // Register it in imap, wire it to the pending surface slot, and request
            // a redraw so the next commitFrameDmabuf can attach it.
            // Register the new wl_buffer.
            // A buffer the map cannot record is a buffer the next frame will not
            // attach, which the dmabuf path already recovers from by falling back.
            w.imap.set(info.buffer_id, &wlp.WlBuffer.interface) catch {};
            // Remove the params object (consumed by create).
            w.imap.remove(ev.object_id);
            // Find the window with matching pending_create params_id.
            for (w.surfaces.items) |*win| {
                if (win.pending_create) |pc| {
                    if (pc.params_id == ev.object_id) {
                        win.dmabuf_wl[pc.slot] = .{ .buffer_id = info.buffer_id, .busy = false };
                        win.pending_create = null;
                        // Emit redraw so the next frame commits with the new buffer.
                        sink(sink_ctx, event_mod.Event{ .redraw_requested = win.id });
                        break;
                    }
                }
            }
        },

        .zwp_linux_buffer_params_failed => {
            // The compositor rejected the async dmabuf create for the params object
            // at ev.object_id. This is NON-FATAL (async create failure, not create_immed).
            // Clear pending state, remove params from imap, and fall back to shm.
            // The connection stays alive. Mark the surface as dmabuf_failed so it never
            // re-attempts dmabuf (mode selection always forces shm after this).
            // Remove the failed params object from imap.
            w.imap.remove(ev.object_id);
            // Find the surface whose pending_create matches this params_id and fall back.
            for (w.surfaces.items) |*win| {
                if (win.pending_create) |pc| {
                    if (pc.params_id == ev.object_id) {
                        win.pending_create = null;
                        win.present_mode = .shm;
                        win.dmabuf_failed = true;
                        // Tear down dmabuf state so surfaceRenderTarget reinitializes as shm.
                        w.destroyDmabufState(win);
                        // Request a redraw so the shm path gets set up on the next frame.
                        sink(sink_ctx, event_mod.Event{ .redraw_requested = win.id });
                        break;
                    }
                }
            }
            // Fallback: if no window matched via pending_create (e.g. race or legacy path),
            // switch all dmabuf surfaces to shm.
            for (w.surfaces.items) |*win| {
                if (win.present_mode == .dmabuf) {
                    win.present_mode = .shm;
                    win.dmabuf_failed = true;
                    w.destroyDmabufState(win);
                }
            }
        },

        .wl_output_geometry => |g| {
            if (findOutputAccum(w, ev.object_id)) |acc| {
                acc.applyGeometry(g.x, g.y, g.physical_width, g.physical_height, g.subpixel, g.make, g.model, g.transform);
            }
        },

        .wl_output_mode => |m| {
            if (findOutputAccum(w, ev.object_id)) |acc| {
                acc.applyMode(m.width, m.height, m.refresh_mhz, m.flags);
            }
        },

        .wl_output_scale => |s| {
            if (findOutputAccum(w, ev.object_id)) |acc| {
                acc.applyScale(s.factor);
            }
        },

        .wl_output_name => |n| {
            if (findOutputAccum(w, ev.object_id)) |acc| {
                acc.applyName(n.name);
            }
        },

        .wl_output_done => {
            if (findOutputAccum(w, ev.object_id)) |acc| {
                // Check if this output was already known (hotplug vs initial).
                const already_known = blk: {
                    for (w.outputs.items) |o| {
                        if (o.id.value() == acc.id) break :blk true;
                    }
                    break :blk false;
                };
                if (!already_known) {
                    // Capacity is pre-reserved to 32 outputs in init; drop extras beyond that.
                    if (w.outputs.items.len < w.outputs.capacity) {
                        // Convert to neutral Output and store.
                        const lattice_id: u32 = @intCast(w.outputs.items.len + 1);
                        // Append: capacity is pre-reserved so this won't realloc, keeping Output.name slices valid.
                        w.output_name_bufs.appendAssumeCapacity(acc.name_buf);
                        var o = acc.toOutput(lattice_id);
                        o.name = w.output_name_bufs.items[w.output_name_bufs.items.len - 1][0..acc.name_len];
                        w.outputs.appendAssumeCapacity(o);
                        sink(sink_ctx, event_mod.Event{ .output_added = id_mod.OutputId.from(lattice_id) });
                    }
                }
            }
        },

        .xdg_ping => |p| {
            try xdg.XdgWmBase.pong(wire, gpa, w.xdg_wm_base_id, p.serial);
            try w.conn.sendMessage(wire.finish());
            // No neutral event emitted for ping/pong.
        },

        .wl_pointer_enter => |e2| {
            // Match the entered wl_surface object to a Window; set pointer focus.
            for (w.surfaces.items) |*win| {
                if (win.wl_surface_id == e2.surface_obj) {
                    w.focus_surface = win.id;
                }
            }
        },

        .wl_seat_capabilities => |cap| {
            // Publish the neutral seat state BEFORE the touch binding below, which
            // returns early when a request fails. A dropped state update would leave
            // seatCapabilities() reporting a seat the parent no longer has.
            const new_caps = input_mod.seatCapabilitiesFromMask(cap.caps);
            if (!new_caps.eql(w.seat_caps)) {
                w.seat_caps = new_caps;
                sink(sink_ctx, .{ .seat_capabilities = new_caps });
            }

            // Create the touch object only once the seat advertises touch. Issuing
            // get_touch on a seat that never had the touch capability is a protocol
            // violation that disconnects us, and most seats have no touchscreen.
            // (Pointer/keyboard are created optimistically at bind time since a
            // nested parent always advertises them.)
            if (w.seat_id != 0 and w.touch_id == 0 and (cap.caps & wlp.WlSeat.Capability.touch) != 0) {
                // Commit w.touch_id only after all three steps succeed, so a failure
                // leaves it 0 and a later capabilities event can retry.
                const tid = w.conn.objects.allocId();
                wlp.WlSeat.getTouch(wire, gpa, w.seat_id, tid) catch return;
                try w.conn.sendMessage(wire.finish());
                try w.imap.set(tid, &wlp.WlTouch.interface);
                w.touch_id = tid;
            }
        },

        .wl_keyboard_keymap => |km| {
            // The fd is ours to close. format 1 carries XKB v1 text; format 0 is
            // the compositor saying it has no keymap, in which case the embedded
            // fallback keeps the keys working. A bad fd or a bad string keeps the
            // current map: the wire is untrusted and a poisoned keymap must not
            // kill the keys that already work.
            defer _ = linux.close(km.fd);
            if (km.format != 1) {
                w.keyboard.setKeymapFromString(keyboard_mod.minimal_keymap) catch {};
                return;
            }
            if (km.size == 0) return;
            const mapped = posix.mmap(null, km.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, km.fd, 0) catch return;
            defer posix.munmap(mapped);
            // The protocol size includes the trailing NUL, which the keymap lexer
            // does not want. The parse runs BEFORE the munmap, because the slice
            // aliases the mapping.
            w.keyboard.setKeymapFromString(mapped[0 .. mapped.len - 1]) catch {};
        },

        .wl_keyboard_modifiers => |m| {
            // The group index is wire input, so it gets a checked conversion.
            w.keyboard.updateMods(m.depressed, m.latched, m.locked, std.math.cast(i32, m.group) orelse 0);
        },

        .wl_keyboard_enter => |e2| {
            for (w.surfaces.items) |*win| {
                if (win.wl_surface_id == e2.surface_obj) w.key_focus = win.id;
            }
        },

        .wl_keyboard_leave => |e2| {
            for (w.surfaces.items) |*win| {
                if (win.wl_surface_id == e2.surface_obj and w.key_focus == win.id) {
                    w.key_focus = null;
                }
            }
        },

        .wl_keyboard_key => |k| {
            // Keys go to the KEYBOARD focus, which is tracked independently of the
            // pointer: a compositor is free to focus a window the pointer is not
            // over. The first surface is the fallback for a compositor that never
            // sent an enter, which nested backends do.
            const surf = w.key_focus orelse blk: {
                if (w.surfaces.items.len > 0) break :blk w.surfaces.items[0].id;
                break :blk null;
            };
            if (surf) |s| {
                var iev = input_mod.inputFromLogical(logical, s) orelse return;
                std.debug.assert(iev == .key);
                const t = try w.keyboard.translate(k.key, k.state == 1);
                iev.key.keysym = t.keysym;
                iev.key.mods = t.mods;
                iev.key.text = t.text;
                sink(sink_ctx, .{ .input = iev });
            }
        },

        .wl_pointer_motion,
        .wl_pointer_button,
        .wl_pointer_axis,
        .wl_touch_down,
        .wl_touch_up,
        .wl_touch_motion,
        => {
            const surf = w.focus_surface orelse blk: {
                if (w.surfaces.items.len > 0) break :blk w.surfaces.items[0].id;
                break :blk null;
            };
            if (surf) |s| {
                if (input_mod.inputFromLogical(logical, s)) |iev| {
                    sink(sink_ctx, .{ .input = iev });
                }
            }
        },

        .wl_relative_motion => |m| {
            // Seat-global: no surface focus needed for relative motion.
            sink(sink_ctx, .{ .input = .{ .pointer_relative = .{
                .dx = m.dx,
                .dy = m.dy,
                .dx_unaccel = m.dx_unaccel,
                .dy_unaccel = m.dy_unaccel,
            } } });
        },

        // Tablet seat events: register new tablet/tool objects in imap so their
        // subsequent events decode correctly.
        .tablet_seat_tablet_added => |t| {
            w.imap.set(t.new_id, &tv2.ZwpTabletV2.interface) catch {};
        },
        .tablet_seat_tool_added => |t| {
            w.imap.set(t.new_id, &tv2.ZwpTabletToolV2.interface) catch {};
        },

        // Tablet tool events: resolve surface from focus and emit neutral events.
        .tablet_tool_proximity_in => {
            const surf = w.focus_surface orelse blk: {
                if (w.surfaces.items.len > 0) break :blk w.surfaces.items[0].id;
                break :blk null;
            };
            if (surf) |s| {
                sink(sink_ctx, .{ .input = .{ .tablet_proximity = .{ .surface = s, .in_prox = true } } });
            }
        },
        .tablet_tool_proximity_out => {
            const surf = w.focus_surface orelse blk: {
                if (w.surfaces.items.len > 0) break :blk w.surfaces.items[0].id;
                break :blk null;
            };
            if (surf) |s| {
                sink(sink_ctx, .{ .input = .{ .tablet_proximity = .{ .surface = s, .in_prox = false } } });
            }
        },
        .tablet_tool_down => {
            const surf = w.focus_surface orelse blk: {
                if (w.surfaces.items.len > 0) break :blk w.surfaces.items[0].id;
                break :blk null;
            };
            if (surf) |s| {
                sink(sink_ctx, .{ .input = .{ .tablet_tip = .{ .surface = s, .down = true } } });
            }
        },
        .tablet_tool_up => {
            const surf = w.focus_surface orelse blk: {
                if (w.surfaces.items.len > 0) break :blk w.surfaces.items[0].id;
                break :blk null;
            };
            if (surf) |s| {
                sink(sink_ctx, .{ .input = .{ .tablet_tip = .{ .surface = s, .down = false } } });
            }
        },
        // Frame-accumulate: motion and pressure update pending state; frame emits tablet_axis.
        .tablet_tool_motion => |m| {
            w.tablet_pending_x = m.x;
            w.tablet_pending_y = m.y;
        },
        .tablet_tool_pressure => |p| {
            w.tablet_pending_pressure = @as(f64, @floatFromInt(p.pressure)) / 65535.0;
        },
        .tablet_tool_frame => {
            const surf = w.focus_surface orelse blk: {
                if (w.surfaces.items.len > 0) break :blk w.surfaces.items[0].id;
                break :blk null;
            };
            if (surf) |s| {
                sink(sink_ctx, .{ .input = .{ .tablet_axis = .{
                    .surface = s,
                    .x = w.tablet_pending_x,
                    .y = w.tablet_pending_y,
                    .pressure = w.tablet_pending_pressure,
                } } });
            }
        },

        .other => {
            // Safely ignore wl_registry.global_remove, wl_display.delete_id,
            // wl_shm.format, unknown future opcodes, etc.
        },
    }
}

/// Zero-timeout poll to check if a fd is readable without blocking.
fn isReadable(fd: posix.fd_t) bool {
    var pfd = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&pfd, 0) catch return false;
    if (n == 0) return false;
    return (pfd[0].revents & posix.POLL.IN) != 0;
}

/// pump one pass: poll on [wayland_fd, wakeup_fd] with timeout, then handle
/// events.
///
/// Non-blocking drain approach: after poll says the wayland fd is readable,
/// we call dispatchEvent up to MAX_DRAIN times. Before each call beyond the
/// first, we do a zero-timeout poll on the fd to confirm more data is ready;
/// if it is not, we stop to avoid blocking. This drains the current burst
/// without blocking on an empty socket.
pub fn pumpOnce(
    w: *Wayland,
    timeout_ms: ?u32,
    sink: lattice_backend.EventSink,
    sink_ctx: *anyopaque,
) !void {
    const wl_fd = w.conn.stream.socket.handle;
    const wake_fd = w.wakeup_fd;

    var fds = [2]posix.pollfd{
        .{ .fd = wl_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = wake_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    const timeout_i32: i32 = if (timeout_ms) |t| @intCast(t) else -1;
    _ = posix.poll(&fds, timeout_i32) catch |err| switch (err) {
        error.SystemResources => return,
        else => return err,
    };

    // Drain wakeup eventfd if signaled.
    if (fds[1].revents & posix.POLL.IN != 0) {
        var drain_buf: [8]u8 = undefined;
        _ = posix.read(wake_fd, &drain_buf) catch {};
    }

    // Drain wayland events if the fd is readable.
    if (fds[0].revents & posix.POLL.IN != 0) {
        var msg_buf: [4096]u8 = undefined;
        var args_buf: [16]wl.Argument = undefined;

        var i: usize = 0;
        while (i < MAX_DRAIN) : (i += 1) {
            // For subsequent iterations, check fd is still readable (zero-timeout
            // poll) to avoid blocking when we've drained the current burst.
            if (i > 0 and !isReadable(wl_fd)) break;

            const ev = client.dispatchEvent(&w.conn, &w.imap, &msg_buf, &args_buf) catch |err| switch (err) {
                // UnknownOpcode: the interface table doesn't know this opcode.
                // Safe to skip.
                error.UnknownOpcode => break,
                else => return err,
            };

            const decoded = ev orelse continue; // null = unknown object id, skipped
            try handleEvent(w, decoded, sink, sink_ctx);
        }
    }
}

// -------------------------------------------------------------------------
// Unit tests
// -------------------------------------------------------------------------

test "classify xdg_surface.configure returns serial" {
    const args = [_]wl.Argument{.{ .uint = 42 }};
    const result = classify(&xdg.XdgSurface.interface, @intFromEnum(xdg.XdgSurface.EventOpcode.configure), &args);
    try std.testing.expect(result == .xdg_surface_configure);
    try std.testing.expectEqual(@as(u32, 42), result.xdg_surface_configure.serial);
}

test "classify xdg_toplevel.configure width/height" {
    const args = [_]wl.Argument{
        .{ .int = 1280 },
        .{ .int = 720 },
        .{ .array = null },
    };
    const result = classify(&xdg.XdgToplevel.interface, @intFromEnum(xdg.XdgToplevel.EventOpcode.configure), &args);
    try std.testing.expect(result == .xdg_toplevel_configure);
    try std.testing.expectEqual(@as(i32, 1280), result.xdg_toplevel_configure.width);
    try std.testing.expectEqual(@as(i32, 720), result.xdg_toplevel_configure.height);
}

test "classify xdg_toplevel.close" {
    const result = classify(&xdg.XdgToplevel.interface, @intFromEnum(xdg.XdgToplevel.EventOpcode.close), &.{});
    try std.testing.expect(result == .xdg_toplevel_close);
}

test "classify wl_callback.done -> frame_done" {
    const args = [_]wl.Argument{.{ .uint = 0 }};
    const result = classify(&wlp.WlCallback.interface, @intFromEnum(wlp.WlCallback.EventOpcode.done), &args);
    try std.testing.expect(result == .frame_done);
}

test "classify wl_buffer.release -> wl_buffer_release" {
    const result = classify(&wlp.WlBuffer.interface, @intFromEnum(wlp.WlBuffer.EventOpcode.release), &.{});
    try std.testing.expect(result == .wl_buffer_release);
}

test "classify wl_output.mode" {
    const args = [_]wl.Argument{
        .{ .uint = 0x1 }, // flags: current
        .{ .int = 1920 },
        .{ .int = 1080 },
        .{ .int = 60000 },
    };
    const result = classify(&wlp.WlOutput.interface, @intFromEnum(wlp.WlOutput.EventOpcode.mode), &args);
    try std.testing.expect(result == .wl_output_mode);
    try std.testing.expectEqual(@as(u32, 0x1), result.wl_output_mode.flags);
    try std.testing.expectEqual(@as(i32, 1920), result.wl_output_mode.width);
    try std.testing.expectEqual(@as(i32, 1080), result.wl_output_mode.height);
}

test "classify xdg_wm_base.ping" {
    const args = [_]wl.Argument{.{ .uint = 99 }};
    const result = classify(&xdg.XdgWmBase.interface, @intFromEnum(xdg.XdgWmBase.EventOpcode.ping), &args);
    try std.testing.expect(result == .xdg_ping);
    try std.testing.expectEqual(@as(u32, 99), result.xdg_ping.serial);
}

test "classify wl_keyboard.keymap carries the format, the fd and the size" {
    const args = [_]wl.Argument{ .{ .uint = 1 }, .{ .fd = 7 }, .{ .uint = 4096 } };
    const result = classify(&wlp.WlKeyboard.interface, @intFromEnum(wlp.WlKeyboard.EventOpcode.keymap), &args);
    try std.testing.expect(result == .wl_keyboard_keymap);
    try std.testing.expectEqual(@as(u32, 1), result.wl_keyboard_keymap.format);
    try std.testing.expectEqual(@as(i32, 7), result.wl_keyboard_keymap.fd);
    try std.testing.expectEqual(@as(u32, 4096), result.wl_keyboard_keymap.size);
}

test "classify wl_keyboard.enter and leave carry the surface object" {
    const enter_args = [_]wl.Argument{ .{ .uint = 1 }, .{ .object = 42 }, .{ .array = null } };
    const enter = classify(&wlp.WlKeyboard.interface, @intFromEnum(wlp.WlKeyboard.EventOpcode.enter), &enter_args);
    try std.testing.expect(enter == .wl_keyboard_enter);
    try std.testing.expectEqual(@as(u32, 42), enter.wl_keyboard_enter.surface_obj);

    const leave_args = [_]wl.Argument{ .{ .uint = 2 }, .{ .object = 42 } };
    const leave = classify(&wlp.WlKeyboard.interface, @intFromEnum(wlp.WlKeyboard.EventOpcode.leave), &leave_args);
    try std.testing.expect(leave == .wl_keyboard_leave);
    try std.testing.expectEqual(@as(u32, 42), leave.wl_keyboard_leave.surface_obj);
}

test "classify wl_keyboard.modifiers carries the four masks" {
    const args = [_]wl.Argument{
        .{ .uint = 9 }, // serial
        .{ .uint = 1 }, // depressed
        .{ .uint = 2 }, // latched
        .{ .uint = 4 }, // locked
        .{ .uint = 0 }, // group
    };
    const result = classify(&wlp.WlKeyboard.interface, @intFromEnum(wlp.WlKeyboard.EventOpcode.modifiers), &args);
    try std.testing.expect(result == .wl_keyboard_modifiers);
    try std.testing.expectEqual(@as(u32, 1), result.wl_keyboard_modifiers.depressed);
    try std.testing.expectEqual(@as(u32, 2), result.wl_keyboard_modifiers.latched);
    try std.testing.expectEqual(@as(u32, 4), result.wl_keyboard_modifiers.locked);
    try std.testing.expectEqual(@as(u32, 0), result.wl_keyboard_modifiers.group);
}

test "classify wl_keyboard.repeat_info is ignored for now" {
    // Key repeat is client-side timing, and the neutral event has no repeat
    // action until a consumer needs one.
    const args = [_]wl.Argument{ .{ .int = 25 }, .{ .int = 600 } };
    const result = classify(&wlp.WlKeyboard.interface, @intFromEnum(wlp.WlKeyboard.EventOpcode.repeat_info), &args);
    try std.testing.expect(result == .other);
}

test "classify unknown opcode returns other" {
    // opcode 255 does not exist on WlCallback (only has done=0)
    const args = [_]wl.Argument{.{ .uint = 0 }};
    const result = classify(&wlp.WlCallback.interface, 255, &args);
    try std.testing.expect(result == .other);
}

test "classify wl_output.name" {
    const name_str: []const u8 = "HDMI-1";
    const args = [_]wl.Argument{.{ .string = name_str }};
    const result = classify(&wlp.WlOutput.interface, @intFromEnum(wlp.WlOutput.EventOpcode.name), &args);
    try std.testing.expect(result == .wl_output_name);
    try std.testing.expectEqualStrings("HDMI-1", result.wl_output_name.name);
}

test "classify wl_output.done" {
    const result = classify(&wlp.WlOutput.interface, @intFromEnum(wlp.WlOutput.EventOpcode.done), &.{});
    try std.testing.expect(result == .wl_output_done);
}

test "classify zwp_relative_pointer.relative_motion decodes deltas" {
    const args = [_]wl.Argument{
        .{ .uint = 0 },                         .{ .uint = 0 },
        .{ .fixed = wl.Fixed.fromDouble(5.0) }, .{ .fixed = wl.Fixed.fromDouble(-3.0) },
        .{ .fixed = wl.Fixed.fromDouble(6.0) }, .{ .fixed = wl.Fixed.fromDouble(-4.0) },
    };
    const r = classify(&rp.ZwpRelativePointerV1.interface, @intFromEnum(rp.ZwpRelativePointerV1.EventOpcode.relative_motion), &args);
    try std.testing.expect(r == .wl_relative_motion);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), r.wl_relative_motion.dx, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, -4.0), r.wl_relative_motion.dy_unaccel, 0.01);
}

test "classify tablet_seat.tablet_added decodes new_id" {
    const args = [_]wl.Argument{.{ .new_id = 42 }};
    const r = classify(&tv2.ZwpTabletSeatV2.interface, @intFromEnum(tv2.ZwpTabletSeatV2.EventOpcode.tablet_added), &args);
    try std.testing.expect(r == .tablet_seat_tablet_added);
    try std.testing.expectEqual(@as(u32, 42), r.tablet_seat_tablet_added.new_id);
}

test "classify tablet_seat.tool_added decodes new_id" {
    const args = [_]wl.Argument{.{ .new_id = 99 }};
    const r = classify(&tv2.ZwpTabletSeatV2.interface, @intFromEnum(tv2.ZwpTabletSeatV2.EventOpcode.tool_added), &args);
    try std.testing.expect(r == .tablet_seat_tool_added);
    try std.testing.expectEqual(@as(u32, 99), r.tablet_seat_tool_added.new_id);
}

test "classify tablet_tool.motion decodes surface-local coords" {
    const args = [_]wl.Argument{
        .{ .fixed = wl.Fixed.fromDouble(150.5) },
        .{ .fixed = wl.Fixed.fromDouble(75.25) },
    };
    const r = classify(&tv2.ZwpTabletToolV2.interface, @intFromEnum(tv2.ZwpTabletToolV2.EventOpcode.motion), &args);
    try std.testing.expect(r == .tablet_tool_motion);
    try std.testing.expectApproxEqAbs(@as(f64, 150.5), r.tablet_tool_motion.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 75.25), r.tablet_tool_motion.y, 0.01);
}

test "classify tablet_tool.pressure decodes raw uint" {
    const args = [_]wl.Argument{.{ .uint = 32768 }};
    const r = classify(&tv2.ZwpTabletToolV2.interface, @intFromEnum(tv2.ZwpTabletToolV2.EventOpcode.pressure), &args);
    try std.testing.expect(r == .tablet_tool_pressure);
    try std.testing.expectEqual(@as(u32, 32768), r.tablet_tool_pressure.pressure);
}

test "classify tablet_tool.frame returns tablet_tool_frame" {
    const args = [_]wl.Argument{.{ .uint = 1000 }};
    const r = classify(&tv2.ZwpTabletToolV2.interface, @intFromEnum(tv2.ZwpTabletToolV2.EventOpcode.frame), &args);
    try std.testing.expect(r == .tablet_tool_frame);
}

test "classify tablet_tool.proximity_in and proximity_out" {
    // proximity_in: args = [serial(u), tablet(o), surface(o)]
    const args_in = [_]wl.Argument{ .{ .uint = 1 }, .{ .object = 5 }, .{ .object = 6 } };
    const r_in = classify(&tv2.ZwpTabletToolV2.interface, @intFromEnum(tv2.ZwpTabletToolV2.EventOpcode.proximity_in), &args_in);
    try std.testing.expect(r_in == .tablet_tool_proximity_in);

    const r_out = classify(&tv2.ZwpTabletToolV2.interface, @intFromEnum(tv2.ZwpTabletToolV2.EventOpcode.proximity_out), &.{});
    try std.testing.expect(r_out == .tablet_tool_proximity_out);
}

test "classify tablet_tool.down and up" {
    const args_down = [_]wl.Argument{.{ .uint = 7 }};
    const r_down = classify(&tv2.ZwpTabletToolV2.interface, @intFromEnum(tv2.ZwpTabletToolV2.EventOpcode.down), &args_down);
    try std.testing.expect(r_down == .tablet_tool_down);

    const r_up = classify(&tv2.ZwpTabletToolV2.interface, @intFromEnum(tv2.ZwpTabletToolV2.EventOpcode.up), &.{});
    try std.testing.expect(r_up == .tablet_tool_up);
}
