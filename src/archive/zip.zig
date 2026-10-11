const std = @import("std");
const deflate = @import("deflate.zig");
const limits = @import("limits").reader;

pub const Error = error{
    ReadFailed,
    UnexpectedEof,
    FileTooSmall,
    EndOfCentralDirectoryNotFound,
    InvalidEndOfCentralDirectory,
    UnsupportedMultiDisk,
    UnsupportedZip64,
    InvalidCentralDirectory,
    UnsupportedFilenameLength,
    TooManyEntries,
    UnsafePath,
    OverlappingEntries,
    EntryNotFound,
    EncryptedEntry,
    UnsupportedDataDescriptor,
    UnsupportedCompression,
    InvalidLocalHeader,
    EmptyReadBuffer,
    EntryNotFullyRead,
    ChecksumMismatch,
    EntryTooLarge,
    InflateFailed,
};

pub const Reader = struct {
    context: *anyopaque,
    size: u32,
    read_at: *const fn (context: *anyopaque, offset: u32, destination: []u8) Error!void,

    pub fn readAt(self: Reader, offset: u32, destination: []u8) Error!void {
        const end = std.math.add(u32, offset, @intCast(destination.len)) catch return error.UnexpectedEof;
        if (end > self.size) return error.UnexpectedEof;
        return self.read_at(self.context, offset, destination);
    }
};

pub const Archive = struct {
    reader: Reader,
    central_directory_offset: u32,
    central_directory_size: u32,
    entry_count: u16,
    end_record_offset: ?u32 = null,
    require_member_bounds: bool = false,

    pub fn find(self: Archive, name: []const u8, filename_buffer: []u8) Error!Entry {
        var finder = EntryFinder.init(self, name);
        while (finder.entry_index < self.entry_count) {
            if (try finder.step(filename_buffer)) |entry| return entry;
        }
        return error.EntryNotFound;
    }

    pub fn openStored(self: Archive, entry: Entry) Error!StoredEntry {
        if (entry.flags & 0x0001 != 0) return error.EncryptedEntry;
        if (entry.flags & 0x0008 != 0) return error.UnsupportedDataDescriptor;
        if (entry.compression != .stored) return error.UnsupportedCompression;
        if (entry.compressed_size != entry.uncompressed_size) return error.InvalidLocalHeader;

        const data_offset = try self.entryDataOffset(entry);
        const data_end = std.math.add(u32, data_offset, entry.compressed_size) catch return error.InvalidLocalHeader;
        if (data_end > self.reader.size) return error.InvalidLocalHeader;

        return .{
            .reader = self.reader,
            .next_offset = data_offset,
            .end_offset = data_end,
            .expected_crc32 = entry.crc32,
        };
    }

    /// Stored and DEFLATE streams borrow caller-owned storage; opening an entry does
    /// not allocate.
    pub fn begin(self: Archive, entry: Entry, storage: *StreamStorage) Error!EntryStream {
        return switch (entry.compression) {
            .stored => .{ .storage = storage, .kind = .{ .stored = try self.openStored(entry) } },
            .deflated => .{ .storage = storage, .kind = .{ .deflated = try self.openDeflated(entry, storage) } },
            else => error.UnsupportedCompression,
        };
    }

    fn openDeflated(self: Archive, entry: Entry, storage: *StreamStorage) Error!DeflatedEntry {
        if (entry.flags & 0x0001 != 0) return error.EncryptedEntry;
        if (entry.flags & 0x0008 != 0) return error.UnsupportedDataDescriptor;
        if (storage.compressed_input.len == 0 or storage.window.len < 32 * 1024) return error.EntryTooLarge;
        const data_offset = try self.entryDataOffset(entry);
        const compressed_end_offset = std.math.add(u32, data_offset, entry.compressed_size) catch return error.InvalidLocalHeader;
        storage.reset();
        return .{
            .reader = self.reader,
            .next_compressed_offset = data_offset,
            .compressed_end_offset = compressed_end_offset,
            .expected_uncompressed_size = entry.uncompressed_size,
            .expected_crc32 = entry.crc32,
        };
    }

    fn entryDataOffset(self: Archive, entry: Entry) Error!u32 {
        if (self.require_member_bounds and entry.region_end == null) return error.InvalidLocalHeader;
        const region_end = entry.region_end orelse self.central_directory_offset;
        if (region_end > self.central_directory_offset) return error.InvalidLocalHeader;
        const local_header_end = std.math.add(u32, entry.local_header_offset, 30) catch return error.InvalidLocalHeader;
        // Reject directory overlap before reading the local header, so metadata cannot
        // be treated as member data.
        if (entry.local_header_offset >= self.central_directory_offset or local_header_end > self.central_directory_offset) return error.InvalidLocalHeader;
        if (local_header_end > region_end) return error.OverlappingEntries;

        var header: [30]u8 = undefined;
        try self.reader.readAt(entry.local_header_offset, &header);
        if (readU32(header[0..4]) != local_file_header_signature) return error.InvalidLocalHeader;
        if (readU16(header[6..8]) != entry.flags or @as(Compression, @enumFromInt(readU16(header[8..10]))) != entry.compression) return error.InvalidLocalHeader;
        if (readU32(header[14..18]) != entry.crc32 or readU32(header[18..22]) != entry.compressed_size or readU32(header[22..26]) != entry.uncompressed_size) return error.InvalidLocalHeader;

        const filename_length = readU16(header[26..28]);
        const extra_length = readU16(header[28..30]);
        const data_offset = std.math.add(u32, entry.local_header_offset, 30 + filename_length + extra_length) catch return error.InvalidLocalHeader;
        const data_end = std.math.add(u32, data_offset, entry.compressed_size) catch return error.InvalidLocalHeader;
        if (data_end > self.central_directory_offset or data_end > self.reader.size) return error.InvalidLocalHeader;
        if (data_end > region_end) return error.OverlappingEntries;
        return data_offset;
    }

    pub fn open(reader: Reader, scan_buffer: []u8) Error!Archive {
        var scanner = try ArchiveScanner.init(reader);
        while (try scanner.step(scan_buffer)) |archive| return archive;
        return error.EndOfCentralDirectoryNotFound;
    }
};

