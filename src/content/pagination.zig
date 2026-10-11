const std = @import("std");
const xhtml = @import("xhtml.zig");
const word_index = @import("word_index.zig");
const token_width_cache = @import("token_width_cache.zig");
const limits = @import("limits").reader;

pub const max_lines = limits.page_line_count;
pub const max_cached_line_bytes = limits.page_line_bytes;

test "full-screen reader pages hold eleven body lines" {
    try std.testing.expectEqual(@as(u8, 11), max_lines);
}

/// Owns drawable text so decoded source chunks can be discarded.
pub const PageCache = struct {
    lines: [max_lines][max_cached_line_bytes]u8 = undefined,
    lengths: [max_lines]u16 = [_]u16{0} ** max_lines,
    // List markers and dividers have no word ordinal. Prefix lengths let selection skip
    // them.
    line_synthetic_prefix_bytes: [max_lines]u16 = [_]u16{0} ** max_lines,
    line_continues_word: [max_lines]bool = [_]bool{false} ** max_lines,
    line_word_counts: [max_lines]u16 = [_]u16{0} ** max_lines,
    line_count: u8 = 0,
    // Distinct source words visible on this page. Adjacent pages overlap by
    // one ordinal when a word continues across their visual boundary.
    first_word_ordinal: u32 = 0,
    word_count: u32 = 0,
    last_word_continues: bool = false,

    pub fn clear(self: *PageCache) void {
        self.line_count = 0;
        @memset(&self.lengths, 0);
        @memset(&self.line_synthetic_prefix_bytes, 0);
        @memset(&self.line_word_counts, 0);
        @memset(&self.line_continues_word, false);
        self.first_word_ordinal = 0;
        self.word_count = 0;
        self.last_word_continues = false;
    }

    pub fn appendLine(self: *PageCache, text: []const u8) error{ PageFull, LineTooLong }!void {
        try self.appendLineWithMetadata(text, 0, 0);
    }

    pub fn appendLineWithMetadata(self: *PageCache, text: []const u8, synthetic_prefix_bytes: u16, source_word_count: u16) error{ PageFull, LineTooLong }!void {
        if (self.line_count == max_lines) return error.PageFull;
        if (text.len > max_cached_line_bytes) return error.LineTooLong;
        if (synthetic_prefix_bytes > text.len) return error.LineTooLong;
        const index: usize = self.line_count;
        @memcpy(self.lines[index][0..text.len], text);
        self.lengths[index] = @intCast(text.len);
        self.line_synthetic_prefix_bytes[index] = synthetic_prefix_bytes;
        self.line_word_counts[index] = source_word_count;
        self.line_count += 1;
    }

    pub fn line(self: *const PageCache, index: usize) []const u8 {
        return self.lines[index][0..self.lengths[index]];
    }

    /// Pace counts a word only when its final visual fragment is passed.
    pub fn completedWordCount(self: *const PageCache) u32 {
        return self.word_count - @as(u32, @intFromBool(self.last_word_continues and self.word_count != 0));
    }

    pub const WordSpan = struct {
        line_index: u8,
        start: u16,
        end: u16,
        last_line_index: u8 = 0,
    };

    /// Continuation lines start at the preceding line's final source word.
    pub fn lineFirstWordOrdinal(self: *const PageCache, wanted: usize) u32 {
        var ordinal = self.first_word_ordinal;
        var seen = false;
        for (0..self.line_count) |line_index| {
            const count = self.line_word_counts[line_index];
            if (count != 0 and self.line_continues_word[line_index] and seen) ordinal -= 1;
            if (line_index == wanted) return ordinal;
            ordinal += count;
            seen = seen or count != 0;
        }
        return ordinal;
    }

    pub fn wordSpanOnLine(self: *const PageCache, ordinal: u32, line_index: usize) ?WordSpan {
        if (line_index >= self.line_count) return null;
        const first = self.lineFirstWordOrdinal(line_index);
        if (ordinal < first or ordinal - first >= self.line_word_counts[line_index]) return null;
        const text = self.line(line_index);
        var offset: usize = self.line_synthetic_prefix_bytes[line_index];
        var found: u16 = 0;
        while (offset < text.len) {
            while (offset < text.len and word_index.isBoundary(text[offset])) : (offset += 1) {}
            const start = offset;
            while (offset < text.len and !word_index.isBoundary(text[offset])) : (offset += 1) {}
            if (start == offset) break;
            if (found == ordinal - first) return .{ .line_index = @intCast(line_index), .start = @intCast(start), .end = @intCast(offset), .last_line_index = @intCast(line_index) };
            found += 1;
        }
        return null;
    }

    pub fn wordSpan(self: *const PageCache, ordinal: u32) ?WordSpan {
        if (ordinal < self.first_word_ordinal or ordinal - self.first_word_ordinal >= self.word_count) return null;
        var result: ?WordSpan = null;
        for (0..self.line_count) |line_index| {
            if (self.wordSpanOnLine(ordinal, line_index)) |span| {
                if (result == null) result = span else result.?.last_line_index = @intCast(line_index);
            }
        }
        return result;
    }

    /// Returns the new selection only when it remains in this cached page.
    /// PagedReader handles selection that crosses a page boundary.
    pub fn moveSelection(self: *const PageCache, selected: ?u32, direction: i8) ?u32 {
        if (self.word_count == 0) return null;
        const first = self.first_word_ordinal;
        const current = selected orelse return first;
        if (current < first or current - first >= self.word_count) return first;
        if (direction > 0 and current - first + 1 < self.word_count) return current + 1;
        if (direction < 0 and current > first) return current - 1;
        return current;
    }
};

