const std = @import("std");
const zip = @import("../src/archive/zip.zig");
const reader = @import("../src/reader/reader_coordinator.zig");
const host = @import("../src/reader/reader_host.zig");
const telemetry = @import("../src/telemetry.zig");
const cache = @import("../src/storage/publication_cache.zig");
const persistence = @import("../src/storage/persistence.zig");
const codec = @import("../src/storage/generation_record.zig").Codec(cache.encoded_size);

/// Exercise the real two-generation cache format in heap-owned host storage.
const CacheFiles = struct {
    workspace: codec.Workspace = .{},
    slots: [2][codec.encoded_size]u8 = undefined,
    present: [2]bool = .{ false, false },
    fail_writes: bool = false,
    short_write: bool = false,
    writes: usize = 0,
    small: [4]SmallRecord = .{ .{}, .{}, .{}, .{} },
    const SmallRecord = struct { name: [96]u8 = undefined, name_len: usize = 0, bytes: [576]u8 = undefined, len: usize = 0 };

    fn files(self: *CacheFiles) codec.Files {
        return .{ .workspace = &self.workspace, .context = self, .read = rawRead, .write = rawWrite, .delete = rawDelete };
    }
    fn slot(name: []const u8) ?usize {
        if (!std.mem.endsWith(u8, name, "publication.bin.0") and !std.mem.endsWith(u8, name, "publication.bin.1")) return null;
        return name[name.len - 1] - '0';
    }
    fn rawRead(context: *anyopaque, name: []const u8, output: []u8) codec.ReadResult {
        const self: *CacheFiles = @ptrCast(@alignCast(context));
        const index = slot(name) orelse return .missing;
        if (!self.present[index]) return .missing;
        if (output.len != codec.encoded_size) return .invalid;
        @memcpy(output, &self.slots[index]);
        return .ok;
    }
    fn rawWrite(context: *anyopaque, name: []const u8, input: []const u8) bool {
        const self: *CacheFiles = @ptrCast(@alignCast(context));
        const index = slot(name) orelse return false;
        self.writes += 1;
        if (self.fail_writes) return false;
        if (input.len != codec.encoded_size) return false;
        if (self.short_write) {
            @memcpy(self.slots[index][0 .. input.len / 2], input[0 .. input.len / 2]);
            self.present[index] = true;
            return false;
        }
        @memcpy(&self.slots[index], input);
        self.present[index] = true;
        return true;
    }
    fn rawDelete(context: *anyopaque, name: []const u8) bool {
        const self: *CacheFiles = @ptrCast(@alignCast(context));
        for (&self.small) |*record| if (std.mem.eql(u8, name, record.name[0..record.name_len])) {
            record.len = 0;
        };
        return true;
    }
    fn read(context: *anyopaque, name: []const u8, output: []u8) bool {
        const self: *CacheFiles = @ptrCast(@alignCast(context));
        if (output.len <= 576) {
            for (&self.small) |*record| {
                if (record.len == output.len and std.mem.eql(u8, name, record.name[0..record.name_len])) {
                    @memcpy(output, record.bytes[0..record.len]);
                    return true;
                }
            }
            return false;
        }
        return codec.read(self.files(), name, output);
    }
    fn write(context: *anyopaque, name: []const u8, input: []const u8) bool {
        const self: *CacheFiles = @ptrCast(@alignCast(context));
        if (input.len <= 576) {
            for (&self.small) |*record| {
                if (record.len == 0 or std.mem.eql(u8, name, record.name[0..record.name_len])) {
                    @memcpy(record.name[0..name.len], name);
                    record.name_len = name.len;
                    @memcpy(record.bytes[0..input.len], input);
                    record.len = input.len;
                    return true;
                }
            }
            return false;
        }
        return codec.write(self.files(), name, input);
    }
    fn ensure(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn port(self: *CacheFiles) persistence.FileStore {
        return .{ .context = self, .read = read, .write = write, .delete = rawDelete, .ensure_directory = ensure };
    }
};

const Source = struct {
    io: std.Io,
    file: std.Io.File,
    size: u32,
    loading: *telemetry.Loading,
    handles: [4]Handle = undefined,
    patch_offset: ?u32 = null,
    clock_ticks: ?u32 = null,
    clock_step: u32 = 1,
    header_offsets: [640]u32 = undefined,
    header_count: usize = 0,
    const Handle = struct {
        source: *Source,
        offset: u32 = 0,
        track: bool = false,
        fn readAt(context: *anyopaque, offset: u32, output: []u8) zip.Error!void {
            const self: *Handle = @ptrCast(@alignCast(context));
            const source = self.source;
            if (output.len == 30) {
                if (source.header_count >= source.header_offsets.len) return error.ReadFailed;
                source.header_offsets[source.header_count] = offset;
                source.header_count += 1;
            }
            if (self.track) source.loading.recordRead(output.len, self.offset != offset);
            self.offset = offset + @as(u32, @intCast(output.len));
            const count = source.file.readPositionalAll(source.io, output, offset) catch return error.ReadFailed;
            if (count != output.len) return error.UnexpectedEof;
            if (source.patch_offset) |patch| if (patch >= offset and patch - offset < output.len) {
                output[patch - offset] ^= 1;
            };
        }
    };
    fn open(context: *anyopaque, file_slot: host.FileSlot, _: [:0]const u8) host.FileError!zip.Reader {
        const self: *Source = @ptrCast(@alignCast(context));
        const handle = &self.handles[@intFromEnum(file_slot)];
        handle.* = .{ .source = self, .track = file_slot == .opening or file_slot == .chapter };
        return .{ .context = handle, .size = self.size, .read_at = Handle.readAt };
    }
    fn close(_: *anyopaque, _: host.FileSlot) void {}
    fn list(_: *anyopaque, _: *host.Library) void {}
    fn width(_: *anyopaque, _: @import("../src/storage/settings.zig").ReadingFont, text: []const u8) usize {
        return text.len * 7;
    }
    fn clock(context: *anyopaque) u32 {
        const self: *Source = @ptrCast(@alignCast(context));
        if (self.clock_ticks) |ticks| {
            self.clock_ticks = ticks +% self.clock_step;
            return ticks;
        }
        return 0;
    }
    fn port(self: *Source) host.ReaderHost {
        return .{ .files = .{ .context = self, .open = open, .close = close, .list_epubs = list }, .measure = .{ .context = self, .width = width, .font_height = testFontHeight } };
    }
    fn readHeader(self: *const Source, offset: u32) bool {
        return std.mem.indexOfScalar(u32, self.header_offsets[0..self.header_count], offset) != null;
    }
};

fn fixtureEntry(source: *Source, name: []const u8) !zip.Entry {
    var handle: Source.Handle = .{ .source = source };
    const file: zip.Reader = .{ .context = &handle, .size = source.size, .read_at = Source.Handle.readAt };
    var scan: [1024]u8 = undefined;
    var names: [256]u8 = undefined;
    const archive = try zip.Archive.open(file, &scan);
    return archive.find(name, &names);
}

fn openToDestination(coordinator: *reader.ReaderCoordinator) !void {
    const started = coordinator.frame_now_ms +% 20;
    coordinator.frame_now_ms = started;
    try std.testing.expect(coordinator.openSelectedBook());
    for (0..10000) |frame| {
        coordinator.update(.{ .crank_docked = true }, started +% @as(u32, @intCast(frame * 20)));
        if (coordinator.lifecycle != .opening and coordinator.lifecycle != .ready) return error.TestUnexpectedResult;
        if (!coordinator.book_loading) return;
    }
    return error.TestUnexpectedResult;
}
fn saveCache(coordinator: *reader.ReaderCoordinator) !void {
    const started = coordinator.frame_now_ms +% 30000;
    for (0..10000) |frame| {
        if (coordinator.pending_publication_cache == null) return;
        coordinator.update(.{ .crank_docked = true }, started +% @as(u32, @intCast(frame * 20)));
    }
    return error.TestUnexpectedResult;
}
const Measurements = struct { opening_updates: u32 = 0, reads: u32 = 0, seeks: u32 = 0 };
fn measurements(state: *const telemetry.Loading) Measurements {
    var result: Measurements = .{};
    for (state.phases, 0..) |phase, index| {
        if (index < @intFromEnum(telemetry.LoadingPhase.chapter)) result.opening_updates += phase.updates;
        result.reads += phase.reads;
        result.seeks += phase.seeks;
    }
    return result;
}

test "large and ordinary cold and cached books skip corrupt unused image headers" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    for ([_][]const u8{ "tests/fixtures/big.epub", "tests/fixtures/book.epub" }) |path| {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const coordinator = try std.testing.allocator.create(reader.ReaderCoordinator);
        defer std.testing.allocator.destroy(coordinator);
        coordinator.initInPlace(reader.default_checkpoint_byte_budget);
        coordinator.attachAllocator(std.testing.allocator);
        const files = try std.testing.allocator.create(CacheFiles);
        defer std.testing.allocator.destroy(files);
        files.* = .{};
        coordinator.attachPersistence(persistence.Service.init(files.port()));
        var source = Source{ .io = io, .file = file, .size = @intCast(stat.size), .loading = &coordinator.telemetry.loading };
        const image = try fixtureEntry(&source, if (std.mem.endsWith(u8, path, "big.epub")) "OEBPS/6867107016949424948_cover.jpg" else "OEBPS/3809243430796983855_cover.jpg");
        source.patch_offset = image.local_header_offset;
        coordinator.attachHost(source.port());
        coordinator.library.add(path);
        defer coordinator.leaveBook(999999);
        try openToDestination(coordinator);
        try std.testing.expect(!coordinator.telemetry.loading.cache_hit);
        try std.testing.expect(!source.readHeader(image.local_header_offset));
        try std.testing.expect(coordinator.book_session.descriptors.require_member_bounds);
        for (coordinator.book_session.descriptors.spine[0..coordinator.book_session.descriptors.spine_len]) |entry| {
            if (entry) |member| try std.testing.expect(member.region_end != null);
        }
        const cold = measurements(&coordinator.telemetry.loading);
        if (std.mem.endsWith(u8, path, "big.epub")) {
            // Include first-page work in the I/O bounds.
            try std.testing.expect(cold.opening_updates < 96);
            try std.testing.expect(cold.reads < 70);
            try std.testing.expect(cold.seeks < 30);
        }
        const directory_offset = coordinator.book_session.descriptors.directory_offset;
        const label_count = coordinator.book_session.publication.spine_len;
        const first_label = coordinator.book_session.publication.chapter_labels[1];
        const navigation_path = coordinator.book_session.publication.navigation_document;
        try saveCache(coordinator);
        coordinator.leaveBook(999999);
        source.header_count = 0;
        try openToDestination(coordinator);
        const warm = &coordinator.telemetry.loading;
        try std.testing.expect(warm.cache_hit);
        try std.testing.expectEqual(@as(u32, 0), warm.phases[@intFromEnum(telemetry.LoadingPhase.metadata_parse)].updates);
        try std.testing.expectEqual(@as(u32, 0), warm.phases[@intFromEnum(telemetry.LoadingPhase.navigation)].updates);
        try std.testing.expect(!source.readHeader(image.local_header_offset));
        try std.testing.expectEqual(@as(u32, 0), warm.phases[@intFromEnum(telemetry.LoadingPhase.member_bounds)].reads);
        try std.testing.expectEqual(label_count, coordinator.book_session.publication.spine_len);
        try std.testing.expectEqualStrings(first_label.slice(), coordinator.book_session.publication.chapter_labels[1].slice());
        const cached = measurements(warm);
        try std.testing.expect(cached.opening_updates < cold.opening_updates);
        try std.testing.expect(cached.reads < cold.reads);
        coordinator.leaveBook(999999);
        // A harmless same-size central-directory edit must invalidate cache.
        source.patch_offset = directory_offset + 4;
        try openToDestination(coordinator);
        try std.testing.expect(!coordinator.telemetry.loading.cache_hit);
        source.patch_offset = null;
        coordinator.leaveBook(999999);
        // A cached book still rejects a malformed required mimetype header.
        source.patch_offset = 0;
        try std.testing.expect(coordinator.openSelectedBook());
        for (0..1000) |_| {
            coordinator.advanceOpening();
            if (coordinator.book_session.opening_job == null) break;
        }
        try std.testing.expectEqual(reader.Lifecycle.invalid_mimetype, coordinator.lifecycle);
        coordinator.leaveBook(999999);
        // Required metadata still fails on a cache miss; optional navigation failure
        // uses fallback labels.
        files.present = .{ false, false };
        const container = try fixtureEntry(&source, "META-INF/container.xml");
        source.patch_offset = container.local_header_offset;
        try std.testing.expect(coordinator.openSelectedBook());
        for (0..1000) |_| {
            coordinator.advanceOpening();
            if (coordinator.book_session.opening_job == null) break;
        }
        try std.testing.expectEqual(reader.Lifecycle.invalid_archive, coordinator.lifecycle);
        coordinator.leaveBook(999999);
        if (navigation_path.path_len != 0) {
            const navigation = try fixtureEntry(&source, navigation_path.slice());
            source.patch_offset = navigation.local_header_offset;
            try openToDestination(coordinator);
            try std.testing.expect(source.readHeader(navigation.local_header_offset));
            try std.testing.expectEqual(reader.Lifecycle.ready, coordinator.lifecycle);
        }
    }
}

