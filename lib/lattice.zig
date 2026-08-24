//! Root of lattice: a portable, neutral display library. Consumers reach the
//! pieces as namespaces: `lattice.Context`, `lattice.Surface`, `lattice.Output`,
//! `lattice.Event`, `lattice.color`.
const std = @import("std");

pub const name = "lattice";

pub const options = @import("lattice/options.zig");
pub const Options = options.Options;
pub const InputConfig = options.InputConfig;
pub const AccelProfile = options.AccelProfile;
pub const ScrollMethod = options.ScrollMethod;

pub const color = @import("lattice/color.zig");
pub const PixelFormat = color.PixelFormat;
pub const Colorspace = color.Colorspace;
pub const TransferFunction = color.TransferFunction;
pub const Luminance = color.Luminance;
pub const ColorConfig = color.ColorConfig;

pub const id = @import("lattice/id.zig");
pub const SurfaceId = id.SurfaceId;
pub const OutputId = id.OutputId;

pub const event = @import("lattice/event.zig");
pub const Event = event.Event;
pub const InputEvent = event.InputEvent;
pub const SeatCapabilities = event.SeatCapabilities;

pub const keyboard = @import("lattice/keyboard.zig");
pub const KeyboardState = keyboard.KeyboardState;

pub const output = @import("lattice/output.zig");
pub const Output = output.Output;
pub const HdrCaps = output.HdrCaps;

pub const surface = @import("lattice/surface.zig");
pub const Surface = surface.Surface;
pub const SurfaceDesc = surface.SurfaceDesc;
pub const RenderTarget = surface.RenderTarget;

pub const backend = @import("lattice/backend.zig");
pub const Backend = backend.Backend;
pub const Capabilities = backend.Capabilities;

pub const backends = struct {
    pub const Headless = @import("lattice/backend/headless.zig").Headless;
    pub const backends_wayland = @import("lattice/backend/wayland.zig");
};

pub const context = @import("lattice/context.zig");
pub const Context = context.Context;
pub const Handler = context.Handler;
pub const ClientInfo = context.ClientInfo;

pub const render = @import("lattice/render.zig");

pub const outputs_internal = @import("lattice/backend/wayland/outputs.zig");
pub const shmbuffer_internal = @import("lattice/backend/wayland/shmbuffer.zig");
pub const dispatch_internal = @import("lattice/backend/wayland/dispatch.zig");
pub const wayland_color_internal = @import("lattice/backend/wayland/color.zig");
pub const surface_state_internal = @import("lattice/compositor/surface_state.zig");

pub const compositor_types = @import("lattice/compositor/hosted.zig");
pub const HostedSurface = compositor_types.HostedSurface;
pub const CompositorEvent = compositor_types.CompositorEvent;

pub const compositor = @import("lattice/compositor.zig");
pub const Compositor = compositor.Compositor;
pub const Rect = compositor.Rect;

pub const compositor_xdg = @import("lattice/compositor/xdg.zig");
pub const compositor_draw = @import("lattice/compositor/draw.zig");
pub const compositor_seat = @import("lattice/compositor/seat.zig");
pub const compositor_color_manager = @import("lattice/compositor/color_manager.zig");
pub const constraints_internal = @import("lattice/compositor/constraints.zig");
pub const tablet_input_internal = @import("lattice/compositor/tablet_input.zig");

pub const format_map = @import("lattice/format_map.zig");

pub const dmabuf_bindings_test = @import("lattice/dmabuf_bindings_test.zig");
pub const color_management_bindings_test = @import("lattice/color_management_bindings_test.zig");
pub const xkbcommon_bindings_test = @import("lattice/xkbcommon_bindings_test.zig");
pub const kms_input_internal = @import("lattice/backend/kms/input.zig");
pub const wayland_input_internal = @import("lattice/backend/wayland/input.zig");

test "module compiles and name is set" {
    try std.testing.expectEqualStrings("lattice", name);
}

test {
    std.testing.refAllDecls(@This());
}
