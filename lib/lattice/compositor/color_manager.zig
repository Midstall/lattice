//! Server-side wp_color_manager_v1 helper, ported from
//! wayland.zig/example/color_management.zig.
//!
//! Instantiate with ColorManager(@import("color_management")).create(display, .{})
//! to advertise HDR color management to nested clients. The compositor calls
//! surfaceState(client, wl_surface_id) to read the per-surface color state.

const std = @import("std");

const wl = @import("wayland");
const Display = wl.Display;
const Client = wl.server_client.Client;
const Object = wl.Object;
const Global = wl.Global;

/// Composite surface key (client, wl_surface id): object ids are unique only
/// per client, so two hosted clients can pick the same wl_surface id. Key the
/// color side maps by (client, id) to avoid cross-client collision. The
/// *Client pointer is compositor-internal (never leaks onto a neutral type).
const SurfaceKey = @import("../compositor.zig").SurfaceKey;

// Protocol constants (from color-management-v1.xml). Kept here so the runtime
// validation logic does not depend on the generated enum spellings.

/// wp_color_manager_v1.render_intent
pub const RenderIntent = struct {
    pub const perceptual: u32 = 0;
    pub const relative: u32 = 1;
    pub const saturation: u32 = 2;
    pub const absolute: u32 = 3;
    pub const relative_bpc: u32 = 4;
    pub const absolute_no_adaptation: u32 = 5;
};

/// wp_color_manager_v1.feature
pub const Feature = struct {
    pub const icc_v2_v4: u32 = 0;
    pub const parametric: u32 = 1;
    pub const set_primaries: u32 = 2;
    pub const set_tf_power: u32 = 3;
    pub const set_luminances: u32 = 4;
    pub const set_mastering_display_primaries: u32 = 5;
    pub const extended_target_volume: u32 = 6;
    pub const windows_scrgb: u32 = 7;
};

/// wp_color_manager_v1.primaries (named)
pub const Primaries = struct {
    pub const srgb: u32 = 1;
    pub const pal_m: u32 = 2;
    pub const pal: u32 = 3;
    pub const ntsc: u32 = 4;
    pub const generic_film: u32 = 5;
    pub const bt2020: u32 = 6;
    pub const cie1931_xyz: u32 = 7;
    pub const dci_p3: u32 = 8;
    pub const display_p3: u32 = 9;
    pub const adobe_rgb: u32 = 10;
};

/// wp_color_manager_v1.transfer_function (named)
pub const TransferFunction = struct {
    pub const bt1886: u32 = 1;
    pub const gamma22: u32 = 2;
    pub const gamma28: u32 = 3;
    pub const st240: u32 = 4;
    pub const ext_linear: u32 = 5;
    pub const log_100: u32 = 6;
    pub const log_316: u32 = 7;
    pub const xvycc: u32 = 8;
    pub const srgb: u32 = 9;
    pub const ext_srgb: u32 = 10;
    pub const st2084_pq: u32 = 11;
    pub const st428: u32 = 12;
    pub const hlg: u32 = 13;
    pub const compound_power_2_4: u32 = 14;
};

/// wp_color_manager_v1.error
pub const ManagerError = struct {
    pub const unsupported_feature: u32 = 0;
    pub const surface_exists: u32 = 1;
};

/// wp_color_management_surface_v1.error
pub const SurfaceError = struct {
    pub const render_intent: u32 = 0;
    pub const image_description: u32 = 1;
    pub const inert: u32 = 2;
};

/// wp_color_management_surface_feedback_v1.error
pub const FeedbackError = struct {
    pub const inert: u32 = 0;
    pub const unsupported_feature: u32 = 1;
};

/// wp_image_description_creator_params_v1.error
pub const ParamsError = struct {
    pub const incomplete_set: u32 = 0;
    pub const already_set: u32 = 1;
    pub const unsupported_feature: u32 = 2;
    pub const invalid_tf: u32 = 3;
    pub const invalid_primaries_named: u32 = 4;
    pub const invalid_luminance: u32 = 5;
};

/// wp_image_description_creator_icc_v1.error
pub const IccError = struct {
    pub const incomplete_set: u32 = 0;
    pub const already_set: u32 = 1;
    pub const bad_fd: u32 = 2;
    pub const bad_size: u32 = 3;
    pub const out_of_file: u32 = 4;
};

/// wp_image_description_v1.cause (the `failed` reason)
pub const Cause = struct {
    pub const low_version: u32 = 0;
    pub const unsupported: u32 = 1;
    pub const operating_system: u32 = 2;
    pub const no_output: u32 = 3;
};

/// wp_image_description_v1.error
pub const ImageDescError = struct {
    pub const not_ready: u32 = 0;
    pub const no_information: u32 = 1;
};

// Plain-data color description (no protocol object). This is what a compositor
// reads off a surface / output to drive HDR scanout.

/// A parametric image description: the accumulated, validated parameter set.
/// Luminances follow the protocol scaling: min_lum is in cd/m2 * 10000, the
/// other luminances are unscaled cd/m2. Chromaticities are CIE 1931 xy * 1e6.
pub const ImageDescription = struct {
    /// A named transfer function (TransferFunction.*) if set via set_tf_named.
    tf_named: ?u32 = null,
    /// A power-curve exponent (* 10000) if set via set_tf_power.
    tf_power: ?u32 = null,
    /// A named primaries set (Primaries.*) if set via set_primaries_named.
    primaries_named: ?u32 = null,
    /// Explicit primaries (CIE xy * 1e6, order r,g,b,w) if set via set_primaries.
    primaries: ?[8]i32 = null,

    /// Primary color volume luminance range + reference white (set_luminances).
    min_lum: ?u32 = null,
    max_lum: ?u32 = null,
    reference_lum: ?u32 = null,

    /// Mastering display target color volume (set_mastering_display_primaries).
    mastering_primaries: ?[8]i32 = null,
    /// Mastering luminance range (set_mastering_luminance).
    mastering_min_lum: ?u32 = null,
    mastering_max_lum: ?u32 = null,

    max_cll: ?u32 = null,
    max_fall: ?u32 = null,

    /// A monotonically-assigned identity (the `ready2` 64-bit id, low word).
    identity: u64 = 0,

    /// A required parameter set has both a transfer characteristic and primaries.
    pub fn isComplete(self: *const ImageDescription) bool {
        const have_tf = self.tf_named != null or self.tf_power != null;
        const have_prim = self.primaries_named != null or self.primaries != null;
        return have_tf and have_prim;
    }
};