/// Resumable EOCD scan. Each `step` reads and searches at most one caller-
/// supplied chunk, allowing UI callers to budget archive opening per frame.
pub const ArchiveScanner = struct {
    pub const ReadBoundary = struct { nonzero: u32, zero: u32 };

    reader: Reader,
    earliest_offset: u32,
    scan_end: u32,
    finished: bool = false,
    tail_checked: bool = false,
    tail_signature: [4]u8 = [_]u8{0} ** 4,
    read_boundary: ?ReadBoundary = null,

    pub fn init(reader: Reader) Error!ArchiveScanner {
        if (reader.size < 22) return error.FileTooSmall;
        return .{
            .reader = reader,
            .earliest_offset = reader.size - @min(reader.size, 22 + 65_535),
            .scan_end = reader.size,
        };
    }

    /// Null requests another scan step; exhausting the search returns
    /// EndOfCentralDirectoryNotFound.
    pub fn step(self: *ArchiveScanner, scan_buffer: []u8) Error!?Archive {
        if (scan_buffer.len < 4) return error.FileTooSmall;
        if (self.finished) return error.EndOfCentralDirectoryNotFound;

        // Try the final 22 bytes first: comment-free ZIPs end there, avoiding larger
        // unaligned reads near EOF on device.
        if (!self.tail_checked) {
            self.tail_checked = true;
            const candidate_offset = self.reader.size - 22;
            var header: [22]u8 = undefined;
            try self.reader.readAt(candidate_offset, &header);
            self.tail_signature = header[0..4].*;
            if (readU32(header[0..4]) == end_of_central_directory_signature and readU16(header[20..22]) == 0) {
                self.finished = true;
                return try parseEndOfCentralDirectory(self.reader, header, candidate_offset);
            }
        }
        if (self.read_boundary != null) return self.stepReadBoundaryDiagnostic(scan_buffer);

        const chunk_start = @max(self.earliest_offset, self.scan_end - @min(self.scan_end - self.earliest_offset, @as(u32, @intCast(scan_buffer.len))));
        const chunk_len: usize = self.scan_end - chunk_start;
        try self.reader.readAt(chunk_start, scan_buffer[0..chunk_len]);

        var index = chunk_len - 4;
        while (true) {
            if (readU32(scan_buffer[index..][0..4]) == end_of_central_directory_signature) {
                const candidate_offset = chunk_start + @as(u32, @intCast(index));
                if (candidate_offset <= self.reader.size - 22) {
                    var header: [22]u8 = undefined;
                    try self.reader.readAt(candidate_offset, &header);
                    if (readU16(header[20..22]) == self.reader.size - candidate_offset - 22) {
                        self.finished = true;
                        return try parseEndOfCentralDirectory(self.reader, header, candidate_offset);
                    }
                }
            }
            if (index == 0) break;
            index -= 1;
        }
        if (chunk_start == self.earliest_offset) {
            if (std.mem.allEqual(u8, &self.tail_signature, 0) and self.reader.size > @as(u32, @intCast(scan_buffer.len * 2))) {
                return self.stepReadBoundaryDiagnostic(scan_buffer);
            }
            self.finished = true;
            return error.EndOfCentralDirectoryNotFound;
        }
        // Retain three bytes of overlap so an EOCD signature straddling two
        // chunks is still discovered on the next step.
        self.scan_end = chunk_start + 3;
        return null;
    }

    /// Diagnostic probes narrow a read boundary one step per frame. Zero bytes do not
    /// prove EOF; report only the bracket.
    fn stepReadBoundaryDiagnostic(self: *ArchiveScanner, buffer: []u8) Error!?Archive {
        const probe_len: u32 = @intCast(buffer.len);
        if (self.read_boundary == null) {
            self.read_boundary = .{ .nonzero = 0, .zero = self.reader.size - probe_len };
            return null;
        }
        const boundary = &self.read_boundary.?;
        if (boundary.zero - boundary.nonzero <= probe_len) {
            self.finished = true;
            return error.EndOfCentralDirectoryNotFound;
        }
        const probe_offset = boundary.nonzero + (boundary.zero - boundary.nonzero) / 2;
        try self.reader.readAt(probe_offset, buffer);
        if (std.mem.allEqual(u8, buffer, 0)) {
            boundary.zero = probe_offset;
        } else {
            boundary.nonzero = probe_offset;
        }
        return null;
    }
};

/// Resumable central-directory lookup. Each step reads one directory record
/// and its filename, so callers need not scan a whole large spine in a frame.
pub const EntryFinder = struct {
    archive: Archive,
    name: []const u8,
    cursor: u32,
    entry_index: u16 = 0,

    pub fn init(archive: Archive, name: []const u8) EntryFinder {
        return .{ .archive = archive, .name = name, .cursor = archive.central_directory_offset };
    }

    pub fn step(self: *EntryFinder, filename_buffer: []u8) Error!?Entry {
        if (self.entry_index == self.archive.entry_count) return null;
        const central_directory_end = self.archive.central_directory_offset + self.archive.central_directory_size;
        if (self.cursor > central_directory_end or 46 > central_directory_end - self.cursor) return error.InvalidCentralDirectory;

        var header: [46]u8 = undefined;
        try self.archive.reader.readAt(self.cursor, &header);
        if (readU32(header[0..4]) != central_directory_signature) return error.InvalidCentralDirectory;
        const filename_length = readU16(header[28..30]);
        const extra_length = readU16(header[30..32]);
        const comment_length = readU16(header[32..34]);
        const record_size: u32 = 46 + filename_length + extra_length + comment_length;
        if (record_size > central_directory_end - self.cursor) return error.InvalidCentralDirectory;
        if (filename_length > filename_buffer.len) return error.UnsupportedFilenameLength;
        try self.archive.reader.readAt(self.cursor + 46, filename_buffer[0..filename_length]);
        self.cursor += record_size;
        self.entry_index += 1;
        if (!std.mem.eql(u8, self.name, filename_buffer[0..filename_length])) return null;
        return .{
            .flags = readU16(header[8..10]),
            .compression = @enumFromInt(readU16(header[10..12])),
            .crc32 = readU32(header[16..20]),
            .compressed_size = readU32(header[20..24]),
            .uncompressed_size = readU32(header[24..28]),
            .local_header_offset = readU32(header[42..46]),
        };
    }
};

/// Caller-owned member intervals keep directory validation allocation-free.
pub const MemberRange = struct { start: u32, end: u32 };

/// Compact member metadata retained after validation. A cryptographic name
/// digest avoids reserving 256 bytes per filename for image-heavy EPUBs.
pub const IndexedEntry = struct {
    name_hash: [16]u8,
    entry: Entry,
};

pub fn indexedEntry(name: []const u8, entry: Entry) IndexedEntry {
    return .{ .name_hash = nameHash(name), .entry = entry };
}

/// Store 128-bit name digests instead of full paths to bound index memory.
pub const DirectoryIndex = struct {
    archive: Archive,
    entries: []const IndexedEntry,

    pub fn find(self: *const DirectoryIndex, name: []const u8) Error!Entry {
        const wanted = nameHash(name);
        for (self.entries) |indexed| {
            if (std.mem.eql(u8, &wanted, &indexed.name_hash)) return indexed.entry;
        }
        return error.EntryNotFound;
    }
};

fn nameHash(name: []const u8) [16]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    return digest[0..16].*;
}

/// A caller-owned directory read cache. Keep this in opening's heap state.
/// Local headers use the original reader and cannot evict directory bytes.
pub const DirectoryBuffer = struct {
    source: Reader = undefined,
    start: u32 = 0,
    end: u32 = 0,
    cached_offset: u32 = 0,
    cached_len: usize = 0,
    bytes: [limits.opening_directory_buffer_bytes]u8 = undefined,

    pub fn initInPlace(self: *DirectoryBuffer, archive: Archive) void {
        self.source = archive.reader;
        self.start = archive.central_directory_offset;
        self.end = self.start + archive.central_directory_size;
        self.cached_len = 0;
    }

    pub fn reader(self: *DirectoryBuffer) Reader {
        return .{ .context = self, .size = self.source.size, .read_at = readAt };
    }

    fn readAt(context: *anyopaque, offset: u32, output: []u8) Error!void {
        const self: *DirectoryBuffer = @ptrCast(@alignCast(context));
        if (offset < self.start or offset > self.end or output.len > self.end - offset) return error.InvalidCentralDirectory;
        var cursor = offset;
        var written: usize = 0;
        while (written < output.len) {
            if (self.cached_len == 0 or cursor < self.cached_offset or cursor - self.cached_offset >= self.cached_len) {
                self.cached_offset = cursor;
                self.cached_len = @min(self.bytes.len, self.end - cursor);
                try self.source.readAt(cursor, self.bytes[0..self.cached_len]);
            }
            const index = cursor - self.cached_offset;
            const count = @min(output.len - written, self.cached_len - index);
            @memcpy(output[written..][0..count], self.bytes[index..][0..count]);
            written += count;
            cursor += @intCast(count);
        }
    }
};

