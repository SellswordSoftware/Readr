const std = @import("std");
const epub = @import("../publication/epub.zig");
const zip = @import("../archive/zip.zig");

// Encode bytes explicitly, excluding padding and pointers. Bump the revision when
// parsing, label policy, or the format changes.
pub const revision: u32 = 1;
const header_size = 452;
const item_size = 199;
pub const encoded_size = header_size + epub.max_spine_items * item_size + 4;
const checksum_offset = encoded_size - 4;
pub const Key = struct { book_id: u32, file_size: u32, directory_digest: [32]u8 };

pub fn encode(bytes: []u8, key: Key, publication: *const epub.Publication, directory: *const zip.DirectoryIndex, fingerprint: [16]u8) void {
    std.debug.assert(bytes.len == encoded_size);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "RPUB");
    put32(bytes, 4, revision);
    put32(bytes, 8, key.book_id);
    put32(bytes, 12, key.file_size);
    @memcpy(bytes[16..48], &key.directory_digest);
    bytes[48] = publication.spine_len;
    putString(bytes[49..178], publication.titleSlice());
    putString(bytes[178..307], publication.navigation_document.slice());
    putString(bytes[307..436], publication.ncx_document.slice());
    @memcpy(bytes[436..452], &fingerprint);
    for (publication.spine[0..publication.spine_len], 0..) |*item, index| {
        const record = bytes[header_size + index * item_size ..][0..item_size];
        putString(record[0..129], item.slice());
        putString(record[129..178], publication.chapter_labels[index].slice());
        if (directory.find(item.slice())) |entry| {
            record[178] = 1;
            putEntry(record[179..199], entry);
        } else |_| {}
    }
    put32(bytes, checksum_offset, std.hash.Crc32.hash(bytes[0..checksum_offset]));
}

/// Validate before mutating publication. Decode into caller-owned heap storage to avoid
/// large return values.
pub fn decode(bytes: []const u8, key: Key, directory: *const zip.DirectoryIndex, publication: *epub.Publication) bool {
    if (bytes.len != encoded_size or !std.mem.eql(u8, bytes[0..4], "RPUB")) return false;
    if (get32(bytes, 4) != revision or get32(bytes, 8) != key.book_id or get32(bytes, 12) != key.file_size) return false;
    if (!std.mem.eql(u8, bytes[16..48], &key.directory_digest)) return false;
    if (get32(bytes, checksum_offset) != std.hash.Crc32.hash(bytes[0..checksum_offset])) return false;
    const count = bytes[48];
    if (count == 0 or count > epub.max_spine_items) return false;
    if (!validString(bytes[49..178]) or !validString(bytes[178..307]) or !validString(bytes[307..436])) return false;
    for (0..count) |index| {
        const record = bytes[header_size + index * item_size ..][0..item_size];
        if (!validString(record[0..129]) or record[0] == 0 or !validString(record[129..178]) or record[178] > 1) return false;
        const entry = directory.find(string(record[0..129])) catch null;
        if (record[178] == 0) {
            if (entry != null) return false;
        } else {
            const current = entry orelse return false;
            var expected: [20]u8 = undefined;
            putEntry(&expected, current);
            if (!std.mem.eql(u8, &expected, record[179..199])) return false;
        }
    }
    @memset(std.mem.asBytes(publication), 0);
    publication.spine_len = count;
    copyString(bytes[49..178], &publication.title, &publication.title_len);
    copyString(bytes[178..307], &publication.navigation_document.path, &publication.navigation_document.path_len);
    copyString(bytes[307..436], &publication.ncx_document.path, &publication.ncx_document.path_len);
    for (0..count) |index| {
        const record = bytes[header_size + index * item_size ..][0..item_size];
        copyString(record[0..129], &publication.spine[index].path, &publication.spine[index].path_len);
        copyString(record[129..178], &publication.chapter_labels[index].bytes, &publication.chapter_labels[index].len);
    }
    return true;
}

/// Call only after successful decode; preserves the progress index identity.
pub fn cachedFingerprint(bytes: []const u8) [16]u8 {
    return bytes[436..452].*;
}

