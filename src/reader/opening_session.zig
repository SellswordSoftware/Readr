const std = @import("std");
const zip = @import("../archive/zip.zig");
const epub = @import("../publication/epub.zig");
const publication_navigation = @import("../publication/navigation.zig");
const limits = @import("limits").reader;

pub const Phase = enum {
    open,
    scan_archive,
    validate_directory,
    hash_directory,
    load_publication_cache,
    find_mimetype,
    read_mimetype,
    find_container,
    read_container,
    parse_container,
    find_package,
    read_package,
    parse_package,
    find_navigation,
    read_navigation,
    find_ncx,
    read_ncx,
};

pub const NavigationSource = enum { epub3, ncx };
pub const NavigationCompletion = enum { find_ncx, opened };
pub const MetadataTarget = enum { mimetype, container, package };
pub const Failure = enum { unavailable, invalid_archive, missing_mimetype, invalid_mimetype };
pub const Result = union(enum) { opened, failed: Failure };

/// The adapter owns the handle storage; the session owns when to close it.
pub const FileLease = struct {
    context: *anyopaque,
    close: *const fn (context: *anyopaque) void,
};

pub const NavigationParser = union(enum) {
    epub3: publication_navigation.Parser,
    ncx: publication_navigation.NcxParser,

    pub fn feed(self: *NavigationParser, bytes: []const u8) publication_navigation.Error!void {
        switch (self.*) {
            .epub3 => |*parser| try parser.feed(bytes),
            .ncx => |*parser| try parser.feed(bytes),
        }
    }

    pub fn finish(self: *NavigationParser) publication_navigation.Error!void {
        switch (self.*) {
            .epub3 => |*parser| try parser.finish(),
            .ncx => |*parser| try parser.finish(),
        }
    }

    pub fn labelCount(self: *const NavigationParser) u8 {
        return switch (self.*) {
            .epub3 => |*parser| parser.labelCount(),
            .ncx => |*parser| parser.labelCount(),
        };
    }
};

pub fn navigationParser(source: NavigationSource, publication: *epub.Publication, path: []const u8) NavigationParser {
    return switch (source) {
        .epub3 => .{ .epub3 = publication_navigation.Parser.init(publication, path) },
        .ncx => .{ .ncx = publication_navigation.NcxParser.init(publication, path) },
    };
}

