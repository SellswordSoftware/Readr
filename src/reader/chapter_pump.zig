const prefetch_session = @import("prefetch_session.zig");
const std = @import("std");
const epub = @import("../publication/epub.zig");
const publication_descriptors = @import("../publication/descriptors.zig");
const location = @import("reading_location.zig");

pub const OpenJob = struct {
    index: u8,
    action: location.ChapterOpenAction,
    scanner: ?zip.ArchiveScanner = null,
    finder: ?zip.EntryFinder = null,
};
pub const Lookup = union(enum) {
    working,
    failed,
    found: struct { archive: zip.Archive, entry: zip.Entry, index: u8, action: location.ChapterOpenAction },
};

const zip = @import("../archive/zip.zig");
const deflate = @import("../archive/deflate.zig");
const decode_workspace = @import("decode_workspace.zig");
const reader_host = @import("reader_host.zig");
const limits = @import("limits").reader;

/// Initialize in place: streams borrow these decode buffers. Consumers handle
/// pagination and word progress.
pub const Pump = struct {
    chapter_open: ?OpenJob = null,
    decode_workspace: decode_workspace.DecodeWorkspace = .{},
    chapter_lease_open: bool = false,
    active_prefetch_lease: bool = false,
    archive_scan_buffer: [1024]u8 = undefined,
    archive_filename_buffer: [limits.max_archive_filename_bytes]u8 = undefined,
    deflate_input_buffer: [limits.compressed_input_bytes]u8 = undefined,
    deflate_window: [32 * 1024]u8 = undefined,
    deflate_workspace: deflate.Workspace = undefined,
    opening_storage: zip.StreamStorage = undefined,
    chapter_stream: ?zip.EntryStream = null,
    chapter_storage: zip.StreamStorage = undefined,
    chapter_output: [limits.decoded_output_chunk_bytes]u8 = undefined,
    chapter_output_start: usize = 0,
    chapter_output_end: usize = 0,

    pub fn initInPlace(self: *Pump) void {
        self.chapter_open = null;
        self.decode_workspace = .{};
        self.chapter_lease_open = false;
        self.active_prefetch_lease = false;
        self.chapter_stream = null;
        self.chapter_output_start = 0;
        self.chapter_output_end = 0;
    }

    /// Bind retained descriptors or scan a bounded directory batch. Failures leave the
    /// lease open for cancel to release.
    pub fn stepLookup(self: *Pump, files: ?reader_host.Files, path: [:0]const u8, publication: *const epub.Publication, descriptors: *const publication_descriptors.Descriptors) Lookup {
        const job = &(self.chapter_open orelse return .failed);
        const f = files orelse return .failed;
        if (descriptors.ready) {
            const reader = f.open(f.context, .chapter, path) catch return .failed;
            self.chapter_lease_open = true;
            const archive = descriptors.bind(reader) catch return .failed;
            const entry = descriptors.chapter(job.index) catch return .failed;
            return .{ .found = .{ .archive = archive, .entry = entry, .index = job.index, .action = job.action } };
        }
        if (job.scanner == null) {
            const reader = f.open(f.context, .chapter, path) catch return .failed;
            self.chapter_lease_open = true;
            job.scanner = zip.ArchiveScanner.init(reader) catch return .failed;
            return .working;
        }
        if (job.finder == null) {
            const archive = (job.scanner.?.step(&self.archive_scan_buffer) catch return .failed) orelse return .working;
            if (job.index >= publication.spine_len) return .failed;
            job.finder = zip.EntryFinder.init(archive, publication.spine[job.index].slice());
            return .working;
        }
        for (0..limits.chapter_directory_records_per_update) |_| {
            const entry = job.finder.?.step(&self.archive_filename_buffer) catch return .failed;
            if (entry) |found| return .{ .found = .{ .archive = job.finder.?.archive, .entry = found, .index = job.index, .action = job.action } };
            if (job.finder.?.entry_index == job.finder.?.archive.entry_count) return .failed;
        }
        return .working;
    }

    pub fn begin(self: *Pump, archive: zip.Archive, entry: zip.Entry) !void {
        if (self.decode_workspace.beginActive() != .acquired) return error.DecodeWorkspaceBusy;
        self.chapter_storage = zip.StreamStorage.init(&self.deflate_input_buffer, &self.deflate_window, &self.deflate_workspace);
        self.chapter_stream = archive.begin(entry, &self.chapter_storage) catch |err| {
            self.decode_workspace.release(.active);
            return err;
        };
        self.chapter_output_start = 0;
        self.chapter_output_end = 0;
    }

    /// Share one budget across reads in an update. Consume pending output before
    /// reading again.
    pub fn read(self: *Pump, bytes: usize, budget: *zip.WorkBudget) zip.Error!zip.ReadResult {
        std.debug.assert(self.chapter_output_start == self.chapter_output_end);
        const result = try self.chapter_stream.?.readWithBudget(self.chapter_output[0..@min(self.chapter_output.len, bytes)], budget);
        if (result == .bytes) {
            self.chapter_output_start = 0;
            self.chapter_output_end = result.bytes;
        }
        return result;
    }

    pub fn available(self: *const Pump) []const u8 {
        return self.chapter_output[self.chapter_output_start..self.chapter_output_end];
    }

    pub fn consume(self: *Pump, count: usize) void {
        std.debug.assert(count <= self.chapter_output_end - self.chapter_output_start);
        self.chapter_output_start += count;
    }

    /// The adopted stream still borrows prefetch storage; keep that session in place
    /// until EOF.
    pub fn adoptPrefetch(self: *Pump, session: *prefetch_session.Session, files: ?reader_host.Files) void {
        std.debug.assert(session.state == .active);
        self.decode_workspace.activatePrefetch();
        self.releaseChapterLease(files);
        session.detachFile();
        self.active_prefetch_lease = true;
        self.chapter_stream = session.stream;
        self.chapter_output_start = session.output_start;
        self.chapter_output_end = session.output_end;
    }

    pub fn releaseChapterLease(self: *Pump, files: ?reader_host.Files) void {
        if (!self.chapter_lease_open) return;
        self.chapter_lease_open = false;
        if (files) |f| f.close(f.context, .chapter);
    }

    pub fn cancel(self: *Pump, files: ?reader_host.Files) void {
        self.chapter_open = null;
        self.chapter_stream = null;
        self.chapter_output_start = 0;
        self.chapter_output_end = 0;
        if (self.decode_workspace.owner == .active) self.decode_workspace.release(.active);
        self.releaseChapterLease(files);
    }

    pub fn releasePrefetchLease(self: *Pump, files: ?reader_host.Files) void {
        if (!self.active_prefetch_lease) return;
        self.active_prefetch_lease = false;
        if (files) |f| f.close(f.context, .prefetch);
    }
};

