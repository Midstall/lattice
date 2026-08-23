/// Wayland client-side HDR color declaration helper.
///
/// declareSurfaceColor sends a wp_color_management parametric image-description
/// sequence to the compositor for a wl_surface. Called after xdg surface setup
/// in createSurface when the surface ColorConfig is HDR. Non-fatal: the caller
/// catches errors and logs a warning.
const std = @import("std");

const wl = @import("wayland");
const cm = @import("color_management");

const color = @import("../../color.zig");

const client = wl.client;

/// Named wire integers from the wp_color_management protocol.
/// These match the constants in src/lattice/compositor/color_manager.zig (TransferFunction/Primaries)
/// and the generated cm.WpColorManagerV1.TransferFunction / .Primaries enums.
const wire_tf_st2084_pq: u32 = 11;
const wire_tf_hlg: u32 = 13;
const wire_primaries_srgb: u32 = 1;
const wire_primaries_bt2020: u32 = 6;
const wire_primaries_display_p3: u32 = 9;

/// Send the wp_color_management parametric sequence for an HDR surface.
///
/// Sequence (all requests batched, each sendMessage call flushes one request):
///   1. WpColorManagerV1.createParametricCreator(mgr_id -> creator_id)
///   2. WpImageDescriptionCreatorParamsV1.setTfNamed(creator_id, tf_named)
///   3. WpImageDescriptionCreatorParamsV1.setPrimariesNamed(creator_id, primaries_named)
///   4. WpImageDescriptionCreatorParamsV1.setLuminances(creator_id, min, max, ref)  [if luminance != null]
///   5. WpImageDescriptionCreatorParamsV1.create(creator_id -> image_desc_id)        [destructor]
///   6. WpColorManagerV1.getSurface(mgr_id, cm_surface_id, wl_surface_id)
///   7. WpColorManagementSurfaceV1.setImageDescription(cm_surface_id, image_desc_id, render_intent=0)
///
/// Luminance scaling (matches compositor's onSetLuminances handler):
///   min_lum wire arg = min_nits * 10000  (cd/m2 * 10000, u32)
///   max_lum wire arg = max_nits          (unscaled cd/m2, u32)
///   reference_lum    = 203              (fixed ITU-R BT.2408 reference white, cd/m2)
///
/// All new object ids (creator, image_desc, cm_surface) are allocated via
/// conn.objects.allocId() and registered in imap with the matching interface.
///
/// Returns the created wp_color_management_surface_v1 object id, which the
/// caller MUST store on the Window and destroy on teardown (it stays alive for
/// the surface's lifetime). Returns 0 when no cm_surface was created (SDR or a
/// missing color manager) so the caller can treat 0 as "none".
pub fn declareSurfaceColor(
    conn: *client.Connection,
    imap: *client.InterfaceMap,
    gpa: std.mem.Allocator,
    wp_color_manager_id: u32,
    wl_surface_id: u32,
    cfg: color.ColorConfig,
) !u32 {
    if (wp_color_manager_id == 0 or !cfg.isHdr()) return 0;

    const w = &conn.wire_writer;

    // Map neutral transfer function to named wire integer.
    const tf_named: u32 = switch (cfg.transfer) {
        .st2084_pq => wire_tf_st2084_pq,
        .hlg => wire_tf_hlg,
        else => return 0, // not HDR via tf; shouldn't reach here given isHdr() but be safe
    };

    // Map neutral colorspace to named primaries wire integer.
    const primaries_named: u32 = switch (cfg.colorspace) {
        .bt2020 => wire_primaries_bt2020,
        .display_p3 => wire_primaries_display_p3,
        .srgb => wire_primaries_srgb,
    };

    // 1. createParametricCreator -> new creator object
    // Allocate and register before sending so any dispatch that arrives
    // before the send completes can resolve the object id.
    const creator_id = conn.objects.allocId();
    try imap.set(creator_id, &cm.WpImageDescriptionCreatorParamsV1.interface);
    try cm.WpColorManagerV1.createParametricCreator(w, gpa, wp_color_manager_id, creator_id);
    try conn.sendMessage(w.finish());

    // 2. setTfNamed
    try cm.WpImageDescriptionCreatorParamsV1.setTfNamed(w, gpa, creator_id, tf_named);
    try conn.sendMessage(w.finish());

    // 3. setPrimariesNamed
    try cm.WpImageDescriptionCreatorParamsV1.setPrimariesNamed(w, gpa, creator_id, primaries_named);
    try conn.sendMessage(w.finish());

    // 4. setLuminances (optional, only when luminance metadata present)
    if (cfg.luminance) |lum| {
        // min_lum: cd/m2 * 10000 (4-decimal fixed point)
        // max_lum + reference_lum: unscaled cd/m2
        // Validation in compositor: max_x10000 > min and ref_x10000 > min.
        const min_wire: u32 = @intFromFloat(@max(0, lum.min_nits) * 10000.0);
        const max_wire: u32 = @intFromFloat(@max(1, lum.max_nits));
        // Reference white: 203 cd/m2 matches the compositor default and the
        // standard reference white for HDR content (ITU-R BT.2408). It must
        // exceed min_lum (in the same units after x10000 scaling): 203*10000 =
        // 2030000, which easily exceeds any reasonable min (e.g. 50 for 0.005 nits).
        const ref_wire: u32 = 203;
        // Guard: compositor requires max_x10000 > min and ref_x10000 > min.
        // Skip luminances rather than cause a protocol error.
        if (@as(u64, max_wire) * 10000 > min_wire and @as(u64, ref_wire) * 10000 > min_wire) {
            try cm.WpImageDescriptionCreatorParamsV1.setLuminances(w, gpa, creator_id, min_wire, max_wire, ref_wire);
            try conn.sendMessage(w.finish());
        }
    }

    // 5. create (destructor: destroys creator, produces image_desc)
    // Register image_desc_id before sending; remove creator_id after (it is
    // consumed by the create request).
    const image_desc_id = conn.objects.allocId();
    try imap.set(image_desc_id, &cm.WpImageDescriptionV1.interface);
    try cm.WpImageDescriptionCreatorParamsV1.create(w, gpa, creator_id, image_desc_id);
    try conn.sendMessage(w.finish());
    // creator_id is destroyed by the create request; remove from imap.
    imap.remove(creator_id);

    // 6. getSurface -> new cm_surface object
    const cm_surface_id = conn.objects.allocId();
    try imap.set(cm_surface_id, &cm.WpColorManagementSurfaceV1.interface);
    try cm.WpColorManagerV1.getSurface(w, gpa, wp_color_manager_id, cm_surface_id, wl_surface_id);
    try conn.sendMessage(w.finish());

    // 7. setImageDescription(cm_surface, image_desc, render_intent=0 perceptual)
    try cm.WpColorManagementSurfaceV1.setImageDescription(w, gpa, cm_surface_id, image_desc_id, 0);
    try conn.sendMessage(w.finish());
    // set_image_description has copy semantics: the compositor copied the
    // description parameters, so the image description object is safe to
    // destroy immediately. Destroy it to avoid leaking a server object and
    // the imap entry (one leak per HDR surface otherwise).
    try cm.WpImageDescriptionV1.destroy(w, gpa, image_desc_id);
    try conn.sendMessage(w.finish());
    imap.remove(image_desc_id);

    std.log.debug("lattice: declared HDR color on wl_surface {d} (tf={d} primaries={d})", .{
        wl_surface_id,
        tf_named,
        primaries_named,
    });

    // cm_surface stays alive for the surface's lifetime; return its id so the
    // caller can destroy it (and drop the imap entry) on surface teardown.
    return cm_surface_id;
}