/// Retains an unfinished word and line across feeds; completed lines move into
/// PageCache.
pub const EventPageBuilder = struct {
    const PendingSemantic = enum { line_break, paragraph_break, heading, block_quote, list_item, divider };

    cache: *PageCache,
    measure: Measure,
    max_width: usize,
    line_limit: u8,
    word: [max_cached_line_bytes]u8 = undefined,
    word_len: usize = 0,
    word_width: ?usize = null,
    token_widths: token_width_cache.Cache = .{},
    word_offset: usize = 0,
    word_prefix_bytes: u16 = 0,
    split_ordinal: ?u32 = null,
    split_line_pending: bool = false,
    line_continues_word: bool = false,
    line: [max_cached_line_bytes]u8 = undefined,
    line_len: usize = 0,
    page_full: bool = false,
    source_word: bool = false,
    word_ordinals: word_index.Counter = .{},
    line_first_word_ordinal: ?u32 = null,
    line_source_word_count: u32 = 0,
    line_synthetic_prefix_bytes: u16 = 0,
    // Defer events that arrive on a full page until the carried line reaches the next
    // page.
    pending_semantic: ?PendingSemantic = null,

    pub fn init(cache: *PageCache, max_width: usize, measure: Measure) EventPageBuilder {
        cache.clear();
        return .{
            .cache = cache,
            .measure = measure,
            .max_width = max_width,
            .line_limit = @max(@as(u8, 1), @min(measure.line_limit, max_lines)),
        };
    }

    pub fn wordCount(self: *const EventPageBuilder) u32 {
        return self.word_ordinals.count();
    }

    pub fn consume(self: *EventPageBuilder, event: xhtml.Event) error{ PageFull, LineTooLong }!void {
        if (self.page_full) return error.PageFull;
        switch (event) {
            .text => |bytes| for (bytes) |byte| {
                if (word_index.isBoundary(byte)) try self.finishWord() else {
                    if (self.word_len == self.word.len) return error.LineTooLong;
                    if (self.word_len == 0) self.source_word = true;
                    self.word_width = null;
                    self.word[self.word_len] = byte;
                    self.word_len += 1;
                }
            },
            .line_break => try self.consumeSemantic(.line_break),
            .paragraph_break => try self.consumeSemantic(.paragraph_break),
            .heading => try self.consumeSemantic(.heading),
            .block_quote => try self.consumeSemantic(.block_quote),
            .list_item => try self.consumeSemantic(.list_item),
            .divider => try self.consumeSemantic(.divider),
        }
    }

    pub fn end(self: *EventPageBuilder) error{ PageFull, LineTooLong }!void {
        try self.finishLine();
    }

    /// Carry unfinished text into the next page.
    pub fn beginNextPage(self: *EventPageBuilder, cache: *PageCache) void {
        self.cache = cache;
        self.cache.clear();
        self.page_full = false;
        // The page-full result consumes boundary whitespace. Finalize the carried word
        // before feeding more text, or adjacent words merge and ordinals shift.
        self.finishWord() catch |err| switch (err) {
            error.PageFull => return,
            error.LineTooLong => unreachable,
        };
        if (self.pending_semantic) |event| {
            self.pending_semantic = null;
            self.consumeSemantic(event) catch |err| switch (err) {
                error.PageFull => return,
                error.LineTooLong => unreachable,
            };
        }
    }

    fn consumeSemantic(self: *EventPageBuilder, event: PendingSemantic) error{ PageFull, LineTooLong }!void {
        self.applySemantic(event) catch |err| switch (err) {
            error.PageFull => {
                self.pending_semantic = event;
                return error.PageFull;
            },
            error.LineTooLong => return error.LineTooLong,
        };
    }

    fn applySemantic(self: *EventPageBuilder, event: PendingSemantic) error{ PageFull, LineTooLong }!void {
        switch (event) {
            .line_break => try self.finishLine(),
            .paragraph_break => {
                try self.finishLine();
                if (!self.page_full and self.cache.line_count != 0) try self.appendLine("");
            },
            .heading, .block_quote => try self.finishLine(),
            .list_item => {
                try self.finishLine();
                try self.addSyntheticWord("- ");
            },
            .divider => {
                try self.finishLine();
                try self.appendLine("---");
            },
        }
    }

    fn addSyntheticWord(self: *EventPageBuilder, bytes: []const u8) error{ PageFull, LineTooLong }!void {
        self.word_width = null;
        // The list marker shares the drawable token but not its ordinal; selection
        // skips the prefix.
        self.source_word = true;
        self.line_synthetic_prefix_bytes = @intCast(bytes.len);
        self.word_prefix_bytes = @intCast(bytes.len);
        for (bytes) |byte| {
            if (self.word_len == self.word.len) return error.LineTooLong;
            self.word[self.word_len] = byte;
            self.word_len += 1;
        }
    }

    fn measureWord(self: *EventPageBuilder) usize {
        if (self.word_width) |width| return width;
        const text = self.word[0..self.word_len];
        const width = self.token_widths.lookup(text) orelse blk: {
            const measured = self.measure.width(self.measure.context, text);
            self.token_widths.remember(text, measured);
            break :blk measured;
        };
        // Retain the finished token width across PageFull retries, including
        // tokens too long for the shared short-token cache.
        self.word_width = width;
        return width;
    }

    fn finishWord(self: *EventPageBuilder) error{ PageFull, LineTooLong }!void {
        if (self.word_len == 0) return;
        if (self.split_ordinal != null or self.measureWord() > self.max_width) {
            try self.finishSplitWord();
            return;
        }
        const line_was_empty = self.line_len == 0;
        const extra: usize = if (self.line_len == 0) 0 else 1;
        const candidate_len = self.line_len + extra + self.word_len;
        const exceeds_capacity = candidate_len > self.line.len;
        // Measure in the heap-owned line buffer; a stack copy is too large on device.
        if (!exceeds_capacity) {
            if (extra != 0) self.line[self.line_len] = ' ';
            @memcpy(self.line[self.line_len + extra .. candidate_len], self.word[0..self.word_len]);
        }
        if (self.line_len != 0 and (exceeds_capacity or self.measure.width(self.measure.context, self.line[0..candidate_len]) > self.max_width)) {
            try self.appendLine(self.line[0..self.line_len]);
            if (self.page_full) return error.PageFull;
            @memcpy(self.line[0..self.word_len], self.word[0..self.word_len]);
            self.line_len = self.word_len;
        } else {
            self.line_len = candidate_len;
        }
        if (self.source_word) self.recordSourceWord();
        if (!self.source_word and line_was_empty) self.line_synthetic_prefix_bytes = @intCast(self.line_len);
        self.word_len = 0;
        self.word_width = null;
        self.word_prefix_bytes = 0;
        self.source_word = false;
    }

    fn finishSplitWord(self: *EventPageBuilder) error{ PageFull, LineTooLong }!void {
        if (self.split_line_pending) {
            try self.appendLine(self.line[0..self.line_len]);
            self.split_line_pending = false;
        } else if (self.line_len != 0) {
            try self.appendLine(self.line[0..self.line_len]);
        }
        while (self.word_offset < self.word_len) {
            const start = self.word_offset;
            var fragment_end = start;
            while (fragment_end < self.word_len) {
                var next = fragment_end + 1;
                while (next < self.word_len and self.word[next] & 0xc0 == 0x80) : (next += 1) {}
                // Never split UTF-8 or strand a synthetic list marker by itself.
                const width = self.measure.width(self.measure.context, self.word[start..next]);
                if (width > self.max_width and fragment_end > start and fragment_end > self.word_prefix_bytes) break;
                fragment_end = next;
                if (width > self.max_width and fragment_end > self.word_prefix_bytes) break;
            }
            if (self.split_ordinal == null) self.split_ordinal = self.word_ordinals.accept();
            @memcpy(self.line[0 .. fragment_end - start], self.word[start..fragment_end]);
            self.line_len = fragment_end - start;
            self.line_first_word_ordinal = self.split_ordinal;
            self.line_source_word_count = 1;
            self.line_continues_word = start != 0;
            self.line_synthetic_prefix_bytes = if (start == 0) self.word_prefix_bytes else 0;
            self.word_offset = fragment_end;
            self.split_line_pending = true;
            try self.appendLine(self.line[0..self.line_len]);
            self.split_line_pending = false;
        }
        self.word_len = 0;
        self.word_width = null;
        self.word_offset = 0;
        self.word_prefix_bytes = 0;
        self.split_ordinal = null;
        self.source_word = false;
    }

    fn recordSourceWord(self: *EventPageBuilder) void {
        const ordinal = self.word_ordinals.accept();
        if (self.line_source_word_count == 0) self.line_first_word_ordinal = ordinal;
        self.line_source_word_count += 1;
    }

    fn finishLine(self: *EventPageBuilder) error{ PageFull, LineTooLong }!void {
        try self.finishWord();
        if (self.line_len != 0) try self.appendLine(self.line[0..self.line_len]);
    }

    fn appendLine(self: *EventPageBuilder, text: []const u8) error{ PageFull, LineTooLong }!void {
        if (self.cache.line_count >= self.line_limit) {
            if (self.line_continues_word) self.cache.last_word_continues = true;
            self.page_full = true;
            return error.PageFull;
        }
        const index = self.cache.line_count;
        self.cache.appendLineWithMetadata(text, self.line_synthetic_prefix_bytes, @intCast(self.line_source_word_count)) catch |err| switch (err) {
            error.PageFull => {
                self.page_full = true;
                return error.PageFull;
            },
            error.LineTooLong => return error.LineTooLong,
        };
        self.cache.line_continues_word[index] = self.line_continues_word;
        if (self.line_source_word_count != 0) {
            const repeated: u32 = if (self.line_continues_word and self.cache.word_count != 0) 1 else 0;
            if (self.cache.word_count == 0) self.cache.first_word_ordinal = self.line_first_word_ordinal.?;
            self.cache.word_count += self.line_source_word_count - repeated;
            self.line_first_word_ordinal = null;
            self.line_source_word_count = 0;
        }
        self.line_synthetic_prefix_bytes = 0;
        self.line_continues_word = false;
        self.line_len = 0;
    }
};

