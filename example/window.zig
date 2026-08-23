const std = @import("std");
const linux = std.os.linux;
const lattice = @import("lattice");

// Quit after this many frames OR after the deadline, whichever comes first.
// Compositors throttle frame callbacks for unfocused/occluded surfaces, so the
// deadline ensures the example exits even when running in the background.
const MAX_FRAMES: u32 = 60;
const DEADLINE_NS: u64 = 5 * std.time.ns_per_s;

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec * std.time.ns_per_s + ts.nsec);
}

const App = struct {
    ctx: *lattice.Context,
    sid: lattice.SurfaceId,
    frame_count: u32,
    done: bool,
    start_ns: u64,
    hdr: bool,

    fn handler(self_ptr: *anyopaque, ev: lattice.Event) void {
        const self: *App = @ptrCast(@alignCast(self_ptr));
        switch (ev) {
            .redraw_requested => {
                if (self.done) return;
                self.render() catch |err| {
                    std.log.err("render error: {}", .{err});
                    self.ctx.quit();
                    self.done = true;
                    return;
                };
                if (self.frame_count >= MAX_FRAMES or nowNs() - self.start_ns >= DEADLINE_NS) {
                    self.ctx.quit();
                    self.done = true;
                }
            },
            .close_requested => {
                self.ctx.quit();
                self.done = true;
            },
            else => {},
        }
    }

    fn render(self: *App) !void {
        if (!self.ctx.renderAvailable(self.sid)) return;
        const rt = try self.ctx.renderTarget(self.sid);
        if (!self.hdr) {
            var cb = try rt.context.beginCommands();
            try cb.setRenderTarget(rt.target);
            try cb.clear(.{ .r = 0.15, .g = 0.35, .b = 0.85, .a = 1.0 });
            try rt.context.submit(cb);
            cb.deinit();
        }
        try self.ctx.commit(self.sid);
        self.frame_count += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // driver = null => createBestDevice: picks nvidia on this box (has /dev/nvidia0),
    // falls back to software on boxes with no supported GPU driver.
    // The selected driver + device name are printed to stderr from Wayland.init.
    var ctx = try lattice.Context.init(
        gpa,
        init.io,
        init.environ_map,
        .{ .initial_width = 800, .initial_height = 600, .driver = null },
    );
    defer ctx.deinit();

    // Print discovered outputs so we can verify outputs() is populated.
    const outs = ctx.outputs();
    std.debug.print("outputs: {d}\n", .{outs.len});
    for (outs) |out| {
        std.debug.print("  output: name={s} size={d}x{d} refresh_mhz={d}\n", .{
            out.name,
            out.width,
            out.height,
            out.refresh_mhz,
        });
    }

    // When LATTICE_HDR=1, declare the surface as HDR fp16 (PQ / Rec.2020 / 1000 nits).
    // When LATTICE_HDR10=1, declare as HDR10 10-bit (argb2101010 / PQ / Rec.2020 / 1000 nits).
    // If both are set, fp16 (LATTICE_HDR) wins. The default is SDR sRGB.
    const hdr_env = init.environ_map.get("LATTICE_HDR");
    const hdr10_env = init.environ_map.get("LATTICE_HDR10");
    const color_cfg: lattice.ColorConfig = if (hdr_env != null and std.mem.eql(u8, hdr_env.?, "1"))
        lattice.ColorConfig{
            .format = .rgba16_float,
            .colorspace = .bt2020,
            .transfer = .st2084_pq,
            .luminance = .{ .min_nits = 0.005, .max_nits = 1000, .max_cll = 1000, .max_fall = 400 },
        }
    else if (hdr10_env != null and std.mem.eql(u8, hdr10_env.?, "1"))
        lattice.ColorConfig{
            .format = .argb2101010,
            .colorspace = .bt2020,
            .transfer = .st2084_pq,
            .luminance = .{ .min_nits = 0.005, .max_nits = 1000, .max_cll = 1000, .max_fall = 400 },
        }
    else
        lattice.ColorConfig.sdr(.xrgb8888);

    const surface = try ctx.createSurface(.{
        .title = "lattice",
        .width = 800,
        .height = 600,
        .color = color_cfg,
    });

    var app = App{
        .ctx = &ctx,
        .sid = surface.id,
        .frame_count = 0,
        .done = false,
        .start_ns = nowNs(),
        // Derived from the chosen surface format (the same field the backend keys
        // on) so app.hdr can never drift from the color config above.
        .hdr = color_cfg.format.isHdr(),
    };

    // Drive the event loop. Use poll(500ms timeout) instead of blocking run(null)
    // so the deadline check fires even when the compositor throttles frame callbacks
    // to near-zero (e.g. for occluded/unfocused surfaces running in background).
    // At 60Hz each frame is ~16ms; 500ms poll timeout gives plenty of time for
    // frames while bounding exit latency.
    ctx.running = true;
    while (ctx.running) {
        try ctx.poll(500, App.handler, &app);
        if (nowNs() - app.start_ns >= DEADLINE_NS and !app.done) {
            ctx.quit();
            app.done = true;
        }
    }

    ctx.destroySurface(surface.id);

    std.debug.print("rendered {d} frames\n", .{app.frame_count});
}
