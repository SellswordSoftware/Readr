const std = @import("std");
const unicode = @import("unicode.zig");
const limits = @import("limits").reader;

/// Payloads are valid only during the callback. Copy text that must outlive it.
pub const Event = union(enum) {
    text: []const u8,
    line_break,
    paragraph_break,
    heading,
    block_quote,
    list_item,
    divider,
};

pub const EventSink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: Event) anyerror!void,

    pub fn write(self: EventSink, event: Event) !void {
        try self.emit(self.context, event);
    }
};

/// Feed arbitrary decoded chunks, then call finish at EOF. Pending tag, entity,
/// delimiter, and UTF-8 bytes survive feeds; document text is not retained.
pub const StreamExtractor = struct {
    pub const max_tag_bytes = limits.max_xml_tag_bytes;
    pub const max_entity_bytes = limits.max_xml_entity_bytes;
    const Mode = enum { text, tag, comment, cdata };

    sink: EventSink,
    mode: Mode = .text,
    ignored_depth: u8 = 0,
    tag: [max_tag_bytes]u8 = undefined,
    tag_len: usize = 0,
    tag_quote: u8 = 0,
    delimiter: [3]u8 = undefined,
    delimiter_len: u2 = 0,
    entity: [max_entity_bytes]u8 = undefined,
    entity_len: usize = 0,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_expected: u3 = 0,
    pending_space: bool = false,
    has_content: bool = false,
    at_block_break: bool = false,
    // Use u32 like ZIP entry lengths; u64 would require alignment the device allocator
    // cannot provide.
    source_offset: u32 = 0,

    pub const FeedResult = union(enum) {
        consumed: usize,
        page_full: usize,
    };

    pub fn init(sink: EventSink) StreamExtractor {
        return .{ .sink = sink };
    }

    /// Page-full includes the triggering byte. The builder retains unfinished text;
    /// resume at the next byte.
    pub fn feed(self: *StreamExtractor, input: []const u8) anyerror!FeedResult {
        for (input, 0..) |byte, index| {
            self.source_offset += 1;
            self.feedByte(byte) catch |err| return if (err == error.PageFull) .{ .page_full = index + 1 } else err;
        }
        return .{ .consumed = input.len };
    }

    fn feedByte(self: *StreamExtractor, byte: u8) anyerror!void {
        switch (self.mode) {
            .text => if (byte == '<') {
                try self.flushEntity();
                try self.flushUtf8();
                self.mode = .tag;
                self.tag_len = 0;
                self.tag_quote = 0;
                try self.pushTag(byte);
            } else try self.textByte(byte),
            .tag => {
                try self.pushTag(byte);
                if (self.tag_len == 4 and std.mem.eql(u8, self.tag[0..4], "<!--")) {
                    self.mode = .comment;
                    self.tag_len = 0;
                    self.delimiter_len = 0;
                } else if (self.tag_len == 9 and std.mem.eql(u8, self.tag[0..9], "<![CDATA[")) {
                    self.mode = .cdata;
                    self.tag_len = 0;
                    self.delimiter_len = 0;
                } else if (self.tag_quote != 0) {
                    if (byte == self.tag_quote) self.tag_quote = 0;
                } else if (byte == '\'' or byte == '"') {
                    self.tag_quote = byte;
                } else if (byte == '>') {
                    self.mode = .text;
                    try self.handleTag();
                }
            },
            .comment => {
                self.pushDelimiter(byte);
                if (self.delimiter_len == 3 and std.mem.eql(u8, self.delimiter[0..3], "-->")) {
                    self.mode = .text;
                    self.delimiter_len = 0;
                }
            },
            .cdata => {
                self.pushDelimiter(byte);
                if (self.delimiter_len == 3 and std.mem.eql(u8, self.delimiter[0..3], "]]>")) {
                    self.mode = .text;
                    self.delimiter_len = 0;
                } else if (self.delimiter_len == 3) {
                    if (self.ignored_depth == 0) try self.textByte(self.delimiter[0]);
                    self.delimiter[0] = self.delimiter[1];
                    self.delimiter[1] = self.delimiter[2];
                    self.delimiter_len = 2;
                }
            },
        }
    }

    pub fn finish(self: *StreamExtractor) anyerror!void {
        if (self.mode == .cdata and self.ignored_depth == 0) {
            for (self.delimiter[0..self.delimiter_len]) |byte| try self.textByte(byte);
        }
        if (self.mode == .text or self.mode == .cdata) {
            try self.flushEntity();
            try self.flushUtf8();
        }
        // Ignore unfinished markup at EOF so a damaged final tag does not discard
        // readable text.
    }

    fn pushTag(self: *StreamExtractor, byte: u8) anyerror!void {
        if (self.tag_len == self.tag.len) return error.TokenTooLong;
        self.tag[self.tag_len] = byte;
        self.tag_len += 1;
    }

    fn pushDelimiter(self: *StreamExtractor, byte: u8) void {
        if (self.delimiter_len < self.delimiter.len) {
            self.delimiter[self.delimiter_len] = byte;
            self.delimiter_len += 1;
        } else {
            self.delimiter[0] = self.delimiter[1];
            self.delimiter[1] = self.delimiter[2];
            self.delimiter[2] = byte;
        }
    }

    fn emitSpace(self: *StreamExtractor) anyerror!void {
        if (self.has_content and !self.pending_space) {
            try self.sink.write(.{ .text = " " });
            self.pending_space = true;
        }
    }

    fn emitText(self: *StreamExtractor, bytes: []const u8) anyerror!void {
        if (bytes.len == 0) return;
        try self.sink.write(.{ .text = bytes });
        self.pending_space = false;
        self.has_content = true;
        self.at_block_break = false;
    }

    fn textByte(self: *StreamExtractor, byte: u8) anyerror!void {
        if (self.ignored_depth != 0) return;
        if (self.entity_len != 0) {
            if (self.entity_len == self.entity.len) return error.EntityTooLong;
            self.entity[self.entity_len] = byte;
            self.entity_len += 1;
            if (byte == ';') try self.flushEntity();
            return;
        }
        if (byte == '&') {
            try self.flushUtf8();
            self.entity[0] = byte;
            self.entity_len = 1;
        } else if (std.ascii.isWhitespace(byte)) {
            try self.flushUtf8();
            try self.emitSpace();
        } else if (byte < 0x80) {
            try self.flushUtf8();
            try self.emitText(&[_]u8{byte});
        } else try self.utf8Byte(byte);
    }

    fn utf8Byte(self: *StreamExtractor, byte: u8) anyerror!void {
        if (self.utf8_len == 0) {
            self.utf8_expected = if (byte >= 0xc2 and byte <= 0xdf) 2 else if (byte >= 0xe0 and byte <= 0xef) 3 else if (byte >= 0xf0 and byte <= 0xf4) 4 else {
                try self.emitText("?");
                return;
            };
        } else if (byte & 0xc0 != 0x80) {
            // Do not let an invalid continuation poison the following ASCII
            // byte or valid UTF-8 leading byte.
            try self.flushUtf8();
            return self.utf8Byte(byte);
        }
        self.utf8[self.utf8_len] = byte;
        self.utf8_len += 1;
        if (self.utf8_len == self.utf8_expected) try self.flushUtf8();
    }

    fn flushUtf8(self: *StreamExtractor) anyerror!void {
        if (self.utf8_len == 0) return;
        const len = self.utf8_len;
        const expected = self.utf8_expected;
        self.utf8_len = 0;
        self.utf8_expected = 0;
        if (len != expected) return self.emitText("?");
        const codepoint = std.unicode.utf8Decode(self.utf8[0..len]) catch {
            try self.emitText("?");
            return;
        };
        try self.emitCodepoint(codepoint);
    }

    /// Normalize separators here; leave missing-glyph fallback to the display adapter.
    fn emitCodepoint(self: *StreamExtractor, codepoint: u21) anyerror!void {
        if (unicode.isWhitespace(codepoint)) return self.emitSpace();
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &encoded) catch {
            try self.emitText("?");
            return;
        };
        try self.emitText(encoded[0..len]);
    }

    fn flushEntity(self: *StreamExtractor) anyerror!void {
        if (self.entity_len == 0) return;
        const entity = self.entity[0..self.entity_len];
        // The source byte is consumed even if a separator fills the page.
        self.entity_len = 0;
        if (decodeEntity(entity)) |decoded| {
            try self.emitCodepoint(@intCast(decoded.codepoint));
        } else {
            // Unknown entities remain literal, but malformed UTF-8 inside
            // them must not bypass the text validator.
            var literal: [max_entity_bytes]u8 = undefined;
            var source: usize = 0;
            var written: usize = 0;
            while (source < entity.len) {
                const len: usize = std.unicode.utf8ByteSequenceLength(entity[source]) catch 1;
                const end = @min(source + len, entity.len);
                const bytes = entity[source..end];
                if (len <= entity.len - source and std.unicode.utf8ValidateSlice(bytes)) {
                    @memcpy(literal[written..][0..bytes.len], bytes);
                    written += bytes.len;
                    source = end;
                } else {
                    literal[written] = '?';
                    written += 1;
                    source += 1;
                }
            }
            try self.emitText(literal[0..written]);
        }
    }

    fn handleTag(self: *StreamExtractor) anyerror!void {
        const tag = parseTag(self.tag[0..self.tag_len], 0) orelse return;
        self.tag_len = 0;
        if (tag.name.len == 0) return;
        if (isIgnored(tag.name)) {
            if (tag.closing) {
                if (self.ignored_depth != 0) self.ignored_depth -= 1;
            } else if (!tag.self_closing and self.ignored_depth != std.math.maxInt(u8)) self.ignored_depth += 1;
            return;
        }
        if (self.ignored_depth != 0) return;
        if (std.mem.eql(u8, tag.name, "br")) {
            if (self.has_content) try self.sink.write(.line_break);
        } else if (std.mem.eql(u8, tag.name, "hr")) {
            if (self.has_content and !self.at_block_break) try self.sink.write(.divider);
            self.at_block_break = true;
        } else if (isHeading(tag.name)) {
            if (tag.closing) {
                try self.sink.write(.paragraph_break);
                self.at_block_break = true;
            } else {
                if (self.has_content and !self.at_block_break) try self.sink.write(.paragraph_break);
                try self.sink.write(.heading);
                self.at_block_break = true;
            }
        } else if (std.mem.eql(u8, tag.name, "blockquote")) {
            if (tag.closing) {
                try self.sink.write(.paragraph_break);
                self.at_block_break = true;
            } else {
                if (self.has_content and !self.at_block_break) try self.sink.write(.paragraph_break);
                try self.sink.write(.block_quote);
                self.at_block_break = true;
            }
        } else if (isBlock(tag.name)) {
            if (self.has_content and !self.at_block_break) try self.sink.write(.paragraph_break);
            self.at_block_break = true;
            if (!tag.closing and std.mem.eql(u8, tag.name, "li")) try self.sink.write(.list_item);
        }
    }
};

