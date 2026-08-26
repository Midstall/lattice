//! Server-side global registration: wl_compositor, wl_output.
//! wl_shm is handled by wl.shm.Shm(wlp) directly.
//! wl_seat and xdg_wm_base are added in later tasks (Tasks 6/9).
//!
//! Task 5: surface_impl handlers are filled in here (attach/commit/frame/damage/destroy).
//! The GlobalsCtx lives on the heap-allocated Compositor; all surface resources share
//! &globals_ctx.surface_impl (the pointer registered with the Display stays stable).
//! Per-surface state is stored in Compositor.surfaces, looked up by resource.id.

const std = @import("std");
const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const hosted_mod = @import("hosted.zig");

const Object = wl.Object;
const Client = wl.server_client.Client;

// Forward declaration: resolved at runtime through the back-pointer.
// Imported here so the handler signatures can reach HostedEntry fields.
const SurfaceState = @import("surface_state.zig").SurfaceState;
const BufferRef = @import("surface_state.zig").BufferRef;
const Committed = @import("surface_state.zig").Committed;
const xdg_mod = @import("xdg.zig");

// wl_output mode flags: current(0x1) | preferred(0x2).
const OUTPUT_MODE_CURRENT: u32 = 0x1;
const OUTPUT_MODE_PREFERRED: u32 = 0x2;

/// Forward reference: Compositor is defined in compositor.zig and imports this file.
/// We break the cycle by using an opaque pointer + comptime accessor pattern.
/// The compositor module calls setCompositor() after allocating itself.
const CompositorOpaque = opaque {};

/// The compositor instance owning the Wayland globals.
/// Set by registerGlobals so bind callbacks can reach back to the Compositor.
pub const GlobalsCtx = struct {
    compositor_impl: wlp.WlCompositor.Implementation,
    surface_impl: wlp.WlSurface.Implementation,
    region_impl: wlp.WlRegion.Implementation,
    /// Back-pointer to the owning Compositor (set by Compositor.init after allocation).
    compositor: *CompositorOpaque = undefined,
};

/// Initialize the stub implementations with real Task-5 handlers.
/// The surface_impl function pointers here are the ones already registered
/// with each wl_surface resource (via &globals_ctx.surface_impl).
/// Filling them in here is the "in-place" update the task requires.
pub fn makeGlobalsCtx() GlobalsCtx {
    return .{
        .compositor_impl = .{
            .create_surface = onCreateSurface,
            .create_region = onCreateRegion,
        },
        .surface_impl = .{
            .destroy = onSurfaceDestroy,
            .attach = onSurfaceAttach,
            .damage = onSurfaceDamage,
            .frame = onSurfaceFrame,
            .commit = onSurfaceCommit,
            .damage_buffer = onSurfaceDamageBuffer,
        },
        .region_impl = .{},
    };
}

/// Register wl_compositor (v6) and wl_output (v4) globals on the display.
/// The wl_shm global is registered separately by the caller via Shm(wlp).create.
pub fn registerGlobals(
    display: *wl.Display,
    ctx: *GlobalsCtx,
) !void {
    _ = try display.globalCreate(
        &wlp.WlCompositor.interface,
        wlp.WlCompositor.version,
        bindCompositor,
        ctx,
    );
    _ = try display.globalCreate(
        &wlp.WlOutput.interface,
        4,
        bindOutput,
        null,
    );
}

// ---------------------------------------------------------------------------
// Internal helper: reach the Compositor from a GlobalsCtx pointer.
// The Compositor type is defined in the parent package; we import it here
// using a lazy @import to avoid a circular dependency at the type level.
// ---------------------------------------------------------------------------

fn getCompositor(ctx: *GlobalsCtx) *@import("../compositor.zig").Compositor {
    return @ptrCast(@alignCast(ctx.compositor));
}

// ---------------------------------------------------------------------------
// wl_compositor bind
// ---------------------------------------------------------------------------

fn bindCompositor(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx: *GlobalsCtx = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &wlp.WlCompositor.interface, version, id) catch return;
    wlp.WlCompositor.setImplementation(resource, &ctx.compositor_impl, ctx, null);
}

fn onCreateSurface(client_data: ?*anyopaque, resource: *Object, id: u32) void {
    const ctx: *GlobalsCtx = @ptrCast(@alignCast(client_data.?));
    const surface = Object.create(resource.client, &wlp.WlSurface.interface, resource.version, id) catch return;
    // Use ctx as client_data so handlers can reach the Compositor via back-pointer.
    // The 4th arg is the ResourceDestroyFn hook: it fires on explicit
    // wl_surface.destroy AND on client disconnect, freeing the HostedEntry +
    // texture and dropping the client from clients_list once it has no surfaces.
    wlp.WlSurface.setImplementation(surface, &ctx.surface_impl, ctx, wlSurfaceResourceDestroyed);

    // Register a HostedEntry for this surface.
    const comp = getCompositor(ctx);
    comp.createSurfaceEntry(surface, id) catch {};
}