test "cancellation and transferred prefetch leases each close exactly once" {
    const Probe = struct {
        chapter_closes: usize = 0,
        prefetch_closes: usize = 0,
        fn close(context: *anyopaque, slot: reader_host.FileSlot) void {
            const probe: *@This() = @ptrCast(@alignCast(context));
            switch (slot) {
                .chapter => probe.chapter_closes += 1,
                .prefetch => probe.prefetch_closes += 1,
                else => unreachable,
            }
        }
        fn open(_: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
            return error.OpenFailed;
        }
        fn list(_: *anyopaque, _: *reader_host.Library) void {}
    };
    const pump = try std.testing.allocator.create(Pump);
    defer std.testing.allocator.destroy(pump);
    pump.initInPlace();
    var probe = Probe{};
    const files = reader_host.Files{ .context = &probe, .open = Probe.open, .close = Probe.close, .list_epubs = Probe.list };
    pump.chapter_lease_open = true;
    pump.active_prefetch_lease = true;
    _ = pump.decode_workspace.beginActive();
    pump.chapter_open = .{ .index = 2, .action = .normal };
    pump.chapter_output_end = 10;
    pump.cancel(files);
    pump.cancel(files);
    // Cancelling the chapter does not implicitly release transferred storage.
    try std.testing.expectEqual(@as(usize, 0), probe.prefetch_closes);
    pump.releasePrefetchLease(files);
    pump.releasePrefetchLease(files);
    try std.testing.expectEqual(@as(usize, 1), probe.chapter_closes);
    try std.testing.expectEqual(@as(usize, 1), probe.prefetch_closes);
    try std.testing.expect(pump.chapter_open == null);
    try std.testing.expectEqual(decode_workspace.DecodeWorkspace.Owner.none, pump.decode_workspace.owner);
    try std.testing.expectEqual(@as(usize, 0), pump.chapter_output_end);
}

test "pump yields bounded decoder work and retains every byte until consumed" {
    const fixture = @import("../testing/decoder_work_fixture.zig");
    var bytes: [90000]u8 = undefined;
    const text = "<p>one two</p>";
    var source = fixture.Source{ .bytes = fixture.archive(&bytes, .dynamic, 200, text) };
    var scan: [128]u8 = undefined;
    var filename: [32]u8 = undefined;
    const archive = try zip.Archive.open(source.reader(), &scan);
    const entry = try archive.find(fixture.name, &filename);
    const pump = try std.testing.allocator.create(Pump);
    defer std.testing.allocator.destroy(pump);
    pump.initInPlace();
    try pump.begin(archive, entry);
    var decoded: [text.len]u8 = undefined;
    var count: usize = 0;
    var yields: usize = 0;
    for (0..2000) |_| {
        source.bytes_read = 0;
        var budget = zip.WorkBudget{};
        const result = try pump.read(2, &budget);
        try std.testing.expect(source.bytes_read <= limits.decoder_input_bytes_per_update);
        switch (result) {
            .bytes => |n| {
                @memcpy(decoded[count..][0..n], pump.chapter_output[pump.chapter_output_start..pump.chapter_output_end]);
                count += n;
                pump.chapter_output_start += n;
            },
            .yielded => yields += 1,
            .end => {
                try pump.chapter_stream.?.finish();
                break;
            },
            .needs_input => return error.TestUnexpectedResult,
        }
    } else return error.TestUnexpectedResult;
    try std.testing.expect(yields > 10);
    try std.testing.expectEqualStrings(text, decoded[0..count]);
    pump.cancel(null);
}
