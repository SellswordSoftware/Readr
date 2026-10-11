const std = @import("std");
const xhtml = @import("xhtml.zig");
const word_index = @import("word_index.zig");

/// Slots own their word text; the reader sets the history-window size.
pub const max_word_bytes = 384;
pub const default_wpm: u16 = 300;
pub const min_wpm: u16 = 100;
pub const max_wpm: u16 = 1000;
pub const wpm_step: u16 = 25;

pub fn validateWpm(wpm: u16) ?u16 {
    if (wpm < min_wpm or wpm > max_wpm or (wpm - min_wpm) % wpm_step != 0) return null;
    return wpm;
}

pub fn clampWpm(wpm: u16) u16 {
    if (wpm <= min_wpm) return min_wpm;
    if (wpm >= max_wpm) return max_wpm;
    return min_wpm + @divTrunc(wpm - min_wpm, wpm_step) * wpm_step;
}

pub fn adjustWpm(wpm: u16, direction: i8) u16 {
    const value = clampWpm(wpm);
    if (direction > 0) return @min(max_wpm, value + wpm_step);
    if (direction < 0) return @max(min_wpm, value - wpm_step);
    return value;
}

/// Advance at most one word per elapsed interval, regardless of update frequency.
pub const Timer = struct {
    running: bool = false,
    last_ms: u32 = 0,

    pub fn start(self: *Timer, now_ms: u32) void {
        self.running = true;
        self.last_ms = now_ms;
    }

    pub fn stop(self: *Timer) void {
        self.running = false;
    }

    pub fn reset(self: *Timer, now_ms: u32) void {
        self.last_ms = now_ms;
    }

    pub fn due(self: *Timer, now_ms: u32, wpm: u16) bool {
        if (!self.running) return false;
        const interval_ms: u32 = @divTrunc(60_000, clampWpm(wpm));
        if (now_ms -% self.last_ms < interval_ms) return false;
        self.last_ms = now_ms;
        return true;
    }
};

pub const Position = struct {
    word: u32 = 0,
    sentence: u32 = 0,
};

pub const Word = struct {
    bytes: []const u8,
    position: Position,
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, word: Word) anyerror!void,

    pub fn write(self: Sink, word: Word) !void {
        try self.emit(self.context, word);
    }
};

/// Semantic breaks delimit words. Replay from the chapter start to reconstruct
/// Position.
pub const Cursor = struct {
    sink: Sink,
    word: [max_word_bytes]u8 = undefined,
    word_len: usize = 0,
    next_position: Position = .{},
    word_ordinals: word_index.Counter = .{},

    pub fn init(sink: Sink) Cursor {
        return .{ .sink = sink };
    }

    pub fn consume(self: *Cursor, event: xhtml.Event) !void {
        switch (event) {
            .text => |bytes| try self.text(bytes),
            else => try self.finishWord(),
        }
    }

    pub fn finish(self: *Cursor) !void {
        try self.finishWord();
    }

    pub fn wordCount(self: *const Cursor) u32 {
        return self.word_ordinals.count();
    }

    fn text(self: *Cursor, bytes: []const u8) !void {
        for (bytes) |byte| {
            if (word_index.isBoundary(byte)) {
                try self.finishWord();
            } else {
                if (self.word_len == self.word.len) return error.WordTooLong;
                self.word[self.word_len] = byte;
                self.word_len += 1;
            }
        }
    }

    fn finishWord(self: *Cursor) !void {
        if (self.word_len == 0) return;
        const bytes = self.word[0..self.word_len];
        self.next_position.word = self.word_ordinals.accept();
        try self.sink.write(.{ .bytes = bytes, .position = self.next_position });
        if (endsSentence(bytes)) self.next_position.sentence += 1;
        self.word_len = 0;
    }
};

/// Anchors count codepoints, skipping ASCII and common Unicode punctuation. Other non-
/// ASCII codepoints count as letters.
pub fn anchorIndex(word: []const u8) u8 {
    const letters = letterCount(word);
    return if (letters <= 1) 0 else (letters - 1) / 3;
}

