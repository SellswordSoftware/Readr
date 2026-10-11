const std = @import("std");

/// Discard on font/metric changes. Cache tokens only; full lines still need measurement
/// for kerning.
pub const Cache = struct {
    pub const capacity = 8;
    pub const max_token_bytes = 64;
    const Entry = struct {
        text: [max_token_bytes]u8 = undefined,
        len: u8,
        width: usize,
    };

    entries: [capacity]Entry = undefined,
    count: u8 = 0,
    replacement: u8 = 0,

    pub fn lookup(self: *const Cache, text: []const u8) ?usize {
        if (text.len == 0 or text.len > max_token_bytes) return null;
        for (self.entries[0..self.count]) |*entry| {
            if (entry.len == text.len and std.mem.eql(u8, entry.text[0..entry.len], text)) return entry.width;
        }
        return null;
    }

    pub fn remember(self: *Cache, text: []const u8, width: usize) void {
        if (text.len == 0 or text.len > max_token_bytes) return;
        const slot = if (self.count < capacity) blk: {
            const next = self.count;
            self.count += 1;
            break :blk next;
        } else blk: {
            const next = self.replacement;
            self.replacement = (self.replacement + 1) % capacity;
            break :blk next;
        };
        const entry = &self.entries[slot];
        @memcpy(entry.text[0..text.len], text);
        entry.len = @intCast(text.len);
        entry.width = width;
    }
};

test "token cache matches full UTF-8 bytes and preserves zero and large exact widths" {
    var cache = Cache{};
    cache.remember("éV", 9);
    cache.remember("é", 0);
    cache.remember("- 東京", std.math.maxInt(usize));
    try std.testing.expectEqual(@as(?usize, 9), cache.lookup("éV"));
    try std.testing.expectEqual(@as(?usize, 0), cache.lookup("é"));
    try std.testing.expectEqual(@as(?usize, std.math.maxInt(usize)), cache.lookup("- 東京"));
    try std.testing.expect(cache.lookup("eV") == null);
    try std.testing.expect(cache.lookup("東京") == null);
}

test "token cache has bounded replacement and skips oversized text" {
    var cache = Cache{};
    for (0..Cache.capacity) |index| {
        const token = [_]u8{@intCast('a' + index)};
        cache.remember(&token, index);
    }
    cache.remember("new", 17);
    try std.testing.expect(cache.lookup("a") == null);
    try std.testing.expectEqual(@as(?usize, 1), cache.lookup("b"));
    try std.testing.expectEqual(@as(?usize, 17), cache.lookup("new"));
    const oversized = [_]u8{'x'} ** (Cache.max_token_bytes + 1);
    cache.remember(&oversized, 100);
    try std.testing.expect(cache.lookup(&oversized) == null);
    try std.testing.expectEqual(@as(u8, Cache.capacity), cache.count);
    try std.testing.expectEqual(@as(?usize, 17), cache.lookup("new"));
}
