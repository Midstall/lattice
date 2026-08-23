const std = @import("std");
const wayland_build = @import("wayland");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("lattice", .{
        .root_source_file = b.path("lib/lattice.zig"),
        .target = target,
        .optimize = optimize,
    });

    const wayland_dep = b.dependency("wayland", .{ .target = target, .optimize = optimize });
    const wayland_mod = wayland_dep.module("wayland");
    const prism_dep = b.dependency("prism", .{ .target = target, .optimize = optimize });
    const xkbcommon_dep = b.dependency("xkbcommon", .{ .target = target, .optimize = optimize });
    const drm_dep = b.dependency("drm", .{ .target = target, .optimize = optimize });
    const libseat_dep = b.dependency("libseat", .{ .target = target, .optimize = optimize });
    const udev_dep = b.dependency("udev", .{ .target = target, .optimize = optimize });
    const libinput_dep = b.dependency("libinput", .{ .target = target, .optimize = optimize });
    const wl_protocols = b.dependency("wayland_protocols", .{});
    const wl_xml = b.dependency("wayland_xml", .{});

    const wl_proto = wayland_build.generateProtocol(b, wayland_dep, wl_xml.path("protocol/wayland.xml"), "wayland_protocol");
    const xdg_proto = wayland_build.generateProtocol(b, wayland_dep, wl_protocols.path("stable/xdg-shell/xdg-shell.xml"), "xdg_shell");
    const linux_dmabuf_proto = wayland_build.generateProtocol(b, wayland_dep, wl_protocols.path("stable/linux-dmabuf/linux-dmabuf-v1.xml"), "linux_dmabuf");
    const color_mgmt_proto = wayland_build.generateProtocol(b, wayland_dep, wayland_dep.path("protocol/color-management-v1.xml"), "color_management");
    const relative_pointer_proto = wayland_build.generateProtocol(b, wayland_dep, wl_protocols.path("unstable/relative-pointer/relative-pointer-unstable-v1.xml"), "relative_pointer");
    const pointer_constraints_proto = wayland_build.generateProtocol(b, wayland_dep, wl_protocols.path("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml"), "pointer_constraints");
    const tablet_v2_proto = wayland_build.generateProtocol(b, wayland_dep, wl_protocols.path("unstable/tablet/tablet-unstable-v2.xml"), "tablet_v2");

    root_module.addImport("wayland", wayland_mod);
    root_module.addImport("wayland_protocol", wl_proto);
    root_module.addImport("xdg_shell", xdg_proto);
    root_module.addImport("linux_dmabuf", linux_dmabuf_proto);
    root_module.addImport("color_management", color_mgmt_proto);
    root_module.addImport("relative_pointer", relative_pointer_proto);
    root_module.addImport("pointer_constraints", pointer_constraints_proto);
    root_module.addImport("tablet_v2", tablet_v2_proto);
    root_module.addImport("prism", prism_dep.module("prism"));
    root_module.addImport("xkbcommon", xkbcommon_dep.module("xkbcommon"));
    root_module.addImport("drm", drm_dep.module("drm"));
    root_module.addImport("libseat", libseat_dep.module("libseat"));
    root_module.addImport("udev", udev_dep.module("udev"));
    root_module.addImport("libinput", libinput_dep.module("libinput"));

    const example = b.addExecutable(.{
        .name = "lattice-window",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/window.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("lattice", root_module);
    b.installArtifact(example);
    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example-window", "Run the wayland window example");
    example_step.dependOn(&run_example.step);

    const smoke = b.addExecutable(.{
        .name = "compositor-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/compositor_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    smoke.root_module.addImport("lattice", root_module);
    smoke.root_module.addImport("prism", prism_dep.module("prism"));
    b.installArtifact(smoke);
    const run_smoke = b.addRunArtifact(smoke);
    const smoke_step = b.step("example-compositor-smoke", "Run the compositor smoke test");
    smoke_step.dependOn(&run_smoke.step);

    const nested = b.addExecutable(.{
        .name = "lattice-nested",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/nested.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    nested.root_module.addImport("lattice", root_module);
    b.installArtifact(nested);
    const run_nested = b.addRunArtifact(nested);
    // Ensure lattice-window is built and installed before we run nested.
    run_nested.step.dependOn(&b.addInstallArtifact(example, .{}).step);
    const nested_step = b.step("example-nested", "Run the nested compositor self-host example");
    nested_step.dependOn(&run_nested.step);

    const kms_demo = b.addExecutable(.{
        .name = "lattice-kms-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/kms_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kms_demo.root_module.addImport("lattice", root_module);
    b.installArtifact(kms_demo);
    const run_kms = b.addRunArtifact(kms_demo);
    const kms_step = b.step("example-kms", "Run the KMS scanout demo (needs root + a free VT)");
    kms_step.dependOn(&run_kms.step);

    const constraints_e2e = b.addExecutable(.{
        .name = "constraints-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/constraints_e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    constraints_e2e.root_module.addImport("lattice", root_module);
    constraints_e2e.root_module.addImport("prism", prism_dep.module("prism"));
    constraints_e2e.root_module.addImport("wayland", wayland_mod);
    constraints_e2e.root_module.addImport("wayland_protocol", wl_proto);
    constraints_e2e.root_module.addImport("xdg_shell", xdg_proto);
    constraints_e2e.root_module.addImport("relative_pointer", relative_pointer_proto);
    constraints_e2e.root_module.addImport("pointer_constraints", pointer_constraints_proto);
    b.installArtifact(constraints_e2e);
    const run_e2e = b.addRunArtifact(constraints_e2e);
    const e2e_step = b.step("example-constraints-e2e", "Run the pointer-constraints e2e test");
    e2e_step.dependOn(&run_e2e.step);

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