/// Return the whole UTF-8 anchor glyph so measurement cannot split it.
pub fn anchorBytes(word: []const u8) ?struct { start: usize, end: usize } {
    const wanted = anchorIndex(word);
    var seen: u8 = 0;
    var index: usize = 0;
    while (index < word.len) {
        const length = utf8SequenceLength(word[index]);
        const end = @min(word.len, index + length);
        if (isLetter(word[index..end])) {
            if (seen == wanted) return .{ .start = index, .end = end };
            seen += 1;
        }
        index = end;
    }
    return null;
}

fn letterCount(word: []const u8) u8 {
    var count: u8 = 0;
    var index: usize = 0;
    while (index < word.len) {
        const end = @min(word.len, index + utf8SequenceLength(word[index]));
        if (isLetter(word[index..end]) and count != std.math.maxInt(u8)) count += 1;
        index = end;
    }
    return count;
}

fn utf8SequenceLength(first: u8) usize {
    return if (first < 0x80) 1 else if (first & 0xe0 == 0xc0) 2 else if (first & 0xf0 == 0xe0) 3 else if (first & 0xf8 == 0xf0) 4 else 1;
}

fn isLetter(bytes: []const u8) bool {
    if (bytes.len == 1) return std.ascii.isAlphabetic(bytes[0]);
    const codepoint = std.unicode.utf8Decode(bytes) catch return false;
    return !@import("unicode.zig").isPunctuation(codepoint);
}

fn endsSentence(bytes: []const u8) bool {
    var end = bytes.len;
    while (end != 0) {
        var start = end - 1;
        while (start != 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
        const codepoint = std.unicode.utf8Decode(bytes[start..end]) catch return false;
        switch (codepoint) {
            '.', '!', '?', 0x2026, 0x3002, 0xff01, 0xff1f => return true,
            '"', '\'', ')', ']', '}', 0x2019, 0x201d, 0x00bb, 0x3009, 0x300b, 0x300d, 0x300f, 0xff09 => {},
            else => return false,
        }
        end = start;
    }
    return false;
}

const Collected = struct {
    words: [8][max_word_bytes]u8 = undefined,
    lengths: [8]u16 = [_]u16{0} ** 8,
    positions: [8]Position = undefined,
    len: usize = 0,

    fn emit(context: *anyopaque, emitted_word: Word) !void {
        const self: *Collected = @ptrCast(@alignCast(context));
        if (self.len == self.words.len) return error.TestOverflow;
        @memcpy(self.words[self.len][0..emitted_word.bytes.len], emitted_word.bytes);
        self.lengths[self.len] = @intCast(emitted_word.bytes.len);
        self.positions[self.len] = emitted_word.position;
        self.len += 1;
    }

    fn word(self: *const Collected, index: usize) []const u8 {
        return self.words[index][0..self.lengths[index]];
    }
};

fn forwardXhtmlEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
    const cursor: *Cursor = @ptrCast(@alignCast(context));
    try cursor.consume(event);
}

test "cursor reconstructs sentence and word positions from chunked XHTML events" {
    var collected = Collected{};
    var cursor = Cursor.init(.{ .context = &collected, .emit = Collected.emit });
    try cursor.consume(.{ .text = "One" });
    try cursor.consume(.{ .text = "! two" });
    try cursor.consume(.paragraph_break);
    try cursor.consume(.{ .text = "three?" });
    try cursor.finish();
    try std.testing.expectEqual(@as(usize, 3), collected.len);
    try std.testing.expectEqualStrings("One!", collected.word(0));
    try std.testing.expectEqual(Position{ .word = 0, .sentence = 0 }, collected.positions[0]);
    try std.testing.expectEqual(Position{ .word = 1, .sentence = 1 }, collected.positions[1]);
    try std.testing.expectEqual(Position{ .word = 2, .sentence = 1 }, collected.positions[2]);
}

