const std = @import("std");
const epub = @import("epub.zig");

/// Choose only the initial destination. Earlier spine items remain available to
/// manual navigation and saved positions.
pub fn firstChapter(publication: *const epub.Publication) u8 {
    if (publication.reading_start) |index| {
        if (index < publication.spine_len) return index;
    }
    for (publication.spine[0..publication.spine_len], 0..) |item, index| {
        if (storyHeading(publication.chapter_labels[index].slice()) or storyHeading(stem(item.slice()))) return @intCast(index);
    }
    for (publication.spine[0..publication.spine_len], 0..) |item, index| {
        if (!frontMatter(publication.chapter_labels[index].slice()) and !frontMatter(stem(item.slice()))) return @intCast(index);
    }
    return 0;
}

test "new books start at the first named chapter rather than cover and contents" {
    var publication: epub.Publication = undefined;
    @memset(std.mem.asBytes(&publication), 0);
    const paths = [_][]const u8{ "OPS/wrap0000.xhtml", "OPS/title.xhtml", "OPS/toc.xhtml", "OPS/text0003.xhtml", "OPS/text0004.xhtml" };
    const labels = [_][]const u8{ "", "Title page", "Contents", "Chapter I", "Chapter II" };
    publication.spine_len = paths.len;
    for (paths, labels, 0..) |path, label, index| {
        @memcpy(publication.spine[index].path[0..path.len], path);
        publication.spine[index].path_len = @intCast(path.len);
        @memcpy(publication.chapter_labels[index].bytes[0..label.len], label);
        publication.chapter_labels[index].len = @intCast(label.len);
    }
    try std.testing.expectEqual(@as(u8, 3), firstChapter(&publication));
}

fn stem(path: []const u8) []const u8 {
    const name = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| index + 1 else 0..];
    return name[0..(std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len)];
}

fn storyHeading(raw: []const u8) bool {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    // Match whole words; filenames may instead join the prefix to a number.
    for ([_][]const u8{ "chapter", "chap", "part", "volume", "prologue" }) |prefix| {
        if (text.len < prefix.len or !std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix)) continue;
        if (text.len == prefix.len) return true;
        const next = text[prefix.len];
        if (std.ascii.isWhitespace(next) or std.ascii.isDigit(next) or next == '_' or next == '-' or next == '.') return true;
    }
    return text.len >= 2 and std.ascii.isDigit(text[0]) and (text[1] == '.' or text[1] == ' ');
}

fn frontMatter(raw: []const u8) bool {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    for ([_][]const u8{ "wrap0000", "cover", "title", "titlepage", "title page", "copyright", "toc", "contents", "table of contents", "frontmatter" }) |name| {
        if (std.ascii.eqlIgnoreCase(text, name)) return true;
    }
    return false;
}

test "explicit reading starts win and ambiguous books keep their beginning" {
    var publication: epub.Publication = undefined;
    @memset(std.mem.asBytes(&publication), 0);
    publication.spine_len = 3;
    try std.testing.expectEqual(@as(u8, 0), firstChapter(&publication));
    publication.reading_start = 2;
    try std.testing.expectEqual(@as(u8, 2), firstChapter(&publication));
    publication.reading_start = 4;
    try std.testing.expectEqual(@as(u8, 0), firstChapter(&publication));
    try std.testing.expect(storyHeading("VOLUME ONE"));
    try std.testing.expect(storyHeading("CHAPTER I. Down the Rabbit-Hole"));
    try std.testing.expect(!storyHeading("Chapterhouse"));
}