const Tag = struct {
    name: []const u8,
    closing: bool,
    self_closing: bool,
    end: usize,
};

fn parseTag(xhtml: []const u8, start: usize) ?Tag {
    var cursor = start + 1;
    if (cursor >= xhtml.len) return null;
    if (xhtml[cursor] == '?' or xhtml[cursor] == '!') {
        const end = std.mem.indexOfPos(u8, xhtml, cursor, ">") orelse return null;
        return .{ .name = "", .closing = false, .self_closing = true, .end = end + 1 };
    }
    const closing = xhtml[cursor] == '/';
    if (closing) cursor += 1;
    while (cursor < xhtml.len and std.ascii.isWhitespace(xhtml[cursor])) cursor += 1;
    const name_start = cursor;
    while (cursor < xhtml.len and isNameChar(xhtml[cursor])) cursor += 1;
    const name = xhtml[name_start..cursor];
    var quote: u8 = 0;
    var self_closing = false;
    while (cursor < xhtml.len) : (cursor += 1) {
        const byte = xhtml[cursor];
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') {
            var before = cursor;
            while (before > name_start and std.ascii.isWhitespace(xhtml[before - 1])) before -= 1;
            self_closing = before > name_start and xhtml[before - 1] == '/';
            return .{ .name = localName(name), .closing = closing, .self_closing = self_closing, .end = cursor + 1 };
        }
    }
    return null;
}

