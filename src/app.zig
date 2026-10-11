const render_invalidation = @import("ui/render_invalidation.zig");
const std = @import("std");
const sound = @import("audio/sound.zig");
const PlaydateAudio = @import("platform/playdate_audio.zig").Audio;
const zip = @import("archive/zip.zig");
const persistence = @import("storage/persistence.zig");
const reader_input = @import("reader/reader_input.zig");
const reader_coordinator = @import("reader/reader_coordinator.zig");
const reader_host = @import("reader/reader_host.zig");
const pdapi = @import("platform/playdate_api_definitions.zig");
const PlaydateAllocator = @import("platform/playdate_allocator.zig").PlaydateAllocator;
const PlaydateFileReader = @import("platform/playdate_file_reader.zig").PlaydateFileReader;
const playdate_persistence = @import("platform/playdate_persistence.zig");
const PlaydateRenderer = @import("platform/playdate_renderer.zig").Renderer;

pub const App = struct {
    playdate: *pdapi.PlaydateAPI,
    allocator: *PlaydateAllocator,
    persistence_store: playdate_persistence.Store,
    renderer: PlaydateRenderer,
    audio: ?PlaydateAudio = null,
    sound_policy: sound.Policy = .{},
    sound_batch: sound.Batch = .{},
    coordinator: reader_coordinator.ReaderCoordinator,
    // Keep render storage on the heap; a temporary model exceeds the device stack
    // budget.
    render_model: reader_coordinator.RenderModel = .opening,
    render_frames: render_invalidation.State = .{},
    opening_file: ?PlaydateFileReader = null,
    // Keep the chapter handle stable while the stream borrows it.
    chapter_file: ?PlaydateFileReader = null,
    // Prefetch uses a separate handle so it can become active without moving borrowed
    // state.
    prefetch_file: ?PlaydateFileReader = null,
    // Progress indexing owns an independent stream and decoder workspace.
    progress_file: ?PlaydateFileReader = null,
    settings_menu: ?*pdapi.PDMenuItem = null,
    rsvp_menu: ?*pdapi.PDMenuItem = null,
    rsvp_menu_mode: reader_coordinator.ReadingMode = .paged,

    pub fn init(playdate: *pdapi.PlaydateAPI, allocator: *PlaydateAllocator) !*App {
        comptime {
            if (pdapi.is_compiling_for_playdate_hardware()) {
                std.debug.assert(@alignOf(App) <= @alignOf(usize));
                std.debug.assert(@alignOf(@import("reader/opening_session.zig").Session) <= @alignOf(usize));
            }
        }
        const newsleak_serif_font = playdate.graphics.loadFont("assets/fonts/Newsleak-Serif.pft", null) orelse return error.FontLoadFailed;
        const newsleak_serif_bold_font = playdate.graphics.loadFont("assets/fonts/Newsleak-Serif-Bold.pft", null) orelse return error.FontLoadFailed;
        const sasser_slab_font = playdate.graphics.loadFont("assets/fonts/Sasser-Slab.pft", null) orelse return error.FontLoadFailed;
        const asheville_sans_font = playdate.graphics.loadFont("assets/fonts/Asheville-Sans-14-Bold.pft", null) orelse return error.FontLoadFailed;
        const espy_serif_3_font = playdate.graphics.loadFont("assets/fonts/EspySerif-3.pft", null) orelse return error.FontLoadFailed;
        const espy_serif_4_font = playdate.graphics.loadFont("assets/fonts/EspySerif-4.pft", null) orelse return error.FontLoadFailed;
        const espy_sans_5_font = playdate.graphics.loadFont("assets/fonts/EspySans-5.pft", null) orelse return error.FontLoadFailed;
        const literata_36pt_medium_30_font = playdate.graphics.loadFont("assets/fonts/Literata36pt-Medium-30.pft", null) orelse return error.FontLoadFailed;
        const roobert_11_bold_font = playdate.graphics.loadFont("/System/Fonts/Roobert-11-Bold.pft", null) orelse return error.FontLoadFailed;
        const roobert_20_medium_font = playdate.graphics.loadFont("/System/Fonts/Roobert-20-Medium.pft", null) orelse return error.FontLoadFailed;
        const roobert_24_medium_font = playdate.graphics.loadFont("/System/Fonts/Roobert-24-Medium.pft", null) orelse return error.FontLoadFailed;
        const app = try allocator.allocator().create(App);
        app.playdate = playdate;
        app.audio = null;
        app.sound_policy = .{};
        app.sound_batch = .{};
        app.allocator = allocator;
        app.persistence_store = .{ .file_api = playdate.file, .allocator = allocator.allocator() };
        app.renderer.initInPlace(
            playdate,
            newsleak_serif_font,
            newsleak_serif_bold_font,
            sasser_slab_font,
            asheville_sans_font,
            espy_serif_3_font,
            espy_serif_4_font,
            espy_sans_5_font,
            literata_36pt_medium_30_font,
            roobert_11_bold_font,
            roobert_20_medium_font,
            roobert_24_medium_font,
        );
        app.render_model = .opening;
        app.render_frames = .{};
        app.opening_file = null;
        app.chapter_file = null;
        app.prefetch_file = null;
        app.progress_file = null;
        app.settings_menu = null;
        app.rsvp_menu = null;
        app.rsvp_menu_mode = .paged;
        if (!playdate_persistence.ensureDataRoot(playdate.file)) return error.DataFolderUnavailable;
        app.coordinator.initInPlace(reader_coordinator.default_checkpoint_byte_budget);
        app.coordinator.attachAllocator(allocator.allocator());
        app.coordinator.attachPersistence(persistence.Service.init(playdate_persistence.fileStore(&app.persistence_store)));
        app.coordinator.attachHost(app.readerHost());
        app.coordinator.loadSettings();
        app.installSystemMenu();
        app.discoverLibrary();
        app.audio = .{ .api = playdate.sound, .channel = undefined, .filter = undefined };
        app.audio.?.initInPlace(playdate.sound) catch |err| {
            playdate.system.logToConsole("EPUBDate audio unavailable: %s", @errorName(err).ptr);
            app.audio = null;
        };
        return app;
    }

    pub fn updateAndRender(self: *App) c_int {
        const started_at = self.playdate.system.getCurrentTimeMilliseconds();

        var current: pdapi.PDButtons = 0;
        var pushed: pdapi.PDButtons = 0;
        self.playdate.system.getButtonState(&current, &pushed, null);
        self.coordinator.update(.{
            .buttons = buttonsFromPlaydate(pushed),
            .a_held = current & pdapi.BUTTON_A != 0,
            .crank_change = self.playdate.system.getCrankChange(),
            .crank_docked = self.playdate.system.isCrankDocked() != 0,
            .reduce_flashing = self.playdate.system.getReduceFlashing() != 0,
        }, started_at);
        self.syncRsvpMenu();

        defer self.playSoundEvents(started_at);
        self.coordinator.renderModelInto(&self.render_model);
        const notice = self.coordinator.persistenceNotice();
        const key = render_invalidation.fingerprint(&self.render_model, self.coordinator.theme, self.coordinator.pages_font, self.coordinator.rsvp_font, self.coordinator.reduceFlashing(), notice);
        // Skip only drawing. Input, background work, and saves still run; animations
        // need a final cleanup frame.
        if (!self.render_frames.shouldDraw(key, self.renderer.animationsActive(&self.render_model))) return 0;
        self.renderer.beginFrame(self.coordinator.theme, self.coordinator.pages_font, self.coordinator.rsvp_font);
        self.renderer.draw(&self.render_model, self.allocator.stats, started_at, self.coordinator.reduceFlashing());
        self.renderer.drawPersistenceNotice(notice);
        return 1;
    }

    pub fn handleSystemEvent(self: *App, event: pdapi.PDSystemEvent) void {
        switch (event) {
            .EventLock, .EventPause, .EventTerminate, .EventLowPower => {
                self.coordinator.systemPaused(self.playdate.system.getCurrentTimeMilliseconds());
                self.sound_policy.reset();
                if (self.audio) |*audio| {
                    if (event == .EventTerminate) {
                        audio.deinit();
                        self.audio = null;
                    } else audio.stop();
                }
            },
            .EventUnlock, .EventResume => {
                self.coordinator.systemResumed();
                self.render_frames.invalidate();
            },
            else => {},
        }
    }

    fn playSoundEvents(self: *App, now: u32) void {
        const level = self.coordinator.sound_level;
        self.sound_policy.drainInto(&self.coordinator.sound_events, level, now, &self.sound_batch);
        if (self.audio) |*audio| {
            if (level == .off) {
                if (audio.slots.items[0] != null or audio.slots.items[1] != null) audio.stop();
                self.sound_policy.reset();
                return;
            }
            audio.update(now);
            for (self.sound_batch.items[0..self.sound_batch.len]) |request| audio.play(request, now);
        }
    }

    fn discoverLibrary(self: *App) void {
        self.coordinator.discoverLibrary();
    }

    fn readerHost(self: *App) reader_host.ReaderHost {
        return .{
            .clock = .{ .context = self, .milliseconds = clockMilliseconds },
            .files = .{ .context = self, .open = openReaderFile, .close = closeReaderFile, .list_epubs = listEpubs },
            .measure = .{
                .context = self,
                .width = measureTextWidthForFont,
                .font_height = measureFontHeightForFont,
            },
        };
    }

    fn installSystemMenu(self: *App) void {
        self.settings_menu = self.playdate.system.addMenuItem("Settings", settingsMenuSelected, self);
        self.syncRsvpMenu();
    }

    fn rsvpMenuTitle(self: *const App) [*:0]const u8 {
        return if (self.coordinator.mode == .rsvp) "RSVP: On" else "RSVP: Off";
    }

    fn syncRsvpMenu(self: *App) void {
        if (!self.coordinator.canToggleReadingMode()) {
            if (self.rsvp_menu) |item| self.playdate.system.removeMenuItem(item);
            self.rsvp_menu = null;
            return;
        }
        if (self.rsvp_menu == null) {
            self.rsvp_menu = self.playdate.system.addMenuItem(self.rsvpMenuTitle(), rsvpMenuSelected, self);
            self.rsvp_menu_mode = self.coordinator.mode;
            return;
        }
        if (self.rsvp_menu_mode == self.coordinator.mode) return;
        if (self.rsvp_menu) |item| self.playdate.system.setMenuItemTitle(item, self.rsvpMenuTitle());
        self.rsvp_menu_mode = self.coordinator.mode;
    }

    fn closeOpeningFile(self: *App) void {
        if (self.opening_file) |*file| file.close();
        self.opening_file = null;
    }

    fn textWidth(self: *const App, text: []const u8) c_int {
        return self.renderer.readingTextWidth(.roobert_20_medium, text);
    }
};