/// Owns temporary opening/parser state and a lease on the adapter-owned file handle.
pub const Session = struct {
    file: ?FileLease = null,
    phase: Phase = .open,
    scanner: ?zip.ArchiveScanner = null,
    archive: ?zip.Archive = null,
    validator: ?zip.DirectoryValidator = null,
    directory_buffer: zip.DirectoryBuffer = .{},
    // Store SHA state as bytes to keep Session four-byte aligned. Each hash step
    // restores a small, aligned stack copy.
    directory_hasher: [@sizeOf(std.crypto.hash.sha2.Sha256)]u8 = undefined,
    directory_hash_cursor: u32 = 0,
    directory_digest: [32]u8 = undefined,
    cache_bytes: ?[]u8 = null,
    cache_hit: bool = false,
    scan_buffer: [1024]u8 = undefined,
    filename_buffer: [limits.max_archive_filename_bytes]u8 = undefined,
    local_order: [limits.max_archive_entries]u16 = undefined,
    indexed_entries: [limits.max_archive_entries]zip.IndexedEntry = undefined,
    finder: ?zip.EntryFinder = null,
    stream: ?zip.EntryStream = null,
    target: MetadataTarget = .mimetype,
    output_len: usize = 0,
    output: [limits.metadata_read_chunk_bytes]u8 = undefined,
    mimetype: [32]u8 = undefined,
    mimetype_len: usize = 0,
    container_xml: [epub.max_container_document_bytes]u8 = undefined,
    container_xml_len: usize = 0,
    package_path: [256]u8 = undefined,
    package_path_len: usize = 0,
    navigation_parser: ?NavigationParser = null,
    package_xml: ?[]u8 = null,
    opf_workspace: epub.OpfWorkspace = undefined,
    result: ?Result = null,

    pub fn start() Session {
        return .{};
    }

    pub fn initInPlace(self: *Session) void {
        self.* = .{};
    }

    pub fn takeResult(self: *Session) ?Result {
        const result = self.result;
        self.result = null;
        return result;
    }

    /// After release, the recipient must close the file; session cleanup no longer
    /// does.
    pub fn releaseFileLease(self: *Session) void {
        self.file = null;
    }

    pub fn closeFileLease(self: *Session) void {
        if (self.file) |file| file.close(file.context);
        self.file = null;
    }

    pub fn beginArchiveScan(self: *Session, file: FileLease, reader: zip.Reader) zip.Error!void {
        self.file = file;
        self.scanner = try zip.ArchiveScanner.init(reader);
        self.phase = .scan_archive;
    }

    /// One EOCD scan step per call. A found archive starts on-use directory validation.
    pub fn stepArchiveScan(self: *Session) zip.Error!?zip.Archive {
        var archive = try self.scanner.?.step(&self.scan_buffer) orelse return null;
        archive.require_member_bounds = true;
        self.archive = archive;
        self.validator = try zip.DirectoryValidator.initOnUse(archive, &self.indexed_entries, &self.local_order);
        self.directory_buffer.initInPlace(archive);
        self.validator.?.directory_reader = self.directory_buffer.reader();
        const hasher = std.crypto.hash.sha2.Sha256.init(.{});
        @memcpy(&self.directory_hasher, std.mem.asBytes(&hasher));
        self.directory_hash_cursor = archive.central_directory_offset;
        self.phase = .validate_directory;
        return archive;
    }

    /// Checks one directory record or derives one member boundary without I/O.
    /// The index becomes available only after both passes complete.
    pub fn stepDirectoryValidation(self: *Session) zip.Error!bool {
        if (!try self.validator.?.step(&self.filename_buffer)) return false;
        self.phase = .hash_directory;
        return true;
    }

    /// Hash every central-directory byte, including extra fields and comments.
    /// One bounded sequential read per step; reuse the directory buffer.
    pub fn stepDirectoryHash(self: *Session) zip.Error!bool {
        const archive = self.archive.?;
        var hasher: std.crypto.hash.sha2.Sha256 = undefined;
        @memcpy(std.mem.asBytes(&hasher), &self.directory_hasher);
        const end = archive.central_directory_offset + archive.central_directory_size;
        const count = @min(self.directory_buffer.bytes.len, end - self.directory_hash_cursor);
        if (count != 0) {
            const bytes = self.directory_buffer.bytes[0..count];
            try archive.reader.readAt(self.directory_hash_cursor, bytes);
            hasher.update(bytes);
            self.directory_hash_cursor += @intCast(count);
        }
        @memcpy(&self.directory_hasher, std.mem.asBytes(&hasher));
        if (self.directory_hash_cursor != end) return false;
        hasher.final(&self.directory_digest);
        self.phase = .find_mimetype;
        return true;
    }

    /// The index borrows session buffers. Resolve descriptors and fingerprints before
    /// closing the session.
    pub fn directoryIndex(self: *const Session) error{DirectoryUnavailable}!zip.DirectoryIndex {
        const archive = self.archive orelse return error.DirectoryUnavailable;
        return .{ .archive = archive, .entries = self.indexed_entries[0..archive.entry_count] };
    }

    pub fn mimetypeIsValid(self: *const Session) bool {
        return std.mem.eql(u8, self.mimetype[0..self.mimetype_len], "application/epub+zip");
    }

    pub fn packagePath(self: *const Session) []const u8 {
        return self.package_path[0..self.package_path_len];
    }

    /// The caller must allocate package_xml before appending package chunks.
    pub fn appendMetadataBytes(self: *Session, bytes: []const u8) error{ EntryTooLarge, InvalidPackageBuffer }!void {
        const destination: []u8 = switch (self.target) {
            .mimetype => &self.mimetype,
            .container => &self.container_xml,
            .package => self.package_xml orelse return error.InvalidPackageBuffer,
        };
        if (bytes.len > destination.len - self.output_len) return error.EntryTooLarge;
        @memcpy(destination[self.output_len .. self.output_len + bytes.len], bytes);
        self.output_len += bytes.len;
        switch (self.target) {
            .mimetype => self.mimetype_len = self.output_len,
            .container => self.container_xml_len = self.output_len,
            .package => {},
        }
    }

    pub fn parseContainer(self: *Session) epub.Error!void {
        const path = try epub.parseContainer(self.container_xml[0..self.container_xml_len], &self.package_path);
        self.package_path_len = path.len;
        self.phase = .find_package;
    }

    /// Idempotent: failure and user cancellation can reach the same cleanup path.
    pub fn cancel(self: *Session, allocator: std.mem.Allocator) void {
        if (self.package_xml) |buffer| allocator.free(buffer);
        self.package_xml = null;
        if (self.cache_bytes) |bytes| allocator.free(bytes);
        self.cache_bytes = null;
        self.stream = null;
        self.navigation_parser = null;
        self.closeFileLease();
    }

    pub fn fail(self: *Session, allocator: std.mem.Allocator, failure: Failure) void {
        self.cancel(allocator);
        self.result = .{ .failed = failure };
    }

    pub fn succeed(self: *Session) void {
        self.result = .opened;
    }

    /// No usable EPUB 3 labels means try the NCX fallback.
    pub fn finishNavigation(self: *Session, source: NavigationSource, has_labels: bool) NavigationCompletion {
        self.stream = null;
        self.navigation_parser = null;
        if (source == .epub3 and !has_labels) {
            self.phase = .find_ncx;
            return .find_ncx;
        }
        self.succeed();
        return .opened;
    }

    pub fn finishMetadataRead(self: *Session, target: MetadataTarget) void {
        self.stream = null;
        self.phase = switch (target) {
            .mimetype => .find_container,
            .container => .parse_container,
            .package => .parse_package,
        };
    }

    /// The caller opens the stream before selecting its destination and read phase.
    pub fn beginMetadataRead(self: *Session, target: MetadataTarget) void {
        self.target = target;
        self.output_len = 0;
        self.phase = switch (target) {
            .mimetype => .read_mimetype,
            .container => .read_container,
            .package => .read_package,
        };
        if (target == .mimetype) self.mimetype_len = 0;
        if (target == .container) self.container_xml_len = 0;
    }

    /// Release OPF input only after publication data has been copied out.
    pub fn finishPackageParsing(self: *Session, allocator: std.mem.Allocator) void {
        if (self.package_xml) |buffer| allocator.free(buffer);
        self.package_xml = null;
        self.phase = .find_navigation;
    }

    pub fn beginNavigationRead(self: *Session, source: NavigationSource, publication: *epub.Publication, path: []const u8) void {
        self.output_len = 0;
        self.navigation_parser = navigationParser(source, publication, path);
        self.phase = switch (source) {
            .epub3 => .read_navigation,
            .ncx => .read_ncx,
        };
    }
};