const Entity = struct { codepoint: u32, len: usize };

fn decodeEntity(source: []const u8) ?Entity {
    const end = std.mem.indexOfScalarPos(u8, source, 1, ';') orelse return null;
    if (end > 16) return null;
    const name = source[1..end];
    const codepoint: u32 = if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "quot")) '"' else if (std.mem.eql(u8, name, "apos")) '\'' else if (std.mem.eql(u8, name, "nbsp")) ' ' else if (parseNumericEntity(name)) |value| value else return null;
    return .{ .codepoint = codepoint, .len = end + 1 };
}

fn parseNumericEntity(name: []const u8) ?u32 {
    if (name.len < 2 or name[0] != '#') return null;
    const base: u8 = if (name[1] == 'x' or name[1] == 'X') 16 else 10;
    var value: u32 = 0;
    const digits = name[if (base == 16) 2 else 1..];
    if (digits.len == 0) return null;
    for (digits) |digit| {
        const amount: u8 = if (digit >= '0' and digit <= '9') digit - '0' else if (base == 16 and digit >= 'a' and digit <= 'f') digit - 'a' + 10 else if (base == 16 and digit >= 'A' and digit <= 'F') digit - 'A' + 10 else return null;
        if (amount >= base or value > (0x10ffff - @as(u32, amount)) / base) return null;
        value = value * base + amount;
    }
    return value;
}