fn clockMilliseconds(context: *anyopaque) u32 {
    const app: *App = @ptrCast(@alignCast(context));
    return app.playdate.system.getCurrentTimeMilliseconds();
}

fn openReaderFile(context: *anyopaque, slot: reader_host.FileSlot, path: [:0]const u8) reader_host.FileError!zip.Reader {
    const app: *App = @ptrCast(@alignCast(context));
    closeReaderFile(context, slot);
    const opened = PlaydateFileReader.open(app.playdate.file, path) catch return error.OpenFailed;
    switch (slot) {
        .opening => app.opening_file = opened,
        .chapter => app.chapter_file = opened,
        .prefetch => app.prefetch_file = opened,
        .progress => app.progress_file = opened,
    }
    return switch (slot) {
        .opening => if (app.opening_file) |*file| file.reader() else unreachable,
        .chapter => if (app.chapter_file) |*file| file.reader() else unreachable,
        .prefetch => if (app.prefetch_file) |*file| file.reader() else unreachable,
        .progress => if (app.progress_file) |*file| file.reader() else unreachable,
    };
}

fn closeReaderFile(context: *anyopaque, slot: reader_host.FileSlot) void {
    const app: *App = @ptrCast(@alignCast(context));
    switch (slot) {
        .opening => app.closeOpeningFile(),
        .chapter => {
            if (app.chapter_file) |*file| file.close();
            app.chapter_file = null;
        },
        .prefetch => {
            if (app.prefetch_file) |*file| file.close();
            app.prefetch_file = null;
        },
        .progress => {
            if (app.progress_file) |*file| file.close();
            app.progress_file = null;
        },
    }
}

