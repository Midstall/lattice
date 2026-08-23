const std = @import("std");
const udev = @import("udev");

pub const Card = struct { name: []const u8, boot_vga: bool, connected: bool };

/// Pure selector: boot_vga wins, then first connected, then first card, else null.
pub fn choose(cards: []const Card) ?usize {
    for (cards, 0..) |c, i| if (c.boot_vga) return i;
    for (cards, 0..) |c, i| if (c.connected) return i;
    return if (cards.len > 0) 0 else null;
}

/// Scan udev for DRM primary nodes (cardN, not renderD*) and return the chosen
/// devnode as a gpa-owned slice. Caller must free. Returns error.NoDrmDevice if
/// no card is found.
pub fn pickDrmCard(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    var ctx = udev.Context.init(gpa, io);
    defer ctx.deinit();

    var en = udev.Enumerate.init(&ctx);
    defer en.deinit();

    try en.addMatchSubsystem("drm");
    try en.scanDevices();

    var cards: std.ArrayListUnmanaged(Card) = .empty;
    var nodes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (cards.items) |c| gpa.free(c.name);
        cards.deinit(gpa);
        for (nodes.items) |n| gpa.free(n);
        nodes.deinit(gpa);
    }

    var it = en.devices();
    while (it.next()) |syspath| {
        var dev = udev.Device.fromSyspath(&ctx, syspath) catch continue;
        defer dev.deinit();

        const name = dev.sysname();
        if (!std.mem.startsWith(u8, name, "card")) continue;

        const node = dev.devnode() orelse continue;

        var boot_vga = false;
        if (dev.parentWithSubsystem("pci", null) catch null) |p| {
            var parent_dev = p;
            defer parent_dev.deinit();
            if (parent_dev.getSysattr("boot_vga") catch null) |v|
                boot_vga = std.mem.eql(u8, v, "1");
        }

        try cards.append(gpa, .{
            .name = try gpa.dupe(u8, name),
            .boot_vga = boot_vga,
            .connected = true,
        });
        try nodes.append(gpa, try gpa.dupe(u8, node));
    }

    const idx = choose(cards.items) orelse return error.NoDrmDevice;
    return gpa.dupe(u8, nodes.items[idx]);
}

test "choose prefers boot_vga, then a connected card, then first, else null" {
    const c = [_]Card{
        .{ .name = "card0", .boot_vga = false, .connected = false },
        .{ .name = "card1", .boot_vga = true, .connected = false },
    };
    try std.testing.expectEqual(@as(?usize, 1), choose(&c));

    const c2 = [_]Card{
        .{ .name = "card0", .boot_vga = false, .connected = false },
        .{ .name = "card1", .boot_vga = false, .connected = true },
    };
    try std.testing.expectEqual(@as(?usize, 1), choose(&c2));

    const c3 = [_]Card{
        .{ .name = "card0", .boot_vga = false, .connected = false },
    };
    try std.testing.expectEqual(@as(?usize, 0), choose(&c3));

    try std.testing.expectEqual(@as(?usize, null), choose(&.{}));
}
