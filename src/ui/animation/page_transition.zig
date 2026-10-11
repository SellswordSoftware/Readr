const std = @import("std");

pub const band_count: u8 = 10;
pub const stagger_ms: u16 = 15;
pub const total_ms: u16 = 300;
pub const travel_ms: u16 = total_ms - stagger_ms * (band_count - 1);

pub const Direction = enum { forward, backward };

pub const Style = enum(u8) {
    bands = 0,
    slide = 1,
    paper_lift = 2,
    edge_wipe = 3,
    // Keep persisted IDs stable; 4 and 6 belonged to removed animations.
    corner_peel = 5,

    pub fn next(self: Style) Style {
        return switch (self) {
            .bands => .slide,
            .slide => .paper_lift,
            .paper_lift => .edge_wipe,
            .edge_wipe => .corner_peel,
            .corner_peel => .bands,
        };
    }

    pub fn label(self: Style) []const u8 {
        return switch (self) {
            .bands => "Bands",
            .slide => "Slide",
            .paper_lift => "Paper lift",
            .edge_wipe => "Edge wipe",
            .corner_peel => "Corner peel",
        };
    }

    pub fn duration(self: Style) u16 {
        return switch (self) {
            .bands, .corner_peel => 300,
            .slide, .edge_wipe => 220,
            .paper_lift => 260,
        };
    }
};

pub const State = struct {
    source_page: ?u32 = null,
    direction: Direction = .forward,
    started_at: u32 = 0,
    active: bool = false,
    style: Style = .bands,

    pub fn begin(self: *State, source_page: ?u32, direction: Direction, now_ms: u32) void {
        self.beginStyled(source_page, direction, .bands, now_ms);
    }

    pub fn beginStyled(self: *State, source_page: ?u32, direction: Direction, style: Style, now_ms: u32) void {
        self.* = .{ .source_page = source_page, .direction = direction, .style = style, .started_at = now_ms, .active = true };
    }

    pub fn cancel(self: *State) void {
        self.active = false;
    }

    pub fn elapsed(self: *State, now_ms: u32) ?u16 {
        if (!self.active) return null;
        const value = now_ms -% self.started_at;
        if (value >= self.style.duration()) {
            self.active = false;
            return null;
        }
        return @intCast(value);
    }
};

/// Returns 0..screen_width for one band's horizontal travel. Forward begins
/// at the bottom; backward begins at the top.
pub fn bandOffset(elapsed_ms: u16, band: u8, direction: Direction, screen_width: u16) u16 {
    std.debug.assert(band < band_count);
    const order: u16 = switch (direction) {
        .forward => band_count - 1 - band,
        .backward => band,
    };
    const delay = order * stagger_ms;
    if (elapsed_ms <= delay) return 0;
    const local = @min(elapsed_ms - delay, travel_ms);
    return @intCast((@as(u32, screen_width) * local) / travel_ms);
}

test "ten bands stagger within one 300ms transition" {
    try std.testing.expectEqual(@as(u16, 165), travel_ms);
    try std.testing.expectEqual(@as(u16, 0), bandOffset(1, 0, .forward, 400));
    try std.testing.expect(bandOffset(1, 9, .forward, 400) > 0);
    try std.testing.expect(bandOffset(1, 0, .backward, 400) > 0);
    try std.testing.expectEqual(@as(u16, 0), bandOffset(1, 9, .backward, 400));
    try std.testing.expectEqual(@as(u16, 400), bandOffset(300, 0, .forward, 400));
    try std.testing.expectEqual(@as(u16, 400), bandOffset(300, 9, .forward, 400));
}

test "all styles cycle once and stop at their own duration across clock wrap" {
    var style = Style.bands;
    for (std.enums.values(Style)) |expected| {
        try std.testing.expectEqual(expected, style);
        var state = State{};
        state.beginStyled(1, .backward, style, std.math.maxInt(u32) - 100);
        try std.testing.expectEqual(@as(?u16, 0), state.elapsed(state.started_at));
        try std.testing.expectEqual(@as(?u16, style.duration() - 1), state.elapsed(state.started_at +% (style.duration() - 1)));
        try std.testing.expect(state.elapsed(state.started_at +% style.duration()) == null);
        style = style.next();
    }
    try std.testing.expectEqual(Style.bands, style);
}