/// Keep metrics fixed for the builder lifetime. Font changes need a new builder;
/// candidate lines and split fragments bypass token caching.
pub const Measure = struct {
    context: *anyopaque,
    width: *const fn (context: *anyopaque, text: []const u8) usize,
    line_limit: u8 = max_lines,
};

fn monospaceWidth(_: *anyopaque, text: []const u8) usize {
    return text.len;
}

const BuilderEvents = struct {
    builder: *EventPageBuilder,

    fn emit(context: *anyopaque, event: xhtml.Event) anyerror!void {
        const self: *BuilderEvents = @ptrCast(@alignCast(context));
        try self.builder.consume(event);
    }
};

test "page cache owns completed lines without chapter source storage" {
    var cache = PageCache{};
    try cache.appendLine("First line");
    try cache.appendLine("Second line");
    try std.testing.expectEqual(@as(u8, 2), cache.line_count);
    try std.testing.expectEqualStrings("First line", cache.line(0));
    try std.testing.expectEqualStrings("Second line", cache.line(1));
}

test "event page builder owns wrapped lines" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, 7, .{ .context = &context, .width = monospaceWidth });
    try builder.consume(.{ .text = "one two three" });
    try builder.end();
    try std.testing.expectEqualStrings("one two", cache.line(0));
    try std.testing.expectEqualStrings("three", cache.line(1));
    try std.testing.expectEqual(@as(u32, 0), cache.first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 3), cache.word_count);
}

