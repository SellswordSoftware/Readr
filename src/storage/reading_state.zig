const std = @import("std");
const reading_position = @import("resume.zig");

pub const Mode = reading_position.Mode;

pub const ReadingSnapshot = struct {
    book_id: u32,
    layout_revision: u16,
    chapter: u16,
    word_ordinal: u32,
    mode: Mode,
    at_book_end: bool = false,
};

pub fn encodeResume(snapshot: ReadingSnapshot, output: *[reading_position.encoded_size]u8) void {
    reading_position.encode(.{
        .book_id = snapshot.book_id,
        .layout_revision = snapshot.layout_revision,
        .chapter = snapshot.chapter,
        .word_ordinal = snapshot.word_ordinal,
        .mode = snapshot.mode,
        .at_book_end = snapshot.at_book_end,
    }, output);
}

pub const RestoredPosition = union(enum) {
    snapshot: ReadingSnapshot,
    legacy_paged_page: struct {
        chapter: u16,
        page: u32,
    },
};

/// Legacy page records need page-based reconstruction; do not treat their payload as a
/// word ordinal.
pub fn restoreResume(input: *const [reading_position.encoded_size]u8, book_id: u32, layout_revision: u16) ?RestoredPosition {
    const position = reading_position.decode(input) catch return null;
    if (!reading_position.matches(position, book_id, layout_revision)) return null;
    if (position.legacy_paged_page) |page| return .{ .legacy_paged_page = .{
        .chapter = position.chapter,
        .page = page,
    } };
    return .{ .snapshot = .{
        .book_id = position.book_id,
        .layout_revision = position.layout_revision,
        .chapter = position.chapter,
        .word_ordinal = position.word_ordinal,
        .mode = position.mode,
        .at_book_end = position.at_book_end,
    } };
}

test "a reading snapshot preserves the version 5 resume record bytes" {
    const snapshot = ReadingSnapshot{
        .book_id = 0x12_34_56_78,
        .layout_revision = 7,
        .chapter = 3,
        .word_ordinal = 42,
        .mode = .rsvp,
    };
    var actual: [reading_position.encoded_size]u8 = undefined;
    encodeResume(snapshot, &actual);

    var expected: [reading_position.encoded_size]u8 = undefined;
    reading_position.encode(.{
        .book_id = snapshot.book_id,
        .layout_revision = snapshot.layout_revision,
        .chapter = snapshot.chapter,
        .word_ordinal = snapshot.word_ordinal,
        .mode = snapshot.mode,
    }, &expected);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "restore rejects a snapshot for another book or layout" {
    var bytes: [reading_position.encoded_size]u8 = undefined;
    encodeResume(.{
        .book_id = 7,
        .layout_revision = 2,
        .chapter = 3,
        .word_ordinal = 42,
        .mode = .paged,
    }, &bytes);

    try std.testing.expect(restoreResume(&bytes, 8, 2) == null);
    try std.testing.expect(restoreResume(&bytes, 7, 3) == null);
}

test "saved terminal viewport metadata is restored separately from its actual word" {
    const snapshot = ReadingSnapshot{ .book_id = 1, .layout_revision = 1, .chapter = 2, .word_ordinal = 90, .mode = .paged, .at_book_end = true };
    var bytes: [reading_position.encoded_size]u8 = undefined;
    encodeResume(snapshot, &bytes);
    try std.testing.expectEqual(snapshot, restoreResume(&bytes, 1, 1).?.snapshot);
}