test "cached later chapters enforce local headers and bounds in foreground prefetch and indexing" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, "tests/fixtures/book.epub", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    for (0..2) |fault| {
        const coordinator = try std.testing.allocator.create(reader.ReaderCoordinator);
        defer std.testing.allocator.destroy(coordinator);
        coordinator.initInPlace(reader.default_checkpoint_byte_budget);
        coordinator.attachAllocator(std.testing.allocator);
        const files = try std.testing.allocator.create(CacheFiles);
        defer std.testing.allocator.destroy(files);
        files.* = .{};
        coordinator.attachPersistence(persistence.Service.init(files.port()));
        var source = Source{ .io = io, .file = file, .size = @intCast(stat.size), .loading = &coordinator.telemetry.loading };
        coordinator.attachHost(source.port());
        coordinator.library.add("book.epub");
        defer coordinator.leaveBook(999999);
        try openToDestination(coordinator);
        try saveCache(coordinator);
        const target = coordinator.book_session.publication.spine_len - 1;
        const original = try coordinator.book_session.descriptors.chapter(target);
        coordinator.leaveBook(999999);
        source.header_count = 0;
        if (fault == 0) source.patch_offset = original.local_header_offset;
        try openToDestination(coordinator);
        try std.testing.expect(coordinator.telemetry.loading.cache_hit);
        try std.testing.expect(!source.readHeader(original.local_header_offset));
        try std.testing.expect(coordinator.book_session.opening_job == null);
        if (fault == 1) coordinator.book_session.descriptors.spine[target].?.region_end = original.local_header_offset + 30;

        // Use the copied prefetch descriptor after freeing opening storage.
        coordinator.cancelChapter();
        coordinator.cancelPrefetch();
        coordinator.chapter_index = target - 1;
        coordinator.paged.next_ready = true;
        coordinator.chapter_pump.decode_workspace = .{ .owner = .active, .active_verified_eof = true };
        try std.testing.expect(coordinator.startPrefetch());
        coordinator.stepPrefetch();
        try std.testing.expect(!coordinator.paged.prefetch.isPrefetching());
        try std.testing.expectEqual(reader.Lifecycle.ready, coordinator.lifecycle);
        try std.testing.expect(source.readHeader(original.local_header_offset));

        // Indexing consumes the same bounded entry and records a failed chapter.
        const key = coordinator.progress_worker.snapshot().?.key;
        coordinator.progress_worker.close();
        const fresh = try persistence.ProgressIndex.init(key);
        const input = try Source.open(&source, .progress, "book.epub");
        const Lease = struct {
            fn close(_: *anyopaque) void {}
        };
        try coordinator.progress_worker.openWithDescriptors(fresh, &coordinator.book_session.publication, target, input, .{ .context = &source, .close = Lease.close }, &coordinator.book_session.descriptors);
        const step = coordinator.progress_worker.update(512);
        try std.testing.expectEqual(target, step.chapter_failed);
        try std.testing.expect(coordinator.progress_worker.snapshot().?.failed.contains(target));
        try std.testing.expectEqual(reader.Lifecycle.ready, coordinator.lifecycle);

        coordinator.openChapter(target, .normal);
        _ = coordinator.stepChapter(100000);
        try std.testing.expectEqual(reader.Lifecycle.chapter_error, coordinator.lifecycle);
        try std.testing.expectEqual(reader.ChapterFailure.archive, coordinator.chapter_failure);
    }
}