/// Full validation checks every local header. On-use validation prepares a
/// physical boundary for every member without reading its local header.
pub const DirectoryValidator = struct {
    pub const Mode = enum { full, deferred_full, on_use };
    archive: Archive,
    ranges: []MemberRange,
    indexed_entries: ?[]IndexedEntry = null,
    directory_reader: ?Reader = null,
    mode: Mode = .full,
    local_order: ?[]u16 = null,
    local_index: u16 = 0,
    cursor: u32,
    entry_index: u16 = 0,

    pub fn init(archive: Archive, ranges: []MemberRange) Error!DirectoryValidator {
        if (archive.entry_count > ranges.len) return error.TooManyEntries;
        return .{ .archive = archive, .ranges = ranges, .cursor = archive.central_directory_offset };
    }

    pub fn initWithIndex(archive: Archive, ranges: []MemberRange, indexed_entries: []IndexedEntry) Error!DirectoryValidator {
        if (archive.entry_count > ranges.len or archive.entry_count > indexed_entries.len) return error.TooManyEntries;
        return .{ .archive = archive, .ranges = ranges, .indexed_entries = indexed_entries, .cursor = archive.central_directory_offset };
    }

    pub fn initOnUse(archive: Archive, indexed_entries: []IndexedEntry, order: []u16) Error!DirectoryValidator {
        if (archive.entry_count > indexed_entries.len or archive.entry_count > order.len) return error.TooManyEntries;
        return .{ .archive = archive, .ranges = &.{}, .indexed_entries = indexed_entries, .local_order = order, .mode = .on_use, .cursor = archive.central_directory_offset };
    }

    /// Returns true only after every declared record has been checked and the
    /// cursor exactly reaches the declared central-directory end.
    pub fn step(self: *DirectoryValidator, filename_buffer: []u8) Error!bool {
        const directory_end = self.archive.central_directory_offset + self.archive.central_directory_size;
        if (self.entry_index == self.archive.entry_count) {
            if (self.cursor != directory_end) return error.InvalidCentralDirectory;
            if (self.local_index < self.entry_index) switch (self.mode) {
                .full => {},
                .deferred_full => return self.stepLocalHeader(),
                .on_use => return self.stepMemberBounds(),
            };
            return true;
        }
        if (self.cursor > directory_end or 46 > directory_end - self.cursor) return error.InvalidCentralDirectory;

        var header: [46]u8 = undefined;
        try (self.directory_reader orelse self.archive.reader).readAt(self.cursor, &header);
        if (readU32(header[0..4]) != central_directory_signature) return error.InvalidCentralDirectory;
        const filename_length = readU16(header[28..30]);
        const extra_length = readU16(header[30..32]);
        const comment_length = readU16(header[32..34]);
        const record_size: u32 = 46 + filename_length + extra_length + comment_length;
        if (record_size > directory_end - self.cursor) return error.InvalidCentralDirectory;
        if (filename_length == 0 or filename_length > filename_buffer.len) return error.UnsupportedFilenameLength;
        try (self.directory_reader orelse self.archive.reader).readAt(self.cursor + 46, filename_buffer[0..filename_length]);
        try validateArchivePath(filename_buffer[0..filename_length]);

        const entry = Entry{
            .flags = readU16(header[8..10]),
            .compression = @enumFromInt(readU16(header[10..12])),
            .crc32 = readU32(header[16..20]),
            .compressed_size = readU32(header[20..24]),
            .uncompressed_size = readU32(header[24..28]),
            .local_header_offset = readU32(header[42..46]),
        };
        if (self.mode == .full) try self.validateMember(entry, self.entry_index);
        if (self.indexed_entries) |indexed_entries| {
            indexed_entries[self.entry_index] = indexedEntry(filename_buffer[0..filename_length], entry);
            if (self.local_order) |order| {
                if (order.len < self.archive.entry_count) return error.TooManyEntries;
                // Incremental nonrecursive insertion sort, one new member per
                // step. Typical ZIPs already have members in file order.
                var position: usize = self.entry_index;
                while (position != 0 and indexed_entries[order[position - 1]].entry.local_header_offset > entry.local_header_offset) : (position -= 1) {
                    order[position] = order[position - 1];
                }
                order[position] = self.entry_index;
            }
        }
        self.cursor += record_size;
        self.entry_index += 1;
        if (self.entry_index == self.archive.entry_count and self.cursor != directory_end) return error.InvalidCentralDirectory;
        return self.entry_index == self.archive.entry_count and self.mode == .full;
    }

    fn stepMemberBounds(self: *DirectoryValidator) Error!bool {
        const entries = self.indexed_entries.?;
        const order = self.local_order.?;
        const entry = &entries[order[self.local_index]].entry;
        const end = if (self.local_index + 1 < self.entry_index)
            entries[order[self.local_index + 1]].entry.local_header_offset
        else
            self.archive.central_directory_offset;
        if (entry.local_header_offset >= self.archive.central_directory_offset or end > self.archive.central_directory_offset) return error.InvalidLocalHeader;
        const header_end = std.math.add(u32, entry.local_header_offset, 30) catch return error.InvalidLocalHeader;
        const minimum_end = std.math.add(u32, header_end, entry.compressed_size) catch return error.InvalidLocalHeader;
        if (minimum_end > end) return error.OverlappingEntries;
        entry.region_end = end;
        self.local_index += 1;
        return self.local_index == self.entry_index;
    }

    fn validateMember(self: *DirectoryValidator, entry: Entry, index: u16) Error!void {
        const start = try self.archive.entryDataOffset(entry);
        const end = std.math.add(u32, start, entry.compressed_size) catch return error.InvalidLocalHeader;
        for (self.ranges[0..index]) |range| {
            if (start < range.end and range.start < end) return error.OverlappingEntries;
        }
        self.ranges[index] = .{ .start = start, .end = end };
    }

    fn stepLocalHeader(self: *DirectoryValidator) Error!bool {
        const entries = self.indexed_entries orelse return error.InvalidCentralDirectory;
        const index = if (self.local_order) |order| order[self.local_index] else self.local_index;
        try self.validateMember(entries[index].entry, self.local_index);
        self.local_index += 1;
        return self.local_index == self.entry_index;
    }
};

fn validateArchivePath(path: []const u8) Error!void {
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.UnsafePath;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        // A final empty segment is a conventional directory entry; empty
        // interior segments, dot segments, and traversal are rejected.
        if (segment.len == 0) {
            if (segments.rest().len == 0) return;
            return error.UnsafePath;
        }
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.UnsafePath;
    }
}

const end_of_central_directory_signature = 0x0605_4b50;
const central_directory_signature = 0x0201_4b50;
const local_file_header_signature = 0x0403_4b50;

pub const Compression = enum(u16) {
    stored = 0,
    deflated = 8,
    _,
};

pub const Entry = struct {
    flags: u16,
    compression: Compression,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    local_header_offset: u32,
    /// Runtime geometry derived from all directory offsets, never cache data.
    region_end: ?u32 = null,
};

/// DEFLATE streams borrow these buffers. Keep them on the heap and at stable addresses
/// until the stream closes; stored entries do not use them.
pub const StreamStorage = struct {
    compressed_input: []u8,
    window: []u8,
    workspace: *deflate.Workspace,
    inflater: deflate.InflateState,
    input_start: usize = 0,
    input_end: usize = 0,

    pub fn init(compressed_input: []u8, window: []u8, workspace: *deflate.Workspace) StreamStorage {
        const storage: StreamStorage = .{
            .compressed_input = compressed_input,
            .window = window,
            .workspace = workspace,
            .inflater = deflate.InflateState.init(window, workspace),
        };
        return storage;
    }

    fn reset(self: *StreamStorage) void {
        self.inflater = deflate.InflateState.init(self.window, self.workspace);
        self.input_start = 0;
        self.input_end = 0;
    }
};

pub const WorkBudget = deflate.WorkBudget;

pub const ReadResult = union(enum) {
    bytes: usize,
    end,
    needs_input,
    yielded,
};

