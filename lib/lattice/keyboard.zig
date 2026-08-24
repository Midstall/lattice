//! Keyboard state for the client backends: keymap plus modifier tracking, built
//! on Midstall's xkbcommon.zig. Both client backends turn raw evdev keycodes into
//! keysyms through this one type: the Wayland backend feeds it the keymap the
//! compositor sends on wl_keyboard, and the KMS backend builds it from the XKB
//! environment, because a bare evdev device has no compositor to ask.
//!
//! The keysym values are the X11 numbers, which is what phantom's input.Keysym
//! carries, so the handover to consumers needs no translation table.
const std = @import("std");
const xkb = @import("xkbcommon");
const event_mod = @import("event.zig");

test "a press on a letter key reports its keysym and its text" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    const t = try k.translate(30, true); // evdev KEY_A
    try std.testing.expectEqual(@as(u32, 'a'), t.keysym);
    try std.testing.expectEqualStrings("a", t.text.?);
    try std.testing.expect(t.mods.none());
}

test "shift changes the keysym, the text and the modifiers" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    _ = try k.translate(42, true); // evdev KEY_LEFTSHIFT
    const t = try k.translate(30, true);
    try std.testing.expectEqual(@as(u32, 'A'), t.keysym);
    try std.testing.expectEqualStrings("A", t.text.?);
    try std.testing.expect(t.mods.shift);
    try std.testing.expect(!t.mods.ctrl);
}

test "releasing shift restores the base keysym" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    _ = try k.translate(42, true);
    _ = try k.translate(42, false);
    const t = try k.translate(30, true);
    try std.testing.expectEqual(@as(u32, 'a'), t.keysym);
    try std.testing.expect(t.mods.none());
}

test "a named key reports its keysym and no text" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    const tab = try k.translate(15, true); // evdev KEY_TAB
    try std.testing.expectEqual(@as(u32, 0xFF09), tab.keysym);
    try std.testing.expect(tab.text == null);

    const up = try k.translate(103, true); // evdev KEY_UP
    try std.testing.expectEqual(@as(u32, 0xFF52), up.keysym);
    try std.testing.expect(up.text == null);
}

test "control suppresses the text but keeps the keysym" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    _ = try k.translate(29, true); // evdev KEY_LEFTCTRL
    const t = try k.translate(30, true);
    try std.testing.expectEqual(@as(u32, 'a'), t.keysym);
    try std.testing.expect(t.mods.ctrl);
    // A shortcut must never insert text: a text field inserts `text` blindly.
    try std.testing.expect(t.text == null);
}

test "a release reports the keysym and never carries text" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    _ = try k.translate(30, true);
    const t = try k.translate(30, false);
    try std.testing.expectEqual(@as(u32, 'a'), t.keysym);
    try std.testing.expect(t.text == null);
}

test "updateMods applies the compositor's modifier mask" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    // Bit 0 is the Shift modifier, which the Wayland wl_keyboard.modifiers event
    // reports as a serialized mask rather than as key presses.
    k.updateMods(0x1, 0, 0, 0);
    const t = try k.translate(30, true);
    try std.testing.expectEqual(@as(u32, 'A'), t.keysym);
    try std.testing.expect(t.mods.shift);

    k.updateMods(0, 0, 0, 0);
    const plain = try k.translate(30, true);
    try std.testing.expectEqual(@as(u32, 'a'), plain.keysym);
}

test "a keycode the keymap does not cover reports no symbol and does not crash" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    const t = try k.translate(240, true);
    try std.testing.expectEqual(@as(u32, 0), t.keysym);
    try std.testing.expect(t.text == null);
    try std.testing.expect(t.mods.none());
}

test "an empty keyboard reports nothing and does not crash" {
    // The Wayland backend starts empty: the compositor's keymap has not arrived
    // yet. A key event in that window degrades to a zero keysym, never a crash.
    var k = KeyboardState{};
    const t = try k.translate(30, true);
    try std.testing.expectEqual(@as(u32, 0), t.keysym);
    try std.testing.expect(t.text == null);
}