fn isIgnored(name: []const u8) bool {
    return std.mem.eql(u8, name, "script") or std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "head") or std.mem.eql(u8, name, "svg");
}

fn isHeading(name: []const u8) bool {
    return name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6';
}

fn isBlock(name: []const u8) bool {
    return std.mem.eql(u8, name, "p") or std.mem.eql(u8, name, "div") or std.mem.eql(u8, name, "section") or std.mem.eql(u8, name, "article") or std.mem.eql(u8, name, "pre") or std.mem.eql(u8, name, "li");
}

fn localName(name: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, name, ':')) |index| index + 1 else 0;
    return name[start..];
}

fn isNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == ':' or byte == '-' or byte == '_';
}

const TestEvents = struct {
    bytes: [2048]u8 = undefined,
    len: usize = 0,

    fn emit(context: *anyopaque, event: Event) !void {
        const self: *TestEvents = @ptrCast(@alignCast(context));
        const text: []const u8 = switch (event) {
            .text => |value| value,
            .line_break => "\\n",
            .paragraph_break => "\\n\\n",
            .heading => "",
            .block_quote => "",
            .list_item => "- ",
            .divider => "---\\n\\n",
        };
        if (self.len + text.len > self.bytes.len) return error.OutputTooSmall;
        @memcpy(self.bytes[self.len .. self.len + text.len], text);
        self.len += text.len;
    }
};

test "stream extractor preserves text across every input split" {
    const document = "<p>Hello &amp; <em>world</em></p><!-- nope --><p>next</p>";
    for (0..document.len + 1) |split| {
        var events = TestEvents{};
        var extractor = StreamExtractor.init(.{ .context = &events, .emit = TestEvents.emit });
        _ = try extractor.feed(document[0..split]);
        _ = try extractor.feed(document[split..]);
        try extractor.finish();
        try std.testing.expectEqualStrings("Hello & world\\n\\nnext\\n\\n", events.bytes[0..events.len]);
    }
}

test "stream extractor rejects over-limit markup" {
    var events = TestEvents{};
    var extractor = StreamExtractor.init(.{ .context = &events, .emit = TestEvents.emit });
    var input: [StreamExtractor.max_tag_bytes + 2]u8 = undefined;
    @memset(&input, 'a');
    input[0] = '<';
    try std.testing.expectError(error.TokenTooLong, extractor.feed(&input));
}

test "stream extractor preserves split UTF-8 punctuation" {
    var events = TestEvents{};
    var extractor = StreamExtractor.init(.{ .context = &events, .emit = TestEvents.emit });
    const input = "<p>“Don’t—wait…”</p>";
    for (input) |byte| _ = try extractor.feed(&[_]u8{byte});
    try extractor.finish();
    try std.testing.expectEqualStrings("“Don’t—wait…”\\n\\n", events.bytes[0..events.len]);
}

test "stream extractor replaces malformed UTF-8 with a question mark" {
    var events = TestEvents{};
    var extractor = StreamExtractor.init(.{ .context = &events, .emit = TestEvents.emit });
    _ = try extractor.feed("<p>bad ");
    _ = try extractor.feed(&[_]u8{ 0xe2, 'x' });
    try extractor.finish();
    try std.testing.expectEqualStrings("bad ?x", events.bytes[0..events.len]);
}

test "stream extractor preserves Unicode and numeric entities" {
    var events = TestEvents{};
    var extractor = StreamExtractor.init(.{ .context = &events, .emit = TestEvents.emit });
    _ = try extractor.feed("<p>caf\xc3\xa9 &#169; “ok”</p>");
    try extractor.finish();
    try std.testing.expectEqualStrings("café © “ok”\\n\\n", events.bytes[0..events.len]);
}

const PausingEvents = struct {
    paused: bool = true,
    bytes: [8]u8 = undefined,
    len: usize = 0,

    fn emit(context: *anyopaque, event: Event) !void {
        const self: *PausingEvents = @ptrCast(@alignCast(context));
        if (self.paused) return error.PageFull;
        switch (event) {
            .text => |text| {
                @memcpy(self.bytes[self.len .. self.len + text.len], text);
                self.len += text.len;
            },
            else => {},
        }
    }
};