test "a started opening session has no result before file or archive work" {
    var session = Session.start();
    try std.testing.expectEqual(Phase.open, session.phase);
    try std.testing.expect(session.navigation_parser == null);
    try std.testing.expect(session.takeResult() == null);
}

test "cancelling an opening session releases temporary allocations exactly once" {
    var session = Session.start();
    session.package_xml = try std.testing.allocator.alloc(u8, 12);

    session.cancel(std.testing.allocator);
    try std.testing.expect(session.package_xml == null);
    session.cancel(std.testing.allocator);
}

test "cancelling an opening session closes its platform file lease once" {
    const Tracker = struct {
        closed: bool = false,

        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed = true;
        }
    };
    var tracker = Tracker{};
    var session = Session.start();
    session.file = .{ .context = &tracker, .close = Tracker.close };

    session.cancel(std.testing.allocator);
    try std.testing.expect(tracker.closed);
    try std.testing.expect(session.file == null);
}

test "a successful opening can transfer its file lease without closing it" {
    const Tracker = struct {
        closed: bool = false,

        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed = true;
        }
    };
    var tracker = Tracker{};
    var session = Session.start();
    session.file = .{ .context = &tracker, .close = Tracker.close };

    session.releaseFileLease();
    session.cancel(std.testing.allocator);

    try std.testing.expect(!tracker.closed);
    try std.testing.expect(session.file == null);
}

test "a failed opening retains its reader-facing failure result" {
    var session = Session.start();
    session.fail(std.testing.allocator, .invalid_archive);
    try std.testing.expectEqual(Failure.invalid_archive, session.result.?.failed);
}