test "cache corruption and failed optional cache writes never prevent reading" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, "tests/fixtures/book.epub", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const coordinator = try std.testing.allocator.create(reader.ReaderCoordinator);
    defer std.testing.allocator.destroy(coordinator);
    coordinator.initInPlace(reader.default_checkpoint_byte_budget);
    coordinator.attachAllocator(std.testing.allocator);
    const files = try std.testing.allocator.create(CacheFiles);
    defer std.testing.allocator.destroy(files);
    files.* = .{ .fail_writes = true };
    coordinator.attachPersistence(persistence.Service.init(files.port()));
    var source = Source{ .io = io, .file = file, .size = @intCast(stat.size), .loading = &coordinator.telemetry.loading };
    coordinator.attachHost(source.port());
    coordinator.library.add("book.epub");
    defer coordinator.leaveBook(999999);
    try openToDestination(coordinator);
    for (0..100) |frame| {
        coordinator.update(.{ .crank_docked = true }, @intCast(100000 + frame * 20));
        if (files.writes != 0) break;
    }
    try std.testing.expect(files.writes != 0);
    try std.testing.expect(!coordinator.persistence.?.hasSaveFailure());
    try std.testing.expect(coordinator.pending_publication_cache != null);
    const attempts = files.writes;
    coordinator.update(.{ .crank_docked = true }, coordinator.frame_now_ms +% 1);
    try std.testing.expectEqual(attempts, files.writes);
    files.fail_writes = false;
    try saveCache(coordinator);
    coordinator.leaveBook(999999);
    files.slots[0][20] ^= 1;
    try openToDestination(coordinator);
    try std.testing.expect(!coordinator.telemetry.loading.cache_hit);
}

