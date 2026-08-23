//! Compositor: runs a nested Wayland server (Display), registers globals,
//! and exposes a stable epoll fd for the shell to fold into its own pump.
//!
//! Task 4 scope: bring-up only.
//! - Display.create + Shm + wl_compositor (v6) + wl_output (v4).
//! - addSocketAuto: socket name stored in socket_name_buf.
//! - Compositor.fd() -> display event-loop epoll fd.
//! - Compositor.socketName() -> the chosen socket name.
//! - Compositor.deinit() -> destroy display, free self.
//!
//! Task 5: wl_surface attach/commit/frame/damage/destroy handlers wired.
//! Per-wl_surface HostedEntry tracks buffer state + pixel dims.
//! shmFormatToPixelFormat() pure helper unit-tested here.

const std = @import("std");
const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const prism = @import("prism");

const globals = @import("compositor/globals.zig");
const xdg_mod = @import("compositor/xdg.zig");
const hosted = @import("compositor/hosted.zig");
const surface_state = @import("compositor/surface_state.zig");
const draw_mod = @import("compositor/draw.zig");
const seat_mod = @import("compositor/seat.zig");
const dmabuf_mod = @import("compositor/dmabuf.zig");
const constraints_mod = @import("compositor/constraints.zig");
const tablet_mod = @import("compositor/tablet_input.zig");
pub const color_manager = @import("compositor/color_manager.zig");

const ColorMgr = color_manager.ColorManager(@import("color_management"));

pub const Rect = draw_mod.Rect;

pub const SurfaceState = surface_state.SurfaceState;
pub const BufferRef = surface_state.BufferRef;

const Shm = wl.shm.Shm(wlp);

/// wl_shm formats the nested compositor advertises + accepts. In addition to
/// the mandatory ARGB8888 (0) and XRGB8888 (1), we advertise the HDR RGBA fp16
/// format ABGR16161616F (0x48344241). wl_shm sends non-ARGB/XRGB formats as
/// their raw DRM fourcc, so a conforming client uses that fourcc + stride=w*8;
/// wl.shm.Shm gates create_buffer on this list and carries the fourcc through
/// to Buffer.format -> onSurfaceCommit -> uploadToTexture (which maps it to
/// prism rgba16_float). Keeping ARGB/XRGB first leaves the SDR path unchanged.
const shm_formats = [_]u32{
    wl.shm.FORMAT_ARGB8888,
    wl.shm.FORMAT_XRGB8888,
    0x48344241, // DRM_FORMAT_ABGR16161616F (RGBA fp16)
    0x30334241, // DRM_FORMAT_ABGR2101010 (10-bit HDR10 rgb10a2)
    0x30334258, // DRM_FORMAT_XBGR2101010 (10-bit HDR10 rgb10x2) - parity with the dmabuf table
};

pub const HostedSurface = hosted.HostedSurface;
pub const HostedSurfaceId = hosted.HostedSurfaceId;
pub const Client = hosted.Client;
pub const ClientId = hosted.ClientId;
pub const CompositorEvent = hosted.CompositorEvent;
pub const CompositorHandler = hosted.CompositorHandler;

const color = @import("color.zig");

/// Runtime options for Compositor.init.
/// `runtime_dir`: the XDG_RUNTIME_DIR path (required for socket creation).
/// Passing it explicitly avoids std.posix.getenv which is unavailable in Zig 0.16.
pub const Options = struct {
    runtime_dir: []const u8,
    /// Root of the XKB config database (rules/, symbols/, keycodes/, ...).
    /// When set, the seat builds a REAL us/evdev XKB keymap from it at init.
    /// When null (or the build fails), the seat falls back to MINIMAL_KEYMAP.
    /// Passed explicitly since std.posix.getenv is unavailable in Zig 0.16;
    /// the caller derives it from the environment (XKB_CONFIG_ROOT).
    xkb_config_root: ?[]const u8 = null,
};

/// Per-wl_surface entry: tracks the protocol object, double-buffer state, and
/// the last committed pixel dimensions for Task 7 texture upload.
pub const HostedEntry = struct {
    /// The wayland object id of the wl_surface resource.
    object_id: u32,
    /// The wl_surface resource Object pointer.
    wl_surface_res: *wl.Object,
    /// Double-buffer state machine (pure).
    state: SurfaceState = .{},
    /// The currently attached wl_buffer resource (null if detached).
    pending_buffer_res: ?*wl.Object = null,
    /// Frame callback resource (null until a frame request arrives).
    frame_callback_res: ?*wl.Object = null,

    // xdg-shell resources (Task 6).
    /// The xdg_surface resource Object pointer (null until get_xdg_surface).
    xdg_surface_res: ?*wl.Object = null,
    /// The xdg_toplevel resource Object pointer (null until get_toplevel).
    xdg_toplevel_res: ?*wl.Object = null,
    /// The wl_surface object id this xdg_surface is linked to (same as object_id usually).
    wl_surface_object_id: u32 = 0,
    /// Pending configure serial (sent in xdg_surface.configure; cleared on ack).
    pending_configure_serial: ?u32 = null,
    /// True once the client acks the initial configure.
    configure_acked: bool = false,
    /// Stable fixed buffer for the toplevel title string.
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    /// Stable fixed buffer for the toplevel app_id string.
    app_id_buf: [256]u8 = undefined,
    app_id_len: usize = 0,

    // Captured from the last committed buffer (populated on new_buffer commit).
    last_pixels_len: usize = 0,
    last_w: u32 = 0,
    last_h: u32 = 0,
    last_stride: u32 = 0,
    last_format: u32 = 0,

    /// The wl_buffer resource that was committed on this frame (null if no new commit).
    /// Set in onSurfaceCommit, released + nulled in endFrame. Distinct from
    /// pending_buffer_res (the attach-staging pointer) so endFrame never double-releases.
    committed_buffer_res: ?*wl.Object = null,

    /// The dma-buf wl_buffer resource committed on this frame (null if not a dmabuf commit).
    /// Released via wlp.WlBuffer.sendRelease in endFrame (not Shm.releaseBuffer).
    /// Exactly one of committed_buffer_res and committed_dmabuf_res is non-null per frame.
    committed_dmabuf_res: ?*wl.Object = null,

    /// Set to true after a successful texture upload on commit; Task 10 drains this.
    needs_committed_event: bool = false,
    /// Set to true when the surface first transitions to mapped; Task 10 drains this.
    needs_mapped_event: bool = false,
    /// Set to true when the committed size differs from the last-emitted size.
    needs_resized_event: bool = false,
    /// Set to true when a surface becomes unmapped (buffer_cleared or role destroyed).
    needs_unmapped_event: bool = false,

    /// Set to true once we have logged the first HDR color transition for this surface.
    hdr_logged: bool = false,

    /// Set to true once we have logged the first HDR-format (rgba16_float) buffer
    /// import + texel readback proof for this surface.
    hdr_fmt_logged: bool = false,

    /// The neutral hosted surface metadata (shared with shell consumers).
    surface: HostedSurface,
};

/// Composite surface key: object ids are only unique PER CLIENT, so a bare
/// wl_surface object id can collide across clients. Key surface lookups by
/// (client, id). The *Client pointer is COMPOSITOR-INTERNAL (never leaks onto
/// HostedSurface or any neutral type).
pub const SurfaceKey = struct {
    client: *wl.server_client.Client,
    id: u32,
};