fn onCreateRegion(client_data: ?*anyopaque, resource: *Object, id: u32) void {
    const ctx: *GlobalsCtx = @ptrCast(@alignCast(client_data.?));
    const region = Object.create(resource.client, &wlp.WlRegion.interface, resource.version, id) catch return;
    wlp.WlRegion.setImplementation(region, &ctx.region_impl, ctx, null);
}

// ---------------------------------------------------------------------------
// wl_surface handlers (Task 5)
// ---------------------------------------------------------------------------

/// ResourceDestroyFn (signature: fn(*Object) void) installed on every wl_surface.
/// Recovers the GlobalsCtx from the surface's user_data (set as the impl
/// client_data), then delegates to the compositor. Fires both on explicit
/// wl_surface.destroy (after onSurfaceDestroy already removed the entry; the
/// second removeSurfaceEntry is a no-op) and on client disconnect.
fn wlSurfaceResourceDestroyed(resource: *Object) void {
    const ctx: *GlobalsCtx = @ptrCast(@alignCast(resource.user_data orelse return));
    const comp = getCompositor(ctx);
    comp.onWlSurfaceDestroyed(resource);
}

fn onSurfaceDestroy(client_data: ?*anyopaque, resource: *Object) void {
    const ctx: *GlobalsCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);
    comp.removeSurfaceEntry(resource.client, resource.id);
    resource.destroy();
}

fn onSurfaceAttach(
    client_data: ?*anyopaque,
    resource: *Object,
    buffer_: ?*Object,
    x_: i32,
    y_: i32,
) void {
    _ = x_;
    _ = y_;
    const ctx: *GlobalsCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);
    const entry = comp.findSurface(resource.client, resource.id) orelse return;

    if (buffer_) |buf_res| {
        // Discriminate: is this a dma-buf buffer or an shm buffer?
        if (comp.findDmabufBuffer(buf_res.client, buf_res.id)) |dbuf| {
            // dma-buf path: dimensions come from DmabufClientBuffer.
            entry.state.attach(.{
                .resource_id = buf_res.id,
                .width = dbuf.width,
                .height = dbuf.height,
                .stride = dbuf.stride,
                .format = dbuf.format,
            });
            entry.pending_buffer_res = buf_res;
        } else {
            // shm path: user_data is a *wl.shm.Buffer set by Shm (unchanged).
            const buf: *wl.shm.Buffer = @ptrCast(@alignCast(buf_res.user_data.?));
            entry.state.attach(.{
                .resource_id = buf_res.id,
                .width = @intCast(buf.width),
                .height = @intCast(buf.height),
                .stride = @intCast(buf.stride),
                .format = buf.format,
            });
            entry.pending_buffer_res = buf_res;
        }
    } else {
        entry.state.attachNull();
        entry.pending_buffer_res = null;
    }
}

