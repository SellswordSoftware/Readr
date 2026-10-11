const std = @import("std");
const epub = @import("../publication/epub.zig");

pub const visible_rows: u8 = 9;

/// Store spine indices; borrow paths and labels from Publication.
pub const SpineMap = struct {
    ready: bool = false,
    count: u8 = 0,
    indices: [epub.max_spine_items]u8 = undefined,

    pub fn build(self: *SpineMap, publication: *const epub.Publication) void {
        self.count = 0;
        const visibility = Visibility.init(publication);
        for (0..publication.spine_len) |index| {
            if (!visibility.includes(publication, @intCast(index))) continue;
            self.indices[self.count] = @intCast(index);
            self.count += 1;
        }
        self.ready = true;
    }

    pub fn spineIndex(self: *const SpineMap, position_value: u8) ?u8 {
        return if (position_value < self.count) self.indices[position_value] else null;
    }

    pub fn position(self: *const SpineMap, index: u8) u8 {
        for (self.indices[0..self.count], 0..) |spine, pos| if (spine >= index) return @intCast(pos);
        return self.count -| 1;
    }
};

pub const Model = struct {
    entry_count: u8 = 0,
    selected: u8 = 0,
    first_visible: u8 = 0,

    pub fn init(entry_count: u8, current: u8) Model {
        if (entry_count == 0) return .{};
        var model = Model{ .entry_count = entry_count, .selected = @min(current, entry_count - 1) };
        model.ensureSelectedVisible();
        return model;
    }

    pub fn move(self: *Model, direction: i16) void {
        if (self.entry_count == 0 or direction == 0) return;
        const target: i32 = @as(i32, self.selected) + @as(i32, direction);
        self.selected = @intCast(@max(@as(i32, 0), @min(@as(i32, self.entry_count - 1), target)));
        self.ensureSelectedVisible();
    }

    pub fn displayedCount(self: *const Model) u8 {
        return @min(visible_rows, self.entry_count - self.first_visible);
    }

    fn ensureSelectedVisible(self: *Model) void {
        if (self.entry_count == 0) return;
        if (self.selected < self.first_visible) {
            self.first_visible = self.selected;
            return;
        }
        const last_visible = self.first_visible +| visible_rows - 1;
        if (self.selected > last_visible) self.first_visible = self.selected - visible_rows + 1;
    }
};

/// Use the navigation label when present, otherwise a bounded filename fallback.
pub fn formatLabel(output: []u8, index: u8, navigation_label: []const u8, path: []const u8) []const u8 {
    const prefix = std.fmt.bufPrint(output, "{d}. ", .{@as(u16, index) + 1}) catch return "";
    const text = if (navigation_label.len != 0) navigation_label else withoutMarkupExtension(basename(path));
    var output_len = prefix.len;
    appendNormalized(output, &output_len, text);
    return output[0..output_len];
}

/// Hide unlabeled suffixes only in the browser; reading still uses the complete spine.
pub const Visibility = struct {
    final_labeled_spine: ?u8,

    pub fn init(publication: *const epub.Publication) Visibility {
        var index = publication.spine_len;
        while (index != 0) {
            index -= 1;
            if (publication.chapter_labels[index].len != 0) return .{ .final_labeled_spine = index };
        }
        return .{ .final_labeled_spine = null };
    }

    pub fn includes(self: Visibility, publication: *const epub.Publication, index: u8) bool {
        if (index >= publication.spine_len) return false;
        if (isCoverWrapper(publication.spine[index].slice())) return false;
        return if (self.final_labeled_spine) |last| index <= last else true;
    }
};

/// This is a filename heuristic, not XHTML classification; browser filtering also hides
/// later matches.
pub fn isCoverWrapper(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(withoutMarkupExtension(basename(path)), "wrap0000");
}

fn appendNormalized(output: []u8, output_len: *usize, text: []const u8) void {
    var source_index: usize = 0;
    while (source_index < text.len and output_len.* < output.len) {
        const byte = text[source_index];
        if (byte < 0x80) {
            appendBytes(output, output_len, &[_]u8{byte});
            source_index += 1;
            continue;
        }
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(byte) catch {
            appendBytes(output, output_len, "?");
            source_index += 1;
            continue;
        };
        if (sequence_len > text.len - source_index) {
            appendBytes(output, output_len, "?");
            break;
        }
        const bytes = text[source_index .. source_index + sequence_len];
        const codepoint = std.unicode.utf8Decode(bytes) catch {
            appendBytes(output, output_len, "?");
            source_index += 1;
            continue;
        };
        const normalized: []const u8 = if (@import("../content/unicode.zig").isWhitespace(codepoint)) " " else bytes;
        if (normalized.len > output.len - output_len.*) break;
        appendBytes(output, output_len, normalized);
        source_index += sequence_len;
    }
}

fn appendBytes(output: []u8, output_len: *usize, bytes: []const u8) void {
    const copied = @min(output.len - output_len.*, bytes.len);
    @memcpy(output[output_len.* .. output_len.* + copied], bytes[0..copied]);
    output_len.* += copied;
}

fn basename(path: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[separator + 1 ..];
}

fn withoutMarkupExtension(name: []const u8) []const u8 {
    const extensions = [_][]const u8{ ".xhtml", ".html", ".htm" };
    for (extensions) |extension| {
        if (name.len > extension.len and std.ascii.eqlIgnoreCase(name[name.len - extension.len ..], extension)) return name[0 .. name.len - extension.len];
    }
    return name;
}

