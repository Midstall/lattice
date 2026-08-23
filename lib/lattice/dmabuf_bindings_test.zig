//! Compile-verification that the generated linux_dmabuf bindings expose the
//! client + server API the later dmabuf slices need. Referencing these decls
//! makes a missing/broken binding a build failure.
const std = @import("std");
const ld = @import("linux_dmabuf");

test "linux_dmabuf bindings expose the core dmabuf + params + feedback API" {
    // Interfaces exist (PascalCase structs with a static .interface descriptor).
    _ = ld.ZwpLinuxDmabufV1.interface;
    _ = ld.ZwpLinuxBufferParamsV1.interface;
    _ = ld.ZwpLinuxDmabufFeedbackV1.interface;

    // Version constants exist.
    try std.testing.expect(ld.ZwpLinuxDmabufV1.version >= 1);

    // Request fns exist as decls (take a comptime reference, no call). Confirm
    // the exact generated names against the module if these mismatch — the
    // generator emits camelCase request fns (createParams / add / create / createImmed).
    _ = @TypeOf(ld.ZwpLinuxDmabufV1.createParams);
    _ = @TypeOf(ld.ZwpLinuxBufferParamsV1.add);
    _ = @TypeOf(ld.ZwpLinuxBufferParamsV1.create);
    _ = @TypeOf(ld.ZwpLinuxBufferParamsV1.createImmed);

    // Event opcode enums exist (the modifier/format advertisement + params created/failed + feedback).
    _ = ld.ZwpLinuxDmabufV1.EventOpcode;
    _ = ld.ZwpLinuxBufferParamsV1.EventOpcode;
    _ = ld.ZwpLinuxDmabufFeedbackV1.EventOpcode;
}
