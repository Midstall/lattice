const cm = @import("color_management");

test "color_management bindings present" {
    _ = cm.WpColorManagerV1.interface;
    _ = cm.WpColorManagementSurfaceV1.interface;
    _ = cm.WpImageDescriptionCreatorParamsV1.interface;
    _ = cm.WpImageDescriptionV1.interface;
}