fn onSurfaceCommit(client_data: ?*anyopaque, resource: *Object) void {
    const ctx: *GlobalsCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);
    const entry = comp.findSurface(resource.client, resource.id) orelse return;

    // Update the surface's declared color state from wp_color_management if present.
    // The wl_surface object id (resource.id) is the key used by the color manager.
    if (comp.surfaceColorState(resource.client, resource.id)) |state| {
        const new_color = @import("color_manager.zig").colorStateToConfig(state);
        entry.surface.color = new_color;
    }

    const result = entry.state.commit();
    if (result == .new_buffer) {
        // Discriminate: is this a dma-buf buffer or an shm buffer?
        const buf_res = entry.pending_buffer_res orelse return;
        if (comp.findDmabufBuffer(buf_res.client, buf_res.id)) |dbuf| {
            // dma-buf import path: mmap on first use (cached across frames).
            if (dbuf.mapping == null) {
                const map_size = @as(usize, dbuf.stride) * @as(usize, dbuf.height);
                dbuf.mapping = std.posix.mmap(
                    null,
                    map_size,
                    .{ .READ = true },
                    .{ .TYPE = .SHARED },
                    dbuf.fd,
                    0,
                ) catch blk: {
                    break :blk null;
                };
                if (dbuf.mapping != null) {}
            }
            if (dbuf.mapping) |pixels| {
                const w = dbuf.width;
                const h = dbuf.height;
                const stride = dbuf.stride;
                const fmt = dbuf.format;

                entry.last_pixels_len = pixels.len;
                entry.last_w = w;
                entry.last_h = h;
                entry.last_stride = stride;
                entry.last_format = fmt;

                hosted_mod.uploadToTexture(comp.device, entry, pixels, w, h, stride, fmt) catch {};

                // HDR slice 2 Part 2b proof: when the committed dma-buf carries an
                // Record the committed dmabuf resource for release in endFrame.
                entry.committed_dmabuf_res = buf_res;

                entry.needs_committed_event = true;
                if (w != entry.surface.width or h != entry.surface.height) {
                    entry.needs_resized_event = true;
                }
            }
        } else {
            // shm path (byte-for-byte unchanged):
            const buf: *wl.shm.Buffer = @ptrCast(@alignCast(buf_res.user_data.?));
            const pixels = buf.pixels();

            const w: u32 = @intCast(buf.width);
            const h: u32 = @intCast(buf.height);
            const stride: u32 = @intCast(buf.stride);
            const fmt = buf.format;

            entry.last_pixels_len = pixels.len;
            entry.last_w = w;
            entry.last_h = h;
            entry.last_stride = stride;
            entry.last_format = fmt;

            // Task 7: upload pixels -> prism sampled texture.
            hosted_mod.uploadToTexture(comp.device, entry, pixels, w, h, stride, fmt) catch {};

            // HDR slice 2 (Task 4) proof: when the committed shm buffer carries an
            // FIX C3: record the buffer that was committed so endFrame releases exactly it.
            entry.committed_buffer_res = buf_res;

            // Flag for Task 10 to drain into a surface_committed event.
            entry.needs_committed_event = true;

            // If the surface size changed, also flag a surface_resized event.
            if (w != entry.surface.width or h != entry.surface.height) {
                entry.needs_resized_event = true;
            }
        }
    } else if (result == .buffer_cleared) {
        // FIX I1: null-buffer commit means the surface is being unmapped.
        entry.surface.mapped = false;
        entry.needs_unmapped_event = true;
        // FIX M5: null both committed buffer refs so endFrame doesn't release
        // a stale (possibly destroyed) buffer.
        entry.committed_buffer_res = null;
        entry.committed_dmabuf_res = null;
        // Clear focus if this surface was focused.
        if (comp.seat_ctx.focus_tracker.focused) |fid| {
            if (fid == entry.surface.id) {
                comp.seat_ctx.focus_tracker.focused = null;
            }
        }
        // Destroy the texture since the surface has no content.
        if (entry.surface.texture) |t| {
            comp.device.destroyResource(t);
            entry.surface.texture = null;
        }
    }

    // Task 6: mark surface as mapped once role=toplevel, configure acked, and has buffer.
    if (!entry.surface.mapped) {
        const has_buffer = entry.state.current_buffer != null;
        if (xdg_mod.mappable(entry.state.role, entry.configure_acked, has_buffer)) {
            entry.surface.mapped = true;
            // Flag for Task 10 to drain into a surface_mapped event.
            entry.needs_mapped_event = true;
        }
    }
}

fn onSurfaceFrame(client_data: ?*anyopaque, resource: *Object, callback_id: u32) void {
    const ctx: *GlobalsCtx = @ptrCast(@alignCast(client_data.?));
    const comp = getCompositor(ctx);
    const entry = comp.findSurface(resource.client, resource.id) orelse return;

    // Create the wl_callback Object so the client's id is valid.
    const cb_res = Object.create(resource.client, &wlp.WlCallback.interface, 1, callback_id) catch return;
    // Store the callback resource pointer for Task 10 to fire.
    entry.frame_callback_res = cb_res;
}

fn onSurfaceDamage(
    client_data: ?*anyopaque,
    resource: *Object,
    x_: i32,
    y_: i32,
    width_: i32,
    height_: i32,
) void {
    _ = client_data;
    _ = resource;
    _ = x_;
    _ = y_;
    _ = width_;
    _ = height_;
    // No-op: damage tracking deferred to Task 7+.
}

fn onSurfaceDamageBuffer(
    client_data: ?*anyopaque,
    resource: *Object,
    x_: i32,
    y_: i32,
    width_: i32,
    height_: i32,
) void {
    _ = client_data;
    _ = resource;
    _ = x_;
    _ = y_;
    _ = width_;
    _ = height_;
    // No-op: damage tracking deferred to Task 7+.
}

// ---------------------------------------------------------------------------
// wl_output bind
// ---------------------------------------------------------------------------

fn bindOutput(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    _ = data;
    const resource = Object.create(client, &wlp.WlOutput.interface, version, id) catch return;
    // geometry(x, y, phys_w_mm, phys_h_mm, subpixel, make, model, transform)
    wlp.WlOutput.sendGeometry(resource, 0, 0, 510, 287, 0, "lattice", "Virtual-1", 0);
    // mode(flags, width, height, refresh_mHz)
    wlp.WlOutput.sendMode(resource, OUTPUT_MODE_CURRENT | OUTPUT_MODE_PREFERRED, 1920, 1080, 60000);
    if (version >= 2) wlp.WlOutput.sendScale(resource, 1);
    if (version >= 4) wlp.WlOutput.sendName(resource, "WL-1");
    if (version >= 2) wlp.WlOutput.sendDone(resource);
}
