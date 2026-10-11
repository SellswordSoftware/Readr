const std = @import("std");
const App = @import("../src/app.zig").App;
const pdapi = @import("../src/platform/playdate_api_definitions.zig");
const Allocator = @import("../src/platform/playdate_allocator.zig").PlaydateAllocator;
const reader = @import("../src/reader/reader_coordinator.zig");

const Fake = struct {
    var now: u32 = 0;
    var pressed: pdapi.PDButtons = 0;
    var clears: usize = 0;
    var texts: usize = 0;
    var measurements: usize = 0;
    fn clock() callconv(.c) c_uint {
        return now;
    }
    fn buttons(current: ?*pdapi.PDButtons, pushed: ?*pdapi.PDButtons, released: ?*pdapi.PDButtons) callconv(.c) void {
        if (current) |value| value.* = 0;
        if (pushed) |value| value.* = pressed;
        if (released) |value| value.* = 0;
    }
    fn crank() callconv(.c) f32 {
        return 0;
    }
    fn yes() callconv(.c) c_int {
        return 1;
    }
    fn clear(_: pdapi.LCDColor) callconv(.c) void {
        clears += 1;
    }
    fn background(_: pdapi.LCDSolidColor) callconv(.c) void {}
    fn mode(_: pdapi.LCDBitmapDrawMode) callconv(.c) void {}
    fn font(_: ?*pdapi.LCDFont) callconv(.c) void {}
    fn fontHeight(_: ?*pdapi.LCDFont) callconv(.c) u8 {
        return 20;
    }
    fn glyph(_: ?*pdapi.LCDFont, _: u32, _: ?*?*pdapi.LCDBitmap, _: ?*c_int) callconv(.c) ?*pdapi.LCDFontGlyph {
        return @ptrFromInt(4);
    }
    fn width(_: ?*pdapi.LCDFont, _: ?*const anyopaque, len: usize, _: pdapi.PDStringEncoding, _: c_int) callconv(.c) c_int {
        measurements += 1;
        return @intCast(len * 7);
    }
    fn text(_: ?*const anyopaque, _: usize, _: pdapi.PDStringEncoding, _: c_int, _: c_int) callconv(.c) c_int {
        texts += 1;
        return 1;
    }
    fn line(_: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: pdapi.LCDColor) callconv(.c) void {}
    fn rect(_: c_int, _: c_int, _: c_int, _: c_int, _: pdapi.LCDColor) callconv(.c) void {}
    fn clip(_: c_int, _: c_int, _: c_int, _: c_int) callconv(.c) void {}
    fn noArgs() callconv(.c) void {}
    fn roundRect(_: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: pdapi.LCDColor) callconv(.c) void {}
    fn outlineRoundRect(_: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: pdapi.LCDColor) callconv(.c) void {}

    fn setup(app: *App, api: *pdapi.PlaydateAPI, system: *pdapi.PlaydateSys, graphics: *pdapi.PlaydateGraphics, allocator: *Allocator, mode_value: reader.ReadingMode) !void {
        now = 0;
        pressed = 0;
        clears = 0;
        texts = 0;
        measurements = 0;
        system.* = undefined;
        system.getCurrentTimeMilliseconds = clock;
        system.getButtonState = buttons;
        system.getCrankChange = crank;
        system.isCrankDocked = yes;
        system.getReduceFlashing = yes;
        graphics.* = undefined;
        graphics.clear = clear;
        graphics.setBackgroundColor = background;
        graphics.setDrawMode = mode;
        graphics.setFont = font;
        graphics.getFontHeight = fontHeight;
        graphics.getFontGlyph = glyph;
        graphics.getTextWidth = width;
        graphics.drawText = text;
        graphics.drawLine = line;
        graphics.fillRect = rect;
        graphics.drawRect = rect;
        graphics.setClipRect = clip;
        graphics.clearClipRect = noArgs;
        graphics.fillRoundRect = roundRect;
        graphics.drawRoundRect = outlineRoundRect;
        api.* = undefined;
        api.system = system;
        api.graphics = graphics;
        allocator.* = Allocator.init(system);
        app.playdate = api;
        app.audio = null;
        app.sound_policy = .{};
        app.sound_batch = .{};
        app.allocator = allocator;
        const face: *pdapi.LCDFont = @ptrFromInt(4);
        app.renderer.initInPlace(api, face, face, face, face, face, face, face, face, face, face, face);
        app.render_frames = .{};
        app.coordinator.initInPlace(128);
        app.coordinator.mode = mode_value;
        app.coordinator.screen = .reading;
        app.coordinator.lifecycle = .ready;
        app.coordinator.book_session.publication.spine_len = 1;
        if (mode_value == .paged) {
            app.coordinator.paged.current_ready = true;
            try app.coordinator.paged.pages[0].appendLineWithMetadata("one two", 0, 2);
            app.coordinator.paged.pages[0].word_count = 2;
        } else {
            app.coordinator.rsvp_reader.begin(0);
            _ = try app.coordinator.rsvp_reader.feed("<p>one two three </p>");
        }
    }
};