test "browser model clamps a one-entry spine" {
    var browser = Model.init(1, 0);
    browser.move(20);
    try std.testing.expectEqual(@as(u8, 0), browser.selected);
    try std.testing.expectEqual(@as(u8, 0), browser.first_visible);
    try std.testing.expectEqual(@as(u8, 1), browser.displayedCount());
}

test "browser model keeps the selected chapter inside its viewport" {
    var browser = Model.init(18, 0);
    browser.move(10);
    try std.testing.expectEqual(@as(u8, 10), browser.selected);
    try std.testing.expectEqual(@as(u8, 2), browser.first_visible);
    browser.move(7);
    try std.testing.expectEqual(@as(u8, 17), browser.selected);
    try std.testing.expectEqual(@as(u8, 9), browser.first_visible);
    browser.move(-99);
    try std.testing.expectEqual(@as(u8, 0), browser.selected);
    try std.testing.expectEqual(@as(u8, 0), browser.first_visible);
}

test "browser model opens at a final current chapter and coalesces beyond both bounds" {
    var browser = Model.init(18, 17);
    try std.testing.expectEqual(@as(u8, 17), browser.selected);
    try std.testing.expectEqual(@as(u8, 9), browser.first_visible);
    try std.testing.expectEqual(@as(u8, 9), browser.displayedCount());
    browser.move(120);
    try std.testing.expectEqual(@as(u8, 17), browser.selected);
    browser.move(-120);
    try std.testing.expectEqual(@as(u8, 0), browser.selected);
    try std.testing.expectEqual(@as(u8, 0), browser.first_visible);
}

test "empty browser model and label output are safe" {
    var browser = Model.init(0, 0);
    browser.move(1);
    try std.testing.expectEqual(@as(u8, 0), browser.displayedCount());
    var empty: [0]u8 = .{};
    try std.testing.expectEqualStrings("", formatLabel(&empty, 0, "", "chapter.xhtml"));
}

test "browser label uses a safe filename fallback and bounded output" {
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings("4. chapter", formatLabel(&output, 3, "", "OEBPS/part/chapter.XHTML"));
    var short: [11]u8 = undefined;
    try std.testing.expectEqualStrings("3. a-very-l", formatLabel(&short, 2, "", "OEBPS/a-very-long-chapter.xhtml"));
    try std.testing.expectEqualStrings("1. ", formatLabel(&output, 0, "", "OPS/"));
}

test "browser label prefers a bounded EPUB navigation label" {
    var output: [13]u8 = undefined;
    try std.testing.expectEqualStrings("2. TRANSLATOR", formatLabel(&output, 1, "TRANSLATOR’S PREFACE", "nonsense.xhtml"));
    try std.testing.expectEqualStrings("2. nonsense", formatLabel(&output, 1, "", "nonsense.xhtml"));
}

test "browser labels preserve Unicode punctuation" {
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1. Don’t—wait…", formatLabel(&output, 0, "Don’t—wait…", "ignored.xhtml"));
}

test "TOC boundary preserves gaps and fallback while hiding trailing entries" {
    var publication: epub.Publication = undefined;
    @memset(std.mem.asBytes(&publication), 0);
    const paths = [_][]const u8{
        "OEBPS/wrap0000.xhtml",
        "OEBPS/chapter0001.xhtml",
        "OEBPS/unlisted-middle.xhtml",
        "OEBPS/chapter0003.xhtml",
        "OEBPS/image-wrapper-1.xhtml",
        "OEBPS/image-wrapper-2.xhtml",
    };
    publication.spine_len = @intCast(paths.len);
    for (paths, 0..) |path, index| {
        publication.spine[index].path_len = @intCast(path.len);
        @memcpy(publication.spine[index].path[0..path.len], path);
    }
    publication.chapter_labels[1].len = 1;
    publication.chapter_labels[3].len = 1;

    const bounded = Visibility.init(&publication);
    try std.testing.expect(!bounded.includes(&publication, 0));
    try std.testing.expect(bounded.includes(&publication, 1));
    try std.testing.expect(bounded.includes(&publication, 2));
    try std.testing.expect(bounded.includes(&publication, 3));
    try std.testing.expect(!bounded.includes(&publication, 4));
    try std.testing.expect(!bounded.includes(&publication, 5));

    var mapping: SpineMap = .{};
    mapping.build(&publication);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, mapping.indices[0..mapping.count]);
    try std.testing.expectEqual(@as(?u8, 2), mapping.spineIndex(1));
    try std.testing.expectEqual(@as(?u8, null), mapping.spineIndex(3));
    try std.testing.expectEqual(@as(u8, 0), mapping.position(0));
    try std.testing.expectEqual(@as(u8, 2), mapping.position(5));

    @memset(std.mem.asBytes(&publication.chapter_labels), 0);
    const fallback = Visibility.init(&publication);
    try std.testing.expect(fallback.includes(&publication, 4));
    try std.testing.expect(!fallback.includes(&publication, 0));
    mapping.build(&publication);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, mapping.indices[0..mapping.count]);
    publication.spine_len = 0;
    mapping.build(&publication);
    try std.testing.expectEqual(@as(?u8, null), mapping.spineIndex(0));
    try std.testing.expectEqual(@as(u8, 0), mapping.position(0));
}

test "chapter labels preserve UTF-8 and truncate only between complete codepoints" {
    const label = "café — 東京";
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1. café — 東京", formatLabel(&output, 0, label, ""));
    for (0..output.len + 1) |len| {
        const result = formatLabel(output[0..len], 0, label, "");
        try std.testing.expect(std.unicode.utf8ValidateSlice(result));
    }
    try std.testing.expectEqualStrings("1. café next", formatLabel(&output, 0, "café\u{a0}next", ""));
}