test "stream extractor reports the consumed page-full boundary" {
    var events = PausingEvents{};
    var extractor = StreamExtractor.init(.{ .context = &events, .emit = PausingEvents.emit });
    const first = try extractor.feed("abc");
    try std.testing.expectEqual(StreamExtractor.FeedResult{ .page_full = 1 }, first);
    events.paused = false;
    const second = try extractor.feed("bc");
    try std.testing.expectEqual(StreamExtractor.FeedResult{ .consumed = 2 }, second);
    try std.testing.expectEqualStrings("bc", events.bytes[0..events.len]);
}

test "stream extractor reports page-full from a tag semantic event" {
    var events = PausingEvents{ .paused = false };
    var extractor = StreamExtractor.init(.{ .context = &events, .emit = PausingEvents.emit });
    _ = try extractor.feed("<p>x");
    events.paused = true;
    const result = try extractor.feed("</p>");
    try std.testing.expectEqual(StreamExtractor.FeedResult{ .page_full = 4 }, result);
    events.paused = false;
    try std.testing.expectEqual(StreamExtractor.FeedResult{ .consumed = 1 }, try extractor.feed("y"));
    try std.testing.expectEqualStrings("xy", events.bytes[0..events.len]);
}

test "stream extractor streams long comments and CDATA without tag scratch growth" {
    var events = TestEvents{};
    var extractor = StreamExtractor.init(.{ .context = &events, .emit = TestEvents.emit });
    var long: [1200]u8 = undefined;
    @memset(&long, 'x');
    _ = try extractor.feed("<p>before</p><!--");
    _ = try extractor.feed(&long);
    _ = try extractor.feed("--><p><![CDATA[");
    _ = try extractor.feed(&long);
    _ = try extractor.feed("]]></p>");
    try extractor.finish();
    try std.testing.expectEqualStrings("before\\n\\n", events.bytes[0.."before\\n\\n".len]);
    try std.testing.expectEqualStrings(long[0..], events.bytes["before\\n\\n".len .. "before\\n\\n".len + long.len]);
    try std.testing.expectEqual(@as(usize, 1200 + "before\\n\\n\\n\\n".len), events.len);
}

test "stream extractor handles semantic blocks and quoted tag attributes across every split" {
    const document = "<h2 title=\"a > b\">Heading</h2><blockquote>Quote</blockquote><script><span>hidden</span></script><p>shown</p>";
    for (0..document.len + 1) |split| {
        var events = TestEvents{};
        var extractor = StreamExtractor.init(.{ .context = &events, .emit = TestEvents.emit });
        _ = try extractor.feed(document[0..split]);
        _ = try extractor.feed(document[split..]);
        try extractor.finish();
        try std.testing.expectEqualStrings("Heading\\n\\nQuote\\n\\nshown\\n\\n", events.bytes[0..events.len]);
    }
}

test "Unicode spaces and numeric entities normalize identically across every split" {
    const input = "café\u{a0}naïve&nbsp;résumé&#160;東京\u{202f}“hello”\u{2003}next&#x2003;last";
    const expected = "café naïve résumé 東京 “hello” next last";
    for (0..input.len + 1) |split| {
        var events = TestEvents{};
        var extractor = StreamExtractor.init(.{ .context = &events, .emit = TestEvents.emit });
        _ = try extractor.feed(input[0..split]);
        _ = try extractor.feed(input[split..]);
        try extractor.finish();
        try std.testing.expectEqualStrings(expected, events.bytes[0..events.len]);
        try std.testing.expect(std.unicode.utf8ValidateSlice(events.bytes[0..events.len]));
    }
}

test "invalid and incomplete UTF-8 cannot span markup or poison following glyphs" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "bad\xe2x", .expected = "bad?x" },
        .{ .source = "\xc0\xaf", .expected = "??" },
        .{ .source = "\xed\xa0\x80", .expected = "?" },
        .{ .source = "\xf4\x90\x80\x80", .expected = "?" },
        .{ .source = "é\xf0\x9f", .expected = "é?" },
        .{ .source = "\xc3<em></em>\xa9", .expected = "??" },
        .{ .source = "&#xD800;é", .expected = "?é" },
        .{ .source = "&bad\xff;é", .expected = "&bad?;é" },
    };
    for (cases) |case| {
        for (0..case.source.len + 1) |split| {
            var events = TestEvents{};
            var extractor = StreamExtractor.init(.{ .context = &events, .emit = TestEvents.emit });
            _ = try extractor.feed(case.source[0..split]);
            _ = try extractor.feed(case.source[split..]);
            try extractor.finish();
            try std.testing.expectEqualStrings(case.expected, events.bytes[0..events.len]);
            try std.testing.expect(std.unicode.utf8ValidateSlice(events.bytes[0..events.len]));
        }
    }
}
