const std = @import("std");

pub const total_ms: u16 = 350;
pub const complete: u16 = 1_000;

pub const State = struct {
    started_at: u32 = 0,
    active: bool = false,

    pub fn begin(self: *State, now_ms: u32) void {
        self.* = .{ .started_at = now_ms, .active = true };
    }

    pub fn cancel(self: *State) void {
        self.active = false;
    }

    pub fn progress(self: *State, now_ms: u32) ?u16 {
        if (!self.active) return null;
        const elapsed = now_ms -% self.started_at;
        if (elapsed >= total_ms) {
            self.active = false;
            return null;
        }
        const linear: u32 = (@as(u32, elapsed) * complete) / total_ms;
        const remaining = complete - linear;
        return @intCast(complete - (remaining * remaining) / complete);
    }
};

pub fn diameter(start: c_int, finish: c_int, progress: u16) c_int {
    return finish + @divTrunc((start - finish) * @as(c_int, complete - progress), complete);
}

/// Paint a 25% Bayer circle directly into MSB-first LCD bits. Integer square roots give
/// inclusive row spans; partial-byte masks preserve outside pixels and padding.
pub fn paintCircle(frame: []u8, stride: usize, width: usize, height: usize, center_x: c_int, center_y: c_int, diameter_value: c_int, foreground_is_white: bool) void {
    std.debug.assert(diameter_value >= 0 and diameter_value <= 65_535);
    std.debug.assert(stride >= (width + 7) / 8 and frame.len >= stride * height);
    const radius: i64 = @divTrunc(diameter_value, 2);
    const radius_squared = radius * radius;
    const first_y: i64 = @max(0, @as(i64, center_y) - radius);
    const last_y = @min(@as(i64, @intCast(height)) - 1, @as(i64, center_y) + radius);
    // Only even rows contain Bayer dots; skip the empty pattern rows entirely.
    var y: i64 = first_y + (first_y & 1);
    while (y <= last_y) : (y += 2) {
        const dy = y - center_y;
        const half_span: i64 = std.math.sqrt(@as(u32, @intCast(radius_squared - dy * dy)));
        const left = @max(0, @as(i64, center_x) - half_span);
        const right = @min(@as(i64, @intCast(width)) - 1, @as(i64, center_x) + half_span);
        if (left > right) continue;
        const first_x: usize = @intCast(left);
        const last_x: usize = @intCast(right);
        const first_byte = first_x / 8;
        const last_byte = last_x / 8;
        const row = frame[@as(usize, @intCast(y)) * stride ..][0..stride];
        for (first_byte..last_byte + 1) |byte| {
            var mask: u8 = 0b10101010;
            if (byte == first_byte) mask &= @as(u8, 0xff) >> @intCast(first_x & 7);
            if (byte == last_byte) mask &= @as(u8, 0xff) << @intCast(7 - (last_x & 7));
            if (foreground_is_white) row[byte] |= mask else row[byte] &= ~mask;
        }
    }
}

test "spotlight begins screen-sized and settles on its target" {
    var state: State = .{};
    state.begin(100);
    try std.testing.expectEqual(@as(u16, 0), state.progress(100).?);
    try std.testing.expect(diameter(1_200, 24, state.progress(275).?) < 400);
    try std.testing.expect(state.progress(450) == null);
}

fn referenceCircle(frame: []u8, stride: usize, width: usize, height: usize, center_x: c_int, center_y: c_int, diameter_value: c_int, white: bool) void {
    const radius: i64 = @divTrunc(diameter_value, 2);
    for (0..height) |y| {
        for (0..width) |x| {
            const dx = @as(i64, @intCast(x)) - center_x;
            const dy = @as(i64, @intCast(y)) - center_y;
            if (dx * dx + dy * dy > radius * radius) continue;
            const pattern: u8 = if (y & 1 == 0) 0b10101010 else 0;
            const bit = @as(u8, 0x80) >> @as(u3, @intCast(x & 7));
            if (pattern & bit == 0) continue;
            const offset = y * stride + x / 8;
            if (white) frame[offset] |= bit else frame[offset] &= ~bit;
        }
    }
}

test "byte spotlight matches original pixels at every edge and preserves padding in both themes" {
    const stride = 52; // Playdate's two padding bytes per row.
    const width = 400;
    const height = 240;
    const actual = try std.testing.allocator.alloc(u8, stride * height + 16);
    defer std.testing.allocator.free(actual);
    const expected = try std.testing.allocator.alloc(u8, actual.len);
    defer std.testing.allocator.free(expected);
    const centers = [_][2]c_int{ .{ 0, 0 }, .{ 399, 0 }, .{ 0, 239 }, .{ 399, 239 }, .{ 8, 4 }, .{ 200, 120 }, .{ 391, 220 }, .{ -20, 120 }, .{ 420, 120 }, .{ 200, -20 }, .{ 200, 260 } };
    const diameters = [_]c_int{ 0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 23, 24, 25, 47, 48, 49, 399, 400, 401, 799, 800, 801, 1199, 1200 };
    for (centers) |center| {
        for (diameters) |size| {
            for ([_]bool{ false, true }) |white| {
                // Mixed underlying page bits catch both clearing and setting
                // errors, including an accidental write to row/guard padding.
                for (actual, 0..) |*byte, index| byte.* = @truncate(index *% 73 +% 29);
                @memcpy(expected, actual);
                paintCircle(actual[0 .. stride * height], stride, width, height, center[0], center[1], size, white);
                referenceCircle(expected, stride, width, height, center[0], center[1], size, white);
                try std.testing.expectEqualSlices(u8, expected, actual);
            }
        }
    }
}

test "spotlight partial bytes match original on a non-byte-aligned viewport" {
    var actual: [4 * 17]u8 = undefined;
    var expected: [4 * 17]u8 = undefined;
    for (0..24) |x| {
        for (0..34) |size| {
            @memset(&actual, 0x5a);
            @memcpy(&expected, &actual);
            paintCircle(&actual, 4, 23, 17, @intCast(x), 8, @intCast(size), false);
            referenceCircle(&expected, 4, 23, 17, @intCast(x), 8, @intCast(size), false);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
        }
    }
}

test "spotlight cancellation and clock wrap retain animation timing" {
    var state: State = .{};
    state.begin(std.math.maxInt(u32) - 100);
    try std.testing.expect(state.progress(50) != null);
    state.cancel();
    try std.testing.expect(state.progress(51) == null);
    state.begin(51);
    try std.testing.expectEqual(@as(u16, 0), state.progress(51).?);
    try std.testing.expect(state.progress(51 + total_ms) == null);
}
