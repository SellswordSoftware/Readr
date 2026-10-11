const std = @import("std");

pub const duration_ms: u32 = 180;
pub const full: u16 = 1000;

/// The panel stays open while focus moves between font controls. Glyphs are
/// revealed through a growing clip, never scaled.
pub const State = struct {
    visible: bool = false,
    active: bool = false,
    started_at: u32 = 0,
    start_value: u16 = 0,

    pub fn update(self: *State, visible: bool, now_ms: u32, reduce_flashing: bool) u16 {
        if (reduce_flashing) {
            self.* = .{ .visible = visible };
            return if (visible) full else 0;
        }
        if (self.visible != visible) {
            const current = self.value(now_ms);
            self.* = .{ .visible = visible, .active = current != (if (visible) full else @as(u16, 0)), .started_at = now_ms, .start_value = current };
        }
        if (now_ms -% self.started_at >= duration_ms) self.active = false;
        return self.value(now_ms);
    }

    fn value(self: *const State, now_ms: u32) u16 {
        const target: u16 = if (self.visible) full else 0;
        if (!self.active or now_ms -% self.started_at >= duration_ms) return target;
        const remaining: u32 = @intCast((duration_ms - (now_ms -% self.started_at)) * full / duration_ms);
        const progress: i32 = @intCast(full - remaining * remaining / full * remaining / full);
        return @intCast(@as(i32, self.start_value) + @divTrunc((@as(i32, target) - self.start_value) * progress, full));
    }
};

test "font preview expands briefly without replaying for another font and can be interrupted" {
    var state: State = .{};
    try std.testing.expectEqual(@as(u16, 0), state.update(true, 1000, false));
    const middle = state.update(true, 1090, false);
    try std.testing.expect(middle > full / 2 and middle < full);
    try std.testing.expect(state.active);
    try std.testing.expectEqual(full, state.update(true, 1180, false));
    try std.testing.expect(!state.active);
    try std.testing.expectEqual(full, state.update(true, 1190, false));
    try std.testing.expectEqual(full, state.update(false, 1191, false));
    try std.testing.expect(state.active);
    const shrinking = state.update(false, 1240, false);
    try std.testing.expect(shrinking > 0 and shrinking < full);
    try std.testing.expectEqual(shrinking, state.update(true, 1240, false));
    try std.testing.expect(state.update(true, 1250, false) > shrinking);
    try std.testing.expectEqual(full, state.update(true, 1251, true));
    try std.testing.expect(!state.active);
}

test "font preview shrinks to nothing and reduced motion settles immediately" {
    var state: State = .{};
    _ = state.update(true, 100, true);
    try std.testing.expectEqual(full, state.update(false, 200, false));
    try std.testing.expect(state.update(false, 290, false) < full);
    try std.testing.expectEqual(@as(u16, 0), state.update(false, 380, false));
    try std.testing.expect(!state.active);
    try std.testing.expectEqual(@as(u16, 0), state.update(false, 400, false));
    _ = state.update(true, 500, true);
    try std.testing.expectEqual(@as(u16, 0), state.update(false, 501, true));
    try std.testing.expect(!state.active);
}