/// CIE 1931 xy chromaticities (* 1e6, order r_x,r_y,g_x,g_y,b_x,b_y,w_x,w_y) for
/// the well-known named primaries, so get_information can report them. Unknown
/// names fall back to the BT.709/sRGB primaries.
pub fn namedPrimariesXy(p: u32) [8]i32 {
    return switch (p) {
        // BT.709 / sRGB primaries, D65 white.
        Primaries.srgb => .{ 640000, 330000, 300000, 600000, 150000, 60000, 312700, 329000 },
        // BT.2020 / BT.2100 primaries, D65 white.
        Primaries.bt2020 => .{ 708000, 292000, 170000, 797000, 131000, 46000, 312700, 329000 },
        // Display P3 primaries, D65 white.
        Primaries.display_p3 => .{ 680000, 320000, 265000, 690000, 150000, 60000, 312700, 329000 },
        // DCI-P3 primaries, DCI white.
        Primaries.dci_p3 => .{ 680000, 320000, 265000, 690000, 150000, 60000, 314000, 351000 },
        else => .{ 640000, 330000, 300000, 600000, 150000, 60000, 312700, 329000 },
    };
}

/// The per-surface color state a compositor reads: the image description plus
/// the rendering intent the client asked for. `null` description means the
/// surface has no explicit color state (handle as sRGB).
pub const SurfaceColorState = struct {
    description: ImageDescription,
    render_intent: u32,
};

pub const Options = struct {
    /// Advertised rendering intents (must include perceptual to conform).
    intents: []const u32 = &default_intents,
    /// Advertised features (parametric is the HDR path; include it).
    features: []const u32 = &default_features,
    /// Advertised named transfer functions (include st2084_pq + hlg for HDR).
    transfer_functions: []const u32 = &default_tfs,
    /// Advertised named primaries (include bt2020 for Rec.2020 HDR).
    primaries: []const u32 = &default_primaries,
    /// The HDR color description an output reports via get_image_description.
    /// Defaults to PQ + Rec.2020, a typical HDR display description.
    output_description: ImageDescription = default_output_description,
};

pub const default_intents = [_]u32{
    RenderIntent.perceptual,
    RenderIntent.relative,
    RenderIntent.saturation,
    RenderIntent.absolute,
    RenderIntent.relative_bpc,
};

pub const default_features = [_]u32{
    Feature.parametric,
    Feature.set_primaries,
    Feature.set_tf_power,
    Feature.set_luminances,
    Feature.set_mastering_display_primaries,
};

pub const default_tfs = [_]u32{
    TransferFunction.bt1886,
    TransferFunction.gamma22,
    TransferFunction.ext_linear,
    TransferFunction.st2084_pq,
    TransferFunction.hlg,
};

pub const default_primaries = [_]u32{
    Primaries.srgb,
    Primaries.display_p3,
    Primaries.bt2020,
};

/// A PQ + Rec.2020 HDR output description (min 0.005, max 10000 nits, ref 203).
/// The target color volume (mastering display) is BT.2020 at 0.005..1000 nits,
/// so get_information delivers a complete parametric info burst.
pub const default_output_description = ImageDescription{
    .tf_named = TransferFunction.st2084_pq,
    .primaries_named = Primaries.bt2020,
    .min_lum = 50, // 0.005 cd/m2 * 10000
    .max_lum = 10000,
    .reference_lum = 203,
    .mastering_primaries = .{ 708000, 292000, 170000, 797000, 131000, 46000, 312700, 329000 },
    .mastering_min_lum = 50, // 0.005 cd/m2 * 10000
    .mastering_max_lum = 1000,
};