test "initFromEnv falls back to the embedded keymap when no XKB database resolves" {
    // No environment and no database path: the real lookup must fail and the
    // embedded US map must take over, because a KMS seat with no xkb data still
    // has keys.
    var empty = std.process.Environ.Map.init(std.testing.allocator);
    defer empty.deinit();
    var k = KeyboardState.initFromEnv(std.testing.allocator, std.testing.io, &empty);
    defer k.deinit();

    const t = try k.translate(30, true);
    try std.testing.expectEqual(@as(u32, 'a'), t.keysym);
    try std.testing.expectEqualStrings("a", t.text.?);
}

test "a replacement keymap swaps the mapping without losing the old one on failure" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    // A bad string must not destroy the working keymap: the compositor's bytes
    // are untrusted input.
    try std.testing.expectError(error.ParseError, k.setKeymapFromString("not a keymap"));
    const still = try k.translate(30, true);
    try std.testing.expectEqual(@as(u32, 'a'), still.keysym);

    // A map where AC01 is x: the same physical key now reports x.
    try k.setKeymapFromString(remapped_keymap);
    const t = try k.translate(30, true);
    try std.testing.expectEqual(@as(u32, 'x'), t.keysym);
}

test "the embedded fallback covers the keys a focus system needs" {
    var k = try KeyboardState.initFromString(std.testing.allocator, std.testing.io, minimal_keymap);
    defer k.deinit();

    // Tab, Return, Escape and the arrows drive focus traversal and scrolling.
    // A fallback that lacks them strands keyboard users on data-less systems.
    const cases = .{
        .{ @as(u32, 15), @as(u32, 0xFF09) }, // tab
        .{ @as(u32, 28), @as(u32, 0xFF0D) }, // return
        .{ @as(u32, 1), @as(u32, 0xFF1B) }, // escape
        .{ @as(u32, 103), @as(u32, 0xFF52) }, // up
        .{ @as(u32, 108), @as(u32, 0xFF54) }, // down
        .{ @as(u32, 105), @as(u32, 0xFF51) }, // left
        .{ @as(u32, 106), @as(u32, 0xFF53) }, // right
        .{ @as(u32, 104), @as(u32, 0xFF55) }, // page up
        .{ @as(u32, 109), @as(u32, 0xFF56) }, // page down
        .{ @as(u32, 102), @as(u32, 0xFF50) }, // home
        .{ @as(u32, 107), @as(u32, 0xFF57) }, // end
        .{ @as(u32, 14), @as(u32, 0xFF08) }, // backspace
        .{ @as(u32, 111), @as(u32, 0xFFFF) }, // delete
    };
    inline for (cases) |c| {
        const t = try k.translate(c[0], true);
        try std.testing.expectEqual(c[1], t.keysym);
    }
}

/// What one key press or release means after the keymap and the modifiers.
pub const Translated = struct {
    /// The X11 keysym value, 0 when the key has no mapping.
    keysym: u32 = 0,
    mods: event_mod.KeyMods = .{},
    /// The UTF-8 text the key produces. Borrows the keyboard's own storage and
    /// is valid until the next `translate` call, the same rule phantom's
    /// terminal decoder follows for `KeyEvent.text`.
    text: ?[]const u8 = null,
};