/// A connected-client entry.
const ClientEntry = struct {
    /// The neutral client metadata the shell sees.
    client: Client,
    /// The wayland server client pointer (compositor-internal; used only as a
    /// map key for clientIdFor - never dereferenced through this field).
    client_ptr: *wl.server_client.Client,
};

pub const Compositor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    display: *wl.Display,
    shm: *Shm,
    device: *prism.Device,

    surface_entries: std.ArrayList(HostedEntry),
    clients_list: std.ArrayList(ClientEntry),

    handler: ?CompositorHandler = null,
    handler_ctx: *anyopaque = undefined,

    socket_name_buf: [16]u8 = undefined,
    socket_name_len: usize = 0,

    /// Flat view of Client values rebuilt by rebuildViews() each pump().
    clients_view: std.ArrayListUnmanaged(Client) = .empty,
    /// Flat view of HostedSurface values rebuilt by rebuildViews() each pump().
    surfaces_view: std.ArrayListUnmanaged(HostedSurface) = .empty,

    next_surface_id: u32 = 1,
    /// Next neutral ClientId to hand out (assigned by clientIdFor). Starts at 1
    /// so 0 stays reserved/unassigned.
    next_client_id: u32 = 1,

    // Stable pointer to the globals context (wl_compositor / wl_output impls).
    // Lives inline in Compositor (heap-allocated), so &globals_ctx is stable.
    globals_ctx: globals.GlobalsCtx,

    // Stable pointer to the xdg context (xdg_wm_base / xdg_surface / xdg_toplevel impls).
    // Lives inline in Compositor (heap-allocated), so &xdg_ctx is stable.
    xdg_ctx: xdg_mod.XdgCtx,

    // Lazily-built pipeline cache for drawSurface (null until first call).
    draw_cache: ?draw_mod.DrawCache = null,

    // Stable pointer to the seat context (wl_seat / wl_pointer / wl_keyboard impls).
    // Lives inline in Compositor (heap-allocated), so &seat_ctx is stable.
    seat_ctx: seat_mod.SeatCtx,

    // Stable pointer to the dmabuf context (zwp_linux_dmabuf_v1 impls).
    // Lives inline in Compositor (heap-allocated), so &dmabuf_ctx is stable.
    dmabuf_ctx: dmabuf_mod.DmabufCtx,

    // Stable pointer to the constraints context (zwp_pointer_constraints_v1 + relative_pointer impls).
    // Lives inline in Compositor (heap-allocated), so &constraints_ctx is stable.
    constraints_ctx: constraints_mod.ConstraintsCtx,

    // Stable pointer to the tablet context (zwp_tablet_manager_v2 + seat/tablet/tool impls).
    // Lives inline in Compositor (heap-allocated), so &tablet_ctx is stable.
    tablet_ctx: tablet_mod.TabletCtx,

    // Cursor state: current pointer position in render-target pixel space.
    // Updated by pointerMotion; read by drawCursor.
    cursor_x: f64 = 0,
    cursor_y: f64 = 0,
    // Lazily-built default cursor texture (24x24 RGBA8 arrow sprite).
    // Created on first drawCursor call; freed in deinit.
    default_cursor: ?*prism.Resource = null,

    /// Dma-buf buffers keyed by wl_buffer object id.
    /// Populated by create/create_immed (Task 3); removed on buffer destroy (Task 4).
    dmabuf_buffers: std.AutoHashMapUnmanaged(SurfaceKey, dmabuf_mod.DmabufClientBuffer) = .empty,

    /// wp_color_manager_v1 global. Null until init completes.
    color_mgr: ?*ColorMgr = null,

    /// Bring up a nested Wayland compositor.
    /// Heap-allocates `Compositor` for stable pointers (the bind callbacks hold
    /// a pointer to globals_ctx, which lives inside the Compositor).
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        device: *prism.Device,
        opts: Options,
    ) !*Compositor {
        const self = try gpa.create(Compositor);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .display = undefined,
            .shm = undefined,
            .device = device,
            .surface_entries = .empty,
            .clients_list = .empty,
            .globals_ctx = globals.makeGlobalsCtx(),
            .xdg_ctx = xdg_mod.makeXdgCtx(),
            .draw_cache = null,
            .seat_ctx = seat_mod.makeSeatCtx(),
            .dmabuf_ctx = dmabuf_mod.makeDmabufCtx(),
            .constraints_ctx = constraints_mod.makeConstraintsCtx(),
            .tablet_ctx = tablet_mod.makeTabletCtx(),
        };

        // Wire the back-pointer so GlobalsCtx handlers can reach this Compositor.
        // GlobalsCtx.compositor is typed as *CompositorOpaque (opaque) to break
        // the import cycle; getCompositor() in globals.zig casts it back.
        self.globals_ctx.compositor = @ptrCast(self);

        // Wire the back-pointer for XdgCtx.
        self.xdg_ctx.compositor = @ptrCast(self);

        // Wire the back-pointer for SeatCtx.
        self.seat_ctx.compositor = @ptrCast(self);

        // Build + cache the seat's XKB keymap ONCE (allocation discipline).
        // Uses a real us/evdev keymap when xkb_config_root is set and the build
        // succeeds; otherwise selects the embedded MINIMAL_KEYMAP fallback.
        seat_mod.initSeatKeymap(&self.seat_ctx, gpa, io, opts.xkb_config_root);

        // Wire the back-pointer for DmabufCtx.
        self.dmabuf_ctx.compositor = @ptrCast(self);

        // Wire the back-pointer for ConstraintsCtx.
        self.constraints_ctx.compositor = @ptrCast(self);

        // Wire the back-pointer for TabletCtx.
        self.tablet_ctx.compositor = @ptrCast(self);

        self.display = try wl.Display.create(gpa);
        errdefer self.display.destroy();

        self.shm = try Shm.createWithFormats(self.display, &shm_formats);
        errdefer self.shm.deinit();

        try globals.registerGlobals(self.display, &self.globals_ctx);
        try xdg_mod.registerXdgGlobal(self.display, &self.xdg_ctx);
        _ = try self.display.globalCreate(
            &wlp.WlSeat.interface,
            wlp.WlSeat.version,
            seat_mod.bindSeat,
            &self.seat_ctx,
        );

        try dmabuf_mod.registerDmabufGlobal(self.display, &self.dmabuf_ctx);

        try constraints_mod.registerConstraintGlobals(self.display, &self.constraints_ctx);

        try tablet_mod.registerTabletGlobals(self.display, &self.tablet_ctx);

        self.color_mgr = try ColorMgr.create(self.display, .{});

        // Pick an available socket in `runtime_dir` and store the name.
        // Using addSocketAutoInDir avoids std.posix.getenv (not available in Zig 0.16).
        const name = try self.display.addSocketAutoInDir(opts.runtime_dir, &self.socket_name_buf);
        self.socket_name_len = name.len;

        return self;
    }

    /// The socket name clients should set in WAYLAND_DISPLAY.
    pub fn socketName(self: *Compositor) []const u8 {
        return self.socket_name_buf[0..self.socket_name_len];
    }

    /// The epoll fd of the Display's event loop.
    /// Fold this into the shell's own poll alongside Context.fd().
    pub fn fd(self: *Compositor) std.posix.fd_t {
        return self.display.getEventLoop().getFd();
    }

    /// Tear down the compositor.
    pub fn deinit(self: *Compositor) void {
        if (self.default_cursor) |tex| {
            self.device.destroyResource(tex);
            self.default_cursor = null;
        }
        if (self.draw_cache) |*dc| dc.deinit(self.device);
        self.shm.deinit();
        self.surfaces_view.deinit(self.gpa);
        self.clients_view.deinit(self.gpa);
        // Flush any pending protocol messages before tearing down the display.
        self.display.flushClients();
        // display.destroy() destroys all still-connected clients, firing each
        // live object's destroy hook. Several of those hooks MUTATE the
        // containers below:
        //   - the wl_surface hook (onWlSurfaceDestroyed -> removeSurfaceEntry /
        //     dropClientIfNoSurfaces) destroys+nulls prism textures and
        //     orderedRemoves entries from `surface_entries` and `clients_list`;
        //   - the dmabuf wl_buffer hook (dmabufBufferResourceDestroyed) does a
        //     fetchRemove from `dmabuf_buffers`, then munmaps + closes the fd;
        //   - the ColorMgr's surface/creator/image-desc hooks dereference their
        //     *Self to reach the allocator + side maps.
        // So `surface_entries`, `clients_list`, `dmabuf_buffers`, and the
        // ColorMgr MUST all still be ALLOCATED and VALID while display.destroy()
        // runs, and must only be freed AFTERWARDS. On a clean disconnect the
        // hooks fully DRAIN these containers (entries removed, textures freed+
        // nulled, dmabuf fds closed+munmapped) before we get here.
        self.display.destroy();
        if (self.color_mgr) |cm| cm.deinit();
        // Same teardown-order rule as the containers above: the wl_seat destroy
        // hook (onSeatDestroy) orderedRemoves from `seat_ctx.clients` while
        // display.destroy() fires it for still-connected clients. deinitSeatCtx
        // frees that list, so it must run AFTER display.destroy() (once every
        // seat hook has drained the list) - never before, or the hook would walk
        // a freed buffer with poisoned length. It does not depend on the display.
        seat_mod.deinitSeatCtx(&self.seat_ctx, self.gpa);
        constraints_mod.deinitConstraintsCtx(&self.constraints_ctx, self.gpa);
        tablet_mod.deinitTabletCtx(&self.tablet_ctx, self.gpa);
        // Safety net: after display.destroy() the hooks have drained these
        // containers for every client object that was still live. These loops
        // only free entries that had NO live object left to fire a hook (an
        // abrupt path the hooks never reached); normally the containers are
        // already empty and these loops are no-ops. Each guard makes the free
        // happen exactly once:
        //   - the dmabuf hook fetchRemove'd its entries, so anything left here
        //     was never removed => its fd/mapping is freed here for the first time;
        //   - removeSurfaceEntry nulled entry.surface.texture after destroying it,
        //     so the `!= null` guard skips already-freed textures and only frees
        //     a texture the hook never touched.
        var dbuf_it = self.dmabuf_buffers.valueIterator();
        while (dbuf_it.next()) |dbuf| {
            if (dbuf.mapping) |m| {
                std.posix.munmap(m);
                dbuf.mapping = null;
            }
            _ = std.os.linux.close(dbuf.fd);
        }
        self.dmabuf_buffers.deinit(self.gpa);
        for (self.surface_entries.items) |*entry| {
            if (entry.surface.texture) |tex| {
                self.device.destroyResource(tex);
                entry.surface.texture = null;
            }
        }
        self.surface_entries.deinit(self.gpa);
        self.clients_list.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    // -----------------------------------------------------------------------
    // Surface entry management (called from globals.zig handlers)
    // -----------------------------------------------------------------------

    /// Called by onCreateSurface in globals.zig when a client issues get_surface.
    /// Appends a new HostedEntry keyed by the wl_surface object id.
    pub fn createSurfaceEntry(self: *Compositor, surface_res: *wl.Object, object_id: u32) !void {
        const surf_id = HostedSurfaceId.from(self.next_surface_id);
        self.next_surface_id += 1;

        try self.surface_entries.append(self.gpa, .{
            .object_id = object_id,
            .wl_surface_res = surface_res,
            .surface = .{
                .id = surf_id,
                .client = try self.clientIdFor(surface_res.client),
            },
        });
    }

    /// Return a stable neutral ClientId for `client`. Looks up `clients_list`
    /// for an entry with a matching *Client; if found returns its ClientId,
    /// otherwise appends a new ClientEntry with the next ClientId and returns it.
    /// The *Client is stored only as a key; it is never dereferenced here.
    /// Runs at surface-create time only (no per-frame allocation).
    pub fn clientIdFor(self: *Compositor, client: *wl.server_client.Client) !ClientId {
        for (self.clients_list.items) |*ce| {
            if (ce.client_ptr == client) return ce.client.id;
        }
        const cid = ClientId.from(self.next_client_id);
        self.next_client_id += 1;
        try self.clients_list.append(self.gpa, .{
            .client = .{ .id = cid },
            .client_ptr = client,
        });
        return cid;
    }

    /// Remove the HostedEntry for a destroyed wl_surface resource.
    /// Destroys the prism texture if one was allocated.
    /// Clears keyboard/pointer focus if this surface was focused (FIX part of I4).
    pub fn removeSurfaceEntry(self: *Compositor, client: *wl.server_client.Client, object_id: u32) void {
        for (self.surface_entries.items, 0..) |*entry, i| {
            if (entry.wl_surface_res.client == client and entry.object_id == object_id) {
                if (entry.surface.texture) |tex| {
                    self.device.destroyResource(tex);
                    entry.surface.texture = null;
                }
                // Clear focus if this surface was focused.
                if (self.seat_ctx.focus_tracker.focused) |fid| {
                    if (fid == entry.surface.id) {
                        self.seat_ctx.focus_tracker.focused = null;
                    }
                }
                _ = self.surface_entries.orderedRemove(i);
                return;
            }
        }
    }

    /// wl_surface resource destroy hook. Fires on an explicit wl_surface.destroy
    /// request AND on client disconnect (Client.destroy iterates each object and
    /// runs its destroy_fn). Frees the HostedEntry + its prism texture (owned by
    /// removeSurfaceEntry, which is idempotent), then drops the client from
    /// clients_list once it has no surfaces left.
    ///
    /// Does NOT touch dmabuf fds/mmaps or color state: those are owned by the
    /// wl_buffer hook (dmabufBufferResourceDestroyed) and the cm_surface hook
    /// (surfaceResourceDestroyed) respectively, which fire independently on the
    /// same disconnect. Touching only surface_entries + clients_list + the
    /// compositor-owned texture keeps this safe regardless of hook order.
    pub fn onWlSurfaceDestroyed(self: *Compositor, resource: *wl.Object) void {
        const client = resource.client;
        self.removeSurfaceEntry(client, resource.id);
        self.dropClientIfNoSurfaces(client);
    }

    /// Remove `client`'s ClientEntry from clients_list if it no longer owns any
    /// surface_entries. Linear scan by client_ptr. No-op if the client still has
    /// surfaces or was never registered. Makes disconnect cleanup complete so
    /// clients_list is no longer grow-only.
    fn dropClientIfNoSurfaces(self: *Compositor, client: *wl.server_client.Client) void {
        for (self.surface_entries.items) |*entry| {
            if (entry.wl_surface_res.client == client) return; // still has surfaces
        }
        for (self.clients_list.items, 0..) |*ce, i| {
            if (ce.client_ptr == client) {
                _ = self.clients_list.orderedRemove(i);
                return;
            }
        }
    }

    /// Find a HostedEntry by (client, wl_surface object id). Object ids are only
    /// unique per client, so the client pointer disambiguates cross-client
    /// collisions. Returns null if not found.
    pub fn findSurface(self: *Compositor, client: *wl.server_client.Client, object_id: u32) ?*HostedEntry {
        for (self.surface_entries.items) |*entry| {
            if (entry.wl_surface_res.client == client and entry.object_id == object_id) return entry;
        }
        return null;
    }

    /// Look up a dma-buf client buffer by its (client, wl_buffer object id) key.
    /// Object ids are only unique per client, so the owning client must be part
    /// of the key. Returns null if no dma-buf buffer is registered (shm path).
    pub fn findDmabufBuffer(self: *Compositor, client: *wl.server_client.Client, object_id: u32) ?*dmabuf_mod.DmabufClientBuffer {
        return self.dmabuf_buffers.getPtr(.{ .client = client, .id = object_id });
    }

    /// Find a HostedEntry by its neutral HostedSurfaceId. Returns null if not found.
    pub fn findSurfaceById(self: *Compositor, id: HostedSurfaceId) ?*HostedEntry {
        for (self.surface_entries.items) |*entry| {
            if (entry.surface.id == id) return entry;
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // drawSurface: textured-quad compositor helper
    // -----------------------------------------------------------------------

    /// Draw the hosted surface identified by `surface_id` into `rt` at pixel rect `rect`.
    ///
    /// `rt_w` / `rt_h` are the render target dimensions in pixels (supplied by the
    /// caller since prism does not expose an rt-size accessor).
    ///
    /// Lazily builds the textured-quad pipeline on first call (cached on self.draw_cache).
    /// If the surface has no uploaded texture yet, returns without drawing.
    ///
    /// The caller is responsible for present + endFrame after the draw.
    pub fn drawSurface(
        self: *Compositor,
        rt: *prism.Resource,
        rt_w: u32,
        rt_h: u32,
        surface_id: HostedSurfaceId,
        rect: Rect,
    ) !void {
        // Lazily build the pipeline cache.
        if (self.draw_cache == null) {
            self.draw_cache = try draw_mod.DrawCache.init(self.gpa, self.device);
        }
        const dc = &self.draw_cache.?;

        // Find the surface; skip if missing or not yet uploaded.
        const entry = self.findSurfaceById(surface_id) orelse return;
        const tex = entry.surface.texture orelse return;

        // Write the quad vertices into the vertex buffer.
        const verts = draw_mod.quadVertices(rect, @floatFromInt(rt_w), @floatFromInt(rt_h));
        const vbuf_bytes = try self.device.mapResource(dc.vbuf);
        @memcpy(vbuf_bytes[0 .. verts.len * 4], std.mem.asBytes(&verts));
        self.device.unmapResource(dc.vbuf);

        // Record + submit the draw commands.
        const cb = try dc.ctx.beginCommands();
        defer cb.deinit();
        try cb.setRenderTarget(rt);
        try cb.bindPipeline(dc.pipeline);
        try cb.bindVertexBuffer(dc.vbuf);
        try cb.bindTexture(prism.hal.TextureBinding{
            .binding = dc.sampler_binding,
            .image = tex,
            .filter = .linear,
            .address_u = .clamp_to_edge,
            .address_v = .clamp_to_edge,
        });
        try cb.draw(6, 0);
        try dc.ctx.submit(cb);
    }

    // -----------------------------------------------------------------------
    // drawCursor: render the default arrow cursor sprite at the current position
    // -----------------------------------------------------------------------

    /// Draw the cursor into `rt`.
    ///
    /// Decision order:
    ///   1. Pointer LOCK active (isCursorHidden) -> draw nothing, return.
    ///   2. Focused client cursor state via pickCursor:
    ///      a. client hid cursor (cursor_hidden) -> draw nothing.
    ///      b. client set cursor surface with uploaded texture -> draw client texture
    ///         at (cursor_x - hotspot_x, cursor_y - hotspot_y).
    ///      c. default -> draw built-in arrow sprite at (cursor_x, cursor_y).
    ///   3. Out-of-bounds guard: skip when the draw position is past the RT edge.
    ///
    /// NOTE: cursor wl_surfaces (role=none) DO receive texture uploads via the
    /// standard onSurfaceCommit -> uploadToTexture path. No xdg role or
    /// configure-ack is required for a buffer commit to upload the texture.
    /// Therefore client cursor images WILL render once the client attaches and
    /// commits a buffer to its cursor surface.
    ///
    /// Lazily creates the default cursor texture on first call; freed in deinit().
    /// Reuses self.draw_cache (same pipeline as drawSurface; built lazily).
    pub fn drawCursor(
        self: *Compositor,
        rt: *prism.Resource,
        rt_w: u32,
        rt_h: u32,
    ) !void {
        // 1. Hide cursor when a pointer lock is active (lock takes precedence over set_cursor).
        if (draw_mod.isCursorHidden(self.constraints_ctx.list.items)) return;

        const cx: f32 = @floatCast(self.cursor_x);
        const cy: f32 = @floatCast(self.cursor_y);

        // 2. Determine cursor choice for the focused client.
        const focused = self.seat_ctx.focus_tracker.focused;
        var choice = draw_mod.CursorChoice.default;
        var client_tex: ?*prism.Resource = null;
        var hotspot_x: i32 = 0;
        var hotspot_y: i32 = 0;
        var client_w: u32 = 0;
        var client_h: u32 = 0;

        if (focused) |fid| {
            if (seat_mod.findClientSeatForSurface(&self.seat_ctx, self, fid)) |cs| {
                // Look up the cursor surface texture if the client specified one.
                var has_texture = false;
                if (cs.cursor_set and !cs.cursor_hidden and cs.cursor_surface_id != 0) {
                    // cursor wl_surface: keyed by (client of focused surface, cursor_surface_id).
                    if (self.findSurfaceById(fid)) |focused_entry| {
                        const cursor_client = focused_entry.wl_surface_res.client;
                        if (self.findSurface(cursor_client, cs.cursor_surface_id)) |centry| {
                            if (centry.surface.texture != null) {
                                has_texture = true;
                                client_tex = centry.surface.texture;
                                client_w = centry.last_w;
                                client_h = centry.last_h;
                            }
                        }
                    }
                }
                choice = draw_mod.pickCursor(cs.cursor_set, cs.cursor_hidden, has_texture);
                hotspot_x = cs.cursor_hotspot_x;
                hotspot_y = cs.cursor_hotspot_y;
            }
        }

        // 2a. Client hid the cursor.
        if (choice == .none) return;

        // Determine the draw position depending on the choice.
        var draw_x: f32 = cx;
        var draw_y: f32 = cy;
        const cursor_size_w: f32 = @floatFromInt(draw_mod.CURSOR_SIZE);
        const cursor_size_h: f32 = @floatFromInt(draw_mod.CURSOR_SIZE);
        var draw_w: f32 = cursor_size_w;
        var draw_h: f32 = cursor_size_h;

        if (choice == .client) {
            // Apply hotspot offset: hotspot is the pixel within the cursor surface
            // that maps to the pointer hot spot. Subtract from cursor_pos to get
            // the top-left corner of the cursor surface in screen space.
            draw_x = cx - @as(f32, @floatFromInt(hotspot_x));
            draw_y = cy - @as(f32, @floatFromInt(hotspot_y));
            // Use the client cursor's committed buffer dimensions. Fall back to
            // CURSOR_SIZE if no buffer has been committed yet (last_w/last_h == 0).
            draw_w = if (client_w > 0) @floatFromInt(client_w) else cursor_size_w;
            draw_h = if (client_h > 0) @floatFromInt(client_h) else cursor_size_h;
        }

        // 3. Out-of-bounds guard (upper AND lower bounds).
        if (draw_x >= @as(f32, @floatFromInt(rt_w)) or draw_y >= @as(f32, @floatFromInt(rt_h))) return;
        if (draw_x + draw_w <= 0 or draw_y + draw_h <= 0) return;

        // Lazily build the draw pipeline cache.
        if (self.draw_cache == null) {
            self.draw_cache = try draw_mod.DrawCache.init(self.gpa, self.device);
        }
        const dc = &self.draw_cache.?;

        // Select the texture to draw.
        const cursor_tex: *prism.Resource = blk: {
            if (choice == .client) {
                break :blk client_tex.?;
            }
            // Default: lazily create + upload the arrow sprite.
            if (self.default_cursor == null) {
                const tex = try self.device.createResource(.{
                    .image = .{
                        .width = draw_mod.CURSOR_SIZE,
                        .height = draw_mod.CURSOR_SIZE,
                        .format = .rgba8_unorm,
                        .usage = .{ .sampled = true },
                    },
                });
                errdefer self.device.destroyResource(tex);

                var pixel_buf: [draw_mod.CURSOR_SIZE * draw_mod.CURSOR_SIZE * 4]u8 = undefined;
                draw_mod.buildArrowCursor(&pixel_buf, draw_mod.CURSOR_SIZE, draw_mod.CURSOR_SIZE);

                const dst = try self.device.mapResource(tex);
                @memcpy(dst[0..pixel_buf.len], &pixel_buf);
                self.device.unmapResource(tex);

                self.default_cursor = tex;
            }
            break :blk self.default_cursor.?;
        };

        const rect = Rect{ .x = draw_x, .y = draw_y, .w = draw_w, .h = draw_h };

        // Write the quad vertices.
        const verts = draw_mod.quadVertices(rect, @floatFromInt(rt_w), @floatFromInt(rt_h));
        const vbuf_bytes = try self.device.mapResource(dc.vbuf);
        @memcpy(vbuf_bytes[0 .. verts.len * 4], std.mem.asBytes(&verts));
        self.device.unmapResource(dc.vbuf);

        // Record + submit the draw commands using the blend-enabled cursor pipeline.
        const cb = try dc.ctx.beginCommands();
        defer cb.deinit();
        try cb.setRenderTarget(rt);
        try cb.bindPipeline(dc.cursor_pipeline);
        try cb.bindVertexBuffer(dc.vbuf);
        try cb.bindTexture(prism.hal.TextureBinding{
            .binding = dc.sampler_binding,
            .image = cursor_tex,
            .filter = .linear,
            .address_u = .clamp_to_edge,
            .address_v = .clamp_to_edge,
        });
        try cb.draw(6, 0);
        try dc.ctx.submit(cb);
    }

    // -----------------------------------------------------------------------
    // Input routing (Task 9)
    // -----------------------------------------------------------------------

    /// Change keyboard + pointer focus to `surface`. Pass null to clear focus.
    /// Sends wl_keyboard/wl_pointer leave to the old focused client and
    /// enter to the new one. No-op if focus does not change.
    pub fn focus(self: *Compositor, surface: ?HostedSurfaceId) void {
        seat_mod.routeFocus(&self.seat_ctx, self, surface);
    }

    /// Route a pointer motion to the currently focused surface.
    /// `x` and `y` are surface-local coordinates in pixels.
    /// Also records the cursor position for drawCursor.
    pub fn pointerMotion(self: *Compositor, x: f64, y: f64) void {
        self.cursor_x = x;
        self.cursor_y = y;
        seat_mod.routePointerMotion(&self.seat_ctx, self, x, y);
    }

    /// Route a pointer button press or release to the currently focused surface.
    /// `button` is a Linux evdev button code (e.g. 0x110 = BTN_LEFT).
    pub fn pointerButton(self: *Compositor, button: u32, pressed: bool) void {
        seat_mod.routePointerButton(&self.seat_ctx, self, button, pressed);
    }

    /// Route a pointer axis scroll to the currently focused surface.
    /// Positive vertical = scroll down, positive horizontal = scroll right.
    pub fn pointerAxis(self: *Compositor, horizontal: f64, vertical: f64) void {
        seat_mod.routePointerAxis(&self.seat_ctx, self, horizontal, vertical);
    }

    /// Route a key press or release to the currently focused surface.
    /// `keycode` is the evdev scancode (kernel keycode; clients add 8 for XKB).
    pub fn key(self: *Compositor, keycode: u32, pressed: bool) void {
        seat_mod.routeKey(&self.seat_ctx, self, keycode, pressed);
    }

    /// Route seat-global relative motion to the focused client's zwp_relative_pointer_v1.
    /// `dx`/`dy` are accelerated deltas; `dx_unaccel`/`dy_unaccel` are raw (unaccelerated).
    /// Sent whenever the focused client has a relative pointer resource.
    pub fn pointerRelative(self: *Compositor, dx: f64, dy: f64, dx_unaccel: f64, dy_unaccel: f64) void {
        seat_mod.routePointerRelative(&self.seat_ctx, self, dx, dy, dx_unaccel, dy_unaccel);
    }

    /// Route modifier state to the currently focused surface.
    pub fn modifiers(
        self: *Compositor,
        mods_depressed: u32,
        mods_latched: u32,
        mods_locked: u32,
        group: u32,
    ) void {
        seat_mod.routeModifiers(&self.seat_ctx, self, mods_depressed, mods_latched, mods_locked, group);
    }

    /// Route a tablet proximity event to the currently focused surface.
    /// Pass in_prox=true when the tool enters proximity, false when it leaves.
    /// No-op if no surface is currently focused.
    pub fn tabletProximity(self: *Compositor, in_prox: bool) void {
        const focused = self.seat_ctx.focus_tracker.focused orelse return;
        tablet_mod.routeTabletProximity(&self.tablet_ctx, self, focused, in_prox);
    }

    /// Route tablet axis (motion + pressure) to the currently focused surface.
    /// x/y are surface-local pixel coordinates; pressure is [0, 1].
    /// No-op if no surface is currently focused.
    pub fn tabletAxis(self: *Compositor, x: f64, y: f64, pressure: f64) void {
        const focused = self.seat_ctx.focus_tracker.focused orelse return;
        tablet_mod.routeTabletAxis(&self.tablet_ctx, self, focused, x, y, pressure);
    }

    /// Route a tablet tip (down/up) event to the currently focused surface.
    /// Pass down=true for tip-down, false for tip-up.
    /// No-op if no surface is currently focused.
    pub fn tabletTip(self: *Compositor, down: bool) void {
        const focused = self.seat_ctx.focus_tracker.focused orelse return;
        tablet_mod.routeTabletTip(&self.tablet_ctx, self, focused, down);
    }

    // -----------------------------------------------------------------------
    // Task 10: pump, clients(), surfaces(), endFrame()
    // -----------------------------------------------------------------------

    /// Drive one iteration of the nested compositor:
    /// 1. flushClients() - send pending protocol messages to hosted clients.
    /// 2. dispatch(timeout_ms) - epoll-wait on the server event loop.
    /// 3. Drain pending events: for each surface with flags set, emit
    ///    surface_mapped first, then surface_committed, then surface_resized.
    ///
    /// Event ordering guarantee: for any single surface, surface_mapped is
    /// always emitted before surface_committed. Surfaces are visited in
    /// insertion order (stable).
    ///
    /// Allocation-free on the drain path (iterates existing ArrayList + flags).
    pub fn pump(
        self: *Compositor,
        timeout_ms: ?u32,
        handler: CompositorHandler,
        ctx: *anyopaque,
    ) !void {
        // Store handler + ctx for any call-site that fires events directly.
        self.handler = handler;
        self.handler_ctx = ctx;

        // 1. Push any buffered protocol messages out to hosted clients.
        self.display.flushClients();

        // 2. Block (up to timeout) for new client requests or fd readiness.
        const timeout_i32: i32 = if (timeout_ms) |t| @intCast(t) else -1;
        try self.display.getEventLoop().dispatch(timeout_i32);

        // 3. Drain pending surface events (mapped before committed, per surface).
        drainSurfaceEvents(self.surface_entries.items, handler, ctx);

        // 4. Rebuild the neutral view slices so clients()/surfaces() are fresh.
        try self.rebuildViews();
    }

    /// Return the current connected-client list as a slice of Client values.
    /// The slice is valid until the next pump() call (or client disconnect).
    pub fn clients(self: *Compositor) []const Client {
        return self.clients_view.items;
    }

    /// Return the current hosted-surface list as a slice of HostedSurface values.
    /// Each HostedSurface is the neutral metadata view (no wire types).
    /// The slice is valid until the next pump() call.
    pub fn surfaces(self: *Compositor) []const HostedSurface {
        // surfaces_view is rebuilt lazily from the HostedEntry list.
        return self.surfaces_view.items;
    }

    /// Rebuild the surfaces_view and clients_view from the live entry lists.
    /// Called at the end of pump() after draining events.
    /// Allocation-free if the view capacity is already large enough.
    fn rebuildViews(self: *Compositor) !void {
        // Rebuild clients_view.
        try self.clients_view.resize(self.gpa, self.clients_list.items.len);
        for (self.clients_list.items, 0..) |ce, i| {
            self.clients_view.items[i] = ce.client;
        }
        // Rebuild surfaces_view.
        try self.surfaces_view.resize(self.gpa, self.surface_entries.items.len);
        for (self.surface_entries.items, 0..) |*entry, i| {
            self.surfaces_view.items[i] = entry.surface;
        }
    }

    /// Called by the shell AFTER it has presented its frame.
    /// For each committed-and-not-yet-released surface:
    ///   1. Releases the wl_shm buffer back to the client (so it can reuse it).
    ///   2. Fires the wl_surface.frame callback with the current time (ms).
    ///
    /// This paces the hosted client to the shell's present cadence.
    pub fn endFrame(self: *Compositor) void {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        const time_ms: u32 = @truncate(@as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000);
        for (self.surface_entries.items) |*entry| {
            // FIX C3: release only the buffer that was committed on this frame.
            // pending_buffer_res is the attach-staging pointer and must not be touched here.
            if (entry.committed_buffer_res) |buf_res| {
                Shm.releaseBuffer(buf_res);
                entry.committed_buffer_res = null;
            }
            // Release a dma-buf committed buffer via wl_buffer.release (not Shm.releaseBuffer).
            if (entry.committed_dmabuf_res) |dbuf_res| {
                wlp.WlBuffer.sendRelease(dbuf_res);
                entry.committed_dmabuf_res = null;
            }
            // Fire the frame callback and destroy the callback object.
            if (entry.frame_callback_res) |cb_res| {
                wlp.WlCallback.sendDone(cb_res, time_ms);
                cb_res.destroy();
                entry.frame_callback_res = null;
            }
        }
        // Flush so the client receives the done + release events promptly.
        self.display.flushClients();
    }

    /// Return the color state a nested client set on a surface (by wl_surface id),
    /// or null if the surface has no explicit color state (treat as sRGB).
    pub fn surfaceColorState(self: *Compositor, client: *wl.server_client.Client, surface_id: u32) ?color_manager.SurfaceColorState {
        return if (self.color_mgr) |cm| cm.surfaceState(client, surface_id) else null;
    }
};

// ---------------------------------------------------------------------------
// Pure event-drain helper (factored for unit testing).
// Iterates entries and delivers events via handler, clearing flags.
// Ordering: for any single surface, surface_mapped fires before
// surface_committed, which fires before surface_resized.
// ---------------------------------------------------------------------------

/// Drain pending surface events from `entries` by calling `handler(ctx, ev)`.
/// Pure in the sense that it only reads/writes flags on the entries; no
/// allocation and no wire calls. Safe to call with an empty entries slice.
pub fn drainSurfaceEvents(
    entries: []HostedEntry,
    handler: CompositorHandler,
    ctx: *anyopaque,
) void {
    for (entries) |*entry| {
        if (entry.needs_mapped_event) {
            entry.needs_mapped_event = false;
            handler(ctx, .{ .surface_mapped = entry.surface.id });
        }
        if (entry.needs_committed_event) {
            entry.needs_committed_event = false;
            handler(ctx, .{ .surface_committed = entry.surface.id });
        }
        if (entry.needs_resized_event) {
            entry.needs_resized_event = false;
            handler(ctx, .{ .surface_resized = .{
                .id = entry.surface.id,
                .width = entry.surface.width,
                .height = entry.surface.height,
            } });
        }
        // FIX I1: unmapped is terminal for a surface; emit after committed/resized.
        if (entry.needs_unmapped_event) {
            entry.needs_unmapped_event = false;
            handler(ctx, .{ .surface_unmapped = entry.surface.id });
        }
    }
}

// ---------------------------------------------------------------------------
// Pure helper: map a wl_shm format value to a lattice PixelFormat.
// 0 = ARGB8888, 1 = XRGB8888 (wl_shm spec, matches wl.shm constants).
// ---------------------------------------------------------------------------

pub fn shmFormatToPixelFormat(format: u32) color.PixelFormat {
    return switch (format) {
        0 => .argb8888,
        1 => .xrgb8888,
        else => .xrgb8888, // fallback; callers should only pass known formats
    };
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "shmFormatToPixelFormat: 0 -> argb8888, 1 -> xrgb8888" {
    const testing = std.testing;
    try testing.expectEqual(color.PixelFormat.argb8888, shmFormatToPixelFormat(0));
    try testing.expectEqual(color.PixelFormat.xrgb8888, shmFormatToPixelFormat(1));
}

// ---------------------------------------------------------------------------
// Unit tests: drainSurfaceEvents ordering
// ---------------------------------------------------------------------------

/// A sentinel non-null pointer for tests that need a *wl.Object but never dereference it.
/// Aligned to the required alignment of wl.Object so @ptrFromInt does not error.
fn dummyObjectPtr() *wl.Object {
    const alignment = @alignOf(wl.Object);
    const addr = std.mem.alignForward(usize, 0x10000, alignment);
    return @ptrFromInt(addr);
}

/// Collect events fired by drainSurfaceEvents into a fixed-size buffer.
const EventCollector = struct {
    buf: [16]CompositorEvent = undefined,
    len: usize = 0,

    fn handler(ctx: *anyopaque, ev: CompositorEvent) void {
        const self: *EventCollector = @ptrCast(@alignCast(ctx));
        if (self.len < self.buf.len) {
            self.buf[self.len] = ev;
            self.len += 1;
        }
    }

    fn events(self: *const EventCollector) []const CompositorEvent {
        return self.buf[0..self.len];
    }
};

fn makeTestEntry(id: u32, mapped: bool, committed: bool, resized: bool) HostedEntry {
    return .{
        .object_id = id,
        .wl_surface_res = dummyObjectPtr(),
        .needs_mapped_event = mapped,
        .needs_committed_event = committed,
        .needs_resized_event = resized,
        .surface = .{
            .id = HostedSurfaceId.from(id),
            .client = ClientId.from(0),
            .width = 100,
            .height = 100,
        },
    };
}

test "drainSurfaceEvents: both flags -> mapped then committed, flags cleared" {
    const testing = std.testing;
    var entries = [_]HostedEntry{makeTestEntry(1, true, true, false)};
    var col = EventCollector{};
    drainSurfaceEvents(&entries, EventCollector.handler, &col);
    const evs = col.events();
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expect(std.meta.activeTag(evs[0]) == .surface_mapped);
    try testing.expect(std.meta.activeTag(evs[1]) == .surface_committed);
    try testing.expectEqual(@as(u32, 1), evs[0].surface_mapped.value());
    try testing.expectEqual(@as(u32, 1), evs[1].surface_committed.value());
    // Flags must be cleared after drain.
    try testing.expect(!entries[0].needs_mapped_event);
    try testing.expect(!entries[0].needs_committed_event);
}

test "drainSurfaceEvents: only committed flag" {
    const testing = std.testing;
    var entries = [_]HostedEntry{makeTestEntry(2, false, true, false)};
    var col = EventCollector{};
    drainSurfaceEvents(&entries, EventCollector.handler, &col);
    const evs = col.events();
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expect(std.meta.activeTag(evs[0]) == .surface_committed);
    try testing.expect(!entries[0].needs_committed_event);
}

test "drainSurfaceEvents: only mapped flag" {
    const testing = std.testing;
    var entries = [_]HostedEntry{makeTestEntry(3, true, false, false)};
    var col = EventCollector{};
    drainSurfaceEvents(&entries, EventCollector.handler, &col);
    const evs = col.events();
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expect(std.meta.activeTag(evs[0]) == .surface_mapped);
    try testing.expect(!entries[0].needs_mapped_event);
}

test "drainSurfaceEvents: no flags -> no events" {
    const testing = std.testing;
    var entries = [_]HostedEntry{makeTestEntry(4, false, false, false)};
    var col = EventCollector{};
    drainSurfaceEvents(&entries, EventCollector.handler, &col);
    try testing.expectEqual(@as(usize, 0), col.events().len);
}

test "drainSurfaceEvents: two surfaces, second gets mapped then committed" {
    const testing = std.testing;
    var entries = [_]HostedEntry{
        makeTestEntry(10, false, true, false),
        makeTestEntry(11, true, true, false),
    };
    var col = EventCollector{};
    drainSurfaceEvents(&entries, EventCollector.handler, &col);
    const evs = col.events();
    // e1: committed only; e2: mapped then committed
    try testing.expectEqual(@as(usize, 3), evs.len);
    try testing.expect(std.meta.activeTag(evs[0]) == .surface_committed);
    try testing.expectEqual(@as(u32, 10), evs[0].surface_committed.value());
    try testing.expect(std.meta.activeTag(evs[1]) == .surface_mapped);
    try testing.expectEqual(@as(u32, 11), evs[1].surface_mapped.value());
    try testing.expect(std.meta.activeTag(evs[2]) == .surface_committed);
    try testing.expectEqual(@as(u32, 11), evs[2].surface_committed.value());
}

test "drainSurfaceEvents: resized flag emitted after committed" {
    const testing = std.testing;
    var entries = [_]HostedEntry{makeTestEntry(5, false, true, true)};
    var col = EventCollector{};
    drainSurfaceEvents(&entries, EventCollector.handler, &col);
    const evs = col.events();
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expect(std.meta.activeTag(evs[0]) == .surface_committed);
    try testing.expect(std.meta.activeTag(evs[1]) == .surface_resized);
    try testing.expectEqual(@as(u32, 100), evs[1].surface_resized.width);
    try testing.expectEqual(@as(u32, 100), evs[1].surface_resized.height);
    try testing.expect(!entries[0].needs_resized_event);
}

// ---------------------------------------------------------------------------
// Unit test: dmabuf discriminator (findDmabufBuffer)
// The commit discriminator is: if (comp.findDmabufBuffer(buf_res.client, buf_res.id)) |dbuf| { dmabuf }
// else { shm }. This test validates the map-lookup helper in isolation.
// ---------------------------------------------------------------------------

test "findDmabufBuffer: known key -> dmabuf, unknown id -> null (shm path)" {
    const testing = std.testing;
    var map = std.AutoHashMapUnmanaged(SurfaceKey, dmabuf_mod.DmabufClientBuffer){};
    defer map.deinit(testing.allocator);

    const client_a = sentinelClient(0x1000);

    // Insert a fake dmabuf entry with id=42 on client_a.
    try map.put(testing.allocator, .{ .client = client_a, .id = 42 }, .{
        .fd = 0,
        .width = 320,
        .height = 240,
        .stride = 320 * 4,
        .format = 0x34325241, // ARGB8888
        .modifier = 0,
    });

    // (client_a, 42) should resolve as dmabuf (non-null).
    const found = map.getPtr(.{ .client = client_a, .id = 42 });
    try testing.expect(found != null);
    try testing.expectEqual(@as(u32, 320), found.?.width);
    try testing.expectEqual(@as(u32, 240), found.?.height);

    // (client_a, 99) is not in the map -> null -> shm path.
    try testing.expect(map.getPtr(.{ .client = client_a, .id = 99 }) == null);
}

test "dmabuf_buffers: two clients share an object id without colliding" {
    const testing = std.testing;
    var map = std.AutoHashMapUnmanaged(SurfaceKey, dmabuf_mod.DmabufClientBuffer){};
    defer map.deinit(testing.allocator);

    // Two distinct client sentinels, same wl_buffer object id.
    const client_a = sentinelClient(0x1000);
    const client_b = sentinelClient(0x2000);
    const id: u32 = 7;

    try map.put(testing.allocator, .{ .client = client_a, .id = id }, .{
        .fd = 0,
        .width = 100,
        .height = 100,
        .stride = 100 * 4,
        .format = 0x34325241,
        .modifier = 0,
    });
    try map.put(testing.allocator, .{ .client = client_b, .id = id }, .{
        .fd = 0,
        .width = 200,
        .height = 200,
        .stride = 200 * 4,
        .format = 0x34325241,
        .modifier = 0,
    });

    // Both are retrievable distinctly under the same id.
    const a = map.getPtr(.{ .client = client_a, .id = id });
    const b = map.getPtr(.{ .client = client_b, .id = id });
    try testing.expect(a != null);
    try testing.expect(b != null);
    try testing.expectEqual(@as(u32, 100), a.?.width);
    try testing.expectEqual(@as(u32, 200), b.?.width);

    // Removing client_a's buffer (mirrors dmabufBufferResourceDestroyed) leaves
    // client_b's buffer at the same id intact.
    const removed = map.fetchRemove(.{ .client = client_a, .id = id });
    try testing.expect(removed != null);
    try testing.expect(map.getPtr(.{ .client = client_a, .id = id }) == null);
    const still = map.getPtr(.{ .client = client_b, .id = id });
    try testing.expect(still != null);
    try testing.expectEqual(@as(u32, 200), still.?.width);
}

// ---------------------------------------------------------------------------
// Unit tests: composite (client, id) keying (multiclient slice 2, Task 1)
// ---------------------------------------------------------------------------

/// Two distinct dummy addresses used purely as *Client map keys. clientIdFor
/// and findSurface only compare/store these pointers, never dereference them.
fn sentinelClient(addr: usize) *wl.server_client.Client {
    const alignment = @alignOf(wl.server_client.Client);
    return @ptrFromInt(std.mem.alignForward(usize, addr, alignment));
}

/// Build a minimal Compositor shell for tests that only exercise clientIdFor /
/// findSurface (list scans over surface_entries / clients_list). Only the
/// fields those two methods touch are populated; the rest stay undefined.
fn makeTestCompositorShell() Compositor {
    return .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .display = undefined,
        .shm = undefined,
        .device = undefined,
        .surface_entries = .empty,
        .clients_list = .empty,
        .globals_ctx = undefined,
        .xdg_ctx = undefined,
        .seat_ctx = undefined,
        .dmabuf_ctx = undefined,
        .constraints_ctx = undefined,
        .tablet_ctx = undefined,
    };
}

test "clientIdFor: distinct clients -> distinct ids, stable per client" {
    const testing = std.testing;
    var comp = makeTestCompositorShell();
    defer comp.clients_list.deinit(comp.gpa);
    defer comp.clients_view.deinit(comp.gpa);

    const client_a = sentinelClient(0x1000);
    const client_b = sentinelClient(0x2000);

    const id_a1 = try comp.clientIdFor(client_a);
    const id_b = try comp.clientIdFor(client_b);
    const id_a2 = try comp.clientIdFor(client_a);

    // Distinct clients get distinct ids.
    try testing.expect(id_a1 != id_b);
    // Repeat lookup for the same client is stable.
    try testing.expectEqual(id_a1, id_a2);
    // Only two entries were appended (no dup on the repeat lookup).
    try testing.expectEqual(@as(usize, 2), comp.clients_list.items.len);
}

/// Build a HostedEntry whose findSurface-relevant fields (wl_surface_res.client
/// and object_id) are set, backing the wl.Object on the caller's stack.
fn makeKeyedEntry(obj: *wl.Object, client: *wl.server_client.Client, id: u32) HostedEntry {
    obj.client = client;
    obj.id = id;
    return .{
        .object_id = id,
        .wl_surface_res = obj,
        .surface = .{
            .id = HostedSurfaceId.from(id),
            .client = ClientId.from(0),
        },
    };
}

test "findSurface: same object id, different clients -> distinct entries" {
    const testing = std.testing;
    var comp = makeTestCompositorShell();
    defer comp.surface_entries.deinit(comp.gpa);
    defer comp.surfaces_view.deinit(comp.gpa);

    const client_a = sentinelClient(0x3000);
    const client_b = sentinelClient(0x4000);

    // Two Object stubs on the stack; findSurface only reads .client and .id.
    var obj_a: wl.Object = undefined;
    var obj_b: wl.Object = undefined;

    // SAME object id (2) but different owning clients.
    try comp.surface_entries.append(comp.gpa, makeKeyedEntry(&obj_a, client_a, 2));
    try comp.surface_entries.append(comp.gpa, makeKeyedEntry(&obj_b, client_b, 2));

    const found_a = comp.findSurface(client_a, 2);
    const found_b = comp.findSurface(client_b, 2);

    try testing.expect(found_a != null);
    try testing.expect(found_b != null);
    // Each resolves to the entry owned by that client (distinct pointers).
    try testing.expect(found_a.?.wl_surface_res.client == client_a);
    try testing.expect(found_b.?.wl_surface_res.client == client_b);
    try testing.expect(found_a != found_b);

    // Unknown client at the same id -> null.
    try testing.expect(comp.findSurface(sentinelClient(0x5000), 2) == null);
}

test "onWlSurfaceDestroyed: removes only that client's entry + drops client from clients_list" {
    const testing = std.testing;
    var comp = makeTestCompositorShell();
    defer comp.surface_entries.deinit(comp.gpa);
    defer comp.surfaces_view.deinit(comp.gpa);
    defer comp.clients_list.deinit(comp.gpa);
    defer comp.clients_view.deinit(comp.gpa);

    const client_a = sentinelClient(0x6000);
    const client_b = sentinelClient(0x7000);

    // Register both clients in clients_list (mirrors createSurfaceEntry path).
    _ = try comp.clientIdFor(client_a);
    _ = try comp.clientIdFor(client_b);

    // Two Object stubs on the stack; same object id (2), different clients.
    // texture stays null so removeSurfaceEntry's destroy path is a no-op (no
    // real device needed); we assert entry removal + clients_list only.
    var obj_a: wl.Object = undefined;
    var obj_b: wl.Object = undefined;
    try comp.surface_entries.append(comp.gpa, makeKeyedEntry(&obj_a, client_a, 2));
    try comp.surface_entries.append(comp.gpa, makeKeyedEntry(&obj_b, client_b, 2));

    // seat_ctx is undefined in the shell; guard the focus check by leaving
    // focused null. makeKeyedEntry sets texture=null so no device deref.
    comp.seat_ctx.focus_tracker.focused = null;

    // Destroy client-A's wl_surface (obj_a: .client=A, .id=2).
    comp.onWlSurfaceDestroyed(&obj_a);

    // A's entry is gone; B's entry (same id, different client) survives.
    try testing.expect(comp.findSurface(client_a, 2) == null);
    try testing.expect(comp.findSurface(client_b, 2) != null);
    try testing.expectEqual(@as(usize, 1), comp.surface_entries.items.len);

    // A had only that one surface -> dropped from clients_list; B remains.
    try testing.expectEqual(@as(usize, 1), comp.clients_list.items.len);
    try testing.expect(comp.clients_list.items[0].client_ptr == client_b);
}