/// Build a wp_color_manager_v1 helper over the generated color-management
/// bindings `CM` (the generator output of color-management-v1.xml). `CM` must
/// expose WpColorManagerV1, WpColorManagementOutputV1, WpColorManagementSurfaceV1,
/// WpColorManagementSurfaceFeedbackV1, WpImageDescriptionCreatorParamsV1,
/// WpImageDescriptionCreatorIccV1, WpImageDescriptionV1.
pub fn ColorManager(comptime CM: type) type {
    return struct {
        const Self = @This();

        const Manager = CM.WpColorManagerV1;
        const Output = CM.WpColorManagementOutputV1;
        const Surface = CM.WpColorManagementSurfaceV1;
        const Feedback = CM.WpColorManagementSurfaceFeedbackV1;
        const Params = CM.WpImageDescriptionCreatorParamsV1;
        const Icc = CM.WpImageDescriptionCreatorIccV1;
        const ImageDesc = CM.WpImageDescriptionV1;
        const Info = CM.WpImageDescriptionInfoV1;

        /// A pending parametric description being accumulated by a creator
        /// resource. Lives in the creator resource's user_data.
        const Creator = struct {
            self: *Self,
            desc: ImageDescription = .{},

            fn isSupported(creator: *Creator, feature: u32) bool {
                for (creator.self.options.features) |f| {
                    if (f == feature) return true;
                }
                return false;
            }
        };

        /// The per-image-description record stored in a wp_image_description_v1
        /// resource's user_data (the compositor can read it back).
        const Record = struct {
            self: *Self,
            desc: ImageDescription,
            ready: bool,
            /// Whether get_information is allowed (true for output/preferred
            /// descriptions, false for client-created parametric ones).
            allow_information: bool,
        };

        /// Per color-management-surface context: which wl_surface it manages,
        /// stored as the surface resource's user_data so set/unset/destroy can
        /// key the side maps. Allocated per get_surface, freed on destroy.
        const SurfaceCtx = struct {
            self: *Self,
            /// The target wl_surface's owning client + object id. Both are needed
            /// to rebuild the composite SurfaceKey in set/unset/destroy, since
            /// the id alone collides across clients.
            surface_client: *Client,
            surface_id: u32,

            fn key(ctx: *const SurfaceCtx) SurfaceKey {
                return .{ .client = ctx.surface_client, .id = ctx.surface_id };
            }
        };

        display: *Display,
        /// Cached independently of `display`: a compositor may destroy the
        /// Display (which frees the Display struct) before freeing this helper,
        /// so deinit must not reach the allocator through `display`.
        allocator: std.mem.Allocator,
        global: *Global,
        options: Options,

        manager_impl: Manager.Implementation,
        output_impl: Output.Implementation,
        surface_impl: Surface.Implementation,
        feedback_impl: Feedback.Implementation,
        params_impl: Params.Implementation,
        icc_impl: Icc.Implementation,
        image_desc_impl: ImageDesc.Implementation,
        image_desc_info_impl: Info.Implementation,

        /// Side map: wl_surface object id -> the client's chosen color state.
        /// A compositor consults this when compositing a surface.
        surface_states: std.AutoHashMapUnmanaged(SurfaceKey, SurfaceColorState) = .empty,
        /// Set of (client, wl_surface id) that already have a color-management
        /// surface (so a second get_surface raises surface_exists).
        managed_surfaces: std.AutoHashMapUnmanaged(SurfaceKey, void) = .empty,

        /// Next image-description identity (never recycled, never zero).
        next_identity: u64 = 1,

        pub fn create(display: *Display, options: Options) !*Self {
            const self = try display.allocator.create(Self);
            errdefer display.allocator.destroy(self);
            self.* = .{
                .display = display,
                .allocator = display.allocator,
                .global = undefined,
                .options = options,
                .manager_impl = .{
                    .destroy = onManagerDestroy,
                    .get_output = onGetOutput,
                    .get_surface = onGetSurface,
                    .get_surface_feedback = onGetSurfaceFeedback,
                    .create_icc_creator = onCreateIccCreator,
                    .create_parametric_creator = onCreateParametricCreator,
                    .create_windows_scrgb = onCreateWindowsScrgb,
                    .get_image_description = onManagerGetImageDescription,
                },
                .output_impl = .{
                    .destroy = onResourceDestroy,
                    .get_image_description = onOutputGetImageDescription,
                },
                .surface_impl = .{
                    .destroy = onSurfaceDestroy,
                    .set_image_description = onSetImageDescription,
                    .unset_image_description = onUnsetImageDescription,
                },
                .feedback_impl = .{
                    .destroy = onResourceDestroy,
                    .get_preferred = onGetPreferred,
                    .get_preferred_parametric = onGetPreferredParametric,
                },
                .params_impl = .{
                    .create = onParamsCreate,
                    .set_tf_named = onSetTfNamed,
                    .set_tf_power = onSetTfPower,
                    .set_primaries_named = onSetPrimariesNamed,
                    .set_primaries = onSetPrimaries,
                    .set_luminances = onSetLuminances,
                    .set_mastering_display_primaries = onSetMasteringPrimaries,
                    .set_mastering_luminance = onSetMasteringLuminance,
                    .set_max_cll = onSetMaxCll,
                    .set_max_fall = onSetMaxFall,
                },
                .icc_impl = .{
                    .create = onIccCreate,
                    .set_icc_file = onSetIccFile,
                },
                .image_desc_impl = .{
                    .destroy = onResourceDestroy,
                    .get_information = onGetInformation,
                },
                .image_desc_info_impl = .{},
            };
            self.global = try display.globalCreate(
                &Manager.interface,
                Manager.version,
                bindManager,
                self,
            );
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.surface_states.deinit(self.allocator);
            self.managed_surfaces.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// Read the color state a client set on a surface (by wl_surface id), or
        /// null if the surface has none. The compositor's scanout path uses this.
        pub fn surfaceState(self: *Self, client: *Client, surface_id: u32) ?SurfaceColorState {
            return self.surface_states.get(.{ .client = client, .id = surface_id });
        }

        fn isFeature(self: *Self, feature: u32) bool {
            for (self.options.features) |f| {
                if (f == feature) return true;
            }
            return false;
        }

        fn isIntent(self: *Self, intent: u32) bool {
            for (self.options.intents) |i| {
                if (i == intent) return true;
            }
            return false;
        }

        fn isTfNamed(self: *Self, tf: u32) bool {
            for (self.options.transfer_functions) |t| {
                if (t == tf) return true;
            }
            return false;
        }

        fn isPrimariesNamed(self: *Self, primaries: u32) bool {
            for (self.options.primaries) |p| {
                if (p == primaries) return true;
            }
            return false;
        }

        /// Bind: create the resource, attach the implementation, and immediately
        /// advertise every supported intent/feature/tf/primaries, then done.
        fn bindManager(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
            const self: *Self = @ptrCast(@alignCast(data.?));
            const resource = Object.create(client, &Manager.interface, version, id) catch return;
            Manager.setImplementation(resource, &self.manager_impl, self, null);
            for (self.options.intents) |intent| Manager.sendSupportedIntent(resource, intent);
            for (self.options.features) |feature| Manager.sendSupportedFeature(resource, feature);
            for (self.options.transfer_functions) |tf| Manager.sendSupportedTfNamed(resource, tf);
            for (self.options.primaries) |p| Manager.sendSupportedPrimariesNamed(resource, p);
            Manager.sendDone(resource);
        }

        fn onManagerDestroy(client_data: ?*anyopaque, resource: *Object) void {
            _ = client_data;
            resource.destroy();
        }

        fn onGetOutput(client_data: ?*anyopaque, resource: *Object, id: u32, output: *Object) void {
            _ = output;
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            const out_res = Object.create(resource.client, &Output.interface, resource.version, id) catch return;
            Output.setImplementation(out_res, &self.output_impl, self, null);
        }

        fn onGetSurface(client_data: ?*anyopaque, resource: *Object, id: u32, surface: *Object) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            // A second color-management surface for the same wl_surface is a
            // surface_exists protocol error.
            const surf_key = SurfaceKey{ .client = surface.client, .id = surface.id };
            if (self.managed_surfaces.contains(surf_key)) {
                resource.postError(ManagerError.surface_exists, "wl_surface {d} already has a color-management surface", .{surface.id});
                return;
            }
            self.managed_surfaces.put(self.allocator, surf_key, {}) catch return;
            // If any later step fails, the surf_key would otherwise be stranded
            // in managed_surfaces with no SurfaceCtx to remove it - reporting a
            // phantom surface_exists forever. Each failing catch below removes it.
            const ctx = self.allocator.create(SurfaceCtx) catch {
                _ = self.managed_surfaces.remove(surf_key);
                return;
            };
            ctx.* = .{ .self = self, .surface_client = surface.client, .surface_id = surface.id };
            const surf_res = Object.create(resource.client, &Surface.interface, resource.version, id) catch {
                _ = self.managed_surfaces.remove(surf_key);
                self.allocator.destroy(ctx);
                return;
            };
            // The surface resource's user_data IS the context (holds *Self + the
            // wl_surface id), so set/unset/destroy can reach both.
            Surface.setImplementation(surf_res, &self.surface_impl, ctx, surfaceResourceDestroyed);
        }

        fn onGetSurfaceFeedback(client_data: ?*anyopaque, resource: *Object, id: u32, surface: *Object) void {
            _ = surface;
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            const fb_res = Object.create(resource.client, &Feedback.interface, resource.version, id) catch return;
            Feedback.setImplementation(fb_res, &self.feedback_impl, self, null);
        }

        fn onCreateIccCreator(client_data: ?*anyopaque, resource: *Object, obj: u32) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            if (!self.isFeature(Feature.icc_v2_v4)) {
                resource.postError(ManagerError.unsupported_feature, "ICC image descriptions are not supported", .{});
                return;
            }
            const icc_res = Object.create(resource.client, &Icc.interface, resource.version, obj) catch return;
            Icc.setImplementation(icc_res, &self.icc_impl, self, null);
        }

        fn onCreateParametricCreator(client_data: ?*anyopaque, resource: *Object, obj: u32) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            if (!self.isFeature(Feature.parametric)) {
                resource.postError(ManagerError.unsupported_feature, "parametric image descriptions are not supported", .{});
                return;
            }
            const creator = self.allocator.create(Creator) catch return;
            creator.* = .{ .self = self };
            const params_res = Object.create(resource.client, &Params.interface, resource.version, obj) catch {
                self.allocator.destroy(creator);
                return;
            };
            Params.setImplementation(params_res, &self.params_impl, creator, creatorResourceDestroyed);
        }

        fn onCreateWindowsScrgb(client_data: ?*anyopaque, resource: *Object, image_description: u32) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            if (!self.isFeature(Feature.windows_scrgb)) {
                resource.postError(ManagerError.unsupported_feature, "windows-scrgb is not supported", .{});
                return;
            }
            // Windows-scRGB: BT.709 primaries, extended-linear TF.
            const desc = ImageDescription{
                .tf_named = TransferFunction.ext_linear,
                .primaries_named = Primaries.srgb,
            };
            _ = self.createReadyImageDescription(resource.client, resource.version, image_description, desc, false);
        }

        fn onManagerGetImageDescription(client_data: ?*anyopaque, resource: *Object, image_description: u32, reference: *Object) void {
            _ = reference;
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            // No reference objects are created in this implementation, so just
            // hand back a ready description with the output's parameters.
            _ = self.createReadyImageDescription(resource.client, resource.version, image_description, self.options.output_description, true);
        }

        fn onOutputGetImageDescription(client_data: ?*anyopaque, resource: *Object, image_description: u32) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            _ = self.createReadyImageDescription(resource.client, resource.version, image_description, self.options.output_description, true);
        }

        fn onSurfaceDestroy(client_data: ?*anyopaque, resource: *Object) void {
            _ = client_data;
            // Destroying the surface object also does unset (handled by the
            // resource-destroyed hook clearing the map entry).
            resource.destroy();
        }

        fn onSetImageDescription(client_data: ?*anyopaque, resource: *Object, image_description: *Object, render_intent: u32) void {
            const ctx: *SurfaceCtx = @ptrCast(@alignCast(client_data.?));
            const self = ctx.self;

            // The render intent must be one we advertised.
            if (!self.isIntent(render_intent)) {
                resource.postError(SurfaceError.render_intent, "render intent {d} not advertised", .{render_intent});
                return;
            }

            // The image description must be a ready record we created.
            const record: *Record = @ptrCast(@alignCast(image_description.user_data orelse {
                resource.postError(SurfaceError.image_description, "unknown image description", .{});
                return;
            }));
            if (!record.ready) {
                resource.postError(SurfaceError.image_description, "image description is not ready", .{});
                return;
            }

            // Set has copy semantics: store a copy of the parameters.
            self.surface_states.put(self.allocator, ctx.key(), .{
                .description = record.desc,
                .render_intent = render_intent,
            }) catch {};
        }

        fn onUnsetImageDescription(client_data: ?*anyopaque, resource: *Object) void {
            _ = resource;
            const ctx: *SurfaceCtx = @ptrCast(@alignCast(client_data.?));
            _ = ctx.self.surface_states.remove(ctx.key());
        }

        fn surfaceResourceDestroyed(resource: *Object) void {
            const ctx: *SurfaceCtx = @ptrCast(@alignCast(resource.user_data.?));
            const self = ctx.self;
            const surf_key = ctx.key();
            // Destroying the surface object also does unset.
            _ = self.surface_states.remove(surf_key);
            _ = self.managed_surfaces.remove(surf_key);
            self.allocator.destroy(ctx);
        }

        fn onGetPreferred(client_data: ?*anyopaque, resource: *Object, image_description: u32) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            _ = self.createReadyImageDescription(resource.client, resource.version, image_description, self.options.output_description, true);
        }

        fn onGetPreferredParametric(client_data: ?*anyopaque, resource: *Object, image_description: u32) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            if (!self.isFeature(Feature.parametric)) {
                resource.postError(FeedbackError.unsupported_feature, "parametric image descriptions are not supported", .{});
                return;
            }
            _ = self.createReadyImageDescription(resource.client, resource.version, image_description, self.options.output_description, true);
        }

        fn onSetTfNamed(client_data: ?*anyopaque, resource: *Object, tf: u32) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            if (creator.desc.tf_named != null or creator.desc.tf_power != null) {
                resource.postError(ParamsError.already_set, "transfer characteristic already set", .{});
                return;
            }
            if (!creator.self.isTfNamed(tf)) {
                resource.postError(ParamsError.invalid_tf, "transfer function {d} not advertised", .{tf});
                return;
            }
            creator.desc.tf_named = tf;
        }

        fn onSetTfPower(client_data: ?*anyopaque, resource: *Object, eexp: u32) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            if (!creator.isSupported(Feature.set_tf_power)) {
                resource.postError(ParamsError.unsupported_feature, "set_tf_power is not supported", .{});
                return;
            }
            if (creator.desc.tf_named != null or creator.desc.tf_power != null) {
                resource.postError(ParamsError.already_set, "transfer characteristic already set", .{});
                return;
            }
            // The exponent (* 10000) must be within [1.0, 10.0].
            if (eexp < 10000 or eexp > 100000) {
                resource.postError(ParamsError.invalid_tf, "tf power exponent out of range", .{});
                return;
            }
            creator.desc.tf_power = eexp;
        }

        fn onSetPrimariesNamed(client_data: ?*anyopaque, resource: *Object, primaries: u32) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            if (creator.desc.primaries_named != null or creator.desc.primaries != null) {
                resource.postError(ParamsError.already_set, "primaries already set", .{});
                return;
            }
            if (!creator.self.isPrimariesNamed(primaries)) {
                resource.postError(ParamsError.invalid_primaries_named, "primaries {d} not advertised", .{primaries});
                return;
            }
            creator.desc.primaries_named = primaries;
        }

        fn onSetPrimaries(
            client_data: ?*anyopaque,
            resource: *Object,
            r_x: i32,
            r_y: i32,
            g_x: i32,
            g_y: i32,
            b_x: i32,
            b_y: i32,
            w_x: i32,
            w_y: i32,
        ) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            if (!creator.isSupported(Feature.set_primaries)) {
                resource.postError(ParamsError.unsupported_feature, "set_primaries is not supported", .{});
                return;
            }
            if (creator.desc.primaries_named != null or creator.desc.primaries != null) {
                resource.postError(ParamsError.already_set, "primaries already set", .{});
                return;
            }
            creator.desc.primaries = .{ r_x, r_y, g_x, g_y, b_x, b_y, w_x, w_y };
        }

        fn onSetLuminances(client_data: ?*anyopaque, resource: *Object, min_lum: u32, max_lum: u32, reference_lum: u32) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            if (!creator.isSupported(Feature.set_luminances)) {
                resource.postError(ParamsError.unsupported_feature, "set_luminances is not supported", .{});
                return;
            }
            if (creator.desc.min_lum != null) {
                resource.postError(ParamsError.already_set, "luminances already set", .{});
                return;
            }
            // min_lum is scaled by 10000; max_lum and reference_lum are unscaled.
            // max_lum and reference_lum must exceed min_lum (in the same units).
            const min_unscaled_x10000 = min_lum; // cd/m2 * 10000
            const max_x10000 = @as(u64, max_lum) * 10000;
            const ref_x10000 = @as(u64, reference_lum) * 10000;
            if (max_x10000 <= min_unscaled_x10000 or ref_x10000 <= min_unscaled_x10000) {
                resource.postError(ParamsError.invalid_luminance, "max/reference luminance must exceed min", .{});
                return;
            }
            creator.desc.min_lum = min_lum;
            creator.desc.max_lum = max_lum;
            creator.desc.reference_lum = reference_lum;
        }

        fn onSetMasteringPrimaries(
            client_data: ?*anyopaque,
            resource: *Object,
            r_x: i32,
            r_y: i32,
            g_x: i32,
            g_y: i32,
            b_x: i32,
            b_y: i32,
            w_x: i32,
            w_y: i32,
        ) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            if (!creator.isSupported(Feature.set_mastering_display_primaries)) {
                resource.postError(ParamsError.unsupported_feature, "set_mastering_display_primaries is not supported", .{});
                return;
            }
            if (creator.desc.mastering_primaries != null) {
                resource.postError(ParamsError.already_set, "mastering primaries already set", .{});
                return;
            }
            creator.desc.mastering_primaries = .{ r_x, r_y, g_x, g_y, b_x, b_y, w_x, w_y };
        }

        fn onSetMasteringLuminance(client_data: ?*anyopaque, resource: *Object, min_lum: u32, max_lum: u32) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            if (!creator.isSupported(Feature.set_mastering_display_primaries)) {
                resource.postError(ParamsError.unsupported_feature, "set_mastering_luminance is not supported", .{});
                return;
            }
            if (creator.desc.mastering_min_lum != null) {
                resource.postError(ParamsError.already_set, "mastering luminance already set", .{});
                return;
            }
            // min_lum is scaled by 10000; max_lum is unscaled. max must exceed min.
            const max_x10000 = @as(u64, max_lum) * 10000;
            if (max_x10000 <= min_lum) {
                resource.postError(ParamsError.invalid_luminance, "mastering max must exceed min", .{});
                return;
            }
            creator.desc.mastering_min_lum = min_lum;
            creator.desc.mastering_max_lum = max_lum;
        }

        fn onSetMaxCll(client_data: ?*anyopaque, resource: *Object, max_cll: u32) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            creator.desc.max_cll = max_cll;
        }

        fn onSetMaxFall(client_data: ?*anyopaque, resource: *Object, max_fall: u32) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            creator.desc.max_fall = max_fall;
        }

        /// wp_image_description_creator_params_v1.create (destructor): validate
        /// the accumulated set, create the image description, post ready/failed,
        /// and destroy the creator.
        fn onParamsCreate(client_data: ?*anyopaque, resource: *Object, image_description: u32) void {
            _ = client_data;
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            const self = creator.self;
            const desc = creator.desc;

            // An incomplete parameter set is a protocol error (not a failed
            // event): a complete set requires a transfer function and primaries.
            if (!desc.isComplete()) {
                resource.postError(ParamsError.incomplete_set, "image description parameter set is incomplete", .{});
                return;
            }
            // max_fall must be <= max_cll when both are set.
            if (desc.max_cll != null and desc.max_fall != null and desc.max_fall.? > desc.max_cll.?) {
                resource.postError(ParamsError.invalid_luminance, "max_fall exceeds max_cll", .{});
                return;
            }

            const ready = self.createReadyImageDescription(resource.client, resource.version, image_description, desc, false);
            _ = ready;
            // create() is a destructor for the creator resource.
            resource.destroy();
        }

        fn onSetIccFile(client_data: ?*anyopaque, resource: *Object, icc_profile: i32, offset: u32, length: u32) void {
            _ = client_data;
            _ = resource;
            _ = offset;
            _ = length;
            // We accept and ignore the fd. Close it so we do not leak the
            // descriptor (the client passed ownership over SCM_RIGHTS).
            if (icc_profile >= 0) {
                _ = std.os.linux.close(icc_profile);
            }
        }

        fn onIccCreate(client_data: ?*anyopaque, resource: *Object, image_description: u32) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            // ICC is not really supported: create the image description object
            // and immediately post `failed` with the unsupported cause.
            const img = Object.create(resource.client, &ImageDesc.interface, resource.version, image_description) catch {
                resource.destroy();
                return;
            };
            ImageDesc.setImplementation(img, &self.image_desc_impl, null, null);
            ImageDesc.sendFailed(img, Cause.unsupported, "ICC image descriptions are not supported");
            resource.destroy();
        }

        fn onGetInformation(client_data: ?*anyopaque, resource: *Object, information: u32) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            const record: *Record = @ptrCast(@alignCast(resource.user_data orelse {
                resource.postError(ImageDescError.no_information, "no information available", .{});
                return;
            }));
            if (!record.allow_information) {
                resource.postError(ImageDescError.no_information, "get_information is not allowed on this image description", .{});
                return;
            }
            // Create the info object, deliver every matching event once, then
            // done (which auto-destroys the info object per the protocol).
            const info = Object.create(resource.client, &Info.interface, resource.version, information) catch return;
            Info.setImplementation(info, &self.image_desc_info_impl, null, null);
            emitInformation(info, &record.desc);
            Info.sendDone(info);
            info.destroy();
        }

        /// Emit the wp_image_description_info_v1 events that describe `desc`:
        /// primaries (named + chromaticities), the transfer function, the
        /// luminance range, and the target color volume.
        fn emitInformation(info: *Object, desc: *const ImageDescription) void {
            // Primaries: named (if any) + explicit chromaticities.
            if (desc.primaries_named) |p| {
                Info.sendPrimariesNamed(info, p);
                const xy = namedPrimariesXy(p);
                Info.sendPrimaries(info, xy[0], xy[1], xy[2], xy[3], xy[4], xy[5], xy[6], xy[7]);
            } else if (desc.primaries) |xy| {
                Info.sendPrimaries(info, xy[0], xy[1], xy[2], xy[3], xy[4], xy[5], xy[6], xy[7]);
            }

            // Transfer function: named or power.
            if (desc.tf_named) |tf| {
                Info.sendTfNamed(info, tf);
            } else if (desc.tf_power) |eexp| {
                Info.sendTfPower(info, eexp);
            }

            // Primary color volume luminances (min is * 10000).
            if (desc.min_lum) |min| {
                Info.sendLuminances(info, min, desc.max_lum orelse 0, desc.reference_lum orelse 0);
            }

            // Target color volume (mastering display).
            if (desc.mastering_primaries) |xy| {
                Info.sendTargetPrimaries(info, xy[0], xy[1], xy[2], xy[3], xy[4], xy[5], xy[6], xy[7]);
            }
            if (desc.mastering_min_lum) |min| {
                Info.sendTargetLuminance(info, min, desc.mastering_max_lum orelse 0);
            }
            if (desc.max_cll) |v| Info.sendTargetMaxCll(info, v);
            if (desc.max_fall) |v| Info.sendTargetMaxFall(info, v);
        }

        /// Create a wp_image_description_v1 resource carrying `desc`, install the
        /// implementation, and immediately post `ready` (ready2 on v2+). Returns
        /// the resource, or null on allocation failure.
        fn createReadyImageDescription(
            self: *Self,
            client: *Client,
            version: u32,
            id: u32,
            desc: ImageDescription,
            allow_information: bool,
        ) ?*Object {
            const record = self.allocator.create(Record) catch return null;
            var d = desc;
            d.identity = self.next_identity;
            self.next_identity += 1;
            record.* = .{ .self = self, .desc = d, .ready = true, .allow_information = allow_information };

            const img = Object.create(client, &ImageDesc.interface, version, id) catch {
                self.allocator.destroy(record);
                return null;
            };
            ImageDesc.setImplementation(img, &self.image_desc_impl, record, imageDescResourceDestroyed);

            // ready2 (since v2) carries the 64-bit identity; ready (v1) carries a
            // 32-bit identity. Send the right one for the bound version.
            if (version >= 2) {
                const id_hi: u32 = @truncate(d.identity >> 32);
                const id_lo: u32 = @truncate(d.identity);
                ImageDesc.sendReady2(img, id_hi, id_lo);
            } else {
                ImageDesc.sendReady(img, @truncate(d.identity));
            }
            return img;
        }

        fn onResourceDestroy(client_data: ?*anyopaque, resource: *Object) void {
            _ = client_data;
            resource.destroy();
        }

        fn creatorResourceDestroyed(resource: *Object) void {
            const creator: *Creator = @ptrCast(@alignCast(resource.user_data.?));
            creator.self.allocator.destroy(creator);
        }

        fn imageDescResourceDestroyed(resource: *Object) void {
            if (resource.user_data) |ud| {
                const record: *Record = @ptrCast(@alignCast(ud));
                record.self.allocator.destroy(record);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Neutral color mapping
// ---------------------------------------------------------------------------

const color = @import("../color.zig");

/// Map a SurfaceColorState (from wp_color_management) to the neutral ColorConfig.
///
/// Transfer function mapping (named tf constant -> neutral TransferFunction):
///   st2084_pq (11) -> .st2084_pq
///   hlg (13)       -> .hlg
///   srgb (9)       -> .srgb
///   else           -> .srgb (safe fallback)
///
/// Primaries mapping (named primaries constant -> neutral Colorspace):
///   bt2020 (6)     -> .bt2020
///   display_p3 (9) -> .display_p3
///   srgb (1)       -> .srgb
///   else           -> .srgb (safe fallback)
///
/// Luminance mapping (protocol scaling per color-management-v1 spec):
///   min_lum is cd/m2 * 10000  -> divide by 10000.0 to get nits
///   max_lum is unscaled cd/m2 -> use directly as nits
///   max_cll / max_fall are unscaled cd/m2 -> use directly (0 if absent)
///
/// format is always .xrgb8888 (signaling does not change the buffer format).
pub fn colorStateToConfig(st: SurfaceColorState) color.ColorConfig {
    const tf: color.TransferFunction = if (st.description.tf_named) |tf_named| switch (tf_named) {
        TransferFunction.st2084_pq => .st2084_pq,
        TransferFunction.hlg => .hlg,
        TransferFunction.srgb => .srgb,
        else => .srgb,
    } else .srgb;

    const cs: color.Colorspace = if (st.description.primaries_named) |p| switch (p) {
        Primaries.bt2020 => .bt2020,
        Primaries.display_p3 => .display_p3,
        else => .srgb,
    } else .srgb;

    const lum: ?color.Luminance = if (st.description.min_lum != null and st.description.max_lum != null) blk: {
        const min_nits: f32 = @as(f32, @floatFromInt(st.description.min_lum.?)) / 10000.0;
        const max_nits: f32 = @as(f32, @floatFromInt(st.description.max_lum.?));
        const max_cll: f32 = if (st.description.max_cll) |v| @as(f32, @floatFromInt(v)) else 0.0;
        const max_fall: f32 = if (st.description.max_fall) |v| @as(f32, @floatFromInt(v)) else 0.0;
        break :blk .{
            .min_nits = min_nits,
            .max_nits = max_nits,
            .max_cll = max_cll,
            .max_fall = max_fall,
        };
    } else null;

    return .{
        .format = .xrgb8888,
        .colorspace = cs,
        .transfer = tf,
        .luminance = lum,
    };
}

// ---------------------------------------------------------------------------
// Unit tests (pure, no Wayland runtime needed)
// ---------------------------------------------------------------------------

test "ImageDescription.isComplete: tf + primaries -> true" {
    const testing = std.testing;
    const desc = ImageDescription{
        .tf_named = TransferFunction.st2084_pq,
        .primaries_named = Primaries.bt2020,
    };
    try testing.expect(desc.isComplete());
}

test "ImageDescription.isComplete: tf only -> false" {
    const testing = std.testing;
    const desc = ImageDescription{
        .tf_named = TransferFunction.hlg,
    };
    try testing.expect(!desc.isComplete());
}

test "ImageDescription.isComplete: primaries only -> false" {
    const testing = std.testing;
    const desc = ImageDescription{
        .primaries_named = Primaries.srgb,
    };
    try testing.expect(!desc.isComplete());
}

test "ImageDescription.isComplete: empty -> false" {
    const testing = std.testing;
    const desc = ImageDescription{};
    try testing.expect(!desc.isComplete());
}

test "ImageDescription.isComplete: tf_power + primaries -> true" {
    const testing = std.testing;
    const desc = ImageDescription{
        .tf_power = 22000,
        .primaries_named = Primaries.srgb,
    };
    try testing.expect(desc.isComplete());
}

test "ImageDescription.isComplete: tf_named + explicit primaries -> true" {
    const testing = std.testing;
    const desc = ImageDescription{
        .tf_named = TransferFunction.srgb,
        .primaries = .{ 640000, 330000, 300000, 600000, 150000, 60000, 312700, 329000 },
    };
    try testing.expect(desc.isComplete());
}

test "namedPrimariesXy: srgb returns BT.709 chromaticities" {
    const testing = std.testing;
    const xy = namedPrimariesXy(Primaries.srgb);
    try testing.expectEqual(@as(i32, 640000), xy[0]); // r_x
    try testing.expectEqual(@as(i32, 312700), xy[6]); // w_x
}

test "namedPrimariesXy: bt2020 returns Rec.2020 chromaticities" {
    const testing = std.testing;
    const xy = namedPrimariesXy(Primaries.bt2020);
    try testing.expectEqual(@as(i32, 708000), xy[0]); // r_x
    try testing.expectEqual(@as(i32, 170000), xy[2]); // g_x
}

test "namedPrimariesXy: unknown falls back to sRGB" {
    const testing = std.testing;
    const xy_unknown = namedPrimariesXy(99);
    const xy_srgb = namedPrimariesXy(Primaries.srgb);
    try testing.expectEqualSlices(i32, &xy_srgb, &xy_unknown);
}

test "luminance scaling: max_x10000 comparison logic" {
    // Verify the luminance scaling logic used in onSetLuminances.
    // min_lum=50 (0.005 cd/m2 * 10000), max_lum=1000 (unscaled), ref=203.
    const testing = std.testing;
    const min_lum: u32 = 50;
    const max_lum: u32 = 1000;
    const reference_lum: u32 = 203;
    const min_unscaled_x10000 = min_lum;
    const max_x10000 = @as(u64, max_lum) * 10000;
    const ref_x10000 = @as(u64, reference_lum) * 10000;
    // max (10000000) > min (50) and ref (2030000) > min (50): valid set.
    try testing.expect(max_x10000 > min_unscaled_x10000);
    try testing.expect(ref_x10000 > min_unscaled_x10000);
}

test "colorStateToConfig: PQ + bt2020 + luminances -> HDR ColorConfig" {
    const testing = std.testing;
    // min_lum=50 means 0.005 nits (50/10000), max_lum=1000 nits, max_cll=1000, max_fall=400.
    const st = SurfaceColorState{
        .description = .{
            .tf_named = TransferFunction.st2084_pq,
            .primaries_named = Primaries.bt2020,
            .min_lum = 50,
            .max_lum = 1000,
            .reference_lum = 203,
            .max_cll = 1000,
            .max_fall = 400,
        },
        .render_intent = RenderIntent.perceptual,
    };
    const cfg = colorStateToConfig(st);
    try testing.expectEqual(color.TransferFunction.st2084_pq, cfg.transfer);
    try testing.expectEqual(color.Colorspace.bt2020, cfg.colorspace);
    try testing.expectEqual(color.PixelFormat.xrgb8888, cfg.format);
    try testing.expect(cfg.luminance != null);
    try testing.expectApproxEqAbs(@as(f32, 0.005), cfg.luminance.?.min_nits, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1000.0), cfg.luminance.?.max_nits, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1000.0), cfg.luminance.?.max_cll, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 400.0), cfg.luminance.?.max_fall, 1e-4);
    try testing.expect(cfg.isHdr());
}