test "wide word fragments share one ordinal and one selection span" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, 4, .{ .context = &context, .width = monospaceWidth });
    try builder.consume(.{ .text = "one abcdefghij two" });
    try builder.end();
    const expected = [_][]const u8{ "one", "abcd", "efgh", "ij", "two" };
    for (expected, 0..) |text, index| try std.testing.expectEqualStrings(text, cache.line(index));
    try std.testing.expectEqual(@as(u32, 3), builder.wordCount());
    try std.testing.expectEqual(@as(u32, 3), cache.word_count);
    const span = cache.wordSpan(1).?;
    try std.testing.expectEqual(@as(u8, 1), span.line_index);
    try std.testing.expectEqual(@as(u8, 3), span.last_line_index);
    try std.testing.expectEqual(@as(u32, 1), cache.lineFirstWordOrdinal(3));
    try std.testing.expectEqual(@as(u32, 2), cache.lineFirstWordOrdinal(4));
}

test "split word survives several full pages and replays a following list event once" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, 3, .{ .context = &context, .width = monospaceWidth, .line_limit = 1 });
    try builder.consume(.{ .text = "abcdefghij" });
    try std.testing.expectError(error.PageFull, builder.consume(.list_item));
    try std.testing.expectEqualStrings("abc", cache.line(0));
    const remaining = [_][]const u8{ "def", "ghi", "j" };
    for (remaining) |text| {
        builder.beginNextPage(&cache);
        try std.testing.expectEqualStrings(text, cache.line(0));
        try std.testing.expectEqual(@as(u32, 0), cache.first_word_ordinal);
        try std.testing.expectEqual(@as(u32, 1), cache.word_count);
        try std.testing.expect(cache.line_continues_word[0]);
        try std.testing.expectEqual(@as(u32, 1), builder.wordCount());
    }
    try builder.consume(.{ .text = "next" });
    try std.testing.expectError(error.PageFull, builder.end());
    builder.beginNextPage(&cache);
    try std.testing.expectEqualStrings("- n", cache.line(0));
    try std.testing.expectEqual(@as(u16, 2), cache.wordSpan(1).?.start);
    try std.testing.expectError(error.PageFull, builder.end());
    builder.beginNextPage(&cache);
    try builder.end();
    try std.testing.expectEqualStrings("ext", cache.line(0));
    try std.testing.expectEqual(@as(u32, 1), cache.first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 2), builder.wordCount());
}

