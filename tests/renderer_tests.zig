const std = @import("std");
const pdapi = @import("../src/platform/playdate_api_definitions.zig");
const Renderer = @import("../src/platform/playdate_renderer.zig").Renderer;

test "Unicode drawing and measurement submit codepoint counts to the SDK" {
    const Fake = struct {
        var length: usize = 0;
        fn font(_: ?*pdapi.LCDFont) callconv(.c) void {}
        fn glyph(_: ?*pdapi.LCDFont, _: u32, _: ?*?*pdapi.LCDBitmap, _: ?*c_int) callconv(.c) ?*pdapi.LCDFontGlyph {
            return @ptrFromInt(4);
        }
        fn draw(_: ?*const anyopaque, len: usize, _: pdapi.PDStringEncoding, _: c_int, _: c_int) callconv(.c) c_int {
            length = len;
            return @intCast(len);
        }
        fn width(_: ?*pdapi.LCDFont, _: ?*const anyopaque, len: usize, _: pdapi.PDStringEncoding, _: c_int) callconv(.c) c_int {
            length = len;
            return @intCast(len);
        }
    };
    var graphics: pdapi.PlaydateGraphics = undefined;
    graphics.setFont = Fake.font;
    graphics.getFontGlyph = Fake.glyph;
    graphics.drawText = Fake.draw;
    graphics.getTextWidth = Fake.width;
    var api: pdapi.PlaydateAPI = undefined;
    api.graphics = &graphics;
    var renderer: Renderer = undefined;
    const face: *pdapi.LCDFont = @ptrFromInt(4);
    renderer.initInPlace(&api, face, face, face, face, face, face, face, face, face, face, face);
    for ([_][]const u8{ "", "plain ASCII", "café", "“Hello”—", "東京", "😀" }) |text| {
        const count = try std.unicode.utf8CountCodepoints(text);
        renderer.readingText(.newsleak_serif, text, 8, 4);
        try std.testing.expectEqual(count, Fake.length);
        try std.testing.expectEqual(@as(c_int, @intCast(count)), renderer.readingTextWidth(.newsleak_serif, text));
        try std.testing.expectEqual(count, Fake.length);
    }
}

test {
    std.testing.refAllDecls(@import("../src/platform/playdate_renderer.zig"));
}
