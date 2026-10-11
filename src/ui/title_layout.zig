const std = @import("std");

pub const capacity = 20;
pub const max_title_bytes = 128;
pub const Measure = struct {
    context: *anyopaque,
    width: *const fn (*anyopaque, []const u8, usize) i32,
};
pub const Entry = struct {
    title: [max_title_bytes]u8 = undefined,
    title_len: usize = 0,
    label: [max_title_bytes]u8 = undefined,
    label_len: usize = 0,
    font: usize = 0,
    available_width: i32 = 0,
    full_width: i32 = 0,
    valid: bool = false,
    pub fn text(self: *const Entry) []const u8 {
        return self.label[0..self.label_len];
    }
};

/// Copy title bytes into the bounded cache so mutable source slices cannot leave stale
/// metrics.
pub const Cache = struct {
    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    next: usize = 0,
    pub fn layout(self: *Cache, title: []const u8, font: usize, width: i32, measure: Measure) *const Entry {
        std.debug.assert(title.len <= max_title_bytes);
        for (&self.entries) |*entry| {
            if (entry.valid and entry.font == font and entry.available_width == width and std.mem.eql(u8, title, entry.title[0..entry.title_len])) return entry;
        }
        const entry = &self.entries[self.next];
        self.next = (self.next + 1) % capacity;
        @memcpy(entry.title[0..title.len], title);
        entry.title_len = title.len;
        entry.font = font;
        entry.available_width = width;
        entry.full_width = measure.width(measure.context, title, font);
        entry.valid = true;
        if (entry.full_width <= width) {
            @memcpy(entry.label[0..title.len], title);
            entry.label_len = title.len;
            return entry;
        }
        const ellipsis = "...";
        const ellipsis_width = measure.width(measure.context, ellipsis, font);
        const limit = @min(title.len, max_title_bytes - ellipsis.len);
        var end: usize = 0;
        while (end < limit) {
            var next = end + 1;
            while (next < title.len and title[next] & 0xc0 == 0x80) : (next += 1) {}
            if (next > limit or next <= end or measure.width(measure.context, title[0..next], font) + ellipsis_width > width) break;
            end = next;
        }
        @memcpy(entry.label[0..end], title[0..end]);
        @memcpy(entry.label[end..][0..ellipsis.len], ellipsis);
        entry.label_len = end + ellipsis.len;
        return entry;
    }
};

pub const Marquee = struct {
    started_at: u32 = 0,
    distance: i32 = 0,
    pub fn offset(self: Marquee, now_ms: u32) i32 {
        if (self.distance <= 0) return 0;
        const pause_ms: u32 = 600;
        const travel_ms: u32 = @intCast(@divTrunc(self.distance * 1000 + 59, 60));
        const phase = (now_ms -% self.started_at) % (pause_ms * 2 + travel_ms * 2);
        if (phase < pause_ms) return 0;
        if (phase < pause_ms + travel_ms) return @min(self.distance, @as(i32, @intCast((phase - pause_ms) * 60 / 1000)));
        if (phase < pause_ms * 2 + travel_ms) return self.distance;
        return @max(@as(i32, 0), self.distance - @as(i32, @intCast((phase - pause_ms * 2 - travel_ms) * 60 / 1000)));
    }
};

const CountingMeasure = struct {
    calls: usize = 0,
    fn width(context: *anyopaque, text: []const u8, font: usize) i32 {
        const self: *CountingMeasure = @ptrCast(@alignCast(context));
        self.calls += 1;
        return @intCast(text.len * font);
    }
    fn port(self: *CountingMeasure) Measure {
        return .{ .context = self, .width = width };
    }
};

test "title layouts reuse measurements and invalidate by exact content font and width" {
    var cache = Cache{};
    var measure = CountingMeasure{};
    const title = "A long book title";
    const label = cache.layout(title, 2, 20, measure.port()).text();
    try std.testing.expectEqualStrings("A long ...", label);
    const initial = measure.calls;
    for (0..120) |_| _ = cache.layout(title, 2, 20, measure.port());
    try std.testing.expectEqual(initial, measure.calls);
    _ = cache.layout(title, 1, 20, measure.port());
    try std.testing.expect(measure.calls > initial);
    const after_font = measure.calls;
    _ = cache.layout(title, 2, 30, measure.port());
    try std.testing.expect(measure.calls > after_font);
    var borrowed = [_]u8{ 'o', 'n', 'e' };
    _ = cache.layout(&borrowed, 1, 20, measure.port());
    borrowed[0] = 'O';
    try std.testing.expectEqualStrings("One", cache.layout(&borrowed, 1, 20, measure.port()).text());
}

test "bounded title eviction preserves UTF-8 truncation and recomputes expired entries" {
    var cache = Cache{};
    var measure = CountingMeasure{};
    try std.testing.expectEqualStrings("caf...", cache.layout("café longer", 1, 7, measure.port()).text());
    const maximum = [_]u8{'a'} ** max_title_bytes;
    const longest = cache.layout(&maximum, 1, 127, measure.port()).text();
    try std.testing.expectEqual(@as(usize, 127), longest.len);
    for (0..capacity + 1) |index| {
        var buffer: [16]u8 = undefined;
        const title = try std.fmt.bufPrint(&buffer, "book-{d}", .{index});
        _ = cache.layout(title, 1, 20, measure.port());
    }
    const initial = measure.calls;
    _ = cache.layout("café longer", 1, 7, measure.port());
    try std.testing.expect(measure.calls > initial);
}

test "marquee uses elapsed time through pauses and clock wraparound" {
    for ([_]u32{ 100, 0xfffffff0 }) |start| {
        const marquee = Marquee{ .started_at = start, .distance = 60 };
        try std.testing.expectEqual(@as(i32, 0), marquee.offset(start +% 599));
        try std.testing.expectEqual(@as(i32, 30), marquee.offset(start +% 1100));
        try std.testing.expectEqual(@as(i32, 60), marquee.offset(start +% 1600));
        try std.testing.expectEqual(@as(i32, 30), marquee.offset(start +% 2700));
        try std.testing.expectEqual(@as(i32, 0), marquee.offset(start +% 3200));
        // Extra calls at any update/draw rate cannot advance animation time.
        for (0..100) |_| try std.testing.expectEqual(@as(i32, 30), marquee.offset(start +% 1100));
    }
}
