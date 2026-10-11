const std = @import("std");

pub const GlyphSupport = struct {
    context: *anyopaque,
    has: *const fn (*anyopaque, u21) bool,
};

/// Use the same font fallback for measurement and drawing. Retained text and word
/// ordinals stay unchanged; substitutions do not grow the input.
pub fn format(value: []const u8, output: []u8, glyphs: GlyphSupport) []const u8 {
    // Ordinary ASCII is already covered by every bundled font.
    var has_unicode = false;
    for (value) |byte| if (byte >= 0x80) {
        has_unicode = true;
        break;
    };
    if (!has_unicode) return value;
    var source: usize = 0;
    var written: usize = 0;
    while (source < value.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(value[source]) catch 1;
        const end = @min(source + len, value.len);
        const bytes = value[source..end];
        const valid = len == bytes.len and std.unicode.utf8ValidateSlice(bytes);
        const codepoint = if (valid) std.unicode.utf8Decode(bytes) catch unreachable else 0xfffd;
        const display: []const u8 = if (!valid) "?" else if (codepoint < 0x80 or glyphs.has(glyphs.context, codepoint)) bytes else switch (codepoint) {
            0x2018, 0x2019 => "'",
            0x201c, 0x201d => "\"",
            0x2013 => "-",
            0x2014 => "--",
            0x2026 => "...",
            else => "?",
        };
        if (display.len > output.len - written) break;
        @memcpy(output[written..][0..display.len], display);
        written += display.len;
        source = if (valid) end else source + 1;
    }
    return output[0..written];
}

test "display fallback preserves supported Unicode and substitutes only missing glyphs" {
    const Support = struct {
        fn has(_: *anyopaque, cp: u21) bool {
            return cp == 0xe9;
        }
    };
    var context: u8 = 0;
    var buffer: [64]u8 = undefined;
    const original = "café—“東京”…";
    try std.testing.expectEqualStrings("café--\"??\"...", format(original, &buffer, .{ .context = &context, .has = Support.has }));
    try std.testing.expectEqualStrings("café—“東京”…", original);
    var short: [4]u8 = undefined;
    const clipped = format("ééé", &short, .{ .context = &context, .has = Support.has });
    try std.testing.expectEqualStrings("éé", clipped);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped));
}

test "complete glyph coverage retains the original bytes and invalid sequences stay safe" {
    const All = struct {
        fn has(_: *anyopaque, _: u21) bool {
            return true;
        }
    };
    var context: u8 = 0;
    var buffer: [64]u8 = undefined;
    const glyphs = GlyphSupport{ .context = &context, .has = All.has };
    const value = "“café”—東京…";
    try std.testing.expectEqualStrings(value, format(value, &buffer, glyphs));
    const repaired = format("bad\xe2x", &buffer, glyphs);
    try std.testing.expect(std.unicode.utf8ValidateSlice(repaired));
    try std.testing.expectEqualStrings("bad?x", repaired);
}