test "opening clock ceiling yields before exhausting directory record allowance" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, "tests/fixtures/big.epub", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const coordinator = try std.testing.allocator.create(reader.ReaderCoordinator);
    defer std.testing.allocator.destroy(coordinator);
    coordinator.initInPlace(reader.default_checkpoint_byte_budget);
    coordinator.attachAllocator(std.testing.allocator);
    var source = Source{ .io = io, .file = file, .size = @intCast(stat.size), .loading = &coordinator.telemetry.loading, .clock_ticks = 0 };
    var port = source.port();
    port.clock = .{ .context = &source, .milliseconds = Source.clock };
    coordinator.attachHost(port);
    coordinator.library.add("big.epub");
    defer coordinator.leaveBook(999999);
    try std.testing.expect(coordinator.openSelectedBook());
    coordinator.advanceOpening();
    coordinator.advanceOpening();
    coordinator.advanceOpening();
    try std.testing.expect(coordinator.book_session.opening_job.?.validator.?.entry_index <= 3);
    try std.testing.expect(coordinator.book_session.opening_job.?.validator.?.entry_index > 0);
}

test "interrupted large cache generation leaves the previous complete generation readable" {
    const files = try std.testing.allocator.create(CacheFiles);
    defer std.testing.allocator.destroy(files);
    files.* = .{};
    const bytes = try std.testing.allocator.alloc(u8, cache.encoded_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 21);
    try std.testing.expect(codec.write(files.files(), "publication.bin", bytes));
    @memset(bytes, 22);
    files.short_write = true;
    try std.testing.expect(!codec.write(files.files(), "publication.bin", bytes));
    try std.testing.expect(codec.read(files.files(), "publication.bin", bytes));
    try std.testing.expect(std.mem.allEqual(u8, bytes, 21));
    files.short_write = false;
    @memset(bytes, 22);
    try std.testing.expect(codec.write(files.files(), "publication.bin", bytes));
    try std.testing.expect(codec.read(files.files(), "publication.bin", bytes));
    try std.testing.expect(std.mem.allEqual(u8, bytes, 22));
}