test "120 idle SDK updates draw once instead of 120 times in Pages and paused RSVP" {
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    var api: pdapi.PlaydateAPI = undefined;
    var system: pdapi.PlaydateSys = undefined;
    var graphics: pdapi.PlaydateGraphics = undefined;
    var allocator: Allocator = undefined;
    for ([_]reader.ReadingMode{ .paged, .rsvp }) |mode| {
        for ([_]bool{ true, false }) |force_redraw| {
            try Fake.setup(app, &api, &system, &graphics, &allocator, mode);
            try std.testing.expectEqual(@as(c_int, 1), app.updateAndRender());
            const first_texts = Fake.texts;
            const first_measurements = Fake.measurements;
            for (1..120) |frame| {
                Fake.now = @intCast(frame * 33);
                if (force_redraw) app.render_frames.invalidate();
                try std.testing.expectEqual(@as(c_int, if (force_redraw) 1 else 0), app.updateAndRender());
            }
            try std.testing.expectEqual(@as(usize, if (force_redraw) 120 else 1), Fake.clears);
            try std.testing.expectEqual(first_texts * @as(usize, if (force_redraw) 120 else 1), Fake.texts);
            try std.testing.expectEqual(first_measurements * @as(usize, if (force_redraw) 120 else 1), Fake.measurements);
            try std.testing.expectEqual(Fake.now, app.coordinator.frame_now_ms);
        }
    }
}

test "SDK idle updates still handle inputs and resume requests a new frame" {
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    var api: pdapi.PlaydateAPI = undefined;
    var system: pdapi.PlaydateSys = undefined;
    var graphics: pdapi.PlaydateGraphics = undefined;
    var allocator: Allocator = undefined;
    try Fake.setup(app, &api, &system, &graphics, &allocator, .rsvp);
    _ = app.updateAndRender();
    try std.testing.expectEqual(@as(c_int, 0), app.updateAndRender());
    const old_wpm = app.coordinator.rsvp_reader.wpm;
    Fake.pressed = pdapi.BUTTON_UP;
    try std.testing.expectEqual(@as(c_int, 1), app.updateAndRender());
    try std.testing.expect(app.coordinator.rsvp_reader.wpm != old_wpm);
    Fake.pressed = 0;
    try std.testing.expectEqual(@as(c_int, 0), app.updateAndRender());
    app.handleSystemEvent(.EventResume);
    try std.testing.expectEqual(@as(c_int, 1), app.updateAndRender());
    try std.testing.expectEqual(@as(c_int, 0), app.updateAndRender());
}

test "background progress changes redraw an idle view and then settle" {
    const progress = @import("../src/storage/progress.zig");
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    var api: pdapi.PlaydateAPI = undefined;
    var system: pdapi.PlaydateSys = undefined;
    var graphics: pdapi.PlaydateGraphics = undefined;
    var allocator: Allocator = undefined;
    try Fake.setup(app, &api, &system, &graphics, &allocator, .paged);
    app.coordinator.progress_worker.index = try progress.Index.init(.{ .book_id = 7, .publication_fingerprint = [_]u8{0} ** 16, .word_semantics_revision = 2, .spine_len = 1 });
    try std.testing.expectEqual(@as(c_int, 1), app.updateAndRender());
    try std.testing.expectEqual(@as(c_int, 0), app.updateAndRender());
    // Emulate a count committed by indexing without any reading input.
    try app.coordinator.progress_worker.index.?.setExact(0, 2);
    try std.testing.expectEqual(@as(c_int, 1), app.updateAndRender());
    try std.testing.expectEqual(@as(c_int, 0), app.updateAndRender());
}

