const std = @import("std");

/// Share word boundaries across Pages, RSVP, and indexing so ordinals agree.
pub fn isBoundary(byte: u8) bool {
    return std.ascii.isWhitespace(byte);
}

/// Saturate ordinals instead of wrapping on oversized chapters.
pub const Counter = struct {
    next: u32 = 0,

    pub fn accept(self: *Counter) u32 {
        const ordinal = self.next;
        if (self.next != std.math.maxInt(u32)) self.next += 1;
        return ordinal;
    }

    pub fn count(self: Counter) u32 {
        return self.next;
    }
};

test "word boundaries are whitespace-only after XHTML normalization" {
    try std.testing.expect(isBoundary(' '));
    try std.testing.expect(isBoundary('\n'));
    try std.testing.expect(!isBoundary('.'));
    try std.testing.expect(!isBoundary('\''));
}

test "word ordinals are monotonic and do not wrap" {
    var counter = Counter{};
    try std.testing.expectEqual(@as(u32, 0), counter.accept());
    try std.testing.expectEqual(@as(u32, 1), counter.accept());
    counter.next = std.math.maxInt(u32);
    try std.testing.expectEqual(std.math.maxInt(u32), counter.accept());
    try std.testing.expectEqual(std.math.maxInt(u32), counter.accept());
}
