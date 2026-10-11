const std = @import("std");
const reader_layout = @import("reader_layout.zig");
const pagination = @import("../content/pagination.zig");

pub const anchor_y: usize = 113;
pub const top: usize = 122;
pub const bottom: usize = 206;
pub const text_top: usize = 128;
pub const text_bottom: usize = 204;
pub const sample = "The morning light fell across the open book. Beyond the window, leaves moved quietly in the breeze.";
pub const rsvp_sample = "Reading";

pub const Lines = struct {
    text: [8][]const u8 = undefined,
    count: u8 = 0,
};

pub fn layout(font_height: usize, measure: pagination.Measure) Lines {
    var lines: Lines = .{};
    const limit = @min(lines.text.len, (text_bottom - text_top + reader_layout.minimum_line_gap) / reader_layout.lineAdvance(font_height));
    var start: usize = 0;
    while (start < sample.len and lines.count < limit) {
        var end = start;
        var next = start;
        while (next < sample.len) {
            const word_end = if (std.mem.indexOfScalarPos(u8, sample, next, ' ')) |space| space else sample.len;
            // Like the reader, measure the whole candidate line to include kerning.
            if (end != start and measure.width(measure.context, sample[start..word_end]) > reader_layout.text_width) break;
            end = word_end;
            next = @min(sample.len, word_end + 1);
        }
        lines.text[lines.count] = sample[start..end];
        lines.count += 1;
        start = @min(sample.len, end + 1);
    }
    return lines;
}

test "font preview wraps measured words and includes only complete fitting lines" {
    const Fake = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len * 24;
        }
    };
    var context: u8 = 0;
    const measure = pagination.Measure{ .context = &context, .width = Fake.width };
    const large = layout(30, measure);
    try std.testing.expectEqual(@as(u8, 2), large.count);
    try std.testing.expectEqualStrings("The morning", large.text[0]);
    try std.testing.expectEqualStrings("light fell", large.text[1]);
    const small = layout(11, measure);
    try std.testing.expectEqual(@as(u8, 6), small.count);
    for (small.text[0..small.count]) |line| try std.testing.expect(measure.width(&context, line) <= reader_layout.text_width);
    try std.testing.expectEqualStrings(large.text[0], small.text[0]);
    try std.testing.expectEqual(@as(u8, 0), layout(100, measure).count);
}