test "cached publication retains partial and complete progress and restores the same normalized word" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, "tests/fixtures/book.epub", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const coordinator = try std.testing.allocator.create(reader.ReaderCoordinator);
    defer std.testing.allocator.destroy(coordinator);
    coordinator.initInPlace(reader.default_checkpoint_byte_budget);
    coordinator.attachAllocator(std.testing.allocator);
    const files = try std.testing.allocator.create(CacheFiles);
    defer std.testing.allocator.destroy(files);
    files.* = .{};
    coordinator.attachPersistence(persistence.Service.init(files.port()));
    var source = Source{ .io = io, .file = file, .size = @intCast(stat.size), .loading = &coordinator.telemetry.loading };
    coordinator.attachHost(source.port());
    coordinator.library.add("book.epub");
    defer coordinator.leaveBook(999999);
    try openToDestination(coordinator);
    try saveCache(coordinator);
    const key = coordinator.progress_worker.snapshot().?.key;
    var saved = coordinator.positionSnapshot();
    saved.chapter = 3;
    saved.word_ordinal = 100;
    coordinator.leaveBook(999999);
    var partial = try persistence.ProgressIndex.init(key);
    try partial.setExact(5, 42);
    try std.testing.expect(coordinator.persistence.?.saveProgress("book.epub", partial));
    try std.testing.expect(coordinator.persistence.?.savePosition("book.epub", saved));
    try openToDestination(coordinator);
    try std.testing.expect(coordinator.telemetry.loading.cache_hit);
    try std.testing.expectEqual(@as(u8, 3), coordinator.chapter_index);
    try std.testing.expectEqual(@as(u32, 100), coordinator.positionSnapshot().word_ordinal);
    try std.testing.expect(coordinator.telemetry.loading.phases[@intFromEnum(telemetry.LoadingPhase.resume_rebuild)].updates != 0);
    const loaded = coordinator.progress_worker.snapshot().?;
    try std.testing.expect(loaded.exact.contains(5));
    try std.testing.expectEqual(@as(u32, 42), loaded.chapter_words[5]);
    coordinator.leaveBook(999999);
    for (0..key.spine_len) |chapter| try partial.setExact(@intCast(chapter), 42);
    try std.testing.expect(coordinator.persistence.?.saveProgress("book.epub", partial));
    try openToDestination(coordinator);
    try std.testing.expect(coordinator.telemetry.loading.cache_hit);
    try std.testing.expectEqualSlices(u8, &key.publication_fingerprint, &coordinator.progress_worker.snapshot().?.key.publication_fingerprint);
    const complete = coordinator.progress_worker.snapshot().?;
    for (0..key.spine_len) |chapter| try std.testing.expect(complete.exact.contains(@intCast(chapter)));
}

