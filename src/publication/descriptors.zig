const std = @import("std");
const zip = @import("../archive/zip.zig");
const epub = @import("epub.zig");

/// Retain value-only descriptors before closing the opening file; initialize their
/// large storage on the heap.
pub const Descriptors = struct {
    ready: bool = false,
    file_size: u32 = 0,
    directory_offset: u32 = 0,
    directory_size: u32 = 0,
    entry_count: u16 = 0,
    end_offset: u32 = 0,
    end_record: [22]u8 = undefined,
    require_member_bounds: bool = false,
    spine_len: u8 = 0,
    spine: [epub.max_spine_items]?zip.Entry = undefined,
    navigation: ?zip.Entry = null,
    ncx: ?zip.Entry = null,

    pub fn resolve(self: *Descriptors, publication: *const epub.Publication, directory: *const zip.DirectoryIndex) zip.Error!void {
        self.ready = false;
        const archive = directory.archive;
        self.end_offset = archive.end_record_offset orelse return error.InvalidEndOfCentralDirectory;
        try archive.reader.readAt(self.end_offset, &self.end_record);
        self.file_size = archive.reader.size;
        self.directory_offset = archive.central_directory_offset;
        self.directory_size = archive.central_directory_size;
        self.entry_count = archive.entry_count;
        self.require_member_bounds = archive.require_member_bounds;
        self.spine_len = publication.spine_len;
        for (publication.spine[0..publication.spine_len], 0..) |*item, index| {
            // Missing members retain chapter-specific recovery semantics.
            self.spine[index] = directory.find(item.slice()) catch null;
        }
        self.navigation = if (publication.navigation_document.path_len != 0) directory.find(publication.navigation_document.slice()) catch null else null;
        self.ncx = if (publication.ncx_document.path_len != 0) directory.find(publication.ncx_document.slice()) catch null else null;
        self.ready = true;
    }

    /// Check file size and directory geometry before reusing offsets. Local headers and
    /// streamed CRCs are still checked when consumed; same-size content edits may pass
    /// this check.
    pub fn bind(self: *const Descriptors, reader: zip.Reader) zip.Error!zip.Archive {
        if (!self.ready or reader.size != self.file_size) return error.InvalidCentralDirectory;
        var end_record: [22]u8 = undefined;
        try reader.readAt(self.end_offset, &end_record);
        if (!std.mem.eql(u8, &end_record, &self.end_record)) return error.InvalidCentralDirectory;
        return .{ .reader = reader, .central_directory_offset = self.directory_offset, .central_directory_size = self.directory_size, .entry_count = self.entry_count, .end_record_offset = self.end_offset, .require_member_bounds = self.require_member_bounds };
    }

    pub fn chapter(self: *const Descriptors, index: u8) zip.Error!zip.Entry {
        if (!self.ready or index >= self.spine_len) return error.EntryNotFound;
        return self.spine[index] orelse error.EntryNotFound;
    }
};

test "bounded resolution preserves digest identity missing chapters and navigation sources" {
    const descriptors = try std.testing.allocator.create(Descriptors);
    defer std.testing.allocator.destroy(descriptors);
    const publication = try std.testing.allocator.create(epub.Publication);
    defer std.testing.allocator.destroy(publication);
    @memset(std.mem.asBytes(publication), 0);
    publication.spine_len = epub.max_spine_items;
    for (&publication.spine) |*item| {
        @memcpy(item.path[0..9], "one.xhtml");
        item.path_len = 9;
    }
    @memcpy(publication.spine[1].path[0..9], "ONE.xhtml");
    @memcpy(publication.navigation_document.path[0..9], "nav.xhtml");
    publication.navigation_document.path_len = 9;
    @memcpy(publication.ncx_document.path[0..8], "gone.ncx");
    publication.ncx_document.path_len = 8;
    const Source = struct {
        fn read(_: *anyopaque, offset: u32, bytes: []u8) zip.Error!void {
            if (offset != 0 or bytes.len != 22) return error.ReadFailed;
            @memset(bytes, 0);
        }
    };
    var context: u8 = 0;
    const entry: zip.Entry = .{ .flags = 0, .compression = .stored, .crc32 = 7, .compressed_size = 4, .uncompressed_size = 4, .local_header_offset = 0 };
    var entries = [_]zip.IndexedEntry{ zip.indexedEntry("one.xhtml", entry), zip.indexedEntry("nav.xhtml", entry) };
    const directory: zip.DirectoryIndex = .{ .archive = .{ .reader = .{ .context = &context, .size = 22, .read_at = Source.read }, .central_directory_offset = 0, .central_directory_size = 0, .entry_count = 2, .end_record_offset = 0 }, .entries = &entries };
    try descriptors.resolve(publication, &directory);
    try std.testing.expectEqual(entry, try descriptors.chapter(127));
    try std.testing.expectError(error.EntryNotFound, descriptors.chapter(1));
    try std.testing.expectError(error.EntryNotFound, descriptors.chapter(128));
    try std.testing.expectEqual(entry, descriptors.navigation.?);
    try std.testing.expect(descriptors.ncx == null);
    // A new publication replaces prior metadata instead of retaining entries.
    publication.spine_len = 0;
    publication.navigation_document.path_len = 0;
    try descriptors.resolve(publication, &directory);
    try std.testing.expect(descriptors.navigation == null);
    try std.testing.expectError(error.EntryNotFound, descriptors.chapter(0));
}
