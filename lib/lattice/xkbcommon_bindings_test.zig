const xkb = @import("xkbcommon");
test "xkbcommon bindings" {
    _ = xkb.Context;
    _ = xkb.Keymap;
    _ = xkb.Flags;
    _ = xkb.LogLevel;
}
