//! Pure, allocation-free double-buffer state machine for wl_surface.
//! Tracks pending vs. current buffer state across attach/commit cycles.

const std = @import("std");

pub const BufferRef = struct {
    resource_id: u32,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
};

pub const Role = enum {
    none,
    toplevel,
    popup,
};

pub const Committed = enum {
    none,
    new_buffer,
    buffer_cleared,
};

pub const SurfaceState = struct {
    pending_buffer: ?BufferRef = null,
    pending_attached: bool = false,
    current_buffer: ?BufferRef = null,
    has_committed: bool = false,
    role: Role = .none,

    pub fn attach(self: *SurfaceState, buf: BufferRef) void {
        self.pending_buffer = buf;
        self.pending_attached = true;
    }

    pub fn attachNull(self: *SurfaceState) void {
        self.pending_buffer = null;
        self.pending_attached = true;
    }

    pub fn commit(self: *SurfaceState) Committed {
        defer self.has_committed = true;

        if (self.pending_attached) {
            self.current_buffer = self.pending_buffer;
            self.pending_attached = false;
            return if (self.pending_buffer != null) .new_buffer else .buffer_cleared;
        }

        return .none;
    }
};

test "fresh commit returns .none" {
    var state = SurfaceState{};
    const result = state.commit();

    try std.testing.expectEqual(Committed.none, result);
    try std.testing.expect(state.current_buffer == null);
    try std.testing.expect(state.has_committed);
}

test "attach then commit returns .new_buffer" {
    var state = SurfaceState{};
    const buf = BufferRef{
        .resource_id = 1,
        .width = 800,
        .height = 600,
        .stride = 3200,
        .format = 0,
    };

    state.attach(buf);
    const result = state.commit();

    try std.testing.expectEqual(Committed.new_buffer, result);
    try std.testing.expect(state.current_buffer != null);
    try std.testing.expectEqual(buf.resource_id, state.current_buffer.?.resource_id);
    try std.testing.expect(state.has_committed);
}

test "second commit with no new attach returns .none" {
    var state = SurfaceState{};
    const buf = BufferRef{
        .resource_id = 1,
        .width = 800,
        .height = 600,
        .stride = 3200,
        .format = 0,
    };

    state.attach(buf);
    _ = state.commit();

    const second_result = state.commit();

    try std.testing.expectEqual(Committed.none, second_result);
    try std.testing.expect(state.current_buffer != null);
    try std.testing.expectEqual(buf.resource_id, state.current_buffer.?.resource_id);
}

test "attachNull then commit returns .buffer_cleared" {
    var state = SurfaceState{};
    const buf = BufferRef{
        .resource_id = 1,
        .width = 800,
        .height = 600,
        .stride = 3200,
        .format = 0,
    };

    state.attach(buf);
    _ = state.commit();

    state.attachNull();
    const result = state.commit();

    try std.testing.expectEqual(Committed.buffer_cleared, result);
    try std.testing.expect(state.current_buffer == null);
}

test "role defaults to .none" {
    const state = SurfaceState{};
    try std.testing.expectEqual(Role.none, state.role);
}