test "cursor accepts text split through UTF-8 and preserves punctuation" {
    var collected = Collected{};
    var cursor = Cursor.init(.{ .context = &collected, .emit = Collected.emit });
    try cursor.consume(.{ .text = "caf\xc3" });
    try cursor.consume(.{ .text = "\xa9, next." });
    try cursor.finish();
    try std.testing.expectEqualStrings("caf\xc3\xa9,", collected.word(0));
    try std.testing.expectEqualStrings("next.", collected.word(1));
}

test "XHTML split at every byte reaches the same bounded word cursor" {
    var collected = Collected{};
    var cursor = Cursor.init(.{ .context = &collected, .emit = Collected.emit });
    var extractor = xhtml.StreamExtractor.init(.{ .context = &cursor, .emit = forwardXhtmlEvent });
    const source = "<p>One! caf\xc3\xa9, <em>next.</em></p>";
    for (source) |byte| _ = try extractor.feed(&[_]u8{byte});
    try extractor.finish();
    try cursor.finish();
    try std.testing.expectEqual(@as(usize, 3), collected.len);
    try std.testing.expectEqualStrings("One!", collected.word(0));
    try std.testing.expectEqualStrings("café,", collected.word(1));
    try std.testing.expectEqualStrings("next.", collected.word(2));
}

test "ORP formula counts letters and returns complete UTF-8 glyph spans" {
    const cases = [_]struct { word: []const u8, anchor: u8 }{
        .{ .word = "a", .anchor = 0 },
        .{ .word = "four", .anchor = 1 },
        .{ .word = "sixsix", .anchor = 1 },
        .{ .word = "tenletters", .anchor = 3 },
        .{ .word = "fourteenletters", .anchor = 4 },
        .{ .word = "\xc3\xa9clair", .anchor = 1 },
    };
    for (cases) |case| try std.testing.expectEqual(case.anchor, anchorIndex(case.word));
    const span = anchorBytes("\xc3\xa9clair").?;
    try std.testing.expectEqualStrings("c", "\xc3\xa9clair"[span.start..span.end]);
    const punctuated = anchorBytes("(word)").?;
    try std.testing.expectEqualStrings("o", "(word)"[punctuated.start..punctuated.end]);
}

test "WPM settings clamp, step, and validate their configured bounds" {
    try std.testing.expectEqual(default_wpm, clampWpm(default_wpm));
    try std.testing.expectEqual(@as(u16, 325), adjustWpm(default_wpm, 1));
    try std.testing.expectEqual(@as(u16, 275), adjustWpm(default_wpm, -1));
    try std.testing.expectEqual(min_wpm, adjustWpm(min_wpm, -1));
    try std.testing.expectEqual(max_wpm, adjustWpm(max_wpm, 1));
    try std.testing.expect(validateWpm(425) != null);
    try std.testing.expect(validateWpm(426) == null);
}

test "autoplay timing is elapsed-time based, not frame-count based" {
    var timer = Timer{};
    timer.start(1_000);
    for (0..100) |_| try std.testing.expect(!timer.due(1_199, 300));
    try std.testing.expect(timer.due(1_200, 300));
    try std.testing.expect(!timer.due(1_200, 300));
    try std.testing.expect(timer.due(1_260, 1_000));
    timer.stop();
    try std.testing.expect(!timer.due(99_999, 1_000));
}

test "Unicode punctuation retains sentence rewind boundaries and letter anchors" {
    const word = "“café…”";
    const anchor = anchorBytes(word).?;
    try std.testing.expectEqualStrings("a", word[anchor.start..anchor.end]);
    var collected = Collected{};
    var cursor = Cursor.init(.{ .context = &collected, .emit = Collected.emit });
    try cursor.consume(.{ .text = "“Done.” next 東京。 last" });
    try cursor.finish();
    try std.testing.expectEqual(Position{ .word = 1, .sentence = 1 }, collected.positions[1]);
    try std.testing.expectEqual(Position{ .word = 3, .sentence = 2 }, collected.positions[3]);
}