test "wide UTF-8 words split only between complete codepoints at every text chunk" {
    const source = "é東京🙂é";
    for (0..source.len + 1) |split| {
        var context: u8 = 0;
        var cache = PageCache{};
        var builder = EventPageBuilder.init(&cache, 4, .{ .context = &context, .width = monospaceWidth });
        try builder.consume(.{ .text = source[0..split] });
        try builder.consume(.{ .text = source[split..] });
        try builder.end();
        var joined: [source.len]u8 = undefined;
        var len: usize = 0;
        for (0..cache.line_count) |index| {
            const text = cache.line(index);
            try std.testing.expect(text.len <= 4);
            try std.testing.expect(std.unicode.utf8ValidateSlice(text));
            @memcpy(joined[len .. len + text.len], text);
            len += text.len;
        }
        try std.testing.expectEqualStrings(source, joined[0..len]);
        try std.testing.expectEqual(@as(u32, 1), cache.word_count);
        try std.testing.expectEqual(@as(u32, 1), builder.wordCount());
    }
}

test "byte capacity wraps a near-capacity word instead of rejecting the combined line" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, max_cached_line_bytes, .{ .context = &context, .width = monospaceWidth });
    const maximum = [_]u8{'x'} ** max_cached_line_bytes;
    try builder.consume(.{ .text = "short " });
    try builder.consume(.{ .text = &maximum });
    try builder.end();
    try std.testing.expectEqualStrings("short", cache.line(0));
    try std.testing.expectEqualStrings(&maximum, cache.line(1));
    try std.testing.expectEqual(@as(u32, 2), cache.word_count);
    const span = cache.wordSpan(1).?;
    try std.testing.expectEqual(@as(u8, 1), span.line_index);
    try std.testing.expectEqual(@as(u16, max_cached_line_bytes), span.end);
}

test "byte capacity wrapping carries the word across a full page without ordinal drift" {
    var context: u8 = 0;
    var current = PageCache{};
    var next = PageCache{};
    var builder = EventPageBuilder.init(&current, max_cached_line_bytes, .{ .context = &context, .width = monospaceWidth, .line_limit = 1 });
    try builder.consume(.{ .text = "first " });
    try builder.consume(.line_break);
    try builder.consume(.{ .text = "short " });
    const maximum = [_]u8{'x'} ** max_cached_line_bytes;
    try builder.consume(.{ .text = &maximum });
    try std.testing.expectError(error.PageFull, builder.consume(.{ .text = " " }));
    builder.beginNextPage(&next);
    try std.testing.expectError(error.PageFull, builder.end());
    try std.testing.expectEqualStrings("short", next.line(0));
    try std.testing.expectEqual(@as(u32, 1), next.first_word_ordinal);
    builder.beginNextPage(&current);
    try builder.end();
    try std.testing.expectEqualStrings(&maximum, current.line(0));
    try std.testing.expectEqual(@as(u32, 2), current.first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 1), current.word_count);
    try std.testing.expectEqual(@as(u32, 3), builder.wordCount());
}

test "a source token above the retained byte limit remains an explicit error" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, max_cached_line_bytes, .{ .context = &context, .width = monospaceWidth });
    const oversized = [_]u8{'x'} ** (max_cached_line_bytes + 1);
    try std.testing.expectError(error.LineTooLong, builder.consume(.{ .text = &oversized }));
}

test "page ordinal metadata survives text chunk boundaries" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, 80, .{ .context = &context, .width = monospaceWidth });
    try builder.consume(.{ .text = "one " });
    try builder.consume(.{ .text = "two" });
    try builder.consume(.paragraph_break);
    try builder.consume(.{ .text = "three" });
    try builder.end();
    try std.testing.expectEqual(@as(u32, 0), cache.first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 3), cache.word_count);
}