/// One keyboard's worth of xkb state: the context, the keymap and the modifier
/// tracking. Every field is optional so a backend can exist before its keymap
/// arrives: on Wayland the compositor sends the keymap after the keyboard
/// object is bound, and a key event in that window degrades to a zero keysym
/// instead of a crash.
pub const KeyboardState = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    ctx: ?*xkb.Context = null,
    keymap: ?*xkb.Keymap = null,
    state: ?*xkb.State = null,
    /// Storage for `Translated.text`. One keysym encodes one codepoint, at most
    /// four bytes of UTF-8.
    text_buf: [8]u8 = undefined,

    /// Build from a complete XKB v1 keymap string. The string is untrusted
    /// input when it comes off a socket, so a parse failure is an error and
    /// never a panic.
    pub fn initFromString(gpa: std.mem.Allocator, io: std.Io, text: []const u8) !KeyboardState {
        var k = KeyboardState{ .gpa = gpa, .io = io };
        try k.setKeymapFromString(text);
        return k;
    }

    /// Build from the XKB environment (XKB_DEFAULT_RULES/MODEL/LAYOUT/VARIANT/
    /// OPTIONS, and the database at XKB_CONFIG_ROOT or the default paths). A
    /// system with no readable XKB database gets the embedded US map instead:
    /// a seat with no data still has keys, and a wrong-letter key beats a dead
    /// one. This never fails.
    pub fn initFromEnv(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) KeyboardState {
        const ctx = xkb.Context.create(gpa, io, .{}, environ) catch
            return initFromString(gpa, io, minimal_keymap) catch .{};
        const km = xkb.Keymap.newFromNames(ctx, .{}, .text_v1) catch {
            ctx.destroy();
            return initFromString(gpa, io, minimal_keymap) catch .{};
        };
        const st = xkb.State.create(km) catch {
            km.destroy();
            ctx.destroy();
            return initFromString(gpa, io, minimal_keymap) catch .{};
        };
        return .{ .gpa = gpa, .io = io, .ctx = ctx, .keymap = km, .state = st };
    }

    /// Replace the keymap, resetting the modifier state. The Wayland backend
    /// calls this when the compositor's wl_keyboard.keymap arrives. The new map
    /// is built BEFORE the old one is dropped, so a bad string from the wire
    /// leaves the working map in place.
    pub fn setKeymapFromString(self: *KeyboardState, text: []const u8) !void {
        // The string is self-contained: no includes resolve, so no filesystem
        // and no environment are read. That keeps the compositor's bytes from
        // naming files on this machine.
        const ctx = try xkb.Context.create(self.gpa, self.io, .{
            .no_default_includes = true,
            .no_environment_names = true,
        }, null);
        errdefer ctx.destroy();
        const km = try xkb.Keymap.newFromString(ctx, text, .text_v1);
        errdefer km.destroy();
        const st = try xkb.State.create(km);
        errdefer st.destroy();

        if (self.state) |old| old.destroy();
        if (self.keymap) |old| old.destroy();
        if (self.ctx) |old| old.destroy();
        self.ctx = ctx;
        self.keymap = km;
        self.state = st;
    }

    /// Apply a serialized modifier mask, which is how wl_keyboard.modifiers
    /// reports latches and locks that no key press of ours caused. `group`
    /// carries the layout index.
    pub fn updateMods(self: *KeyboardState, depressed: u32, latched: u32, locked: u32, group: i32) void {
        const st = self.state orelse return;
        _ = st.updateMask(depressed, latched, locked, 0, 0, group);
    }

    /// Turn one raw evdev keycode into a keysym, the active modifiers and the
    /// text the key produces. The state updates FIRST, so a shifted letter
    /// reports its shifted form, and a release reports the key that was held.
    pub fn translate(self: *KeyboardState, keycode: u32, pressed: bool) !Translated {
        const st = self.state orelse return .{};
        // evdev keycodes are xkb keycodes minus 8. The addition is checked:
        // the keycode is wire input on Wayland and a malicious compositor may
        // send anything.
        const kc = std.math.add(u32, keycode, 8) catch return .{};
        _ = try st.updateKey(kc, if (pressed) .down else .up);

        const sym = st.keyGetOneSym(kc);
        const mods = event_mod.KeyMods{
            .shift = st.modNameIsActive("Shift", .effective),
            .ctrl = st.modNameIsActive("Control", .effective),
            .alt = st.modNameIsActive("Mod1", .effective),
            .super = st.modNameIsActive("Mod4", .effective),
        };
        var out = Translated{ .keysym = @intFromEnum(sym), .mods = mods };
        // Text on a press only, and never with ctrl or alt held: a text field
        // inserts `text` blindly, so a shortcut must not carry any. This is the
        // same rule phantom's terminal decoder applies. Named keys like Tab and
        // Return map to control codepoints, which are not text either.
        const cp = sym.toUtf32();
        if (pressed and !mods.ctrl and !mods.alt and cp >= 0x20 and cp != 0x7F) {
            out.text = st.keyGetUtf8(kc, &self.text_buf);
        }
        return out;
    }

    pub fn deinit(self: *KeyboardState) void {
        if (self.state) |st| st.destroy();
        if (self.keymap) |km| km.destroy();
        if (self.ctx) |ctx| ctx.destroy();
        self.* = .{};
    }
};

