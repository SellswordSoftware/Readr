const std = @import("std");
const xhtml = @import("../src/content/xhtml.zig");
const pagination = @import("../src/content/pagination.zig");
const rsvp = @import("../src/content/rsvp.zig");
const reading_position = @import("../src/storage/resume.zig");
const settings = @import("../src/storage/settings.zig");

/// Record tiny scripted chapters so assertions can span chapter and resume boundaries.
const Words = struct {
    text: [8][rsvp.max_word_bytes]u8 = undefined,
    lengths: [8]u16 = [_]u16{0} ** 8,
    positions: [8]rsvp.Position = undefined,
    len: usize = 0,

    fn emit(context: *anyopaque, emitted_word: rsvp.Word) !void {
        const self: *Words = @ptrCast(@alignCast(context));
        if (self.len == self.text.len) return error.FixtureOverflow;
        @memcpy(self.text[self.len][0..emitted_word.bytes.len], emitted_word.bytes);
        self.lengths[self.len] = @intCast(emitted_word.bytes.len);
        self.positions[self.len] = emitted_word.position;
        self.len += 1;
    }

    fn word(self: *const Words, index: usize) []const u8 {
        return self.text[index][0..self.lengths[index]];
    }
};

fn forwardEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
    const cursor: *rsvp.Cursor = @ptrCast(@alignCast(context));
    try cursor.consume(event);
}

fn streamChapter(source: []const u8, words: *Words) !void {
    var cursor = rsvp.Cursor.init(.{ .context = words, .emit = Words.emit });
    var extractor = xhtml.StreamExtractor.init(.{ .context = &cursor, .emit = forwardEvent });
    // One-byte feeds exercise decoder chunk boundaries.
    for (source) |byte| _ = try extractor.feed(&[_]u8{byte});
    try extractor.finish();
    try cursor.finish();
}

const PageEvents = struct {
    builder: *pagination.EventPageBuilder,

    fn emit(context: *anyopaque, event: xhtml.Event) !void {
        const self: *PageEvents = @ptrCast(@alignCast(context));
        try self.builder.consume(event);
    }
};

fn monospaceWidth(_: *anyopaque, text: []const u8) usize {
    return text.len;
}

fn renderChapterPage(source: []const u8, cache: *pagination.PageCache) !void {
    var measure_context: u8 = 0;
    var builder = pagination.EventPageBuilder.init(cache, 80, .{ .context = &measure_context, .width = monospaceWidth });
    var events = PageEvents{ .builder = &builder };
    var extractor = xhtml.StreamExtractor.init(.{ .context = &events, .emit = PageEvents.emit });
    for (source) |byte| _ = try extractor.feed(&[_]u8{byte});
    try extractor.finish();
    try builder.end();
}

test "RSVP fixture covers stream entry, sentence rewind target, handoff, resume, and paged return" {
    var chapter_one = Words{};
    try streamChapter("<p>One. Two three.</p>", &chapter_one);
    try std.testing.expectEqual(@as(usize, 3), chapter_one.len);
    try std.testing.expectEqualStrings("One.", chapter_one.word(0));
    try std.testing.expectEqualStrings("Two", chapter_one.word(1));
    try std.testing.expectEqual(rsvp.Position{ .word = 1, .sentence = 1 }, chapter_one.positions[1]);

    // Sentence rewind from "three." targets sentence zero, word zero.
    const displayed = chapter_one.positions[2];
    try std.testing.expectEqual(@as(u32, 2), displayed.word);
    try std.testing.expectEqual(@as(u32, 1), displayed.sentence);
    const preceding_sentence = displayed.sentence - 1;
    try std.testing.expectEqual(@as(u32, 0), preceding_sentence);
    try std.testing.expectEqual(rsvp.Position{ .word = 0, .sentence = 0 }, chapter_one.positions[0]);

    try std.testing.expectEqualStrings("three.", chapter_one.word(2));
    var chapter_two = Words{};
    try streamChapter("<p>Next chapter.</p>", &chapter_two);
    try std.testing.expectEqualStrings("Next", chapter_two.word(0));

    var record: [reading_position.encoded_size]u8 = undefined;
    reading_position.encode(.{
        .book_id = 99,
        .layout_revision = 1,
        .chapter = 0,
        .word_ordinal = displayed.word,
        .mode = .rsvp,
    }, &record);
    const restored = try reading_position.decode(&record);
    try std.testing.expect(reading_position.matchesExact(restored, 99, 1, .rsvp));
    try std.testing.expectEqual(displayed.word, restored.word_ordinal);

    try std.testing.expectEqual(settings.ReadingMode.paged, settings.nextReadingMode(.rsvp));
}