test "page cache derives the selected source-word span" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, 7, .{ .context = &context, .width = monospaceWidth });
    try builder.consume(.{ .text = "one two three" });
    try builder.end();

    const first = cache.wordSpan(0).?;
    try std.testing.expectEqual(@as(u8, 0), first.line_index);
    try std.testing.expectEqualStrings("one", cache.line(first.line_index)[first.start..first.end]);
    const last = cache.wordSpan(2).?;
    try std.testing.expectEqual(@as(u8, 1), last.line_index);
    try std.testing.expectEqualStrings("three", cache.line(last.line_index)[last.start..last.end]);
    try std.testing.expect(cache.wordSpan(3) == null);
}

test "selection moves one word without leaving the cached page" {
    var cache = PageCache{ .first_word_ordinal = 7, .word_count = 3 };
    try std.testing.expectEqual(@as(?u32, 7), cache.moveSelection(null, 1));
    try std.testing.expectEqual(@as(?u32, 8), cache.moveSelection(7, 1));
    try std.testing.expectEqual(@as(?u32, 9), cache.moveSelection(9, 1));
    try std.testing.expectEqual(@as(?u32, 7), cache.moveSelection(7, -1));
    try std.testing.expectEqual(@as(?u32, 8), cache.moveSelection(9, -1));
}

test "a carried line assigns its words to the next page ordinal range" {
    var context: u8 = 0;
    var current = PageCache{};
    var next = PageCache{};
    var builder = EventPageBuilder.init(&current, 1, .{ .context = &context, .width = monospaceWidth });
    const words = [_][]const u8{ "a ", "b ", "c ", "d ", "e ", "f ", "g ", "h ", "i ", "j ", "k ", "l ", "m " };
    for (words[0..12]) |chunk| try builder.consume(.{ .text = chunk });
    try std.testing.expectError(error.PageFull, builder.consume(.{ .text = words[12] }));
    try std.testing.expectEqual(@as(u8, max_lines), current.line_count);
    try std.testing.expectEqual(@as(u32, max_lines), current.word_count);
    try std.testing.expectEqual(@as(u32, 0), current.first_word_ordinal);

    builder.beginNextPage(&next);
    try builder.end();
    try std.testing.expectEqualStrings("l", next.line(0));
    try std.testing.expectEqualStrings("m", next.line(1));
    try std.testing.expectEqual(@as(u32, max_lines), next.first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 2), next.word_count);
    const first_next = next.wordSpan(max_lines).?;
    try std.testing.expectEqualStrings("l", next.line(first_next.line_index)[first_next.start..first_next.end]);
}

test "tokenizer page boundaries preserve every carried word ordinal" {
    var context: u8 = 0;
    var pages: [3]PageCache = undefined;
    var builder = EventPageBuilder.init(&pages[0], 1, .{ .context = &context, .width = monospaceWidth });
    var events = BuilderEvents{ .builder = &builder };
    var extractor = xhtml.StreamExtractor.init(.{ .context = &events, .emit = BuilderEvents.emit });
    const source = "a b c d e f g h i j k l m n o p q r s t u v w x y";
    var page_index: usize = 0;
    for (source) |byte| {
        switch (try extractor.feed(&[_]u8{byte})) {
            .consumed => {},
            .page_full => {
                page_index += 1;
                try std.testing.expect(page_index < pages.len);
                builder.beginNextPage(&pages[page_index]);
            },
        }
    }
    try extractor.finish();
    try builder.end();

    try std.testing.expectEqual(@as(u32, 0), pages[0].first_word_ordinal);
    try std.testing.expectEqual(@as(u32, max_lines), pages[0].word_count);
    try std.testing.expectEqual(@as(u32, max_lines), pages[1].first_word_ordinal);
    try std.testing.expectEqual(@as(u32, max_lines), pages[1].word_count);
    try std.testing.expectEqual(@as(u32, max_lines * 2), pages[2].first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 3), pages[2].word_count);
    const first_second = pages[1].wordSpan(max_lines).?;
    try std.testing.expectEqualStrings("l", pages[1].line(first_second.line_index)[first_second.start..first_second.end]);
    const first_third = pages[2].wordSpan(max_lines * 2).?;
    try std.testing.expectEqualStrings("w", pages[2].line(first_third.line_index)[first_third.start..first_third.end]);
}