/// A budget yield may produce no bytes. Call finish at EOF to verify size and CRC.
pub const EntryStream = struct {
    storage: *StreamStorage,
    kind: union(enum) {
        stored: StoredEntry,
        deflated: DeflatedEntry,
    },

    pub fn read(self: *EntryStream, output: []u8) Error!ReadResult {
        var budget = WorkBudget{};
        return self.readWithBudget(output, &budget);
    }

    pub fn readWithBudget(self: *EntryStream, output: []u8, budget: *WorkBudget) Error!ReadResult {
        if (output.len == 0) return error.EmptyReadBuffer;
        return switch (self.kind) {
            .stored => |*stored| if (try stored.read(output)) |len| .{ .bytes = len } else .end,
            .deflated => |*deflated| try deflated.read(self.storage, output, budget),
        };
    }

    pub fn finish(self: *EntryStream) Error!void {
        _ = self.storage;
        switch (self.kind) {
            .stored => |*stored| try stored.finish(),
            .deflated => |*deflated| try deflated.finish(),
        }
    }
};

const DeflatedEntry = struct {
    reader: Reader,
    next_compressed_offset: u32,
    compressed_end_offset: u32,
    expected_uncompressed_size: u32,
    expected_crc32: u32,
    crc32: u32 = 0xffff_ffff,
    output_count: u32 = 0,
    ended: bool = false,

    fn read(self: *DeflatedEntry, storage: *StreamStorage, output: []u8, budget: *WorkBudget) Error!ReadResult {
        var output_written: usize = 0;
        while (true) {
            if (self.ended) return if (output_written == 0) .end else .{ .bytes = output_written };
            if (storage.input_start == storage.input_end and budget.input_remaining != 0 and self.next_compressed_offset < self.compressed_end_offset) {
                const remaining = self.compressed_end_offset - self.next_compressed_offset;
                const amount: usize = @min(storage.compressed_input.len, remaining, budget.input_remaining);
                try self.reader.readAt(self.next_compressed_offset, storage.compressed_input[0..amount]);
                self.next_compressed_offset += @intCast(amount);
                storage.input_start = 0;
                storage.input_end = amount;
            }
            const step = storage.inflater.stepWithBudget(storage.compressed_input[storage.input_start..storage.input_end], output[output_written..], budget) catch return error.InflateFailed;
            storage.input_start += step.input_used;
            if (step.output_written != 0) {
                const new_count = std.math.add(u32, self.output_count, @intCast(step.output_written)) catch return error.InflateFailed;
                if (new_count > self.expected_uncompressed_size) return error.InflateFailed;
                self.crc32 = crc32Update(self.crc32, output[output_written .. output_written + step.output_written]);
                self.output_count = new_count;
                output_written += step.output_written;
            }
            switch (step.status) {
                .needs_output => return .{ .bytes = output_written },
                .yielded => return if (output_written == 0) .yielded else .{ .bytes = output_written },
                .needs_input => {
                    if (storage.input_start != storage.input_end) return error.InflateFailed;
                    if (self.next_compressed_offset == self.compressed_end_offset) return error.InflateFailed;
                    if (budget.input_remaining == 0) return if (output_written == 0) .yielded else .{ .bytes = output_written };
                },
                .end => {
                    if (storage.input_start != storage.input_end or self.next_compressed_offset != self.compressed_end_offset) return error.InflateFailed;
                    if (self.output_count != self.expected_uncompressed_size) return error.InflateFailed;
                    self.ended = true;
                    return if (output_written == 0) .end else .{ .bytes = output_written };
                },
            }
        }
    }

    fn finish(self: *const DeflatedEntry) Error!void {
        if (!self.ended) return error.EntryNotFullyRead;
        if (~self.crc32 != self.expected_crc32) return error.ChecksumMismatch;
    }
};

pub const StoredEntry = struct {
    reader: Reader,
    next_offset: u32,
    end_offset: u32,
    expected_crc32: u32,
    crc32: u32 = 0xffff_ffff,

    /// Returns null at end-of-entry. `finish` must be called after null to
    /// validate the entry checksum.
    pub fn read(self: *StoredEntry, destination: []u8) Error!?usize {
        if (destination.len == 0) return error.EmptyReadBuffer;
        if (self.next_offset == self.end_offset) return null;

        const remaining = self.end_offset - self.next_offset;
        const read_len: usize = @min(destination.len, remaining);
        try self.reader.readAt(self.next_offset, destination[0..read_len]);
        self.crc32 = crc32Update(self.crc32, destination[0..read_len]);
        self.next_offset += @intCast(read_len);
        return read_len;
    }

    pub fn finish(self: StoredEntry) Error!void {
        if (self.next_offset != self.end_offset) return error.EntryNotFullyRead;
        if (~self.crc32 != self.expected_crc32) return error.ChecksumMismatch;
    }
};

fn parseEndOfCentralDirectory(reader: Reader, header: [22]u8, end_record_offset: u32) Error!Archive {
    if (readU32(header[0..4]) != end_of_central_directory_signature) return error.InvalidEndOfCentralDirectory;
    if (readU16(header[4..6]) != 0 or readU16(header[6..8]) != 0) return error.UnsupportedMultiDisk;

    const entry_count = readU16(header[10..12]);
    const central_directory_size = readU32(header[12..16]);
    const central_directory_offset = readU32(header[16..20]);
    if (entry_count == 0xffff or central_directory_size == 0xffff_ffff or central_directory_offset == 0xffff_ffff) return error.UnsupportedZip64;
    if (central_directory_offset > end_record_offset or central_directory_size > end_record_offset - central_directory_offset) return error.InvalidEndOfCentralDirectory;

    return .{
        .reader = reader,
        .central_directory_offset = central_directory_offset,
        .central_directory_size = central_directory_size,
        .entry_count = entry_count,
        .end_record_offset = end_record_offset,
    };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn crc32Update(crc: u32, bytes: []const u8) u32 {
    var result = crc;
    for (bytes) |byte| {
        result = (result >> 8) ^ crc32_table[(result ^ byte) & 0xff];
    }
    return result;
}

/// Keep the CRC table in read-only storage to avoid per-bit work and heap/stack
/// allocation.
const crc32_table = blk: {
    @setEvalBranchQuota(3_000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, index| {
        var value: u32 = @intCast(index);
        for (0..8) |_| value = if (value & 1 != 0) (value >> 1) ^ 0xedb8_8320 else value >> 1;
        entry.* = value;
    }
    break :blk table;
};

test "computes the standard CRC-32 value" {
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), ~crc32Update(0xffff_ffff, "123456789"));
}

test "opens a single stored entry archive" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    try std.testing.expectEqual(@as(u16, 1), archive.entry_count);
}

test "directory validator accepts a complete ordinary archive" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var ranges: [1]MemberRange = undefined;
    const archive = try Archive.open(source.reader(), &scan_buffer);
    var validator = try DirectoryValidator.init(archive, &ranges);
    try std.testing.expect(try validator.step(&filename_buffer));
}

test "validated directory index resolves entries through compact hashes" {
    var archive_bytes: [194]u8 = undefined;
    const archive_len = makeTwoStoredEntriesArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var ranges: [2]MemberRange = undefined;
    var indexed_entries: [2]IndexedEntry = undefined;
    const archive = try Archive.open(source.reader(), &scan_buffer);
    var validator = try DirectoryValidator.initWithIndex(archive, &ranges, &indexed_entries);
    while (!try validator.step(&filename_buffer)) {}
    const index = DirectoryIndex{ .archive = archive, .entries = &indexed_entries };
    const entry = try index.find("second");
    var stored = try archive.openStored(entry);
    var output: [1]u8 = undefined;
    _ = try stored.read(&output);
    try stored.finish();
    try std.testing.expectEqualStrings("b", &output);
}