fn listEpubs(context: *anyopaque, library: *reader_host.Library) void {
    const app: *App = @ptrCast(@alignCast(context));
    library.listing_failed = app.playdate.file.listfiles("", collectLibraryPath, library, 0) != 0;
}

fn measureTextWidthForFont(context: *anyopaque, font: reader_coordinator.ReadingFont, text: []const u8) usize {
    const app: *App = @ptrCast(@alignCast(context));
    return @intCast(app.renderer.readingTextWidth(font, text));
}

fn measureFontHeightForFont(context: *anyopaque, font: reader_coordinator.ReadingFont) usize {
    const app: *App = @ptrCast(@alignCast(context));
    return app.renderer.readingFontHeight(font);
}

fn buttonsFromPlaydate(pushed: pdapi.PDButtons) reader_input.Buttons {
    return .{
        .a = pushed & pdapi.BUTTON_A != 0,
        .b = pushed & pdapi.BUTTON_B != 0,
        .up = pushed & pdapi.BUTTON_UP != 0,
        .down = pushed & pdapi.BUTTON_DOWN != 0,
        .left = pushed & pdapi.BUTTON_LEFT != 0,
        .right = pushed & pdapi.BUTTON_RIGHT != 0,
    };
}

fn settingsMenuSelected(userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.coordinator.reduce_flashing = app.playdate.system.getReduceFlashing() != 0;
    app.coordinator.handleSystemAction(.settings, app.playdate.system.getCurrentTimeMilliseconds());
    app.syncRsvpMenu();
}

