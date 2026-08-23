const std = @import("std");

/// Blit a linear rgba8 image into a wl_shm XRGB8888 buffer (LE byte order B,G,R,X).
/// Swaps R<->B, forces opaque X=0xFF. Per-row strides let callers pass padded buffers.
pub fn blitRgba8ToXrgb8888(
    src: []const u8,
    dst: []u8,
    width: u32,
    height: u32,
    src_stride: u32,
    dst_stride: u32,
) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const srow = src[y * src_stride ..][0 .. width * 4];
        const drow = dst[y * dst_stride ..][0 .. width * 4];
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const s = srow[x * 4 ..][0..4];
            const d = drow[x * 4 ..][0..4];
            d[0] = s[2]; // B <- src[2] (B from RGBA)
            d[1] = s[1]; // G <- src[1]
            d[2] = s[0]; // R <- src[0] (R from RGBA)
            d[3] = 0xFF; // X <- 0xFF (opaque)
        }
    }
}

test "blit swaps R and B and forces opaque" {
    // 2x1 image: pixel0 = R=10 G=20 B=30 A=40, pixel1 = R=1 G=2 B=3 A=4
    const src = [_]u8{ 10, 20, 30, 40, 1, 2, 3, 4 };
    var dst = [_]u8{0} ** 8;
    blitRgba8ToXrgb8888(&src, &dst, 2, 1, 8, 8);
    // dst LE XRGB8888 bytes: B,G,R,X
    try std.testing.expectEqualSlices(u8, &[_]u8{ 30, 20, 10, 0xFF, 3, 2, 1, 0xFF }, &dst);
}

test "blit honors strides" {
    // 1x2 image, src_stride 8 (4 bytes data + 4 pad), dst_stride 8
    const src = [_]u8{ 10, 20, 30, 40, 0, 0, 0, 0, 50, 60, 70, 80, 0, 0, 0, 0 };
    var dst = [_]u8{0} ** 16;
    blitRgba8ToXrgb8888(&src, &dst, 1, 2, 8, 8);
    try std.testing.expectEqual(@as(u8, 30), dst[0]); // row0 B
    try std.testing.expectEqual(@as(u8, 70), dst[8]); // row1 B
}