test "directory validator rejects traversal member names before lookup" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    @memcpy(archive_bytes[58 + 46 .. 58 + 46 + "../evil!".len], "../evil!");
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var ranges: [1]MemberRange = undefined;
    const archive = try Archive.open(source.reader(), &scan_buffer);
    var validator = try DirectoryValidator.init(archive, &ranges);
    try std.testing.expectError(error.UnsafePath, validator.step(&filename_buffer));
}

test "scans the end record incrementally" {
    var archive_bytes: [138]u8 = undefined;
    const end_record_len = makeStoredMimetypeArchive(&archive_bytes);
    writeU16(&archive_bytes, end_record_len - 2, 4);
    @memcpy(archive_bytes[end_record_len .. end_record_len + 4], "note");
    const archive_len = end_record_len + 4;
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [4]u8 = undefined;
    var scanner = try ArchiveScanner.init(source.reader());
    var steps: usize = 0;
    var archive: ?Archive = null;
    while (archive == null) {
        archive = try scanner.step(&scan_buffer);
        steps += 1;
    }
    try std.testing.expect(steps > 1);
    try std.testing.expectEqual(@as(u16, 1), archive.?.entry_count);
}

test "zero-tail scan failure narrows the readable offset boundary" {
    const ZeroBoundaryReader = struct {
        const size = 4 * 1024 * 1024;
        const boundary = 2 * 1024 * 1024;

        fn readAt(_: *anyopaque, offset: u32, destination: []u8) Error!void {
            @memset(destination, if (offset < boundary) 0x7f else 0);
        }
    };
    var context: u8 = 0;
    const reader = Reader{
        .context = &context,
        .size = ZeroBoundaryReader.size,
        .read_at = ZeroBoundaryReader.readAt,
    };
    var scan_buffer: [1024]u8 = undefined;
    var scanner = try ArchiveScanner.init(reader);
    while (true) {
        const result = scanner.step(&scan_buffer) catch |err| {
            try std.testing.expectEqual(error.EndOfCentralDirectoryNotFound, err);
            break;
        };
        try std.testing.expect(result == null);
    }
    const boundary = scanner.read_boundary.?;
    try std.testing.expect(boundary.nonzero < ZeroBoundaryReader.boundary);
    try std.testing.expect(boundary.zero >= ZeroBoundaryReader.boundary);
    try std.testing.expect(boundary.zero - boundary.nonzero <= scan_buffer.len);
}

test "finds the stored mimetype entry by archive name" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    try std.testing.expectEqual(Compression.stored, entry.compression);
    try std.testing.expectEqual(@as(u32, 20), entry.uncompressed_size);
}

test "find scans past nonmatching central-directory entries" {
    var archive_bytes: [194]u8 = undefined;
    const archive_len = makeTwoStoredEntriesArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("second", &filename_buffer);
    try std.testing.expectEqual(@as(u32, 1), entry.uncompressed_size);
    var stored = try archive.openStored(entry);
    var output: [1]u8 = undefined;
    _ = try stored.read(&output);
    try stored.finish();
    try std.testing.expectEqualStrings("b", &output);
}

test "finds a central-directory entry one record at a time" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    var finder = EntryFinder.init(archive, "mimetype");
    const entry = (try finder.step(&filename_buffer)).?;
    try std.testing.expectEqual(@as(u16, 1), finder.entry_index);
    try std.testing.expectEqual(@as(u32, 20), entry.uncompressed_size);
}

test "streams and validates a stored entry" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var output: [20]u8 = undefined;
    var read_buffer: [5]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    var stored = try archive.openStored(entry);
    var output_len: usize = 0;
    while (try stored.read(&read_buffer)) |read_len| {
        @memcpy(output[output_len .. output_len + read_len], read_buffer[0..read_len]);
        output_len += read_len;
    }
    try stored.finish();
    try std.testing.expectEqualStrings("application/epub+zip", output[0..output_len]);
}

test "EntryStream reads stored entries in bounded caller buffers" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [4]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);
    var output: [20]u8 = undefined;
    var read_buffer: [3]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    var output_len: usize = 0;
    while (true) {
        switch (try stream.read(&read_buffer)) {
            .bytes => |len| {
                try std.testing.expect(len != 0);
                @memcpy(output[output_len .. output_len + len], read_buffer[0..len]);
                output_len += len;
            },
            .end => break,
            .yielded => {},
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    try std.testing.expectEqualStrings("application/epub+zip", output[0..output_len]);
}

test "EntryStream reports end after an exact-sized output read" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [4]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);
    var output: [20]u8 = undefined;
    var terminal_buffer: [1]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    try std.testing.expectEqual(ReadResult{ .bytes = output.len }, try stream.read(&output));
    try std.testing.expectEqual(ReadResult.end, try stream.read(&terminal_buffer));
    try stream.finish();
    try std.testing.expectEqualStrings("application/epub+zip", &output);
}

test "EntryStream rejects an empty output buffer" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [4]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    try std.testing.expectError(error.EmptyReadBuffer, stream.read(&.{}));
}

