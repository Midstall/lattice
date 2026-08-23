const std = @import("std");

pub const BackendKind = enum { auto, wayland, kms, headless };

/// Neutral pointer acceleration profile. Maps to libinput filter.Profile
/// inside the KMS backend; safe to use on all platforms.
pub const AccelProfile = enum { flat, adaptive };

/// Neutral scroll method. Maps to libinput pointer.ScrollMethod inside the
/// KMS backend; safe to use on all platforms.
pub const ScrollMethod = enum { none, on_button_down };

/// Per-device input configuration applied at device-open time in the KMS
/// backend. Defaults match libinput's built-in defaults: adaptive accel,
/// speed 0, all behavioural bools false, scroll disabled.
/// The nested (Wayland) backend ignores this - the parent compositor owns it.
pub const InputConfig = struct {
    accel_speed: f64 = 0.0,
    accel_profile: AccelProfile = .adaptive,
    natural_scroll: bool = false,
    left_handed: bool = false,
    middle_emulation: bool = false,
    scroll_method: ScrollMethod = .none,
};

pub const Options = struct {
    backend: BackendKind = .auto,
    initial_width: u32 = 800,
    initial_height: u32 = 600,
    driver: ?[]const u8 = null,
    /// When false, the KMS backend runs in kiosk mode: never initiates a VT
    /// switch and best-effort locks switching. Default true = normal switching.
    vt_switch: bool = true,
    /// Per-device input configuration applied to each libinput device as it is
    /// opened (initial enumeration + hotplug). KMS backend only; ignored by
    /// nested (Wayland) and headless backends.
    input: InputConfig = .{},
};

pub const EnvProbe = struct {
    wayland_display: ?[]const u8 = null,
    x11_display: ?[]const u8 = null,
    xdg_session_type: ?[]const u8 = null,
    kms_device: ?[]const u8 = null,
};

fn eq(a: ?[]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, a.?, b);
}

/// Resolve the concrete backend. Session type wins over device presence.
pub fn resolveBackend(opts: Options, probe: EnvProbe) !BackendKind {
    return switch (opts.backend) {
        .wayland => .wayland,
        .kms => .kms,
        .headless => .headless,
        .auto => detectAuto(probe),
    };
}

/// Pure backend auto-detection from environment indicators. OS-agnostic: it only
/// reads the probe (which env vars are filled + whether a DRM device exists is
/// the caller's job in context.zig). A wayland/x11 SESSION means another display
/// server owns the GPU, so we never grab KMS just because a card node exists.
fn detectAuto(probe: EnvProbe) BackendKind {
    if (probe.wayland_display != null or eq(probe.xdg_session_type, "wayland")) return .wayland;
    if (probe.x11_display != null or eq(probe.xdg_session_type, "x11")) return .headless;
    if (eq(probe.xdg_session_type, "tty")) return .kms;
    if (probe.xdg_session_type == null and probe.wayland_display == null and probe.x11_display == null and probe.kms_device != null) return .kms;
    return .headless;
}

test "resolveBackend picks wayland when WAYLAND_DISPLAY set" {
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{}, .{ .wayland_display = "wayland-0" }));
    try std.testing.expectEqual(BackendKind.headless, try resolveBackend(.{}, .{ .wayland_display = null }));
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{ .backend = .wayland }, .{ .wayland_display = null }));
}

test "resolveBackend: explicit kms" {
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{ .backend = .kms }, .{ .kms_device = null }));
}
test "resolveBackend: auto picks kms when a DRM device is present and no wayland" {
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{}, .{ .kms_device = "/dev/dri/card0" }));
}
test "resolveBackend: wayland wins over kms in auto" {
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{}, .{ .wayland_display = "wayland-1", .kms_device = "/dev/dri/card0" }));
}

test "resolveBackend: wayland session (even if a DRM card exists) -> wayland, NOT kms" {
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{}, .{ .wayland_display = "wayland-1", .xdg_session_type = "wayland", .kms_device = "/dev/dri/card0" }));
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{}, .{ .xdg_session_type = "wayland", .kms_device = "/dev/dri/card0" }));
}
test "resolveBackend: tty session -> kms" {
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{}, .{ .xdg_session_type = "tty", .kms_device = "/dev/dri/card0" }));
}
test "resolveBackend: unset session type, no gfx indicators, drm present -> kms (best-effort)" {
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{}, .{ .kms_device = "/dev/dri/card0" }));
}
test "resolveBackend: x11 session -> headless (x11 backend unbuilt)" {
    try std.testing.expectEqual(BackendKind.headless, try resolveBackend(.{}, .{ .x11_display = ":0", .xdg_session_type = "x11" }));
}
test "resolveBackend: nothing -> headless" {
    try std.testing.expectEqual(BackendKind.headless, try resolveBackend(.{}, .{}));
}
test "resolveBackend: explicit kinds pass through" {
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{ .backend = .kms }, .{}));
    try std.testing.expectEqual(BackendKind.headless, try resolveBackend(.{ .backend = .headless }, .{}));
}

test "InputConfig defaults match libinput built-in defaults" {
    const cfg = InputConfig{};
    try std.testing.expectEqual(AccelProfile.adaptive, cfg.accel_profile);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cfg.accel_speed, 1e-12);
    try std.testing.expect(!cfg.natural_scroll);
    try std.testing.expect(!cfg.left_handed);
    try std.testing.expect(!cfg.middle_emulation);
    try std.testing.expectEqual(ScrollMethod.none, cfg.scroll_method);
}

test "Options.input field zero-initialises to default InputConfig" {
    const opts = Options{};
    try std.testing.expectEqual(AccelProfile.adaptive, opts.input.accel_profile);
    try std.testing.expectEqual(ScrollMethod.none, opts.input.scroll_method);
}