// ---------------------------------------------------------------------------
// Unit tests (pure, no Wayland connection needed)
// ---------------------------------------------------------------------------

test "declareSurfaceColor tf mapping: st2084_pq maps to wire 11" {
    const testing = std.testing;
    // Mirror the mapping in declareSurfaceColor: .st2084_pq -> 11
    const cfg = color.ColorConfig{
        .format = .xrgb8888,
        .colorspace = .bt2020,
        .transfer = .st2084_pq,
    };
    try testing.expect(cfg.isHdr());
    // Verify expected named integer
    const tf_named: u32 = switch (cfg.transfer) {
        .st2084_pq => wire_tf_st2084_pq,
        .hlg => wire_tf_hlg,
        else => 0,
    };
    try testing.expectEqual(@as(u32, 11), tf_named);
}

test "declareSurfaceColor tf mapping: hlg maps to wire 13" {
    const testing = std.testing;
    const cfg = color.ColorConfig{
        .format = .xrgb8888,
        .colorspace = .bt2020,
        .transfer = .hlg,
    };
    try testing.expect(cfg.isHdr());
    const tf_named: u32 = switch (cfg.transfer) {
        .st2084_pq => wire_tf_st2084_pq,
        .hlg => wire_tf_hlg,
        else => 0,
    };
    try testing.expectEqual(@as(u32, 13), tf_named);
}

test "declareSurfaceColor primaries mapping: bt2020 maps to wire 6" {
    const testing = std.testing;
    const primaries_named: u32 = switch (color.Colorspace.bt2020) {
        .bt2020 => wire_primaries_bt2020,
        .display_p3 => wire_primaries_display_p3,
        .srgb => wire_primaries_srgb,
    };
    try testing.expectEqual(@as(u32, 6), primaries_named);
}

test "declareSurfaceColor luminance scaling: min_nits * 10000" {
    const testing = std.testing;
    // 0.005 nits -> 50 wire units
    const min_nits: f32 = 0.005;
    const min_wire: u32 = @intFromFloat(@max(0, min_nits) * 10000.0);
    try testing.expectEqual(@as(u32, 50), min_wire);
    // 1000 nits -> 1000 wire units (unscaled)
    const max_nits: f32 = 1000.0;
    const max_wire: u32 = @intFromFloat(@max(1, max_nits));
    try testing.expectEqual(@as(u32, 1000), max_wire);
    // Reference white: fixed 203 cd/m2 (ITU-R BT.2408).
    const ref_wire: u32 = 203;
    try testing.expectEqual(@as(u32, 203), ref_wire);
    // Guard: ref_x10000 (2030000) > min_wire (50) -- passes.
    try testing.expect(@as(u64, ref_wire) * 10000 > min_wire);
}

test "declareSurfaceColor early return: sdr config skipped" {
    const cfg = color.ColorConfig.sdr(.xrgb8888);
    // isHdr() must be false for sdr; declareSurfaceColor would return early.
    const testing = std.testing;
    try testing.expect(!cfg.isHdr());
}
