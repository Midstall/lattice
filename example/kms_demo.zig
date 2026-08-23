const std = @import("std");
const lattice = @import("lattice");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var ctx = lattice.Context.init(gpa, init.io, init.environ_map, .{ .backend = .kms }) catch |err| {
        std.debug.print("kms-demo: Context.init failed: {s} (need root + a free VT + DRM master)\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ctx.deinit();

    const outs = ctx.outputs();
    std.debug.print("kms-demo: {d} output(s)\n", .{outs.len});
    for (outs) |o| std.debug.print("  output {s} {d}x{d}@{d}mHz hdr={}\n", .{ o.name, o.width, o.height, o.refresh_mhz, o.hdr.supported });

    const hdr10 = init.environ_map.get("LATTICE_KMS_HDR") != null;
    const color = if (hdr10) lattice.ColorConfig{ .format = .argb2101010, .colorspace = .bt2020, .transfer = .st2084_pq, .luminance = .{ .min_nits = 0.005, .max_nits = 1000, .max_cll = 1000, .max_fall = 400 } } else lattice.ColorConfig.sdr(.xrgb8888);
    const surface = try ctx.createSurface(.{ .title = "kms-demo", .color = color });

    const N: u32 = 120;
    var frame: u32 = 0;
    var last_rt: ?lattice.RenderTarget = null;
    var dummy: u8 = 0;
    while (frame < N) : (frame += 1) {
        if (!ctx.renderAvailable(surface.id)) {
            try ctx.poll(16, noopHandler, &dummy);
            continue;
        }
        const rt = try ctx.renderTarget(surface.id);
        var cb = try rt.context.beginCommands();
        try cb.setRenderTarget(rt.target);
        // animate: sweep the blue channel so successive frames differ
        const b: f32 = @as(f32, @floatFromInt(frame % 60)) / 60.0;
        try cb.clear(.{ .r = 0.2, .g = 0.4, .b = b, .a = 1.0 });
        try rt.context.submit(cb);
        cb.deinit();
        try ctx.commit(surface.id);
        last_rt = rt;
        try ctx.poll(100, noopHandler, &dummy); // drain the flip-complete event
    }

    // Readback proof: the last-rendered scanout bo must carry non-black pixels.
    if (last_rt) |rt| {
        const dev = ctx.renderDevice().?;
        const pixels = dev.mapResource(rt.target) catch &[_]u8{};
        if (pixels.len >= 4) {
            const nonzero = pixels[0] != 0 or pixels[1] != 0 or pixels[2] != 0 or pixels[3] != 0;
            std.debug.print("kms-demo: {d} frames flipped; readback top-left = {x:02}{x:02}{x:02}{x:02} nonblack={}\n", .{ N, pixels[0], pixels[1], pixels[2], pixels[3], nonzero });
        }
    }
    // Optional hold: keep the last frame scanned out for LATTICE_KMS_HOLD seconds
    // so an external observer (e.g. a QEMU monitor screendump) can capture it.
    if (init.environ_map.get("LATTICE_KMS_HOLD")) |secs_str| {
        const secs = std.fmt.parseInt(u32, secs_str, 10) catch 0;
        std.debug.print("kms-demo: holding last frame for {d}s (pumping input)\n", .{secs});
        // Pump during the hold so injected keyboard/pointer events are drained and
        // logged. ~10 polls/sec of 100ms each.
        var i: u32 = 0;
        const iters = secs * 10;
        while (i < iters) : (i += 1) {
            try ctx.poll(100, inputHandler, &dummy);
        }
    }

    ctx.destroySurface(surface.id);
    std.debug.print("kms-demo: done, releasing DRM master\n", .{});
}

fn noopHandler(_: *anyopaque, _: lattice.Event) void {}

fn inputHandler(_: *anyopaque, ev: lattice.Event) void {
    switch (ev) {
        .input => |iev| switch (iev) {
            .key => |k| std.debug.print("kms-demo: input: key code={d} state={s}\n", .{ k.keycode, @tagName(k.state) }),
            .pointer_motion => |m| std.debug.print("kms-demo: input: motion x={d:.0} y={d:.0}\n", .{ m.x, m.y }),
            .pointer_button => |b| std.debug.print("kms-demo: input: button {d} {s}\n", .{ b.button, @tagName(b.state) }),
            .pointer_axis => |a| std.debug.print("kms-demo: input: axis h={d:.1} v={d:.1}\n", .{ a.horizontal, a.vertical }),
            else => {},
        },
        else => {},
    }
}