test "colorStateToConfig: SDR (no tf, no primaries, no luminances) -> isHdr false" {
    const testing = std.testing;
    const st = SurfaceColorState{
        .description = .{},
        .render_intent = RenderIntent.perceptual,
    };
    const cfg = colorStateToConfig(st);
    try testing.expectEqual(color.TransferFunction.srgb, cfg.transfer);
    try testing.expectEqual(color.Colorspace.srgb, cfg.colorspace);
    try testing.expect(cfg.luminance == null);
    try testing.expect(!cfg.isHdr());
}

test "colorStateToConfig: HLG + bt2020 -> hlg transfer" {
    const testing = std.testing;
    const st = SurfaceColorState{
        .description = .{
            .tf_named = TransferFunction.hlg,
            .primaries_named = Primaries.bt2020,
        },
        .render_intent = RenderIntent.perceptual,
    };
    const cfg = colorStateToConfig(st);
    try testing.expectEqual(color.TransferFunction.hlg, cfg.transfer);
    try testing.expectEqual(color.Colorspace.bt2020, cfg.colorspace);
    try testing.expect(cfg.isHdr());
}

test "surface_states keyed by (client, id): same id distinct clients stay distinct" {
    const testing = std.testing;
    // Sentinel *Client pointers: the maps only key on the pointer bits and never
    // dereference, so aligned @ptrFromInt values are safe stand-ins.
    const client_a: *Client = @ptrFromInt(0x1000);
    const client_b: *Client = @ptrFromInt(0x2000);
    const id: u32 = 1;

    var surface_states: std.AutoHashMapUnmanaged(SurfaceKey, SurfaceColorState) = .empty;
    defer surface_states.deinit(testing.allocator);

    const state_a = SurfaceColorState{
        .description = .{ .tf_named = TransferFunction.st2084_pq, .primaries_named = Primaries.bt2020 },
        .render_intent = RenderIntent.perceptual,
    };
    const state_b = SurfaceColorState{
        .description = .{ .tf_named = TransferFunction.hlg, .primaries_named = Primaries.display_p3 },
        .render_intent = RenderIntent.relative,
    };
    try surface_states.put(testing.allocator, .{ .client = client_a, .id = id }, state_a);
    try surface_states.put(testing.allocator, .{ .client = client_b, .id = id }, state_b);

    // Same wl_surface id, two distinct clients -> two DISTINCT states.
    try testing.expectEqual(@as(usize, 2), surface_states.count());
    const got_a = surface_states.get(.{ .client = client_a, .id = id }).?;
    const got_b = surface_states.get(.{ .client = client_b, .id = id }).?;
    try testing.expectEqual(TransferFunction.st2084_pq, got_a.description.tf_named.?);
    try testing.expectEqual(TransferFunction.hlg, got_b.description.tf_named.?);
    try testing.expectEqual(RenderIntent.perceptual, got_a.render_intent);
    try testing.expectEqual(RenderIntent.relative, got_b.render_intent);
}

