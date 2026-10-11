const std = @import("std");

pub const Error = error{InvalidRecord};
pub const encoded_size = 16;

pub const Mode = enum(u1) {
    paged = 0,
    rsvp = 1,
};

pub const Position = struct {
    book_id: u32,
    layout_revision: u16,
    chapter: u16,
    word_ordinal: u32,
    mode: Mode = .paged,
    /// Describes this saved viewport, never a permanent completion award.
    at_book_end: bool = false,
    // Versions 2 and 3 used this payload as a Paged page number. Keep it
    // explicit so a legacy record is rebuilt through the old page path once.
    legacy_paged_page: ?u32 = null,
};

pub fn encode(position: Position, output: *[encoded_size]u8) void {
    // Version 5 adds a positional terminal-view hint in the chapter field.
    // The physical word ordinal and the 16-byte payload remain unchanged.
    std.debug.assert(position.chapter < 128);
    output.* = .{ 'E', 'P', 'R', 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, output[4..8], position.book_id, .little);
    std.mem.writeInt(u16, output[8..10], position.layout_revision | (if (position.mode == .rsvp) @as(u16, 0x8000) else 0), .little);
    std.mem.writeInt(u16, output[10..12], position.chapter | (if (position.at_book_end) @as(u16, 0x8000) else 0), .little);
    std.mem.writeInt(u32, output[12..16], position.word_ordinal, .little);
}

pub fn decode(input: *const [encoded_size]u8) Error!Position {
    if (!std.mem.eql(u8, input[0..3], "EPR")) return error.InvalidRecord;
    const version = input[3];
    if (version != 2 and version != 3 and version != 4 and version != 5) return error.InvalidRecord;
    const stored_revision = std.mem.readInt(u16, input[8..10], .little);
    const mode: Mode = if (version >= 3 and (stored_revision & 0x8000) != 0) .rsvp else .paged;
    const payload = std.mem.readInt(u32, input[12..16], .little);
    const stored_chapter = std.mem.readInt(u16, input[10..12], .little);
    if (version == 5 and (stored_chapter & 0x7f80) != 0) return error.InvalidRecord;
    return .{
        .book_id = std.mem.readInt(u32, input[4..8], .little),
        .layout_revision = if (version >= 3) stored_revision & 0x7fff else stored_revision,
        .chapter = if (version == 5) stored_chapter & 0x7f else stored_chapter,
        .at_book_end = version == 5 and (stored_chapter & 0x8000) != 0,
        .word_ordinal = payload,
        .mode = mode,
        .legacy_paged_page = if (version < 4 and mode == .paged) payload else null,
    };
}

/// Stable hash of the supplied path bytes, not a content identity. Hash collisions are
/// possible.
pub fn bookIdentity(path: []const u8) u32 {
    var hash: u32 = 0x811c_9dc5;
    for (path) |byte| {
        hash ^= byte;
        hash *%= 0x0100_0193;
    }
    return hash;
}

pub fn matches(position: Position, book_id: u32, layout_revision: u16) bool {
    return position.book_id == book_id and position.layout_revision == layout_revision;
}

pub fn matchesExact(position: Position, book_id: u32, layout_revision: u16, mode: Mode) bool {
    return matches(position, book_id, layout_revision) and position.mode == mode;
}

test "round trips a version 5 RSVP chapter and word position" {
    var bytes: [encoded_size]u8 = undefined;
    encode(.{ .book_id = 7, .layout_revision = 1, .chapter = 3, .word_ordinal = 42, .mode = .rsvp }, &bytes);
    try std.testing.expectEqual(Position{ .book_id = 7, .layout_revision = 1, .chapter = 3, .word_ordinal = 42, .mode = .rsvp }, try decode(&bytes));
}

test "version 5 paged positions retain a word ordinal, not a legacy page" {
    var bytes: [encoded_size]u8 = undefined;
    encode(.{ .book_id = 7, .layout_revision = 1, .chapter = 3, .word_ordinal = 42, .mode = .paged }, &bytes);
    const decoded = try decode(&bytes);
    try std.testing.expectEqual(@as(u32, 42), decoded.word_ordinal);
    try std.testing.expect(decoded.legacy_paged_page == null);
}

test "migrates a version 2 paged record" {
    var bytes = [_]u8{ 'E', 'P', 'R', 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, bytes[4..8], 7, .little);
    std.mem.writeInt(u16, bytes[8..10], 1, .little);
    std.mem.writeInt(u16, bytes[10..12], 3, .little);
    std.mem.writeInt(u32, bytes[12..16], 42, .little);
    try std.testing.expectEqual(Position{ .book_id = 7, .layout_revision = 1, .chapter = 3, .word_ordinal = 42, .mode = .paged, .legacy_paged_page = 42 }, try decode(&bytes));
}

test "migrates a version 3 paged page and preserves its RSVP word" {
    var paged = [_]u8{ 'E', 'P', 'R', 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u16, paged[8..10], 1, .little);
    std.mem.writeInt(u32, paged[12..16], 9, .little);
    const old_page = try decode(&paged);
    try std.testing.expectEqual(@as(?u32, 9), old_page.legacy_paged_page);

    paged[8] = 1;
    paged[9] = 0x80;
    const old_rsvp = try decode(&paged);
    try std.testing.expectEqual(Mode.rsvp, old_rsvp.mode);
    try std.testing.expectEqual(@as(u32, 9), old_rsvp.word_ordinal);
    try std.testing.expect(old_rsvp.legacy_paged_page == null);
}

test "binds a resume record to one book and layout revision" {
    const book = bookIdentity("books/example.epub");
    var bytes: [encoded_size]u8 = undefined;
    encode(.{ .book_id = book, .layout_revision = 2, .chapter = 3, .word_ordinal = 42 }, &bytes);
    const position = try decode(&bytes);
    try std.testing.expect(matches(position, book, 2));
    try std.testing.expect(!matches(position, bookIdentity("books/other.epub"), 2));
    try std.testing.expect(!matches(position, book, 3));
}

test "distinguishes an exact RSVP resume from a safe cross-mode location" {
    const position = Position{ .book_id = 7, .layout_revision = 1, .chapter = 3, .word_ordinal = 42, .mode = .rsvp };
    try std.testing.expect(matchesExact(position, 7, 1, .rsvp));
    try std.testing.expect(!matchesExact(position, 7, 1, .paged));
}

test "terminal viewport hint round trips without moving the semantic cursor" {
    for ([_]Mode{ .paged, .rsvp }) |mode| {
        const position = Position{ .book_id = 7, .layout_revision = 123, .chapter = 127, .word_ordinal = 91, .mode = mode, .at_book_end = true };
        var bytes: [encoded_size]u8 = undefined;
        encode(position, &bytes);
        try std.testing.expectEqual(@as(u8, 5), bytes[3]);
        try std.testing.expectEqual(position, try decode(&bytes));
        // The next ordinary location removes the hint from the saved record.
        var earlier = position;
        earlier.at_book_end = false;
        earlier.word_ordinal = 42;
        encode(earlier, &bytes);
        try std.testing.expectEqual(earlier, try decode(&bytes));
    }
}

test "version 4 locations restore without a terminal hint and version 5 rejects reserved chapter bits" {
    var bytes: [encoded_size]u8 = undefined;
    encode(.{ .book_id = 7, .layout_revision = 1, .chapter = 3, .word_ordinal = 42 }, &bytes);
    bytes[3] = 4;
    try std.testing.expect(!(try decode(&bytes)).at_book_end);
    bytes[3] = 5;
    bytes[11] = 1;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
}