test "replays a list marker after a page-full carried line" {
    var context: u8 = 0;
    var current = PageCache{};
    var next = PageCache{};
    var builder = EventPageBuilder.init(&current, 80, .{ .context = &context, .width = monospaceWidth });
    for (0..max_lines) |_| try current.appendLine("filled");
    try builder.consume(.{ .text = "before" });
    try std.testing.expectError(error.PageFull, builder.consume(.list_item));

    builder.beginNextPage(&next);
    try builder.consume(.{ .text = "item" });
    try builder.end();
    try std.testing.expectEqualStrings("before", next.line(0));
    try std.testing.expectEqualStrings("- item", next.line(1));
    try std.testing.expectEqual(@as(u32, 2), next.word_count);
    const item = next.wordSpan(1).?;
    try std.testing.expectEqualStrings("item", next.line(item.line_index)[item.start..item.end]);
}

test "replays a divider after a page-full carried line" {
    var context: u8 = 0;
    var current = PageCache{};
    var next = PageCache{};
    var builder = EventPageBuilder.init(&current, 80, .{ .context = &context, .width = monospaceWidth });
    for (0..max_lines) |_| try current.appendLine("filled");
    try builder.consume(.{ .text = "before" });
    try std.testing.expectError(error.PageFull, builder.consume(.divider));

    builder.beginNextPage(&next);
    try std.testing.expectEqualStrings("before", next.line(0));
    try std.testing.expectEqualStrings("---", next.line(1));
}

test "maximum retained word wraps over many pages without truncation or extra ordinals" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, 4, .{ .context = &context, .width = monospaceWidth, .line_limit = 1 });
    const word = [_]u8{'x'} ** max_cached_line_bytes;
    try builder.consume(.{ .text = &word });
    try std.testing.expectError(error.PageFull, builder.consume(.{ .text = " " }));
    var bytes: usize = 0;
    var completed: u32 = 0;
    for (0..max_cached_line_bytes / 4) |index| {
        try std.testing.expectEqualStrings("xxxx", cache.line(0));
        try std.testing.expectEqual(@as(u32, 0), cache.first_word_ordinal);
        try std.testing.expectEqual(@as(u32, 1), cache.word_count);
        bytes += cache.line(0).len;
        completed += cache.completedWordCount();
        if (index + 1 < max_cached_line_bytes / 4) builder.beginNextPage(&cache);
    }
    try std.testing.expectEqual(max_cached_line_bytes, bytes);
    try std.testing.expectEqual(@as(u32, 1), completed);
    try std.testing.expectEqual(@as(u32, 1), builder.wordCount());
    try builder.consume(.{ .text = "z" });
    try std.testing.expectError(error.PageFull, builder.end());
    builder.beginNextPage(&cache);
    try builder.end();
    try std.testing.expectEqualStrings("z", cache.line(0));
    try std.testing.expectEqual(@as(u32, 1), cache.first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 2), builder.wordCount());
}

const ContextualMeasure = struct {
    scale: usize = 1,
    calls: usize = 0,
    bytes: usize = 0,

    fn width(context: *anyopaque, text: []const u8) usize {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.bytes += text.len;
        const utf8 = std.unicode.Utf8View.init(text) catch unreachable;
        var iter = utf8.iterator();
        var result: usize = 0;
        var previous: u21 = 0;
        var before_previous: u21 = 0;
        while (iter.nextCodepoint()) |codepoint| {
            result += (if (codepoint == ' ') @as(usize, 3) else 9) * self.scale;
            if ((previous == 'A' and codepoint == 'V') or (previous == 'T' and codepoint == 'o') or
                (before_previous == 'A' and previous == ' ' and codepoint == 'V')) result -= 2 * self.scale;
            before_previous = previous;
            previous = codepoint;
        }
        return result;
    }
};

fn expectSamePage(a: *const PageCache, b: *const PageCache) !void {
    try std.testing.expectEqual(a.line_count, b.line_count);
    try std.testing.expectEqual(a.first_word_ordinal, b.first_word_ordinal);
    try std.testing.expectEqual(a.word_count, b.word_count);
    try std.testing.expectEqual(a.last_word_continues, b.last_word_continues);
    for (0..a.line_count) |index| {
        try std.testing.expectEqualStrings(a.line(index), b.line(index));
        try std.testing.expectEqual(a.line_synthetic_prefix_bytes[index], b.line_synthetic_prefix_bytes[index]);
        try std.testing.expectEqual(a.line_continues_word[index], b.line_continues_word[index]);
        try std.testing.expectEqual(a.line_word_counts[index], b.line_word_counts[index]);
        try std.testing.expectEqual(a.lineFirstWordOrdinal(index), b.lineFirstWordOrdinal(index));
    }
    for (a.first_word_ordinal..a.first_word_ordinal + a.word_count) |word| {
        try std.testing.expectEqual(a.wordSpan(@intCast(word)), b.wordSpan(@intCast(word)));
    }
}