test "managed_surfaces keyed by (client, id): second client not seen as already-managed" {
    const testing = std.testing;
    const client_a: *Client = @ptrFromInt(0x1000);
    const client_b: *Client = @ptrFromInt(0x2000);

    var managed_surfaces: std.AutoHashMapUnmanaged(SurfaceKey, void) = .empty;
    defer managed_surfaces.deinit(testing.allocator);

    // Client A registers wl_surface id=1.
    try managed_surfaces.put(testing.allocator, .{ .client = client_a, .id = 1 }, {});

    // Client B at the SAME id=1 must NOT be seen as already-managed.
    try testing.expect(!managed_surfaces.contains(.{ .client = client_b, .id = 1 }));
    // Client A at id=1 IS already-managed (would raise surface_exists).
    try testing.expect(managed_surfaces.contains(.{ .client = client_a, .id = 1 }));

    // Client B can register its own id=2 (and even its own id=1) without collision.
    try managed_surfaces.put(testing.allocator, .{ .client = client_b, .id = 2 }, {});
    try managed_surfaces.put(testing.allocator, .{ .client = client_b, .id = 1 }, {});
    try testing.expectEqual(@as(usize, 3), managed_surfaces.count());

    // Removing client A's id=1 leaves client B's entries intact.
    _ = managed_surfaces.remove(.{ .client = client_a, .id = 1 });
    try testing.expect(!managed_surfaces.contains(.{ .client = client_a, .id = 1 }));
    try testing.expect(managed_surfaces.contains(.{ .client = client_b, .id = 1 }));
    try testing.expect(managed_surfaces.contains(.{ .client = client_b, .id = 2 }));
}

test "colorStateToConfig: sRGB tf + sRGB primaries -> sdr" {
    const testing = std.testing;
    const st = SurfaceColorState{
        .description = .{
            .tf_named = TransferFunction.srgb,
            .primaries_named = Primaries.srgb,
        },
        .render_intent = RenderIntent.perceptual,
    };
    const cfg = colorStateToConfig(st);
    try testing.expectEqual(color.TransferFunction.srgb, cfg.transfer);
    try testing.expectEqual(color.Colorspace.srgb, cfg.colorspace);
    try testing.expect(!cfg.isHdr());
}
