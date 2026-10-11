const std = @import("std");
const deflate = @import("../src/archive/deflate.zig");
const zip = @import("../src/archive/zip.zig");
const xhtml = @import("../src/content/xhtml.zig");
const pagination = @import("../src/content/pagination.zig");
const epub = @import("../src/publication/epub.zig");
const publication_navigation = @import("../src/publication/navigation.zig");
const limits = @import("limits").reader;

const FixtureReader = struct {
    io: std.Io,
    file: std.Io.File,
    size: u32,

    fn reader(self: *FixtureReader) zip.Reader {
        return .{
            .context = self,
            .size = self.size,
            .read_at = readAt,
        };
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *FixtureReader = @ptrCast(@alignCast(context));
        const count = self.file.readPositionalAll(self.io, destination, offset) catch return error.ReadFailed;
        if (count != destination.len) return error.UnexpectedEof;
    }
};

fn validateDirectory(archive: zip.Archive) !void {
    var ranges: [limits.max_archive_entries]zip.MemberRange = undefined;
    var filename: [256]u8 = undefined;
    var validator = try zip.DirectoryValidator.init(archive, &ranges);
    while (!try validator.step(&filename)) {}
}

fn readEntry(allocator: std.mem.Allocator, archive: zip.Archive, name: []const u8) ![]u8 {
    var filename: [256]u8 = undefined;
    const entry = try archive.find(name, &filename);
    var result = try allocator.alloc(u8, entry.uncompressed_size);
    errdefer allocator.free(result);

    var compressed_input: [1024]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = zip.StreamStorage.init(&compressed_input, &window, &workspace);
    var stream = try archive.begin(entry, &storage);
    var chunk: [257]u8 = undefined;
    var len: usize = 0;
    while (true) {
        switch (try stream.read(&chunk)) {
            .bytes => |count| {
                if (count > result.len - len) return error.TestUnexpectedResult;
                @memcpy(result[len .. len + count], chunk[0..count]);
                len += count;
            },
            .end => break,
            .yielded => {},
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    if (len != result.len) return error.TestUnexpectedResult;
    return result;
}

const PageSink = struct {
    builder: *pagination.EventPageBuilder,

    fn emit(context: *anyopaque, event: xhtml.Event) !void {
        const self: *PageSink = @ptrCast(@alignCast(context));
        try self.builder.consume(event);
    }
};

fn monospaceWidth(_: *anyopaque, text: []const u8) usize {
    return text.len;
}

/// Retain one page, then drain the remaining stream to verify output length and CRC.
fn renderFirstPage(archive: zip.Archive, name: []const u8, cache: *pagination.PageCache) !void {
    var filename: [256]u8 = undefined;
    const entry = try archive.find(name, &filename);
    var compressed_input: [1024]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = zip.StreamStorage.init(&compressed_input, &window, &workspace);
    var stream = try archive.begin(entry, &storage);

    var measure_context: u8 = 0;
    var builder = pagination.EventPageBuilder.init(cache, 64, .{ .context = &measure_context, .width = monospaceWidth });
    var sink = PageSink{ .builder = &builder };
    var extractor = xhtml.StreamExtractor.init(.{ .context = &sink, .emit = PageSink.emit });
    var output: [257]u8 = undefined;
    var page_full = false;

    while (true) {
        switch (try stream.read(&output)) {
            .bytes => |count| {
                if (page_full) continue;
                const progress = try extractor.feed(output[0..count]);
                if (progress == .page_full) page_full = true;
            },
            .end => break,
            .yielded => {},
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    if (!page_full) {
        try extractor.finish();
        builder.end() catch |err| switch (err) {
            error.PageFull => {},
            else => return err,
        };
    }
}

fn pageContains(cache: *const pagination.PageCache, needle: []const u8) bool {
    for (0..cache.line_count) |index| {
        if (std.mem.indexOf(u8, cache.line(index), needle) != null) return true;
    }
    return false;
}

test "bundled EPUB traverses archive, publication, streamed pages, and first chapter transition" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, "tests/fixtures/book.epub", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var source = FixtureReader{ .io = io, .file = file, .size = @intCast(stat.size) };
    var scan_buffer: [1024]u8 = undefined;
    const archive = try zip.Archive.open(source.reader(), &scan_buffer);
    try validateDirectory(archive);

    const allocator = std.testing.allocator;
    const mimetype = try readEntry(allocator, archive, "mimetype");
    defer allocator.free(mimetype);
    try std.testing.expectEqualStrings("application/epub+zip", mimetype);

    const container = try readEntry(allocator, archive, "META-INF/container.xml");
    defer allocator.free(container);
    var package_path: [256]u8 = undefined;
    const opf_path = try epub.parseContainer(container, &package_path);
    try std.testing.expectEqualStrings("OEBPS/content.opf", opf_path);

    const opf = try readEntry(allocator, archive, opf_path);
    defer allocator.free(opf);
    var publication: epub.Publication = undefined;
    var workspace: epub.OpfWorkspace = undefined;
    try epub.parseOpf(opf, opf_path, &publication, &workspace);
    try std.testing.expectEqualStrings("Alice's Adventures in Wonderland", publication.titleSlice());
    try std.testing.expect(publication.spine_len > 2);
    try std.testing.expectEqualStrings("OEBPS/wrap0000.xhtml", publication.spine[0].slice());
    try std.testing.expectEqualStrings("OEBPS/8761230412384829988_11-h-0.htm.xhtml", publication.spine[1].slice());
    try std.testing.expectEqualStrings("OEBPS/8761230412384829988_11-h-1.htm.xhtml", publication.spine[2].slice());

    const navigation_document = try readEntry(allocator, archive, publication.navigation_document.slice());
    defer allocator.free(navigation_document);
    var navigation_parser = publication_navigation.Parser.init(&publication, publication.navigation_document.slice());
    var navigation_offset: usize = 0;
    while (navigation_offset < navigation_document.len) {
        const end = @min(navigation_document.len, navigation_offset + 257);
        try navigation_parser.feed(navigation_document[navigation_offset..end]);
        navigation_offset = end;
    }
    try navigation_parser.finish();
    try std.testing.expectEqualStrings("CHAPTER I. Down the Rabbit-Hole", publication.chapter_labels[2].slice());

    var header_page = pagination.PageCache{};
    try renderFirstPage(archive, publication.spine[1].slice(), &header_page);
    try std.testing.expect(header_page.line_count != 0);
    try std.testing.expect(pageContains(&header_page, "Project Gutenberg"));

    var next_page = pagination.PageCache{};
    try renderFirstPage(archive, publication.spine[2].slice(), &next_page);
    try std.testing.expect(next_page.line_count != 0);
    try std.testing.expect(pageContains(&next_page, "Rabbit-Hole"));
}

fn waitForNavigationChapter(coordinator: *@import("../src/reader/reader_coordinator.zig").ReaderCoordinator, title: []const u8) !void {
    for (0..1000) |frame| {
        _ = coordinator.stepChapter(@intCast(frame));
        try std.testing.expectEqual(@import("../src/reader/reader_coordinator.zig").Lifecycle.ready, coordinator.lifecycle);
        if (coordinator.chapter_pump.chapter_open == null and coordinator.paged.current_ready and !coordinator.scroll_align_chapter_end) {
            try std.testing.expect(pageContains(coordinator.paged.current().?, title));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "incomplete TOC fixture reads both appendices forward and backward through routed Scroll inputs" {
    const reader = @import("../src/reader/reader_coordinator.zig");
    const host = @import("../src/reader/reader_host.zig");
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, "tests/fixtures/chapter-navigation.epub", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var source = FixtureReader{ .io = io, .file = file, .size = @intCast(stat.size) };
    var scan: [1024]u8 = undefined;
    const archive = try zip.Archive.open(source.reader(), &scan);
    try validateDirectory(archive);
    const opf = try readEntry(std.testing.allocator, archive, "book.opf");
    defer std.testing.allocator.free(opf);
    var coordinator: reader.ReaderCoordinator = undefined;
    coordinator.initInPlace(reader.default_checkpoint_byte_budget);
    var workspace: epub.OpfWorkspace = undefined;
    try epub.parseOpf(opf, "book.opf", &coordinator.book_session.publication, &workspace);
    const nav = try readEntry(std.testing.allocator, archive, "nav.xhtml");
    defer std.testing.allocator.free(nav);
    var parser = publication_navigation.Parser.init(&coordinator.book_session.publication, "nav.xhtml");
    try parser.feed(nav);
    try parser.finish();
    try std.testing.expectEqual(@as(usize, 1), parser.labelCount());
    try std.testing.expectEqual(@as(u8, 5), coordinator.book_session.publication.spine_len);
    const Files = struct {
        fn open(context: *anyopaque, _: host.FileSlot, _: [:0]const u8) host.FileError!zip.Reader {
            const fixture: *FixtureReader = @ptrCast(@alignCast(context));
            return fixture.reader();
        }
        fn close(_: *anyopaque, _: host.FileSlot) void {}
        fn list(_: *anyopaque, _: *host.Library) void {}
    };
    coordinator.attachHost(.{
        .files = .{ .context = &source, .open = Files.open, .close = Files.close, .list_epubs = Files.list },
        .measure = .{ .context = &source, .width = monospaceWidthForFont, .font_height = testFontHeight },
    });
    defer coordinator.leaveBook(9999);
    coordinator.lifecycle = .ready;
    coordinator.screen = .reading;
    coordinator.paged_presentation = .scroll;
    coordinator.openChapter(1, .normal);
    try waitForNavigationChapter(&coordinator, "Main body");
    const targets = [_]struct { forward: bool, chapter: u8, title: []const u8 }{
        .{ .forward = true, .chapter = 2, .title = "Appendix A" },
        .{ .forward = true, .chapter = 3, .title = "Appendix B" },
        .{ .forward = true, .chapter = 4, .title = "Wrapper navigation link." },
        .{ .forward = false, .chapter = 3, .title = "Appendix B" },
        .{ .forward = false, .chapter = 2, .title = "Appendix A" },
        .{ .forward = false, .chapter = 1, .title = "Main body" },
    };
    for (targets, 0..) |target, index| {
        coordinator.update(.{ .buttons = if (target.forward) .{ .right = true } else .{ .left = true }, .crank_docked = true }, @intCast(index + 1000));
        try std.testing.expectEqual(@as(?u8, target.chapter), coordinator.requestedChapter());
        try waitForNavigationChapter(&coordinator, target.title);
        try std.testing.expectEqual(target.chapter, coordinator.chapter_index);
    }
    coordinator.update(.{ .buttons = .{ .left = true }, .crank_docked = true }, 2000);
    try std.testing.expect(coordinator.requestedChapter() == null);
    try std.testing.expectEqual(@as(u8, 1), coordinator.chapter_index);
}

fn testFontHeight(_: *anyopaque, _: @import("../src/storage/settings.zig").ReadingFont) usize {
    return 20;
}

fn monospaceWidthForFont(context: *anyopaque, _: @import("../src/storage/settings.zig").ReadingFont, text: []const u8) usize {
    return monospaceWidth(context, text);
}