/// The embedded US map, for a seat with no XKB database and for tests with no
/// filesystem. Covers the printable ASCII block, the editing keys, the arrows
/// and the modifiers a focus system needs. It is deliberately small: a real
/// database or a compositor's keymap always wins when one is available.
pub const minimal_keymap: [:0]const u8 =
    \\xkb_keymap {
    \\  xkb_keycodes "evdev" {
    \\    minimum = 8;
    \\    maximum = 255;
    \\    <ESC>  = 9;
    \\    <AE01> = 10; <AE02> = 11; <AE03> = 12; <AE04> = 13; <AE05> = 14;
    \\    <AE06> = 15; <AE07> = 16; <AE08> = 17; <AE09> = 18; <AE10> = 19;
    \\    <AE11> = 20; <AE12> = 21;
    \\    <BKSP> = 22;
    \\    <TAB>  = 23;
    \\    <AD01> = 24; <AD02> = 25; <AD03> = 26; <AD04> = 27; <AD05> = 28;
    \\    <AD06> = 29; <AD07> = 30; <AD08> = 31; <AD09> = 32; <AD10> = 33;
    \\    <AD11> = 34; <AD12> = 35;
    \\    <RTRN> = 36;
    \\    <LCTL> = 37;
    \\    <AC01> = 38; <AC02> = 39; <AC03> = 40; <AC04> = 41; <AC05> = 42;
    \\    <AC06> = 43; <AC07> = 44; <AC08> = 45; <AC09> = 46; <AC10> = 47;
    \\    <AC11> = 48;
    \\    <LFSH> = 50;
    \\    <AB01> = 52; <AB02> = 53; <AB03> = 54; <AB04> = 55; <AB05> = 56;
    \\    <AB06> = 57; <AB07> = 58; <AB08> = 59; <AB09> = 60; <AB10> = 61;
    \\    <RTSH> = 62;
    \\    <LALT> = 64;
    \\    <SPCE> = 65;
    \\    <CAPS> = 66;
    \\    <HOME> = 110; <UP> = 111; <PGUP> = 112; <LEFT> = 113; <RGHT> = 114;
    \\    <END>  = 115; <DOWN> = 116; <PGDN> = 117; <INS> = 118; <DELE> = 119;
    \\  };
    \\  xkb_types "complete" {
    \\    type "ONE_LEVEL" {
    \\      modifiers = none;
    \\      level_name[Level1] = "Any";
    \\    };
    \\    type "TWO_LEVEL" {
    \\      modifiers = Shift;
    \\      map[Shift] = Level2;
    \\      level_name[Level1] = "Base";
    \\      level_name[Level2] = "Shift";
    \\    };
    \\    type "ALPHABETIC" {
    \\      modifiers = Shift+Lock;
    \\      map[Shift] = Level2;
    \\      map[Lock]  = Level2;
    \\      level_name[Level1] = "Base";
    \\      level_name[Level2] = "Caps";
    \\    };
    \\  };
    \\  xkb_compat "complete" {};
    \\  xkb_symbols "pc+us" {
    \\    name[group1] = "English (US)";
    \\    key <ESC>  { [ Escape ] };
    \\    key <AE01> { type="TWO_LEVEL", [ 1, exclam ] };
    \\    key <AE02> { type="TWO_LEVEL", [ 2, at ] };
    \\    key <AE03> { type="TWO_LEVEL", [ 3, numbersign ] };
    \\    key <AE04> { type="TWO_LEVEL", [ 4, dollar ] };
    \\    key <AE05> { type="TWO_LEVEL", [ 5, percent ] };
    \\    key <AE06> { type="TWO_LEVEL", [ 6, asciicircum ] };
    \\    key <AE07> { type="TWO_LEVEL", [ 7, ampersand ] };
    \\    key <AE08> { type="TWO_LEVEL", [ 8, asterisk ] };
    \\    key <AE09> { type="TWO_LEVEL", [ 9, parenleft ] };
    \\    key <AE10> { type="TWO_LEVEL", [ 0, parenright ] };
    \\    key <AE11> { type="TWO_LEVEL", [ minus, underscore ] };
    \\    key <AE12> { type="TWO_LEVEL", [ equal, plus ] };
    \\    key <BKSP> { [ BackSpace ] };
    \\    key <TAB>  { [ Tab ] };
    \\    key <AD01> { type="ALPHABETIC", [ q, Q ] };
    \\    key <AD02> { type="ALPHABETIC", [ w, W ] };
    \\    key <AD03> { type="ALPHABETIC", [ e, E ] };
    \\    key <AD04> { type="ALPHABETIC", [ r, R ] };
    \\    key <AD05> { type="ALPHABETIC", [ t, T ] };
    \\    key <AD06> { type="ALPHABETIC", [ y, Y ] };
    \\    key <AD07> { type="ALPHABETIC", [ u, U ] };
    \\    key <AD08> { type="ALPHABETIC", [ i, I ] };
    \\    key <AD09> { type="ALPHABETIC", [ o, O ] };
    \\    key <AD10> { type="ALPHABETIC", [ p, P ] };
    \\    key <AD11> { type="TWO_LEVEL", [ bracketleft, braceleft ] };
    \\    key <AD12> { type="TWO_LEVEL", [ bracketright, braceright ] };
    \\    key <RTRN> { [ Return ] };
    \\    key <LCTL> { [ Control_L ] };
    \\    key <AC01> { type="ALPHABETIC", [ a, A ] };
    \\    key <AC02> { type="ALPHABETIC", [ s, S ] };
    \\    key <AC03> { type="ALPHABETIC", [ d, D ] };
    \\    key <AC04> { type="ALPHABETIC", [ f, F ] };
    \\    key <AC05> { type="ALPHABETIC", [ g, G ] };
    \\    key <AC06> { type="ALPHABETIC", [ h, H ] };
    \\    key <AC07> { type="ALPHABETIC", [ j, J ] };
    \\    key <AC08> { type="ALPHABETIC", [ k, K ] };
    \\    key <AC09> { type="ALPHABETIC", [ l, L ] };
    \\    key <AC10> { type="TWO_LEVEL", [ semicolon, colon ] };
    \\    key <AC11> { type="TWO_LEVEL", [ apostrophe, quotedbl ] };
    \\    key <LFSH> { [ Shift_L ] };
    \\    key <AB01> { type="ALPHABETIC", [ z, Z ] };
    \\    key <AB02> { type="ALPHABETIC", [ x, X ] };
    \\    key <AB03> { type="ALPHABETIC", [ c, C ] };
    \\    key <AB04> { type="ALPHABETIC", [ v, V ] };
    \\    key <AB05> { type="ALPHABETIC", [ b, B ] };
    \\    key <AB06> { type="ALPHABETIC", [ n, N ] };
    \\    key <AB07> { type="ALPHABETIC", [ m, M ] };
    \\    key <AB08> { type="TWO_LEVEL", [ comma, less ] };
    \\    key <AB09> { type="TWO_LEVEL", [ period, greater ] };
    \\    key <AB10> { type="TWO_LEVEL", [ slash, question ] };
    \\    key <RTSH> { [ Shift_R ] };
    \\    key <LALT> { [ Alt_L ] };
    \\    key <SPCE> { [ space ] };
    \\    key <CAPS> { [ Caps_Lock ] };
    \\    key <HOME> { [ Home ] };
    \\    key <UP>   { [ Up ] };
    \\    key <PGUP> { [ Page_Up ] };
    \\    key <LEFT> { [ Left ] };
    \\    key <RGHT> { [ Right ] };
    \\    key <END>  { [ End ] };
    \\    key <DOWN> { [ Down ] };
    \\    key <PGDN> { [ Page_Down ] };
    \\    key <INS>  { [ Insert ] };
    \\    key <DELE> { [ Delete ] };
    \\    modifier_map Shift   { <LFSH>, <RTSH> };
    \\    modifier_map Lock    { <CAPS> };
    \\    modifier_map Control { <LCTL> };
    \\    modifier_map Mod1    { <LALT> };
    \\  };
    \\};
;

/// A one-key variant of the fallback where AC01 is x, for the swap test.
const remapped_keymap: [:0]const u8 =
    \\xkb_keymap {
    \\  xkb_keycodes "evdev" {
    \\    minimum = 8;
    \\    maximum = 255;
    \\    <AC01> = 38;
    \\  };
    \\  xkb_types "complete" {
    \\    type "ONE_LEVEL" {
    \\      modifiers = none;
    \\      level_name[Level1] = "Any";
    \\    };
    \\  };
    \\  xkb_compat "complete" {};
    \\  xkb_symbols "test" {
    \\    key <AC01> { [ x ] };
    \\  };
    \\};
;