fn rsvpMenuSelected(userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.coordinator.handleSystemAction(.toggle_reading_mode, app.playdate.system.getCurrentTimeMilliseconds());
    app.syncRsvpMenu();
}

fn collectLibraryPath(path: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const library: *reader_host.Library = @ptrCast(@alignCast(userdata orelse return));
    const z_path = path orelse return;
    library.add(std.mem.span(z_path));
}

test "RSVP system menu is reader-only and follows mode changes" {
    const FakeMenu = struct {
        var item_count: usize = 0;
        var title: []const u8 = "";
        var callback: ?pdapi.PDMenuItemCallbackFunction = null;
        var context: ?*anyopaque = null;
        fn add(label: ?[*:0]const u8, selected: ?pdapi.PDMenuItemCallbackFunction, userdata: ?*anyopaque) callconv(.c) ?*pdapi.PDMenuItem {
            item_count += 1;
            title = std.mem.span(label.?);
            callback = selected;
            context = userdata;
            return @ptrFromInt(4);
        }
        fn setTitle(_: ?*pdapi.PDMenuItem, label: ?[*:0]const u8) callconv(.c) void {
            title = std.mem.span(label.?);
        }
        fn remove(_: ?*pdapi.PDMenuItem) callconv(.c) void {
            item_count -= 1;
        }
        fn clock() callconv(.c) u32 {
            return 10;
        }
    };
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    var system: pdapi.PlaydateSys = undefined;
    system.addMenuItem = FakeMenu.add;
    system.setMenuItemTitle = FakeMenu.setTitle;
    system.removeMenuItem = FakeMenu.remove;
    system.getCurrentTimeMilliseconds = FakeMenu.clock;
    var api: pdapi.PlaydateAPI = undefined;
    api.system = &system;
    app.playdate = &api;
    app.rsvp_menu = null;
    app.rsvp_menu_mode = .paged;
    app.coordinator.initInPlace(128);
    FakeMenu.item_count = 0;
    app.installSystemMenu();
    try std.testing.expectEqual(@as(usize, 1), FakeMenu.item_count);
    try std.testing.expect(app.rsvp_menu == null);
    _ = app.coordinator.library.add("book.epub");
    _ = app.coordinator.selectBook();
    app.coordinator.screen = .book_actions;
    app.syncRsvpMenu();
    try std.testing.expect(app.rsvp_menu == null);
    app.coordinator.screen = .reading;
    app.coordinator.lifecycle = .ready;
    app.coordinator.book_session.publication.spine_len = 1;
    app.coordinator.book_loading = true;
    app.syncRsvpMenu();
    try std.testing.expect(app.rsvp_menu == null);
    app.coordinator.book_loading = false;
    app.syncRsvpMenu();
    try std.testing.expectEqual(@as(usize, 2), FakeMenu.item_count);
    try std.testing.expectEqualStrings("RSVP: Off", FakeMenu.title);
    FakeMenu.callback.?(FakeMenu.context);
    try std.testing.expectEqual(reader_coordinator.ReadingMode.rsvp, app.coordinator.mode);
    try std.testing.expectEqualStrings("RSVP: On", FakeMenu.title);
    FakeMenu.callback.?(FakeMenu.context);
    try std.testing.expectEqual(reader_coordinator.ReadingMode.paged, app.coordinator.mode);
    try std.testing.expectEqualStrings("RSVP: Off", FakeMenu.title);
    app.coordinator.toggleMode();
    app.syncRsvpMenu();
    try std.testing.expectEqualStrings("RSVP: On", FakeMenu.title);
    for ([_]reader_coordinator.Screen{ .library, .book_actions, .settings, .statistics, .chapter_browser, .opening }) |screen| {
        app.coordinator.screen = screen;
        app.syncRsvpMenu();
        try std.testing.expect(app.rsvp_menu == null);
        try std.testing.expectEqual(@as(usize, 1), FakeMenu.item_count);
    }
    app.coordinator.screen = .library;
    FakeMenu.callback.?(FakeMenu.context);
    try std.testing.expectEqual(reader_coordinator.ReadingMode.rsvp, app.coordinator.mode);
    app.coordinator.screen = .reading;
    app.syncRsvpMenu();
    try std.testing.expectEqual(@as(usize, 2), FakeMenu.item_count);
    try std.testing.expectEqualStrings("RSVP: On", FakeMenu.title);
    app.syncRsvpMenu();
    try std.testing.expectEqual(@as(usize, 2), FakeMenu.item_count);
}

test "SDK library discovery reports listing errors and requests only the top-level visible files" {
    const FakeListing = struct {
        var fail: bool = false;
        fn list(path: ?[*:0]const u8, callback: *const fn (?[*:0]const u8, ?*anyopaque) callconv(.c) void, context: ?*anyopaque, hidden: c_int) callconv(.c) c_int {
            std.debug.assert(std.mem.span(path.?).len == 0 and hidden == 0);
            callback("book.epub", context);
            callback("folder/", context);
            return if (fail) -1 else 0;
        }
    };
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    const library = try std.testing.allocator.create(reader_host.Library);
    defer std.testing.allocator.destroy(library);
    var file: pdapi.PlaydateFile = undefined;
    file.listfiles = FakeListing.list;
    var api: pdapi.PlaydateAPI = undefined;
    api.file = &file;
    app.playdate = &api;
    library.reset();
    FakeListing.fail = false;
    listEpubs(app, library);
    try std.testing.expectEqual(@as(u8, 1), library.len);
    try std.testing.expect(!library.listing_failed);
    library.reset();
    FakeListing.fail = true;
    listEpubs(app, library);
    try std.testing.expect(library.listing_failed);
}