test "EntryStream inflates a DEFLATE member from small file chunks" {
    var archive_bytes: [122]u8 = undefined;
    const archive_len = makeDeflatedStoredBlockArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [2]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);
    var output: [3]u8 = undefined;
    var output_chunk: [1]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("chapter", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    var output_len: usize = 0;
    while (true) {
        switch (try stream.read(&output_chunk)) {
            .bytes => |len| {
                @memcpy(output[output_len .. output_len + len], output_chunk[0..len]);
                output_len += len;
            },
            .end => break,
            .yielded => {},
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    try std.testing.expectEqualStrings("cat", output[0..output_len]);
}

test "EntryStream inflates fixed-Huffman members from small file chunks" {
    var archive_bytes: [119]u8 = undefined;
    const archive_len = makeFixedDeflatedArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [2]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);
    var output: [18]u8 = undefined;
    var output_chunk: [2]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("chapter", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    var output_len: usize = 0;
    while (true) {
        switch (try stream.read(&output_chunk)) {
            .bytes => |len| {
                @memcpy(output[output_len .. output_len + len], output_chunk[0..len]);
                output_len += len;
            },
            .end => break,
            .yielded => {},
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    try std.testing.expectEqualStrings("abcabcabcabcabcabc", output[0..output_len]);
}

test "rejects a central directory that overlaps its end record" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    writeU32(&archive_bytes, 112 + 12, 55);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;

    try std.testing.expectError(error.InvalidEndOfCentralDirectory, Archive.open(source.reader(), &scan_buffer));
}

test "rejects member data that overlaps the central directory" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    const central_directory_offset = 58;
    // Keep the central-directory size fields internally consistent while
    // extending the member one byte into the directory.
    writeU32(&archive_bytes, 18, 21);
    writeU32(&archive_bytes, 22, 21);
    writeU32(&archive_bytes, central_directory_offset + 20, 21);
    writeU32(&archive_bytes, central_directory_offset + 24, 21);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    try std.testing.expectError(error.InvalidLocalHeader, archive.openStored(entry));
}

const MemoryReader = struct {
    bytes: []const u8,
    header_reads: u32 = 0,

    fn reader(self: *MemoryReader) Reader {
        return .{
            .context = self,
            .size = @intCast(self.bytes.len),
            .read_at = readAt,
        };
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) Error!void {
        const self: *MemoryReader = @ptrCast(@alignCast(context));
        if (destination.len == 30) self.header_reads += 1;
        const start: usize = offset;
        const end = std.math.add(usize, start, destination.len) catch return error.UnexpectedEof;
        if (end > self.bytes.len) return error.UnexpectedEof;
        @memcpy(destination, self.bytes[start..end]);
    }
};

fn makeStoredMimetypeArchive(buffer: []u8) usize {
    @memset(buffer, 0);
    const name = "mimetype";
    const contents = "application/epub+zip";
    const crc: u32 = 0x2cab_616f;
    const local_header_size = 30 + name.len + contents.len;
    const central_directory_offset = local_header_size;
    const central_directory_size = 46 + name.len;
    const end_of_central_directory_offset = central_directory_offset + central_directory_size;

    writeU32(buffer, 0, 0x0403_4b50);
    writeU16(buffer, 4, 20);
    writeU32(buffer, 14, crc);
    writeU32(buffer, 18, contents.len);
    writeU32(buffer, 22, contents.len);
    writeU16(buffer, 26, name.len);
    @memcpy(buffer[30 .. 30 + name.len], name);
    @memcpy(buffer[30 + name.len .. local_header_size], contents);

    writeU32(buffer, central_directory_offset, 0x0201_4b50);
    writeU16(buffer, central_directory_offset + 4, 20);
    writeU16(buffer, central_directory_offset + 6, 20);
    writeU32(buffer, central_directory_offset + 16, crc);
    writeU32(buffer, central_directory_offset + 20, contents.len);
    writeU32(buffer, central_directory_offset + 24, contents.len);
    writeU16(buffer, central_directory_offset + 28, name.len);
    @memcpy(buffer[central_directory_offset + 46 .. central_directory_offset + 46 + name.len], name);

    writeU32(buffer, end_of_central_directory_offset, end_of_central_directory_signature);
    writeU16(buffer, end_of_central_directory_offset + 8, 1);
    writeU16(buffer, end_of_central_directory_offset + 10, 1);
    writeU32(buffer, end_of_central_directory_offset + 12, central_directory_size);
    writeU32(buffer, end_of_central_directory_offset + 16, central_directory_offset);
    return end_of_central_directory_offset + 22;
}

fn makeTwoStoredEntriesArchive(buffer: []u8) usize {
    @memset(buffer, 0);
    const first_name = "one";
    const second_name = "second";
    const first_contents = "a";
    const second_contents = "b";
    const first_local_size = 30 + first_name.len + first_contents.len;
    const second_local_offset = first_local_size;
    const second_local_size = 30 + second_name.len + second_contents.len;
    const central_directory_offset = second_local_offset + second_local_size;
    const first_record_size = 46 + first_name.len;
    const second_record_offset = central_directory_offset + first_record_size;
    const central_directory_size = first_record_size + 46 + second_name.len;
    const end_offset = central_directory_offset + central_directory_size;

    writeU32(buffer, 0, local_file_header_signature);
    writeU16(buffer, 4, 20);
    writeU32(buffer, 14, ~crc32Update(0xffff_ffff, first_contents));
    writeU32(buffer, 18, first_contents.len);
    writeU32(buffer, 22, first_contents.len);
    writeU16(buffer, 26, first_name.len);
    @memcpy(buffer[30 .. 30 + first_name.len], first_name);
    @memcpy(buffer[30 + first_name.len .. first_local_size], first_contents);

    writeU32(buffer, second_local_offset, local_file_header_signature);
    writeU16(buffer, second_local_offset + 4, 20);
    writeU32(buffer, second_local_offset + 14, ~crc32Update(0xffff_ffff, second_contents));
    writeU32(buffer, second_local_offset + 18, second_contents.len);
    writeU32(buffer, second_local_offset + 22, second_contents.len);
    writeU16(buffer, second_local_offset + 26, second_name.len);
    @memcpy(buffer[second_local_offset + 30 .. second_local_offset + 30 + second_name.len], second_name);
    @memcpy(buffer[second_local_offset + 30 + second_name.len .. central_directory_offset], second_contents);

    writeU32(buffer, central_directory_offset, central_directory_signature);
    writeU16(buffer, central_directory_offset + 4, 20);
    writeU16(buffer, central_directory_offset + 6, 20);
    writeU32(buffer, central_directory_offset + 16, ~crc32Update(0xffff_ffff, first_contents));
    writeU32(buffer, central_directory_offset + 20, first_contents.len);
    writeU32(buffer, central_directory_offset + 24, first_contents.len);
    writeU16(buffer, central_directory_offset + 28, first_name.len);
    @memcpy(buffer[central_directory_offset + 46 .. central_directory_offset + 46 + first_name.len], first_name);

    writeU32(buffer, second_record_offset, central_directory_signature);
    writeU16(buffer, second_record_offset + 4, 20);
    writeU16(buffer, second_record_offset + 6, 20);
    writeU32(buffer, second_record_offset + 16, ~crc32Update(0xffff_ffff, second_contents));
    writeU32(buffer, second_record_offset + 20, second_contents.len);
    writeU32(buffer, second_record_offset + 24, second_contents.len);
    writeU16(buffer, second_record_offset + 28, second_name.len);
    writeU32(buffer, second_record_offset + 42, second_local_offset);
    @memcpy(buffer[second_record_offset + 46 .. second_record_offset + 46 + second_name.len], second_name);

    writeU32(buffer, end_offset, end_of_central_directory_signature);
    writeU16(buffer, end_offset + 8, 2);
    writeU16(buffer, end_offset + 10, 2);
    writeU32(buffer, end_offset + 12, central_directory_size);
    writeU32(buffer, end_offset + 16, central_directory_offset);
    return end_offset + 22;
}

fn makeDeflatedStoredBlockArchive(buffer: []u8) usize {
    @memset(buffer, 0);
    const name = "chapter";
    const compressed = [_]u8{ 0x01, 0x03, 0x00, 0xfc, 0xff, 'c', 'a', 't' };
    const crc = ~crc32Update(0xffff_ffff, "cat");
    const local_header_size = 30 + name.len + compressed.len;
    const central_directory_offset = local_header_size;
    const central_directory_size = 46 + name.len;
    const end_of_central_directory_offset = central_directory_offset + central_directory_size;

    writeU32(buffer, 0, local_file_header_signature);
    writeU16(buffer, 4, 20);
    writeU16(buffer, 8, @intFromEnum(Compression.deflated));
    writeU32(buffer, 14, crc);
    writeU32(buffer, 18, compressed.len);
    writeU32(buffer, 22, 3);
    writeU16(buffer, 26, name.len);
    @memcpy(buffer[30 .. 30 + name.len], name);
    @memcpy(buffer[30 + name.len .. local_header_size], &compressed);

    writeU32(buffer, central_directory_offset, central_directory_signature);
    writeU16(buffer, central_directory_offset + 4, 20);
    writeU16(buffer, central_directory_offset + 6, 20);
    writeU16(buffer, central_directory_offset + 10, @intFromEnum(Compression.deflated));
    writeU32(buffer, central_directory_offset + 16, crc);
    writeU32(buffer, central_directory_offset + 20, compressed.len);
    writeU32(buffer, central_directory_offset + 24, 3);
    writeU16(buffer, central_directory_offset + 28, name.len);
    @memcpy(buffer[central_directory_offset + 46 .. central_directory_offset + 46 + name.len], name);

    writeU32(buffer, end_of_central_directory_offset, end_of_central_directory_signature);
    writeU16(buffer, end_of_central_directory_offset + 8, 1);
    writeU16(buffer, end_of_central_directory_offset + 10, 1);
    writeU32(buffer, end_of_central_directory_offset + 12, central_directory_size);
    writeU32(buffer, end_of_central_directory_offset + 16, central_directory_offset);
    return end_of_central_directory_offset + 22;
}

fn makeFixedDeflatedArchive(buffer: []u8) usize {
    @memset(buffer, 0);
    const name = "chapter";
    const compressed = [_]u8{ 0x4b, 0x4c, 0x4a, 0x4e, 0x44, 0x45, 0x00 };
    const contents = "abcabcabcabcabcabc";
    const crc = ~crc32Update(0xffff_ffff, contents);
    const local_header_size = 30 + name.len + compressed.len;
    const central_directory_offset = local_header_size;
    const central_directory_size = 46 + name.len;
    const end_of_central_directory_offset = central_directory_offset + central_directory_size;

    writeU32(buffer, 0, local_file_header_signature);
    writeU16(buffer, 4, 20);
    writeU16(buffer, 8, @intFromEnum(Compression.deflated));
    writeU32(buffer, 14, crc);
    writeU32(buffer, 18, compressed.len);
    writeU32(buffer, 22, contents.len);
    writeU16(buffer, 26, name.len);
    @memcpy(buffer[30 .. 30 + name.len], name);
    @memcpy(buffer[30 + name.len .. local_header_size], &compressed);

    writeU32(buffer, central_directory_offset, central_directory_signature);
    writeU16(buffer, central_directory_offset + 4, 20);
    writeU16(buffer, central_directory_offset + 6, 20);
    writeU16(buffer, central_directory_offset + 10, @intFromEnum(Compression.deflated));
    writeU32(buffer, central_directory_offset + 16, crc);
    writeU32(buffer, central_directory_offset + 20, compressed.len);
    writeU32(buffer, central_directory_offset + 24, contents.len);
    writeU16(buffer, central_directory_offset + 28, name.len);
    @memcpy(buffer[central_directory_offset + 46 .. central_directory_offset + 46 + name.len], name);

    writeU32(buffer, end_of_central_directory_offset, end_of_central_directory_signature);
    writeU16(buffer, end_of_central_directory_offset + 8, 1);
    writeU16(buffer, end_of_central_directory_offset + 10, 1);
    writeU32(buffer, end_of_central_directory_offset + 12, central_directory_size);
    writeU32(buffer, end_of_central_directory_offset + 16, central_directory_offset);
    return end_of_central_directory_offset + 22;
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

test "ZIP yields on empty blocks and repeated table builds then verifies size and CRC" {
    const fixture = @import("../testing/decoder_work_fixture.zig");
    for ([_]fixture.EmptyKind{ .stored, .fixed, .dynamic }) |kind| {
        var archive_buffer: [110000]u8 = undefined;
        var source = fixture.Source{ .bytes = fixture.archive(&archive_buffer, kind, 2000, "cat") };
        var scan: [128]u8 = undefined;
        var name_buffer: [32]u8 = undefined;
        const archive = try Archive.open(source.reader(), &scan);
        const entry = try archive.find(fixture.name, &name_buffer);
        var input: [4096]u8 = undefined;
        var window: [32768]u8 = undefined;
        var workspace: deflate.Workspace = undefined;
        var storage = StreamStorage.init(&input, &window, &workspace);
        var stream = try archive.begin(entry, &storage);
        var output: [3]u8 = undefined;
        var written: usize = 0;
        var yields: usize = 0;
        try std.testing.expectError(error.EntryNotFullyRead, stream.finish());
        for (0..10000) |_| {
            source.bytes_read = 0;
            var budget = WorkBudget{};
            var chunk: [1]u8 = undefined;
            switch (try stream.readWithBudget(&chunk, &budget)) {
                .yielded => {
                    yields += 1;
                    const reads = source.bytes_read;
                    try std.testing.expectEqual(ReadResult.yielded, try stream.readWithBudget(&chunk, &budget));
                    try std.testing.expectEqual(reads, source.bytes_read);
                },
                .bytes => |count| {
                    @memcpy(output[written..][0..count], chunk[0..count]);
                    written += count;
                    // A second read shares the exhausted budget instead of
                    // creating another full quantum in the same update.
                    var zero = WorkBudget{ .steps_remaining = 0 };
                    const result = try stream.readWithBudget(&chunk, &zero);
                    try std.testing.expect(result == .yielded or result == .end);
                },
                .end => break,
                .needs_input => return error.TestUnexpectedResult,
            }
            try std.testing.expect(source.bytes_read <= limits.decoder_input_bytes_per_update);
        } else return error.TestUnexpectedResult;
        try std.testing.expect(yields >= 2);
        try stream.finish();
        try std.testing.expectEqualStrings("cat", output[0..written]);
    }
}

test "yielding does not bypass DEFLATE checksum size or truncation failures" {
    const fixture = @import("../testing/decoder_work_fixture.zig");
    for (0..3) |failure| {
        var bytes: [10000]u8 = undefined;
        var source = fixture.Source{ .bytes = fixture.archive(&bytes, .dynamic, 100, "cat") };
        var scan: [128]u8 = undefined;
        var filename: [32]u8 = undefined;
        const archive = try Archive.open(source.reader(), &scan);
        const entry = try archive.find(fixture.name, &filename);
        var compressed: [4096]u8 = undefined;
        var window: [32768]u8 = undefined;
        var workspace: deflate.Workspace = undefined;
        var storage = StreamStorage.init(&compressed, &window, &workspace);
        var stream = try archive.begin(entry, &storage);
        if (failure == 0) stream.kind.deflated.expected_crc32 ^= 1;
        if (failure == 1) stream.kind.deflated.expected_uncompressed_size += 1;
        if (failure == 2) stream.kind.deflated.compressed_end_offset -= 1;
        var output: [4]u8 = undefined;
        var yields: usize = 0;
        var failed = false;
        for (0..1000) |_| {
            const result = stream.read(&output) catch |err| {
                try std.testing.expect(failure != 0);
                try std.testing.expectEqual(error.InflateFailed, err);
                failed = true;
                break;
            };
            if (result == .yielded) yields += 1;
            if (result == .end) {
                try std.testing.expectEqual(@as(usize, 0), failure);
                try std.testing.expectError(error.ChecksumMismatch, stream.finish());
                failed = true;
                break;
            }
        }
        try std.testing.expect(failed);
        try std.testing.expect(yields > 10);
    }
}

test "deferred buffered validation sorts local members without changing directory lookup order" {
    var archive_bytes: [194]u8 = undefined;
    const length = makeTwoStoredEntriesArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..length] };
    var scan: [64]u8 = undefined;
    const archive = try Archive.open(source.reader(), &scan);
    // Reverse the two records (their lengths differ); local members stay put.
    const offset = archive.central_directory_offset;
    const first_len = 46 + "one".len;
    const second_len = 46 + "second".len;
    var copy: [101]u8 = undefined;
    @memcpy(&copy, archive_bytes[offset..][0..copy.len]);
    @memcpy(archive_bytes[offset..][0..second_len], copy[first_len..][0..second_len]);
    @memcpy(archive_bytes[offset + second_len ..][0..first_len], copy[0..first_len]);
    const buffer = try std.testing.allocator.create(DirectoryBuffer);
    defer std.testing.allocator.destroy(buffer);
    buffer.initInPlace(archive);
    var ranges: [2]MemberRange = undefined;
    var entries: [2]IndexedEntry = undefined;
    var order: [2]u16 = undefined;
    var names: [32]u8 = undefined;
    var validator = try DirectoryValidator.initWithIndex(archive, &ranges, &entries);
    validator.directory_reader = buffer.reader();
    validator.mode = .deferred_full;
    validator.local_order = &order;
    try std.testing.expect(!try validator.step(&names));
    try std.testing.expect(!try validator.step(&names));
    try std.testing.expectEqual(@as(u16, 0), validator.local_index);
    try std.testing.expectEqualSlices(u16, &.{ 1, 0 }, &order);
    try std.testing.expect(!try validator.step(&names));
    try std.testing.expect(try validator.step(&names));
    const directory: DirectoryIndex = .{ .archive = archive, .entries = &entries };
    try std.testing.expectEqual(entries[0].entry, try directory.find("second"));
    try std.testing.expectEqual(entries[1].entry, try directory.find("one"));
    const header_reads = source.header_reads;
    validator = try DirectoryValidator.initOnUse(archive, &entries, &order);
    while (!try validator.step(&names)) {}
    try std.testing.expectEqual(header_reads, source.header_reads);
    try std.testing.expectEqual(@as(?u32, 34), entries[1].entry.region_end);
    try std.testing.expectEqual(@as(?u32, archive.central_directory_offset), entries[0].entry.region_end);
}

test "deferred validation still rejects overlapping members before completion" {
    var archive_bytes: [194]u8 = undefined;
    const length = makeTwoStoredEntriesArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..length] };
    var scan: [64]u8 = undefined;
    const archive = try Archive.open(source.reader(), &scan);
    const second_record = archive.central_directory_offset + 46 + "one".len;
    // Point the second directory record at the first local member and copy
    // its CRC. Local checks succeed individually, but ranges must reject it.
    writeU32(&archive_bytes, second_record + 42, 0);
    writeU32(&archive_bytes, second_record + 16, readU32(archive_bytes[archive.central_directory_offset + 16 ..][0..4]));
    var ranges: [2]MemberRange = undefined;
    var entries: [2]IndexedEntry = undefined;
    var names: [32]u8 = undefined;
    var validator = try DirectoryValidator.initWithIndex(archive, &ranges, &entries);
    validator.mode = .deferred_full;
    try std.testing.expect(!try validator.step(&names));
    try std.testing.expect(!try validator.step(&names));
    try std.testing.expect(!try validator.step(&names));
    try std.testing.expectError(error.OverlappingEntries, validator.step(&names));
}