fn comparePaginationStep(cached: *EventPageBuilder, uncached: *EventPageBuilder, event: ?xhtml.Event) !void {
    // Clear only memoization so the control builder measures each token directly.
    uncached.token_widths = .{};
    uncached.word_width = null;
    const a = if (event) |value| cached.consume(value) else cached.end();
    const b = if (event) |value| uncached.consume(value) else uncached.end();
    try std.testing.expectEqual(a, b);
    if (a) |_| {} else |err| try std.testing.expectEqual(error.PageFull, err);
    while (cached.page_full) {
        try expectSamePage(cached.cache, uncached.cache);
        uncached.token_widths = .{};
        uncached.word_width = null;
        cached.beginNextPage(cached.cache);
        uncached.beginNextPage(uncached.cache);
        try std.testing.expectEqual(cached.page_full, uncached.page_full);
    }
}

test "token memoization preserves contextual wrapping UTF-8 split spans and synthetic prefixes" {
    const text = "AV To éV 東京🙂 A V AV To extraordinarilylongword éV 東京🙂 ";
    // Vary layout metrics to catch cached widths changing page breaks.
    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7 }) |scale| for ([_]usize{ 15, 40, 80, 384 }) |width| for ([_]u8{ 1, 3, max_lines }) |line_limit| {
        var cached_metrics = ContextualMeasure{ .scale = scale };
        var direct_metrics = ContextualMeasure{ .scale = scale };
        var cached_page = PageCache{};
        var direct_page = PageCache{};
        var cached = EventPageBuilder.init(&cached_page, width, .{ .context = &cached_metrics, .width = ContextualMeasure.width, .line_limit = line_limit });
        var direct = EventPageBuilder.init(&direct_page, width, .{ .context = &direct_metrics, .width = ContextualMeasure.width, .line_limit = line_limit });
        for (0..4) |_| {
            try comparePaginationStep(&cached, &direct, .list_item);
            for (text) |byte| try comparePaginationStep(&cached, &direct, .{ .text = &.{byte} });
            try comparePaginationStep(&cached, &direct, .paragraph_break);
            try comparePaginationStep(&cached, &direct, .divider);
        }
        try comparePaginationStep(&cached, &direct, null);
        try expectSamePage(&cached_page, &direct_page);
        try std.testing.expectEqual(cached.wordCount(), direct.wordCount());
        try std.testing.expect(cached_metrics.calls <= direct_metrics.calls);
    };
}

test "repeated words avoid isolated measurements while every candidate keeps exact measurement" {
    var metrics = ContextualMeasure{};
    var page = PageCache{};
    var builder = EventPageBuilder.init(&page, 1000, .{ .context = &metrics, .width = ContextualMeasure.width });
    for (0..40) |_| try builder.consume(.{ .text = "AV " });
    try builder.end();
    try std.testing.expectEqual(@as(usize, 40), metrics.calls); // One token measurement plus 39 full candidate measurements.
    try std.testing.expectEqual(@as(u8, 1), page.line_count);
    try std.testing.expectEqual(@as(u32, 40), page.word_count);
    try std.testing.expectEqual(@as(usize, 119), page.line(0).len);
    // Recreating the builder after a font change must remeasure the token.
    metrics.scale = 2;
    builder = EventPageBuilder.init(&page, 1000, .{ .context = &metrics, .width = ContextualMeasure.width });
    try builder.consume(.{ .text = "AV " });
    try builder.end();
    try std.testing.expectEqual(@as(usize, 41), metrics.calls);
}

test "an oversized uncached token retains its exact width across PageFull retries" {
    const Counter = struct {
        long_calls: usize = 0,
        fn width(context: *anyopaque, text: []const u8) usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (text.len == 80) self.long_calls += 1;
            return text.len;
        }
    };
    var metrics = Counter{};
    var page = PageCache{};
    var builder = EventPageBuilder.init(&page, 80, .{ .context = &metrics, .width = Counter.width, .line_limit = 1 });
    try page.appendLine("filled");
    try builder.consume(.{ .text = "A " });
    const long_word = [_]u8{'x'} ** 80;
    try builder.consume(.{ .text = &long_word });
    try std.testing.expectError(error.PageFull, builder.consume(.{ .text = " " }));
    try std.testing.expectEqual(@as(usize, 1), metrics.long_calls);
    builder.beginNextPage(&page);
    try std.testing.expectEqual(@as(usize, 1), metrics.long_calls);
    try std.testing.expectEqual(@as(u32, 2), builder.wordCount());
    try std.testing.expectError(error.PageFull, builder.end());
    builder.beginNextPage(&page);
    try builder.end();
    try std.testing.expectEqualStrings(&long_word, page.line(0));
}