fn validString(bytes: []const u8) bool {
    return bytes[0] < bytes.len and std.mem.indexOfScalar(u8, string(bytes), 0) == null;
}
fn string(bytes: []const u8) []const u8 {
    return bytes[1..][0..bytes[0]];
}
fn putString(bytes: []u8, value: []const u8) void {
    std.debug.assert(value.len < bytes.len);
    bytes[0] = @intCast(value.len);
    @memcpy(bytes[1..][0..value.len], value);
}
fn copyString(bytes: []const u8, output: []u8, length: *u8) void {
    length.* = bytes[0];
    @memcpy(output[0..length.*], string(bytes));
}
fn get32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn put32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn putEntry(bytes: []u8, entry: zip.Entry) void {
    std.mem.writeInt(u16, bytes[0..2], entry.flags, .little);
    std.mem.writeInt(u16, bytes[2..4], @intFromEnum(entry.compression), .little);
    put32(bytes, 4, entry.crc32);
    put32(bytes, 8, entry.compressed_size);
    put32(bytes, 12, entry.uncompressed_size);
    put32(bytes, 16, entry.local_header_offset);
}

test "publication cache validates identity revision bounds and all spine descriptors before restoring" {
    const bytes = try std.testing.allocator.alloc(u8, encoded_size);
    defer std.testing.allocator.free(bytes);
    const original = try std.testing.allocator.create(epub.Publication);
    defer std.testing.allocator.destroy(original);
    const restored = try std.testing.allocator.create(epub.Publication);
    defer std.testing.allocator.destroy(restored);
    @memset(std.mem.asBytes(original), 0);
    original.spine_len = epub.max_spine_items;
    putStringInto(&original.title, &original.title_len, "Example");
    putStringInto(&original.navigation_document.path, &original.navigation_document.path_len, "nav.xhtml");
    for (original.spine[0..original.spine_len], 0..) |*item, index| {
        putStringInto(&item.path, &item.path_len, if (index == 1) "missing.xhtml" else "chapter.xhtml");
        putStringInto(&original.chapter_labels[index].bytes, &original.chapter_labels[index].len, "Chapter label");
    }
    const NullReader = struct {
        fn read(_: *anyopaque, _: u32, _: []u8) zip.Error!void {}
    };
    var context: u8 = 0;
    const entry: zip.Entry = .{ .flags = 0, .compression = .deflated, .crc32 = 1, .compressed_size = 10, .uncompressed_size = 20, .local_header_offset = 2 };
    var entries = [_]zip.IndexedEntry{zip.indexedEntry("chapter.xhtml", entry)};
    const directory: zip.DirectoryIndex = .{ .archive = .{ .reader = .{ .context = &context, .size = 1234, .read_at = NullReader.read }, .central_directory_offset = 1000, .central_directory_size = 200, .entry_count = 1 }, .entries = &entries };
    const key: Key = .{ .book_id = 7, .file_size = 1234, .directory_digest = [_]u8{0xa5} ** 32 };
    encode(bytes, key, original, &directory, [_]u8{3} ** 16);
    try std.testing.expect(decode(bytes, key, &directory, restored));
    try std.testing.expectEqual(@as(u8, epub.max_spine_items), restored.spine_len);
    try std.testing.expectEqualStrings("missing.xhtml", restored.spine[1].slice());
    try std.testing.expectEqualStrings("Chapter label", restored.chapter_labels[127].slice());
    try std.testing.expectEqualStrings("Example", restored.titleSlice());
    var wrong = key;
    wrong.book_id += 1;
    try std.testing.expect(!decode(bytes, wrong, &directory, restored));
    wrong = key;
    wrong.file_size += 1;
    try std.testing.expect(!decode(bytes, wrong, &directory, restored));
    wrong = key;
    wrong.directory_digest[31] ^= 1;
    try std.testing.expect(!decode(bytes, wrong, &directory, restored));
    try std.testing.expect(!decode(bytes[0 .. bytes.len - 1], key, &directory, restored));
    // Reject corrupt data, and structurally invalid data with a valid CRC.
    const mutations = [_]usize{ 4, 48, 49, header_size, header_size + 178, header_size + 179 };
    for (mutations) |offset| {
        encode(bytes, key, original, &directory, [_]u8{3} ** 16);
        bytes[offset] = 255;
        try std.testing.expect(!decode(bytes, key, &directory, restored));
        put32(bytes, checksum_offset, std.hash.Crc32.hash(bytes[0..checksum_offset]));
        try std.testing.expect(!decode(bytes, key, &directory, restored));
        // Validation failures never partially overwrite the previous publication.
        try std.testing.expectEqualStrings("Example", restored.titleSlice());
        try std.testing.expectEqualStrings("Chapter label", restored.chapter_labels[127].slice());
    }
    encode(bytes, key, original, &directory, [_]u8{3} ** 16);
    entries[0].entry.local_header_offset += 1;
    try std.testing.expect(!decode(bytes, key, &directory, restored));
}
fn putStringInto(output: []u8, length: *u8, value: []const u8) void {
    length.* = @intCast(value.len);
    @memcpy(output[0..value.len], value);
}