test "Paged selection and RSVP hand-offs retain the same normalized word" {
    const source = "<p>One. Two three.</p>";
    var rsvp_words = Words{};
    try streamChapter(source, &rsvp_words);

    var page = pagination.PageCache{};
    try renderChapterPage(source, &page);
    try std.testing.expectEqual(@as(u32, 3), page.word_count);

    const selected = page.moveSelection(1, 1).?;
    const span = page.wordSpan(selected).?;
    try std.testing.expectEqual(@as(u32, 2), selected);
    try std.testing.expectEqualStrings(rsvp_words.word(@intCast(selected)), page.line(span.line_index)[span.start..span.end]);

    var record: [reading_position.encoded_size]u8 = undefined;
    reading_position.encode(.{ .book_id = 99, .layout_revision = 1, .chapter = 0, .word_ordinal = selected, .mode = .paged }, &record);
    const restored = try reading_position.decode(&record);
    try std.testing.expect(restored.legacy_paged_page == null);
    try std.testing.expectEqual(selected, restored.word_ordinal);
    const restored_span = page.wordSpan(restored.word_ordinal).?;
    try std.testing.expectEqualStrings(rsvp_words.word(@intCast(restored.word_ordinal)), page.line(restored_span.line_index)[restored_span.start..restored_span.end]);
}

test "RSVP fixture anchor and elapsed autoplay hold across 100, 300, and 1000 WPM" {
    try std.testing.expectEqual(@as(u8, 1), rsvp.anchorIndex("word"));
    for ([_]u16{ 100, 300, 1_000 }) |wpm| {
        var timer = rsvp.Timer{};
        timer.start(10_000);
        const interval = @divTrunc(@as(u32, 60_000), wpm);
        try std.testing.expect(!timer.due(10_000 + interval - 1, wpm));
        try std.testing.expect(timer.due(10_000 + interval, wpm));
    }
}

test "Unicode words agree across pagination RSVP and indexing at every feed split" {
    const source = "café\u{a0}naïve&nbsp;“東京。”&#x202f;résumé\u{2003}fin.";
    var words = Words{};
    try streamChapter(source, &words);
    try std.testing.expectEqual(@as(usize, 5), words.len);
    const expected = [_][]const u8{ "café", "naïve", "“東京。”", "résumé", "fin." };
    for (expected, 0..) |text, ordinal| try std.testing.expectEqualStrings(text, words.word(ordinal));
    for (1..source.len + 1) |chunk_size| {
        var pages: [16]pagination.PageCache = [_]pagination.PageCache{.{}} ** 16;
        var context: u8 = 0;
        var builder = pagination.EventPageBuilder.init(&pages[0], 10, .{ .context = &context, .width = monospaceWidth, .line_limit = 1 });
        var events = PageEvents{ .builder = &builder };
        var extractor = xhtml.StreamExtractor.init(.{ .context = &events, .emit = PageEvents.emit });
        var offset: usize = 0;
        var page_index: usize = 0;
        while (offset < source.len) {
            const result: xhtml.StreamExtractor.FeedResult = if (builder.page_full)
                .{ .page_full = 0 }
            else
                try extractor.feed(source[offset..@min(offset + chunk_size, source.len)]);
            switch (result) {
                .consumed => |count| offset += count,
                .page_full => |count| {
                    offset += count;
                    page_index += 1;
                    builder.beginNextPage(&pages[page_index]);
                },
            }
        }
        try extractor.finish();
        while (true) {
            builder.end() catch |err| {
                if (err != error.PageFull) return err;
                page_index += 1;
                builder.beginNextPage(&pages[page_index]);
                continue;
            };
            break;
        }
        var reconstructed = Words{ .len = words.len };
        for (pages[0 .. page_index + 1]) |*page| {
            for (0..page.line_count) |line_index| {
                for (0..page.line_word_counts[line_index]) |index| {
                    const ordinal = page.lineFirstWordOrdinal(line_index) + @as(u32, @intCast(index));
                    const span = page.wordSpanOnLine(ordinal, line_index).?;
                    const text = page.line(line_index)[span.start..span.end];
                    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
                    const start = reconstructed.lengths[ordinal];
                    @memcpy(reconstructed.text[ordinal][start .. start + text.len], text);
                    reconstructed.lengths[ordinal] += @intCast(text.len);
                }
            }
        }
        try std.testing.expectEqual(@as(u32, @intCast(words.len)), builder.wordCount());
        for (0..words.len) |ordinal| try std.testing.expectEqualStrings(words.word(ordinal), reconstructed.word(ordinal));
    }

    const fixture = @import("../src/testing/decoder_work_fixture.zig");
    const indexer = @import("../src/reader/progress_indexer.zig");
    const epub = @import("../src/publication/epub.zig");
    const progress = @import("../src/storage/progress.zig");
    var bytes: [2048]u8 = undefined;
    var archive_source = fixture.Source{ .bytes = fixture.archive(&bytes, .stored, 0, source) };
    var publication: epub.Publication = undefined;
    publication.spine_len = 1;
    publication.spine[0].path_len = fixture.name.len;
    @memcpy(publication.spine[0].path[0..fixture.name.len], fixture.name);
    const key = progress.Key{ .book_id = 7, .publication_fingerprint = [_]u8{0} ** 16, .word_semantics_revision = 2, .spine_len = 1 };
    var worker: indexer.Indexer = undefined;
    worker.initInPlace();
    const Close = struct {
        fn close(_: *anyopaque) void {}
    };
    try worker.open(try progress.Index.init(key), &publication, 0, archive_source.reader(), .{ .context = &archive_source, .close = Close.close });
    defer worker.close();
    for (0..2000) |_| {
        const result = worker.update(1);
        if (result == .chapter_complete) break;
        try std.testing.expect(result == .working);
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(words.len)), worker.snapshot().?.chapter_words[0]);
}