test "on-use directory validation does no header I/O and checks members on opening" {
    var bytes: [194]u8 = undefined;
    const length = makeTwoStoredEntriesArchive(&bytes);
    var source: MemoryReader = .{ .bytes = bytes[0..length] };
    var scan: [64]u8 = undefined;
    var archive = try Archive.open(source.reader(), &scan);
    archive.require_member_bounds = true;
    var entries: [2]IndexedEntry = undefined;
    var order: [2]u16 = undefined;
    var names: [32]u8 = undefined;
    bytes[34] ^= 1; // Corrupt the unused second member's local signature.
    var validator = try DirectoryValidator.initOnUse(archive, &entries, &order);
    while (!try validator.step(&names)) {}
    try std.testing.expectEqual(@as(u32, 0), source.header_reads);
    const directory: DirectoryIndex = .{ .archive = archive, .entries = &entries };
    const first = try directory.find("one");
    try std.testing.expectEqual(@as(?u32, 34), first.region_end);
    const second = try directory.find("second");
    try std.testing.expectEqual(@as(?u32, archive.central_directory_offset), second.region_end);
    var stored = try archive.openStored(first);
    var output: [1]u8 = undefined;
    _ = try stored.read(&output);
    try stored.finish();
    try std.testing.expectEqualStrings("a", &output);
    try std.testing.expectError(error.InvalidLocalHeader, archive.openStored(second));
    var unbounded = first;
    unbounded.region_end = null;
    try std.testing.expectError(error.InvalidLocalHeader, archive.openStored(unbounded));
    // Bounds still apply when the local variable header differs from the
    // directory's minimum possible extent, including an empty payload.
    writeU16(&bytes, 28, 1);
    try std.testing.expectError(error.OverlappingEntries, archive.openStored(first));
    writeU32(&bytes, 18, 0);
    writeU32(&bytes, 22, 0);
    writeU16(&bytes, 28, 2);
    var empty = first;
    empty.compressed_size = 0;
    empty.uncompressed_size = 0;
    try std.testing.expectError(error.OverlappingEntries, archive.openStored(empty));
}