test "Scroll submits only intersecting lines including partially visible glyph rows" {
    const pagination = @import("../src/content/pagination.zig");
    const layout = @import("../src/ui/reader_layout.zig");
    const invalidation = @import("../src/ui/render_invalidation.zig");
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    var api: pdapi.PlaydateAPI = undefined;
    var system: pdapi.PlaydateSys = undefined;
    var graphics: pdapi.PlaydateGraphics = undefined;
    var allocator: Allocator = undefined;
    try Fake.setup(app, &api, &system, &graphics, &allocator, .paged);
    var cache = pagination.PageCache{};
    for (0..pagination.max_lines) |_| try cache.appendLine("line");
    var model = reader.RenderModel{ .scroll = .{ .window = .{} } };
    model.scroll.window.tile_count = 1;
    model.scroll.window.tiles[0] = .{ .page = .{ .cache = &cache, .origin_y = -80 } };
    app.renderer.beginFrame(.light, .newsleak_serif, .roobert_20_medium);
    app.renderer.draw(&model, allocator.stats, 0, true);
    var expected: usize = 0;
    for (0..cache.line_count) |index| {
        const y = -80 + @as(i32, @intCast(index * layout.lineAdvance(20)));
        if (invalidation.lineVisible(y, 20, layout.text_y, layout.screen_height - layout.text_y - layout.reserved_edge_rows)) expected += 1;
    }
    try std.testing.expect(expected < cache.line_count);
    try std.testing.expectEqual(expected, Fake.texts);
}

const PendingSave = struct {
    writes: usize = 0,
    fn read(_: *anyopaque, _: []const u8, _: []u8) bool {
        return false;
    }
    fn write(context: *anyopaque, _: []const u8, _: []const u8) bool {
        const self: *PendingSave = @ptrCast(@alignCast(context));
        self.writes += 1;
        return true;
    }
    fn remove(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn directory(_: *anyopaque, _: []const u8) bool {
        return true;
    }
};

test "due position persistence continues while idle drawing is skipped" {
    const persistence = @import("../src/storage/persistence.zig");
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    var api: pdapi.PlaydateAPI = undefined;
    var system: pdapi.PlaydateSys = undefined;
    var graphics: pdapi.PlaydateGraphics = undefined;
    var allocator: Allocator = undefined;
    var save = PendingSave{};
    try Fake.setup(app, &api, &system, &graphics, &allocator, .paged);
    app.coordinator.attachPersistence(persistence.Service.init(.{ .context = &save, .read = PendingSave.read, .write = PendingSave.write, .delete = PendingSave.remove, .ensure_directory = PendingSave.directory }));
    app.coordinator.library.add("book.epub");
    _ = app.coordinator.selectBook();
    app.coordinator.requestPositionSave();
    try std.testing.expectEqual(@as(c_int, 1), app.updateAndRender());
    Fake.now = 1999;
    try std.testing.expectEqual(@as(c_int, 0), app.updateAndRender());
    try std.testing.expectEqual(@as(usize, 0), save.writes);
    Fake.now = 2000;
    try std.testing.expectEqual(@as(c_int, 0), app.updateAndRender());
    try std.testing.expectEqual(@as(usize, 1), save.writes);
    try std.testing.expect(!app.coordinator.persistence.?.writePending(.position));
}

test "audio sequences advance through idle renders and Off and pause cancel them" {
    const AudioFake = @import("audio_tests.zig").Fake;
    const Audio = @import("../src/platform/playdate_audio.zig").Audio;
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    var api: pdapi.PlaydateAPI = undefined;
    var system: pdapi.PlaydateSys = undefined;
    var graphics: pdapi.PlaydateGraphics = undefined;
    var allocator: Allocator = undefined;
    try Fake.setup(app, &api, &system, &graphics, &allocator, .paged);
    app.audio = try Audio.init(AudioFake.setup(0));
    defer app.audio.?.deinit();
    _ = app.updateAndRender();
    app.coordinator.sound_events.push(.{ .kind = .mode_changed });
    Fake.now = 1;
    try std.testing.expectEqual(@as(c_int, 0), app.updateAndRender());
    const first_step = AudioFake.notes;
    Fake.now = 50;
    try std.testing.expectEqual(@as(c_int, 0), app.updateAndRender());
    try std.testing.expect(AudioFake.notes > first_step);
    app.coordinator.sound_level = .off;
    const before_stop = AudioFake.stops;
    Fake.now = 51;
    _ = app.updateAndRender();
    try std.testing.expect(AudioFake.stops > before_stop);
    try std.testing.expect(app.audio.?.slots.items[0] == null);
    app.coordinator.sound_level = .subtle;
    app.coordinator.sound_events.push(.{ .kind = .mode_changed });
    Fake.now = 100;
    _ = app.updateAndRender();
    app.handleSystemEvent(.EventPause);
    const before_resume = AudioFake.notes;
    Fake.now = 150;
    _ = app.updateAndRender();
    try std.testing.expectEqual(before_resume, AudioFake.notes);
}