test "deep saved positions batch exact words with page byte and clock ceilings" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, "tests/fixtures/big.epub", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    for (0..4) |presentation| {
        const coordinator = try std.testing.allocator.create(reader.ReaderCoordinator);
        defer std.testing.allocator.destroy(coordinator);
        coordinator.initInPlace(reader.default_checkpoint_byte_budget);
        coordinator.attachAllocator(std.testing.allocator);
        const files = try std.testing.allocator.create(CacheFiles);
        defer std.testing.allocator.destroy(files);
        files.* = .{};
        coordinator.attachPersistence(persistence.Service.init(files.port()));
        var source = Source{ .io = io, .file = file, .size = @intCast(stat.size), .loading = &coordinator.telemetry.loading };
        coordinator.attachHost(source.port());
        coordinator.library.add("big.epub");
        defer coordinator.leaveBook(999999);
        try openToDestination(coordinator);
        try saveCache(coordinator);
        var target: ?u8 = null;
        for (coordinator.book_session.publication.spine[0..coordinator.book_session.publication.spine_len], 0..) |item, index| {
            if (std.mem.endsWith(u8, item.slice(), "1184-h-34.htm.xhtml")) target = @intCast(index);
        }
        var saved = coordinator.positionSnapshot();
        saved.chapter = target.?;
        saved.word_ordinal = 5000;
        saved.mode = if (presentation == 2) .rsvp else .paged;
        coordinator.leaveBook(999999);
        try std.testing.expect(coordinator.persistence.?.savePosition("big.epub", saved));
        coordinator.mode = if (presentation == 2) .rsvp else .paged;
        coordinator.paged_presentation = if (presentation == 1) .scroll else .pages;
        source.header_count = 0;
        if (presentation == 3) {
            // A slow clock forces a yield after one page. Start near wraparound to
            // check elapsed-time subtraction.
            source.clock_ticks = 0xfffffff0;
            source.clock_step = @import("limits").reader.restoration_work_ms_per_update;
            var port = source.port();
            port.clock = .{ .context = &source, .milliseconds = Source.clock };
            coordinator.attachHost(port);
        }
        const started = coordinator.frame_now_ms +% 20;
        try std.testing.expect(coordinator.openSelectedBook());
        for (0..10000) |frame| {
            const restoring = coordinator.mode == .paged and coordinator.paged.isReconstructing() and coordinator.chapter_pump.chapter_open == null;
            const page_before = coordinator.paged.page_index;
            const decoded_before = coordinator.telemetry.chapter_bytes_decoded;
            coordinator.update(.{ .crank_docked = true }, started +% @as(u32, @intCast(frame * 20)));
            if (restoring) {
                const page_limit: u32 = if (presentation == 3) 1 else @import("limits").reader.restoration_pages_per_update;
                try std.testing.expect(coordinator.paged.page_index - page_before <= page_limit);
                try std.testing.expect(coordinator.telemetry.chapter_bytes_decoded - decoded_before <= @import("limits").reader.reconstruction_bytes_per_update);
            }
            if (!coordinator.book_loading) break;
        }
        try std.testing.expect(!coordinator.book_loading);
        try std.testing.expectEqual(reader.Lifecycle.ready, coordinator.lifecycle);
        try std.testing.expectEqual(saved.chapter, coordinator.positionSnapshot().chapter);
        try std.testing.expectEqual(saved.word_ordinal, coordinator.positionSnapshot().word_ordinal);
        const loading = coordinator.telemetry.loading;
        const resume_stats = loading.phases[@intFromEnum(telemetry.LoadingPhase.resume_rebuild)];
        try std.testing.expect(loading.cache_hit);
        // Pages/Scroll batch completed pages; RSVP uses its word-decoder budget.
        if (presentation == 3) {
            try std.testing.expect(resume_stats.updates >= 60 and resume_stats.updates <= 70);
        } else try std.testing.expect(resume_stats.updates <= if (presentation == 2) @as(u32, 16) else @as(u32, 24));
    }
}

fn testFontHeight(_: *anyopaque, _: @import("../src/storage/settings.zig").ReadingFont) usize {
    return 20;
}