test "on-use bounds reject duplicate offsets impossible extents and arithmetic overflow" {
    for (0..5) |mutation| {
        var bytes: [194]u8 = undefined;
        const length = makeTwoStoredEntriesArchive(&bytes);
        var source: MemoryReader = .{ .bytes = bytes[0..length] };
        var scan: [64]u8 = undefined;
        const archive = try Archive.open(source.reader(), &scan);
        const first = archive.central_directory_offset;
        const second = first + 46 + "one".len;
        switch (mutation) {
            0 => writeU32(&bytes, second + 42, 0), // Duplicate header.
            1 => writeU32(&bytes, first + 20, 5), // Cannot fit before next header.
            2 => writeU32(&bytes, first + 20, std.math.maxInt(u32)),
            3 => writeU32(&bytes, second + 42, archive.central_directory_offset),
            4 => writeU32(&bytes, second + 42, std.math.maxInt(u32)),
            else => unreachable,
        }
        var entries: [2]IndexedEntry = undefined;
        var order: [2]u16 = undefined;
        var names: [32]u8 = undefined;
        var validator = try DirectoryValidator.initOnUse(archive, &entries, &order);
        var failure: ?Error = null;
        for (0..4) |_| {
            _ = validator.step(&names) catch |err| {
                failure = err;
                break;
            };
        }
        try std.testing.expectEqual(if (mutation < 2) error.OverlappingEntries else error.InvalidLocalHeader, failure.?);
        try std.testing.expectEqual(@as(u32, 0), source.header_reads);
    }
}

test "on-use deflated members retain bounds decoding and CRC checks" {
    var bytes: [160]u8 = undefined;
    const length = makeDeflatedStoredBlockArchive(&bytes);
    var source: MemoryReader = .{ .bytes = bytes[0..length] };
    var scan: [64]u8 = undefined;
    var archive = try Archive.open(source.reader(), &scan);
    archive.require_member_bounds = true;
    var entries: [1]IndexedEntry = undefined;
    var order: [1]u16 = undefined;
    var names: [32]u8 = undefined;
    var validator = try DirectoryValidator.initOnUse(archive, &entries, &order);
    while (!try validator.step(&names)) {}
    const entry = entries[0].entry;
    var input: [8]u8 = undefined;
    const window = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(window);
    const workspace = try std.testing.allocator.create(deflate.Workspace);
    defer std.testing.allocator.destroy(workspace);
    var storage = StreamStorage.init(&input, window, workspace);
    for (0..2) |corrupt| {
        if (corrupt != 0) bytes[30 + "chapter".len + 5] ^= 1;
        var stream = try archive.begin(entry, &storage);
        var output: [8]u8 = undefined;
        while (true) {
            if (try stream.read(&output) == .end) break;
        }
        if (corrupt == 0) try stream.finish() else try std.testing.expectError(error.ChecksumMismatch, stream.finish());
    }
    writeU16(&bytes, 28, 1);
    try std.testing.expectError(error.InvalidLocalHeader, archive.begin(entry, &storage));
}

test "on-use bounds allow gaps and zero length stored members" {
    var bytes: [194]u8 = undefined;
    const length = makeTwoStoredEntriesArchive(&bytes);
    var source: MemoryReader = .{ .bytes = bytes[0..length] };
    var scan: [64]u8 = undefined;
    const archive = try Archive.open(source.reader(), &scan);
    for ([_]usize{ 14, 18, 22, archive.central_directory_offset + 16, archive.central_directory_offset + 20, archive.central_directory_offset + 24 }) |offset| writeU32(&bytes, offset, 0);
    var entries: [2]IndexedEntry = undefined;
    var order: [2]u16 = undefined;
    var names: [32]u8 = undefined;
    var validator = try DirectoryValidator.initOnUse(archive, &entries, &order);
    while (!try validator.step(&names)) {}
    var empty = try archive.openStored(entries[0].entry);
    var output: [1]u8 = undefined;
    try std.testing.expect(try empty.read(&output) == null);
    try empty.finish();
    var last = try archive.openStored(entries[1].entry);
    _ = try last.read(&output);
    try last.finish();
    try std.testing.expectEqualStrings("b", &output);
}
