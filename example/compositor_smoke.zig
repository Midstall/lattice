//! Smoke test: bring up a Compositor, print its socket name, then shut it down.
//! Expected output: "socket: wayland-N" + "socket file exists: ..." + "ok"
//! Run: zig build example-compositor-smoke

const std = @import("std");
const linux = std.os.linux;
const prism = @import("prism");
const lattice = @import("lattice");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &w.interface;

    const runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse {
        try out.writeAll("error: XDG_RUNTIME_DIR is not set\n");
        try out.flush();
        std.process.exit(1);
    };

    // Bring up the best available prism device (nvidia on this box, else software).
    const sel = prism.drivers.createBestDevice(gpa) orelse {
        try out.writeAll("error: no prism driver available\n");
        try out.flush();
        std.process.exit(1);
    };
    defer sel.device.deinit();

    var dev = sel.device;

    const comp = try lattice.Compositor.init(gpa, io, &dev, .{ .runtime_dir = runtime_dir });
    defer comp.deinit();

    const name = comp.socketName();
    try out.print("socket: {s}\n", .{name});
    try out.flush();

    // Verify the socket file exists by opening it with O_PATH.
    var path_buf: [300]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ runtime_dir, name }) catch {
        try out.writeAll("error: path too long\n");
        try out.flush();
        std.process.exit(1);
    };

    // O_PATH (010000000) just opens a reference, does not require read/write perms.
    const O_PATH: u32 = 0o10000000;
    const orc = linux.open(path.ptr, .{ .PATH = true }, O_PATH);
    if (linux.errno(orc) != .SUCCESS) {
        try out.print("error: socket file {s} not found\n", .{path});
        try out.flush();
        std.process.exit(1);
    }
    _ = linux.close(@intCast(orc));

    try out.print("socket file exists: {s}\n", .{path});
    try out.flush();
    try out.writeAll("ok\n");
    try out.flush();
}