test "a completed opening retains an opened result" {
    var session = Session.start();
    session.succeed();
    try std.testing.expect(switch (session.takeResult().?) {
        .opened => true,
        .failed => false,
    });
    try std.testing.expect(session.takeResult() == null);
}

test "unlabeled EPUB 3 navigation falls back to NCX" {
    var session = Session.start();
    session.phase = .read_navigation;

    try std.testing.expectEqual(
        NavigationCompletion.find_ncx,
        session.finishNavigation(.epub3, false),
    );
    try std.testing.expectEqual(Phase.find_ncx, session.phase);
    try std.testing.expect(session.stream == null);
    try std.testing.expect(session.navigation_parser == null);
}

test "labeled navigation completes opening" {
    var session = Session.start();
    session.phase = .read_ncx;

    try std.testing.expectEqual(
        NavigationCompletion.opened,
        session.finishNavigation(.ncx, true),
    );
    try std.testing.expect(switch (session.result.?) {
        .opened => true,
        .failed => false,
    });
}

test "metadata read completion selects the matching parse or lookup phase" {
    var session = Session.start();

    session.finishMetadataRead(.mimetype);
    try std.testing.expectEqual(Phase.find_container, session.phase);

    session.finishMetadataRead(.container);
    try std.testing.expectEqual(Phase.parse_container, session.phase);

    session.finishMetadataRead(.package);
    try std.testing.expectEqual(Phase.parse_package, session.phase);
}

test "starting a metadata read resets its target, byte count, and phase" {
    var session = Session.start();
    session.output_len = 37;

    session.beginMetadataRead(.container);

    try std.testing.expectEqual(MetadataTarget.container, session.target);
    try std.testing.expectEqual(@as(usize, 0), session.output_len);
    try std.testing.expectEqual(Phase.read_container, session.phase);
}

test "metadata buffers and container path stay within the opening session" {
    var session = Session.start();

    session.beginMetadataRead(.mimetype);
    try session.appendMetadataBytes("application/epub+zip");
    try std.testing.expect(session.mimetypeIsValid());

    session.beginMetadataRead(.container);
    try session.appendMetadataBytes("<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>");
    try session.parseContainer();
    try std.testing.expectEqualStrings("OPS/book.opf", session.packagePath());
    try std.testing.expectEqual(Phase.find_package, session.phase);
}

test "validated directory entries are exposed in compact form" {
    const NoopReader = struct {
        fn readAt(_: *anyopaque, _: u32, _: []u8) zip.Error!void {}
    };
    var reader_context: u8 = 0;
    var session = Session.start();
    session.archive = .{
        .reader = .{ .context = &reader_context, .size = 0, .read_at = NoopReader.readAt },
        .central_directory_offset = 0,
        .central_directory_size = 0,
        .entry_count = 1,
    };
    session.indexed_entries[0] = zip.indexedEntry("one.xhtml", .{
        .flags = 0,
        .compression = .stored,
        .crc32 = 0,
        .compressed_size = 0,
        .uncompressed_size = 0,
        .local_header_offset = 0,
    });
    const index = try session.directoryIndex();
    try std.testing.expectEqual(@as(u16, 1), index.archive.entry_count);
    try std.testing.expectEqual(@as(usize, 1), index.entries.len);
}

test "successful package parsing releases temporary ownership before navigation" {
    var session = Session.start();
    session.package_xml = try std.testing.allocator.alloc(u8, 12);

    session.finishPackageParsing(std.testing.allocator);

    try std.testing.expect(session.package_xml == null);
    try std.testing.expectEqual(Phase.find_navigation, session.phase);
}

test "starting navigation read installs the source parser and read phase" {
    var session = Session.start();
    var publication: epub.Publication = .{};

    session.beginNavigationRead(.epub3, &publication, "nav.xhtml");
    try std.testing.expectEqual(Phase.read_navigation, session.phase);
    try std.testing.expectEqual(@as(usize, 0), session.output_len);
    try std.testing.expect(switch (session.navigation_parser.?) {
        .epub3 => true,
        .ncx => false,
    });

    session.beginNavigationRead(.ncx, &publication, "toc.ncx");
    try std.testing.expectEqual(Phase.read_ncx, session.phase);
    try std.testing.expect(switch (session.navigation_parser.?) {
        .epub3 => false,
        .ncx => true,
    });
}
