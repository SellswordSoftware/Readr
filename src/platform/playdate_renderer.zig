const title_layout = @import("../ui/title_layout.zig");
const invalidation = @import("../ui/render_invalidation.zig");
const display_text = @import("display_text.zig");
const std = @import("std");
const chapter_browser = @import("../ui/chapter_browser.zig");
const pagination = @import("../content/pagination.zig");
const pdapi = @import("playdate_api_definitions.zig");
const AllocatorStats = @import("playdate_allocator.zig").Stats;
const reader_view = @import("../ui/reader_view.zig");
const reader_layout = @import("../ui/reader_layout.zig");
const reading_statistics = @import("../ui/reading_statistics.zig");
const progress_rail = @import("../ui/progress_rail.zig");
const page_transition = @import("../ui/animation/page_transition.zig");
const page_compositor = @import("../ui/animation/page_compositor.zig");
const screen_transition = @import("../ui/animation/screen_transition.zig");
const library_transition = @import("../ui/animation/library_transition.zig");
const word_spotlight = @import("../ui/animation/word_spotlight.zig");
const highlight_collapse = @import("../ui/animation/highlight_collapse.zig");

pub const Renderer = struct {
    playdate: *pdapi.PlaydateAPI,
    ui_regular_font: *pdapi.LCDFont,
    ui_bold_font: *pdapi.LCDFont,
    sasser_slab_font: *pdapi.LCDFont,
    asheville_sans_font: *pdapi.LCDFont,
    espy_serif_3_font: *pdapi.LCDFont,
    espy_serif_4_font: *pdapi.LCDFont,
    espy_sans_5_font: *pdapi.LCDFont,
    literata_36pt_medium_30_font: *pdapi.LCDFont,
    roobert_11_bold_font: *pdapi.LCDFont,
    roobert_20_medium_font: *pdapi.LCDFont,
    roobert_24_medium_font: *pdapi.LCDFont,
    pages_font: reader_view.ReadingFont = .newsleak_serif,
    rsvp_font: reader_view.ReadingFont = .roobert_20_medium,
    theme: reader_view.Theme,
    library_marquee_title: [title_layout.max_title_bytes]u8 = undefined,
    library_marquee_len: usize = 0,
    library_marquee_width: c_int = 0,
    library_marquee_font: usize = 0,
    library_marquee: title_layout.Marquee = .{},
    title_cache: title_layout.Cache = .{},
    last_rendered_kind: ?RenderViewKind = null,
    last_scroll_chapter_transition_nonce: u32 = 0,
    screen_transition_state: screen_transition.State = .{},
    screen_transition_source: ?*pdapi.LCDBitmap = null,
    page_outgoing_bitmap: ?*pdapi.LCDBitmap = null,
    page_incoming_bitmap: ?*pdapi.LCDBitmap = null,
    library_transition_state: library_transition.State = .{},
    word_spotlight_state: word_spotlight.State = .{},
    last_word_spotlight_nonce: u32 = 0,
    highlight_collapse_state: highlight_collapse.State = .{},
    last_highlight_dismiss_nonce: u32 = 0,
    frame_now_ms: u32 = 0,
    reduce_flashing: bool = false,

    pub fn initInPlace(
        self: *Renderer,
        playdate: *pdapi.PlaydateAPI,
        ui_regular_font: *pdapi.LCDFont,
        ui_bold_font: *pdapi.LCDFont,
        sasser_slab_font: *pdapi.LCDFont,
        asheville_sans_font: *pdapi.LCDFont,
        espy_serif_3_font: *pdapi.LCDFont,
        espy_serif_4_font: *pdapi.LCDFont,
        espy_sans_5_font: *pdapi.LCDFont,
        literata_36pt_medium_30_font: *pdapi.LCDFont,
        roobert_11_bold_font: *pdapi.LCDFont,
        roobert_20_medium_font: *pdapi.LCDFont,
        roobert_24_medium_font: *pdapi.LCDFont,
    ) void {
        self.* = .{
            .playdate = playdate,
            .ui_regular_font = ui_regular_font,
            .ui_bold_font = ui_bold_font,
            .sasser_slab_font = sasser_slab_font,
            .asheville_sans_font = asheville_sans_font,
            .espy_serif_3_font = espy_serif_3_font,
            .espy_serif_4_font = espy_serif_4_font,
            .espy_sans_5_font = espy_sans_5_font,
            .literata_36pt_medium_30_font = literata_36pt_medium_30_font,
            .roobert_11_bold_font = roobert_11_bold_font,
            .roobert_20_medium_font = roobert_20_medium_font,
            .roobert_24_medium_font = roobert_24_medium_font,
            .theme = .light,
        };
    }

    pub fn animationsActive(self: *const Renderer, model: *const reader_view.RenderModel) bool {
        const has_library = model.* == .library or model.* == .book_actions;
        const has_page = model.* == .paged or model.* == .statistics;
        return self.screen_transition_state.active or
            (has_library and (self.library_transition_state.active or self.library_marquee.distance > 0)) or
            (has_page and (self.word_spotlight_state.active or self.highlight_collapse_state.active)) or
            invalidation.loadingAnimated(model);
    }

    pub fn beginFrame(self: *Renderer, theme: reader_view.Theme, pages_font: reader_view.ReadingFont, rsvp_font: reader_view.ReadingFont) void {
        self.theme = theme;
        self.pages_font = pages_font;
        self.rsvp_font = rsvp_font;
        self.selectUiFont(false);
        self.playdate.graphics.setBackgroundColor(self.backgroundColor());
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.playdate.graphics.clear(solidColor(self.backgroundColor()));
    }

    fn readingFont(self: *const Renderer, font: reader_view.ReadingFont) *pdapi.LCDFont {
        return switch (font) {
            .newsleak_serif => self.ui_regular_font,
            .sasser_slab => self.sasser_slab_font,
            .asheville_sans_14_bold => self.asheville_sans_font,
            .roobert_11_bold => self.roobert_11_bold_font,
            .roobert_20_medium => self.roobert_20_medium_font,
            .roobert_24_medium => self.roobert_24_medium_font,
            .espy_serif_3 => self.espy_serif_3_font,
            .espy_serif_4 => self.espy_serif_4_font,
            .espy_sans_5 => self.espy_sans_5_font,
            .literata_36pt_medium_30 => self.literata_36pt_medium_30_font,
        };
    }

    fn selectUiFont(self: *Renderer, bold: bool) void {
        self.playdate.graphics.setFont(if (bold) self.ui_bold_font else self.ui_regular_font);
    }

    fn selectReadingFont(self: *Renderer, font: reader_view.ReadingFont) void {
        self.playdate.graphics.setFont(self.readingFont(font));
    }

    pub fn readingTextWidth(self: *const Renderer, font: reader_view.ReadingFont, value: []const u8) c_int {
        return self.fontTextWidth(self.readingFont(font), value);
    }

    const GlyphContext = struct {
        renderer: *const Renderer,
        font: *pdapi.LCDFont,

        fn has(context: *anyopaque, codepoint: u21) bool {
            const glyphs: *GlyphContext = @ptrCast(@alignCast(context));
            return glyphs.renderer.playdate.graphics.getFontGlyph(glyphs.font, codepoint, null, null) != null;
        }
    };

    fn displayText(self: *const Renderer, font: *pdapi.LCDFont, value: []const u8, buffer: []u8) []const u8 {
        var context = GlyphContext{ .renderer = self, .font = font };
        return display_text.format(value, buffer, .{ .context = &context, .has = GlyphContext.has });
    }

    fn fontTextWidth(self: *const Renderer, font: *pdapi.LCDFont, value: []const u8) c_int {
        var buffer: [pagination.max_cached_line_bytes]u8 = undefined;
        const display = self.displayText(font, value, &buffer);
        // The SDK length is decoded codepoints, not UTF-8 bytes. These borrowed
        // slices need not have a NUL terminator.
        const count = std.unicode.utf8CountCodepoints(display) catch unreachable;
        return @intCast(self.playdate.graphics.getTextWidth(font, display.ptr, count, .UTF8Encoding, 0));
    }

    fn drawFontText(self: *Renderer, font: *pdapi.LCDFont, value: []const u8, x: c_int, y: c_int) void {
        var buffer: [pagination.max_cached_line_bytes]u8 = undefined;
        const display = self.displayText(font, value, &buffer);
        self.playdate.graphics.setFont(font);
        const count = std.unicode.utf8CountCodepoints(display) catch unreachable;
        _ = self.playdate.graphics.drawText(display.ptr, count, .UTF8Encoding, x, y);
    }

    pub fn readingFontHeight(self: *const Renderer, font: reader_view.ReadingFont) usize {
        return self.playdate.graphics.getFontHeight(self.readingFont(font));
    }

    pub fn draw(self: *Renderer, model: *const reader_view.RenderModel, allocator_stats: AllocatorStats, now_ms: u32, reduce_flashing: bool) void {
        self.frame_now_ms = now_ms;
        self.reduce_flashing = reduce_flashing;
        if (reduce_flashing) {
            self.word_spotlight_state.cancel();
            self.highlight_collapse_state.cancel();
        }
        if (model.* != .paged and model.* != .statistics) {
            self.word_spotlight_state.cancel();
            self.highlight_collapse_state.cancel();
        }
        const kind = renderViewKind(model);
        const scroll_chapter_transition = switch (model.*) {
            .scroll => |*view| blk: {
                const changed = view.chapter_transition_nonce != 0 and view.chapter_transition_nonce != self.last_scroll_chapter_transition_nonce;
                self.last_scroll_chapter_transition_nonce = view.chapter_transition_nonce;
                break :blk changed;
            },
            else => false,
        };
        const entering_library = entersLibrary(kind, self.last_rendered_kind);
        if (entering_library) self.library_marquee_width = 0;
        if (reduce_flashing) self.library_transition_state.cancel() else if (entering_library) self.library_transition_state.begin(now_ms);
        if (reduce_flashing) {
            self.cancelScreenTransition();
        } else if (scroll_chapter_transition) {
            self.beginScreenTransition(now_ms);
        } else if (self.last_rendered_kind) |previous_kind| {
            if (transitionsBetween(previous_kind, kind)) self.beginScreenTransition(now_ms);
        }
        self.last_rendered_kind = kind;
        const library_entrance_progress = self.library_transition_state.progress(now_ms);

        switch (self.screen_transition_state.phase(now_ms)) {
            .outgoing => |pattern| {
                if (self.screen_transition_source) |source| {
                    self.playdate.graphics.setDrawMode(.DrawModeCopy);
                    self.playdate.graphics.drawBitmap(source, 0, 0, .BitmapUnflipped);
                    self.applyDither(source, pattern);
                    self.playdate.graphics.setDrawMode(self.textDrawMode());
                    return;
                }
            },
            .background => return,
            .incoming => |pattern| {
                self.drawModel(model, allocator_stats, library_entrance_progress, now_ms);
                self.applyDitherToFrame(pattern);
                return;
            },
            .complete => self.cancelScreenTransition(),
        }
        self.drawModel(model, allocator_stats, library_entrance_progress, now_ms);
    }

    pub fn drawPersistenceNotice(self: *Renderer, notice: ?[]const u8) void {
        const message = notice orelse return;
        self.playdate.graphics.clearClipRect();
        const width: c_int = @intCast(reader_layout.screen_width);
        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRect(0, 0, width, 30, solidColor(self.backgroundColor()));
        self.playdate.graphics.fillRect(0, 29, width, 1, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.text(message, 12, 7);
    }

    fn drawModel(self: *Renderer, model: *const reader_view.RenderModel, allocator_stats: AllocatorStats, library_entrance_progress: u16, now_ms: u32) void {
        switch (model.*) {
            .library => |*view| self.drawLibrary(view, library_entrance_progress, now_ms),
            .book_actions => |*view| self.drawBookActions(view, library_entrance_progress, now_ms),
            .settings => |*view| self.drawSettings(view),
            .statistics => |*view| self.drawStatistics(view),
            .chapters => |*view| self.drawChapters(view),
            .opening => self.drawLoadingScene("Opening book", "Preparing EPUB"),
            .paged => |*view| self.drawPage(view),
            .scroll => |*view| self.drawScroll(view),
            .rsvp => |*view| self.drawRsvp(view),
            .failure => |*view| self.drawFailure(view, allocator_stats),
        }
    }

    fn beginScreenTransition(self: *Renderer, now_ms: u32) void {
        self.cancelScreenTransition();
        const source = self.playdate.graphics.newBitmap(
            @intCast(reader_layout.screen_width),
            @intCast(reader_layout.screen_height),
            solidColor(self.backgroundColor()),
        ) orelse return;
        var width: c_int = 0;
        var height: c_int = 0;
        var row_bytes: c_int = 0;
        var data: [*c]u8 = null;
        self.playdate.graphics.getBitmapData(source, &width, &height, &row_bytes, null, &data);
        if (data == null) {
            self.playdate.graphics.freeBitmap(source);
            return;
        }
        const displayed = self.playdate.graphics.getDisplayFrame();
        const rows = @min(@as(usize, @intCast(height)), @as(usize, reader_layout.screen_height));
        const byte_width = @min(@as(usize, @intCast(width)) / 8, @as(usize, pdapi.LCD_ROWSIZE));
        const destination_row_bytes: usize = @intCast(row_bytes);
        for (0..rows) |y| {
            std.mem.copyForwards(u8, data[y * destination_row_bytes ..][0..byte_width], displayed[y * pdapi.LCD_ROWSIZE ..][0..byte_width]);
        }
        self.screen_transition_source = source;
        self.screen_transition_state.begin(now_ms);
    }

    fn cancelScreenTransition(self: *Renderer) void {
        self.screen_transition_state.cancel();
        if (self.screen_transition_source) |source| self.playdate.graphics.freeBitmap(source);
        self.screen_transition_source = null;
    }

    /// Dither the captured outgoing frame or the newly drawn incoming frame with the
    /// theme background.
    fn applyDither(self: *Renderer, source: *pdapi.LCDBitmap, pattern: u8) void {
        var width: c_int = 0;
        var height: c_int = 0;
        var row_bytes: c_int = 0;
        var data: [*c]u8 = null;
        self.playdate.graphics.getBitmapData(source, &width, &height, &row_bytes, null, &data);
        if (data == null) return;
        self.applyDitherBytes(data, @intCast(width), @intCast(height), @intCast(row_bytes), pattern);
    }

    fn applyDitherToFrame(self: *Renderer, pattern: u8) void {
        self.applyDitherBytes(self.playdate.graphics.getFrame(), reader_layout.screen_width, reader_layout.screen_height, pdapi.LCD_ROWSIZE, pattern);
    }

    fn applyDitherBytes(self: *Renderer, source: [*]u8, width: usize, height: usize, source_row_bytes: usize, pattern: u8) void {
        const frame = self.playdate.graphics.getFrame();
        // Playdate framebuffer bits are 1 for white and 0 for black.
        const background: u8 = if (self.theme == .dark) 0x00 else 0xff;
        const byte_width = @min(width / 8, @as(usize, pdapi.LCD_ROWSIZE));
        const rows = @min(height, @as(usize, reader_layout.screen_height));
        const selected = screen_transition.patterns[pattern];
        for (0..rows) |y| {
            const mask = selected[y & 7];
            for (0..byte_width) |x| {
                frame[y * pdapi.LCD_ROWSIZE + x] = (source[y * source_row_bytes + x] & mask) | (background & ~mask);
            }
        }
    }

    pub fn text(self: *Renderer, value: []const u8, x: c_int, y: c_int) void {
        self.drawFontText(self.ui_regular_font, value, x, y);
    }

    pub fn emphasizedText(self: *Renderer, value: []const u8, x: c_int, y: c_int) void {
        self.drawFontText(self.ui_bold_font, value, x, y);
    }

    pub fn readingText(self: *Renderer, font: reader_view.ReadingFont, value: []const u8, x: c_int, y: c_int) void {
        self.drawFontText(self.readingFont(font), value, x, y);
    }

    pub fn uiFontHeight(self: *const Renderer) usize {
        return self.playdate.graphics.getFontHeight(self.ui_regular_font);
    }

    fn uiTextWidth(self: *const Renderer, value: []const u8, bold: bool) c_int {
        const font = if (bold) self.ui_bold_font else self.ui_regular_font;
        return self.fontTextWidth(font, value);
    }

    fn rightAlignedUiText(self: *Renderer, value: []const u8, y: c_int, bold: bool) void {
        const x = @max(@as(c_int, 24), @as(c_int, @intCast(reader_layout.screen_width)) - 12 - self.uiTextWidth(value, bold));
        if (bold) self.emphasizedText(value, x, y) else self.text(value, x, y);
    }

    fn centeredUiText(self: *Renderer, value: []const u8, y: c_int, bold: bool) void {
        self.centeredUiTextWithOffset(value, y, bold, 0);
    }

    fn centeredUiTextWithOffset(self: *Renderer, value: []const u8, y: c_int, bold: bool, x_offset: c_int) void {
        const screen_width: c_int = @intCast(reader_layout.screen_width);
        const x = @divTrunc(screen_width - self.uiTextWidth(value, bold), 2) + x_offset;
        if (bold) self.emphasizedText(value, x, y) else self.text(value, x, y);
    }

    /// Opening has no single progress metric; animate activity without a percentage.
    fn drawLoadingScene(self: *Renderer, title: []const u8, detail: []const u8) void {
        const screen_width: c_int = @intCast(reader_layout.screen_width);
        const screen_height: c_int = @intCast(reader_layout.screen_height);
        const card_x: c_int = 40;
        const card_y: c_int = 49;
        const card_width: c_int = screen_width - card_x * 2;
        const card_height: c_int = 142;
        const rail_x: c_int = card_x + 43;
        const rail_y: c_int = card_y + 109;
        const rail_width: c_int = card_width - 86;
        const segment_width: c_int = 54;
        const travel: c_int = rail_width - 2 - segment_width;
        const phase: c_int = @intCast((self.frame_now_ms / 18) % @as(u32, @intCast(travel * 2)));
        const offset = if (phase <= travel) phase else travel * 2 - phase;

        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRect(0, 0, screen_width, screen_height, self.libraryBodyPatternColor());
        self.playdate.graphics.fillRoundRect(card_x, card_y, card_width, card_height, 8, solidColor(self.backgroundColor()));
        self.playdate.graphics.drawRoundRect(card_x, card_y, card_width, card_height, 8, 1, solidColor(self.foregroundColor()));

        const rules = [_]c_int{ 138, 188, 118, 166 };
        for (rules, 0..) |width, index| {
            const y = card_y + 57 + @as(c_int, @intCast(index)) * 8;
            self.playdate.graphics.fillRect(card_x + 30, y, width, 2, self.loadingRulePatternColor());
        }
        self.playdate.graphics.drawRect(rail_x, rail_y, rail_width, 7, solidColor(self.foregroundColor()));
        self.playdate.graphics.fillRect(rail_x + 1 + offset, rail_y + 1, segment_width, 5, self.loadingRailPatternColor());

        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.centeredUiText(title, card_y + 20, true);
        self.centeredUiText(detail, card_y + 37, false);
    }

    /// Keep the restoration barrier after the mode-switch fade without showing a second
    /// loading treatment.
    fn drawModeSwitchBackground(self: *Renderer) void {
        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRect(0, 0, @intCast(reader_layout.screen_width), @intCast(reader_layout.screen_height), solidColor(self.backgroundColor()));
    }

    pub fn invertedReadingText(self: *Renderer, font: reader_view.ReadingFont, value: []const u8, text_x: c_int, text_y: c_int, rect_x: c_int, rect_y: c_int, width: c_int, height: c_int) void {
        self.playdate.graphics.fillRect(rect_x, rect_y, width, height, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(switch (self.theme) {
            .light => .DrawModeInverted,
            .dark => .DrawModeCopy,
        });
        self.drawFontText(self.readingFont(font), value, text_x, text_y);
        self.playdate.graphics.setDrawMode(self.textDrawMode());
    }

    fn backgroundColor(self: *const Renderer) pdapi.LCDSolidColor {
        return if (self.theme == .dark) .ColorBlack else .ColorWhite;
    }

    fn foregroundColor(self: *const Renderer) pdapi.LCDSolidColor {
        return if (self.theme == .dark) .ColorWhite else .ColorBlack;
    }

    fn textDrawMode(self: *const Renderer) pdapi.LCDBitmapDrawMode {
        return if (self.theme == .dark) .DrawModeInverted else .DrawModeCopy;
    }

    fn filledTextDrawMode(self: *const Renderer) pdapi.LCDBitmapDrawMode {
        return if (self.theme == .dark) .DrawModeCopy else .DrawModeInverted;
    }

    fn drawLibrary(self: *Renderer, view: *const reader_view.LibraryView, entrance_progress: u16, now_ms: u32) void {
        const header_offset = entranceOffset(-40, entrance_progress);
        const cards_offset = entranceOffset(-420, entrance_progress);
        const scrollbar_offset = entranceOffset(18, entrance_progress);
        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRect(0, 0, @intCast(reader_layout.screen_width), @intCast(reader_layout.screen_height), self.libraryBodyPatternColor());
        // Paint behind the entering bar so its motion does not expose an unpainted
        // strip.
        self.playdate.graphics.fillRect(0, header_offset, @intCast(reader_layout.screen_width), 36, solidColor(self.backgroundColor()));
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        var status_buffer: [96]u8 = undefined;
        const heading = if (view.listing_failed) "Library scan failed" else if (view.omitted_capacity != 0 or view.omitted_names != 0)
            std.fmt.bufPrint(&status_buffer, "Library {d}: {d} limit, {d} names skipped", .{ view.count, view.omitted_capacity, view.omitted_names }) catch "Library: books omitted"
        else
            "Readr Library";
        self.emphasizedText(self.truncatedLibraryTitle(heading, 376, true), 12, 12 + header_offset);
        self.playdate.graphics.fillRect(0, 35 + header_offset, @intCast(reader_layout.screen_width), 1, solidColor(self.foregroundColor()));
        if (view.count == 0) {
            self.library_marquee.distance = 0;
            self.drawEmptyLibraryMessage(cards_offset, view.listing_failed, view.omitted_names != 0);
            return;
        }
        const visible_rows = reader_view.library_visible_rows;
        const first: usize = view.first_visible;
        const end = @min(@as(usize, view.count), first + visible_rows);
        for (first..end) |index| {
            const y: c_int = 43 + @as(c_int, @intCast(index - first)) * 32;
            const delay = @as(u16, @intCast(index - first)) * library_transition.card_stagger_ms;
            const card_offset = entranceOffset(-420, self.library_transition_state.staggeredProgress(now_ms, delay));
            self.drawLibraryItem(view.paths[index - first], view.progress[index - first], index == view.selected, y, card_offset);
        }
        self.drawRoundedScrollbar(394 + scrollbar_offset, 43, 4, 187, first, visible_rows, @intCast(view.count));
    }

    fn drawEmptyLibraryMessage(self: *Renderer, x_offset: c_int, listing_failed: bool, long_names: bool) void {
        const sheet_x: c_int = 36 + x_offset;
        const sheet_y: c_int = 39;
        const sheet_width: c_int = 328;
        const sheet_height: c_int = 170;

        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRoundRect(sheet_x, sheet_y, sheet_width, sheet_height, 8, solidColor(self.backgroundColor()));
        self.playdate.graphics.drawRoundRect(sheet_x, sheet_y, sheet_width, sheet_height, 8, 2, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.centeredUiTextWithOffset(if (listing_failed) "Library scan failed" else "No books found", sheet_y + 16, true, x_offset);
        self.emphasizedText(if (long_names) "EPUB names: at most 127 bytes" else "Place .epub files in:", sheet_x + 24, sheet_y + 57);
        self.emphasizedText("Data/com.sellswordsoftware.readr", sheet_x + 24, sheet_y + 80);
        self.emphasizedText("Library scans automatically", sheet_x + 24, sheet_y + 103);
    }

    fn drawBookActions(self: *Renderer, view: *const reader_view.BookActionsView, library_entrance_progress: u16, now_ms: u32) void {
        self.drawLibrary(&view.library, library_entrance_progress, now_ms);
        const sheet_x: c_int = 64;
        const sheet_y: c_int = 58;
        const sheet_width: c_int = 272;
        const sheet_height: c_int = 126;
        const title = self.truncatedLibraryTitle(view.title, 220, true);

        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRoundRect(sheet_x, sheet_y, sheet_width, sheet_height, 8, solidColor(self.backgroundColor()));
        self.playdate.graphics.drawRoundRect(sheet_x, sheet_y, sheet_width, sheet_height, 8, 2, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.centeredUiText(title, sheet_y + 13, true);
        self.drawBookActionItem(if (view.has_resume) "Resume reading" else "Start reading", sheet_y + 42, view.selected == .start_or_resume);
        self.drawBookActionItem("Choose chapter", sheet_y + 72, view.selected == .chapters);
        self.centeredUiText("A: select     B: cancel", sheet_y + 103, false);
    }

    fn drawBookActionItem(self: *Renderer, label: []const u8, y: c_int, selected: bool) void {
        const x: c_int = 84;
        const width: c_int = 232;
        const height: c_int = 24;
        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRoundRect(x, y, width, height, 4, solidColor(if (selected) self.foregroundColor() else self.backgroundColor()));
        self.playdate.graphics.drawRoundRect(x, y, width, height, 4, if (selected) 2 else 1, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(if (selected) self.filledTextDrawMode() else self.textDrawMode());
        self.centeredUiText(label, y + 2, selected);
        self.playdate.graphics.setDrawMode(self.textDrawMode());
    }

    fn drawLibraryItem(self: *Renderer, title: []const u8, progress: ?u8, selected: bool, y: c_int, x_offset: c_int) void {
        const x: c_int = 12 + x_offset;
        const width: c_int = @intCast(reader_layout.screen_width - 24);
        const height: c_int = 27;
        const inset: c_int = 12;
        const inner_width = width - 2;
        const fill_width: c_int = if (progress) |value| @divTrunc(inner_width * @as(c_int, value), 100) else 0;
        const border_width: c_int = if (selected) 2 else 1;

        self.playdate.graphics.fillRoundRect(x, y, width, height, 5, solidColor(self.backgroundColor()));
        if (fill_width == inner_width) {
            self.playdate.graphics.fillRoundRect(x + 1, y + 1, inner_width, height - 2, 4, solidColor(self.foregroundColor()));
        } else if (fill_width > 0) {
            self.playdate.graphics.fillRect(x + 1, y + 1, fill_width, height - 2, solidColor(self.foregroundColor()));
        }
        self.playdate.graphics.drawRoundRect(x, y, width, height, 5, border_width, solidColor(self.foregroundColor()));

        const title_x = x + inset;
        const right = x + width - inset;
        const text_y = y + 5;
        const bold = selected;
        if (progress) |value| {
            var percent_buffer: [4]u8 = undefined;
            const percent = std.fmt.bufPrint(&percent_buffer, "{d}%", .{value}) catch return;
            const percent_x = right - self.uiTextWidth(percent, bold);
            const title_width = percent_x - title_x - inset;
            self.drawLibraryTitle(title, title_x, text_y, bold, selected, title_width, x, y, fill_width, height);
            self.drawLibraryLabel(percent, percent_x, text_y, bold, percent_x, right - percent_x, x, y, fill_width, height);
        } else {
            self.drawLibraryTitle(title, title_x, text_y, bold, selected, right - title_x, x, y, fill_width, height);
        }
    }

    fn drawLibraryTitle(self: *Renderer, title: []const u8, text_x: c_int, text_y: c_int, bold: bool, selected: bool, width: c_int, item_x: c_int, item_y: c_int, fill_width: c_int, item_height: c_int) void {
        if (width <= 0) return;
        const displayed = if (selected) title else self.truncatedLibraryTitle(title, width, bold);
        const marquee_offset = if (selected) self.libraryMarqueeOffset(title, width, bold) else 0;
        self.drawLibraryLabel(displayed, text_x - marquee_offset, text_y, bold, text_x, width, item_x, item_y, fill_width, item_height);
    }

    fn cachedTitle(self: *Renderer, title: []const u8, width: c_int, bold: bool) *const title_layout.Entry {
        const font = if (bold) self.ui_bold_font else self.ui_regular_font;
        return self.title_cache.layout(title, @intFromPtr(font), width, .{ .context = self, .width = titleWidth });
    }

    fn titleWidth(context: *anyopaque, title: []const u8, font: usize) i32 {
        const self: *Renderer = @ptrCast(@alignCast(context));
        return self.fontTextWidth(@ptrFromInt(font), title);
    }

    fn truncatedLibraryTitle(self: *Renderer, title: []const u8, width: c_int, bold: bool) []const u8 {
        return self.cachedTitle(title, width, bold).text();
    }

    fn libraryMarqueeOffset(self: *Renderer, title: []const u8, width: c_int, bold: bool) c_int {
        const layout = self.cachedTitle(title, width, bold);
        if (!std.mem.eql(u8, self.library_marquee_title[0..self.library_marquee_len], title) or self.library_marquee_width != width or self.library_marquee_font != layout.font) {
            @memcpy(self.library_marquee_title[0..title.len], title);
            self.library_marquee_len = title.len;
            self.library_marquee_width = width;
            self.library_marquee_font = layout.font;
            self.library_marquee = .{ .started_at = self.frame_now_ms, .distance = @max(0, layout.full_width - width) };
        }
        return self.library_marquee.offset(self.frame_now_ms);
    }

    fn drawLibraryLabel(self: *Renderer, value: []const u8, text_x: c_int, text_y: c_int, bold: bool, clip_x: c_int, clip_width: c_int, item_x: c_int, item_y: c_int, fill_width: c_int, item_height: c_int) void {
        if (clip_width <= 0) return;
        const clip_y = item_y + 1;
        const clip_height = item_height - 2;
        self.playdate.graphics.setClipRect(clip_x, clip_y, clip_width, clip_height);
        self.drawUiLabel(value, text_x, text_y, bold);

        const fill_left = item_x + 1;
        const fill_right = fill_left + fill_width;
        const overlap_left = @max(clip_x, fill_left);
        const overlap_right = @min(clip_x + clip_width, fill_right);
        if (overlap_right > overlap_left) {
            self.playdate.graphics.setClipRect(overlap_left, clip_y, overlap_right - overlap_left, clip_height);
            self.playdate.graphics.setDrawMode(self.filledTextDrawMode());
            self.drawUiLabel(value, text_x, text_y, bold);
        }
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.playdate.graphics.setClipRect(0, 0, @intCast(reader_layout.screen_width), @intCast(reader_layout.screen_height));
    }

    fn drawUiLabel(self: *Renderer, value: []const u8, x: c_int, y: c_int, bold: bool) void {
        self.drawFontText(if (bold) self.ui_bold_font else self.ui_regular_font, value, x, y);
    }

    fn libraryBodyPatternColor(self: *const Renderer) pdapi.LCDColor {
        return patternColor(if (self.theme == .dark) &library_body_pattern_dark else &library_body_pattern_light);
    }

    fn loadingRulePatternColor(self: *const Renderer) pdapi.LCDColor {
        return patternColor(if (self.theme == .dark) &loading_rule_pattern_dark else &loading_rule_pattern_light);
    }

    fn loadingRailPatternColor(self: *const Renderer) pdapi.LCDColor {
        return patternColor(if (self.theme == .dark) &loading_rail_pattern_dark else &loading_rail_pattern_light);
    }

    fn drawSettings(self: *Renderer, view: *const reader_view.SettingsView) void {
        const screen_width: c_int = @intCast(reader_layout.screen_width);
        const screen_height: c_int = @intCast(reader_layout.screen_height);
        const header_height: c_int = 36;
        const footer_y: c_int = 210;
        const row_y: c_int = 43;
        const row_height: c_int = 22;
        const row_advance: c_int = 24;

        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRect(0, 0, screen_width, screen_height, self.libraryBodyPatternColor());
        self.playdate.graphics.fillRect(0, 0, screen_width, header_height, solidColor(self.backgroundColor()));
        self.playdate.graphics.fillRect(0, footer_y, screen_width, screen_height - footer_y, solidColor(self.backgroundColor()));
        self.playdate.graphics.fillRect(0, header_height - 1, screen_width, 1, solidColor(self.foregroundColor()));
        self.playdate.graphics.fillRect(0, footer_y, screen_width, 1, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.emphasizedText("Settings", 12, 12);

        for (0..view.row_count) |visible_index| {
            const row: reader_view.SettingsRow = @enumFromInt(view.first_visible + @as(u4, @intCast(visible_index)));
            const y = row_y + @as(c_int, @intCast(visible_index)) * row_advance;
            const label = switch (row) {
                .paged_presentation => "Progression",
                .page_animation => "Page animation",
                .theme => "Theme",
                .sound => "Sound",
                .pages_font => "Pages/Scroll font",
                .rsvp_font => "RSVP font",
                .progress_visibility => "Progress bar",
                .progress_position => "Progress position",
                .progress_scope => "Progress scope",
                .reset_progress => "Reset progress",
            };
            if (row == view.selected) self.emphasizedText(label, 24, y) else self.text(label, 24, y);
            const value: []const u8 = switch (row) {
                .paged_presentation => if (view.paged_presentation == .scroll) "Scroll" else "Pages",
                .page_animation => view.page_animation.label(),
                .sound => switch (view.sound) {
                    .off => "Off",
                    .subtle => "Subtle",
                    .full => "Full",
                },
                .theme => if (view.theme == .dark) "Dark" else "Light",
                .pages_font => fontName(view.pages_font),
                .rsvp_font => fontName(view.rsvp_font),
                .progress_visibility => if (view.progress_visibility == .on) "On" else "Off",
                .progress_position => if (view.progress_position == .bottom) "Bottom" else "Top",
                .progress_scope => switch (view.progress_scope) {
                    .chapter => "Chapter",
                    .book => "Book",
                    .both => "Both",
                },
                .reset_progress => "Hold A 3s",
            };
            self.drawSettingsItem(label, value, row == view.selected, row == .reset_progress, view.reset_hold_ms, y, row_height);
        }
        self.drawSettingsScrollbar(view);
        self.text(if (view.selected == .reset_progress) "Hold A: reset     B: back" else "A: change     B: back", 12, 217);
    }

    fn drawSettingsItem(self: *Renderer, label: []const u8, value: []const u8, selected: bool, is_reset: bool, reset_hold_ms: u16, y: c_int, height: c_int) void {
        const x: c_int = 12;
        const width: c_int = @intCast(reader_layout.screen_width - 24);
        const inset: c_int = 12;
        const inner_width = width - 2;
        const fill_width: c_int = if (!selected)
            0
        else if (is_reset and reset_hold_ms != 0)
            @intCast((@as(u32, reset_hold_ms) * @as(u32, @intCast(inner_width))) / reader_view.reset_hold_duration_ms)
        else
            inner_width;
        const border_width: c_int = if (selected) 2 else 1;
        const text_y = y + 2;
        const label_x = x + inset;
        const value_width = self.uiTextWidth(value, selected);
        const value_x = x + width - inset - value_width;
        const label_width = @max(@as(c_int, 0), value_x - label_x - 10);

        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRoundRect(x, y, width, height, 4, solidColor(self.backgroundColor()));
        if (fill_width == inner_width) {
            self.playdate.graphics.fillRoundRect(x + 1, y + 1, inner_width, height - 2, 3, solidColor(self.foregroundColor()));
        } else if (fill_width > 0) {
            self.playdate.graphics.fillRect(x + 1, y + 1, fill_width, height - 2, solidColor(self.foregroundColor()));
        }
        self.playdate.graphics.drawRoundRect(x, y, width, height, 4, border_width, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.drawLibraryLabel(label, label_x, text_y, selected, label_x, label_width, x, y, fill_width, height);
        self.drawLibraryLabel(value, value_x, text_y, selected, value_x, value_width, x, y, fill_width, height);
    }

    fn drawSettingsScrollbar(self: *Renderer, view: *const reader_view.SettingsView) void {
        self.drawRoundedScrollbar(394, 43, 4, 163, @intCast(view.first_visible), @intCast(view.row_count), @intCast(view.total_rows));
    }

    fn drawRoundedScrollbar(self: *Renderer, track_x: c_int, track_y: c_int, track_width: c_int, track_height: c_int, first_visible: usize, visible_rows: usize, total_rows: usize) void {
        if (total_rows <= visible_rows) return;
        const inner_height = track_height - 2;
        const thumb_height = @max(@as(c_int, 8), @divTrunc(inner_height * @as(c_int, @intCast(visible_rows)), @as(c_int, @intCast(total_rows))));
        const max_first: c_int = @intCast(total_rows - visible_rows);
        const thumb_y = track_y + 1 + @divTrunc((inner_height - thumb_height) * @as(c_int, @intCast(first_visible)), max_first);

        self.playdate.graphics.fillRect(track_x, track_y, track_width, track_height, solidColor(self.backgroundColor()));
        self.playdate.graphics.drawRoundRect(track_x, track_y, track_width, track_height, 2, 1, solidColor(self.foregroundColor()));
        self.playdate.graphics.fillRoundRect(track_x + 1, thumb_y, track_width - 2, thumb_height, 1, solidColor(self.foregroundColor()));
    }

    fn drawStatistics(self: *Renderer, view: *const reader_view.StatisticsView) void {
        switch (view.backdrop) {
            .paged => |*backdrop| self.drawPage(backdrop),
            .scroll => |*backdrop| self.drawScroll(backdrop),
        }

        const sheet_x: c_int = 10;
        const resting_y: c_int = 28;
        const sheet_width: c_int = @intCast(reader_layout.screen_width - 20);
        const sheet_height: c_int = 204;
        const travel: u16 = @intCast(reader_layout.screen_height - resting_y);
        const displacement = switch (view.phase) {
            .entering => reading_statistics.sheetDisplacement(view.elapsed_ms, travel),
            .exiting => reading_statistics.sheetExitDisplacement(view.elapsed_ms, travel),
        };
        const sheet_y = resting_y + @as(c_int, @intCast(displacement));

        self.playdate.graphics.fillRoundRect(sheet_x + 2, sheet_y + 2, sheet_width, sheet_height, 9, solidColor(self.foregroundColor()));
        self.playdate.graphics.fillRoundRect(sheet_x, sheet_y, sheet_width, sheet_height, 9, solidColor(self.backgroundColor()));
        self.playdate.graphics.drawRoundRect(sheet_x, sheet_y, sheet_width, sheet_height, 9, 1, solidColor(self.foregroundColor()));

        self.emphasizedText("Reading statistics", sheet_x + 12, sheet_y + 10);
        const lines = [_][]const u8{
            view.content.chapter_progress.slice(),
            view.content.chapter_eta.slice(),
            view.content.book_progress.slice(),
            view.content.book_eta.slice(),
            view.content.pace.slice(),
            view.content.index.slice(),
        };
        const row_advance = @max(reader_layout.lineAdvance(self.uiFontHeight()), 23);
        for (lines, 0..) |line, index| {
            self.text(line, sheet_x + 12, sheet_y + 36 + @as(c_int, @intCast(index * row_advance)));
        }
    }

    fn drawChapters(self: *Renderer, view: *const reader_view.ChaptersView) void {
        var header_buffer: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, "Chapters {d}/{d}", .{ view.selected + 1, view.entries }) catch "Chapters";
        self.emphasizedText(header, 12, 12);
        var label_buffer: [160]u8 = undefined;
        for (view.rows[0..view.row_count], 0..) |row, row_index| {
            const row_advance: c_int = @intCast(@max(reader_layout.lineAdvance(self.uiFontHeight()), 20));
            const y: c_int = 36 + @as(c_int, @intCast(row_index)) * row_advance;
            self.text(if (row.selected) ">" else " ", 8, y);
            const label = chapter_browser.formatLabel(&label_buffer, row.index, row.label, row.path);
            if (row.selected) self.emphasizedText(label, 24, y) else self.text(label, 24, y);
        }
        self.drawRoundedScrollbar(394, 35, 4, 167, view.first_visible, chapter_browser.visible_rows, view.entries);
        self.text("B: back", 12, 220);
    }

    fn drawPage(self: *Renderer, view: *const reader_view.PagedView) void {
        if (view.restoring or view.line_count == 0) {
            self.word_spotlight_state.cancel();
            self.highlight_collapse_state.cancel();
        }
        if (view.restoring) {
            if (view.mode_switch_loading) self.drawModeSwitchBackground() else self.drawLoadingScene("Finding your place", "Restoring reading position");
            return;
        }
        if (view.line_count == 0) {
            if (view.mode_switch_loading) self.drawModeSwitchBackground() else self.drawLoadingScene(if (view.reconstructing) "Finding your place" else "Loading chapter", if (view.reconstructing) "Rebuilding reading position" else "Setting the page");
            return;
        }
        self.drawProgressRails(view.progress, view.progress_visibility, view.progress_position, view.progress_scope);
        const font = self.pages_font;
        const font_height = self.readingFontHeight(font);
        const line_advance = reader_layout.lineAdvance(font_height);
        if (view.transition) |transition| {
            if (!self.screen_transition_state.active) {
                self.drawPageTransition(view, &transition, font, font_height, line_advance);
                return;
            }
        }
        self.drawPageLines(&view.lines, view.line_count, font, line_advance, 0);
        if (view.selected_span) |span| {
            for (span.line_index + 1..@max(span.line_index, span.last_line_index) + 1) |index| {
                const fragment = view.lines[index];
                const y = reader_layout.text_y + index * line_advance;
                const rect = reader_layout.highlightRect(reader_layout.text_x, y, @intCast(self.readingTextWidth(font, fragment)), font_height);
                self.invertedReadingText(font, fragment, @intCast(reader_layout.text_x), @intCast(y), @intCast(rect.x), @intCast(rect.y), @intCast(rect.width), @intCast(rect.height));
            }
            const line = view.lines[span.line_index];
            const x = reader_layout.text_x + @as(usize, @intCast(self.readingTextWidth(font, line[0..span.start])));
            const y = reader_layout.text_y + @as(usize, span.line_index) * line_advance;
            const word = line[span.start..span.end];
            const rect = reader_layout.highlightRect(x, y, @intCast(self.readingTextWidth(font, word)), font_height);
            self.invertedReadingText(font, word, @intCast(x), @intCast(y), @intCast(rect.x), @intCast(rect.y), @intCast(rect.width), @intCast(rect.height));
            if (!self.reduce_flashing and view.spotlight_nonce != self.last_word_spotlight_nonce) {
                self.last_word_spotlight_nonce = view.spotlight_nonce;
                self.word_spotlight_state.begin(self.frame_now_ms);
            }
            self.drawWordSpotlight(rect);
            self.highlight_collapse_state.cancel();
            return;
        }
        self.word_spotlight_state.cancel();
        if (view.dismiss_span) |span| self.drawHighlightCollapse(view, span, font, font_height, line_advance) else self.highlight_collapse_state.cancel();
    }

    fn drawHighlightCollapse(self: *Renderer, view: *const reader_view.PagedView, span: pagination.PageCache.WordSpan, font: reader_view.ReadingFont, font_height: usize, line_advance: usize) void {
        for (span.line_index..@max(span.line_index, span.last_line_index) + 1) |index| {
            const fragment: pagination.PageCache.WordSpan = if (index == span.line_index) span else .{ .line_index = @intCast(index), .start = 0, .end = @intCast(view.lines[index].len) };
            self.drawHighlightCollapseFragment(view, fragment, font, font_height, line_advance);
        }
    }

    fn drawHighlightCollapseFragment(self: *Renderer, view: *const reader_view.PagedView, span: pagination.PageCache.WordSpan, font: reader_view.ReadingFont, font_height: usize, line_advance: usize) void {
        if (!self.reduce_flashing and view.dismiss_nonce != self.last_highlight_dismiss_nonce) {
            self.last_highlight_dismiss_nonce = view.dismiss_nonce;
            self.highlight_collapse_state.begin(self.frame_now_ms);
        }
        const remaining = self.highlight_collapse_state.remaining(self.frame_now_ms) orelse return;
        const line = view.lines[span.line_index];
        const x = reader_layout.text_x + @as(usize, @intCast(self.readingTextWidth(font, line[0..span.start])));
        const y = reader_layout.text_y + @as(usize, span.line_index) * line_advance;
        const word = line[span.start..span.end];
        const rect = reader_layout.highlightRect(x, y, @intCast(self.readingTextWidth(font, word)), font_height);
        const height = highlight_collapse.height(@intCast(rect.height), remaining);
        if (height == 0) return;
        const collapse_y: c_int = @intCast(rect.y + (rect.height - @as(usize, @intCast(height))) / 2);
        self.playdate.graphics.setClipRect(@intCast(rect.x), collapse_y, @intCast(rect.width), height);
        self.invertedReadingText(font, word, @intCast(x), @intCast(y), @intCast(rect.x), @intCast(rect.y), @intCast(rect.width), @intCast(rect.height));
        self.playdate.graphics.clearClipRect();
    }

    fn drawWordSpotlight(self: *Renderer, target: reader_layout.HighlightRect) void {
        const progress = self.word_spotlight_state.progress(self.frame_now_ms) orelse return;
        const finish: c_int = @intCast(@max(target.width, target.height) + 4);
        // Cover all screen corners even for edge words. A 25% Bayer mask leaves the
        // page legible beneath.
        const diameter = word_spotlight.diameter(@intCast(reader_layout.screen_width * 3), finish, progress);
        const center_x: c_int = @intCast(target.x + target.width / 2);
        const center_y: c_int = @intCast(target.y + target.height / 2);
        self.drawForegroundDitheredCircle(center_x, center_y, diameter);
    }

    fn drawForegroundDitheredCircle(self: *Renderer, center_x: c_int, center_y: c_int, diameter: c_int) void {
        const frame = self.playdate.graphics.getFrame();
        word_spotlight.paintCircle(frame[0 .. pdapi.LCD_ROWSIZE * reader_layout.screen_height], pdapi.LCD_ROWSIZE, reader_layout.screen_width, reader_layout.screen_height, center_x, center_y, diameter, self.theme == .dark);
    }

    fn drawPageTransition(self: *Renderer, view: *const reader_view.PagedView, transition: *const reader_view.PageTransitionView, font: reader_view.ReadingFont, font_height: usize, line_advance: usize) void {
        if (transition.style != .bands) {
            self.drawCompositedPageTransition(view, transition, font, line_advance);
            return;
        }
        const screen_width: c_int = @intCast(reader_layout.screen_width);
        const band_height: c_int = @intCast(reader_layout.screen_height / page_transition.band_count);
        for (0..page_transition.band_count) |band_index| {
            const band: u8 = @intCast(band_index);
            const offset: c_int = @intCast(page_transition.bandOffset(transition.elapsed_ms, band, transition.direction, @intCast(reader_layout.screen_width)));
            const y = @as(c_int, @intCast(band_index)) * band_height;
            self.playdate.graphics.setClipRect(0, y, screen_width, band_height);
            const outgoing_x = switch (transition.direction) {
                .forward => -offset,
                .backward => offset,
            };
            const incoming_x = switch (transition.direction) {
                .forward => screen_width - offset,
                .backward => -screen_width + offset,
            };
            self.drawPageBandLines(&transition.lines, transition.line_count, font, font_height, line_advance, outgoing_x, y, band_height);
            self.drawPageBandLines(&view.lines, view.line_count, font, font_height, line_advance, incoming_x, y, band_height);
        }
        self.playdate.graphics.clearClipRect();
    }

    fn pageBitmap(self: *Renderer, stored: *?*pdapi.LCDBitmap) ?*pdapi.LCDBitmap {
        if (stored.* == null) stored.* = self.playdate.graphics.newBitmap(@intCast(reader_layout.screen_width), @intCast(reader_layout.screen_height), solidColor(self.backgroundColor()));
        return stored.*;
    }

    fn bitmapRaster(self: *Renderer, bitmap: *pdapi.LCDBitmap) ?page_compositor.Raster {
        var width: c_int = 0;
        var height: c_int = 0;
        var stride: c_int = 0;
        var pixels: [*c]u8 = null;
        self.playdate.graphics.getBitmapData(bitmap, &width, &height, &stride, null, &pixels);
        if (pixels == null or width != reader_layout.screen_width or height != reader_layout.screen_height or stride < @divTrunc(width, 8)) return null;
        return .{ .bytes = pixels[0..@intCast(stride * height)], .width = @intCast(width), .height = @intCast(height), .stride = @intCast(stride) };
    }

    fn drawPageBitmap(self: *Renderer, bitmap: *pdapi.LCDBitmap, lines: *const [pagination.max_lines][]const u8, count: u8, font: reader_view.ReadingFont, line_advance: usize) void {
        self.playdate.graphics.pushContext(bitmap);
        self.playdate.graphics.clearClipRect();
        self.playdate.graphics.clear(solidColor(self.backgroundColor()));
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.drawPageLines(lines, count, font, line_advance, 0);
        self.playdate.graphics.popContext();
    }

    /// Reuse two SDK bitmaps to keep frame-sized buffers off the stack. If allocation
    /// fails, show the page immediately.
    fn drawCompositedPageTransition(self: *Renderer, view: *const reader_view.PagedView, transition: *const reader_view.PageTransitionView, font: reader_view.ReadingFont, line_advance: usize) void {
        const outgoing_bitmap = self.pageBitmap(&self.page_outgoing_bitmap) orelse {
            self.drawPageLines(&view.lines, view.line_count, font, line_advance, 0);
            return;
        };
        const incoming_bitmap = self.pageBitmap(&self.page_incoming_bitmap) orelse {
            self.drawPageLines(&view.lines, view.line_count, font, line_advance, 0);
            return;
        };
        const outgoing = self.bitmapRaster(outgoing_bitmap) orelse {
            self.drawPageLines(&view.lines, view.line_count, font, line_advance, 0);
            return;
        };
        const incoming = self.bitmapRaster(incoming_bitmap) orelse {
            self.drawPageLines(&view.lines, view.line_count, font, line_advance, 0);
            return;
        };
        self.drawPageBitmap(outgoing_bitmap, &transition.lines, transition.line_count, font, line_advance);
        self.drawPageBitmap(incoming_bitmap, &view.lines, view.line_count, font, line_advance);
        const frame = self.playdate.graphics.getFrame();
        page_compositor.paint(.{
            .bytes = frame[0 .. pdapi.LCD_ROWSIZE * reader_layout.screen_height],
            .width = reader_layout.screen_width,
            .height = reader_layout.screen_height,
            .stride = pdapi.LCD_ROWSIZE,
        }, outgoing, incoming, transition.style, transition.direction, transition.elapsed_ms, reader_layout.text_y, reader_layout.screen_height - reader_layout.reserved_edge_rows, self.theme == .dark);
        self.playdate.graphics.markUpdatedRows(reader_layout.text_y, reader_layout.screen_height - reader_layout.reserved_edge_rows - 1);
    }

    fn drawPageBandLines(self: *Renderer, lines: *const [pagination.max_lines][]const u8, line_count: u8, font: reader_view.ReadingFont, font_height: usize, line_advance: usize, x_offset: c_int, top: c_int, height: c_int) void {
        for (lines.*[0..line_count], 0..) |line, index| {
            const y: c_int = @intCast(reader_layout.text_y + index * line_advance);
            if (invalidation.lineVisible(y, font_height, top, height))
                self.readingText(font, line, @as(c_int, @intCast(reader_layout.text_x)) + x_offset, y);
        }
    }

    fn drawPageLines(self: *Renderer, lines: *const [pagination.max_lines][]const u8, line_count: u8, font: reader_view.ReadingFont, line_advance: usize, x_offset: c_int) void {
        for (lines.*[0..line_count], 0..) |line, index| {
            const y = reader_layout.text_y + index * line_advance;
            self.readingText(font, line, @as(c_int, @intCast(reader_layout.text_x)) + x_offset, @intCast(y));
        }
    }

    fn drawRsvp(self: *Renderer, view: *const reader_view.RsvpView) void {
        const word = view.word orelse {
            if (view.mode_switch_loading) self.drawModeSwitchBackground() else self.drawLoadingScene(if (view.reconstructing) "Finding your place" else "Loading chapter", if (view.reconstructing) "Rebuilding word" else "Preparing RSVP");
            return;
        };
        self.drawProgressRails(view.progress, view.progress_visibility, view.progress_position, view.progress_scope);
        self.text(if (view.playing) "RSVP - playing" else "RSVP - paused", 12, 12);
        if (view.manual_wpm) |wpm| {
            var live_wpm_buffer: [24]u8 = undefined;
            self.rightAlignedUiText(std.fmt.bufPrint(&live_wpm_buffer, "Live: {d} WPM", .{wpm}) catch "", 12, false);
        }
        var buffer: [16]u8 = undefined;
        self.text(std.fmt.bufPrint(&buffer, "WPM: {d}", .{view.wpm}) catch "", 12, 36);
        const font = self.rsvp_font;
        const geometry = reader_layout.rsvpGeometry(self.readingFontHeight(font));
        self.rule(0, geometry.guide_top_y, reader_layout.screen_width - 1, geometry.guide_top_y);
        self.rule(0, geometry.guide_bottom_y, reader_layout.screen_width - 1, geometry.guide_bottom_y);
        self.rule(reader_layout.rsvp_anchor_x, geometry.top_tick_start_y, reader_layout.rsvp_anchor_x, geometry.guide_top_y);
        self.rule(reader_layout.rsvp_anchor_x, geometry.guide_bottom_y, reader_layout.rsvp_anchor_x, geometry.bottom_tick_end_y);
        if (view.anchor) |anchor| {
            const prefix_width = self.readingTextWidth(font, word[0..anchor.start]);
            const anchor_width = self.readingTextWidth(font, word[0..anchor.end]) - prefix_width;
            const x = @as(c_int, @intCast(reader_layout.rsvp_anchor_x)) - prefix_width - @divTrunc(anchor_width, 2);
            self.readingText(font, word, x, @intCast(geometry.word_y));
        } else self.readingText(font, word, @intCast(reader_layout.text_x), @intCast(geometry.word_y));
        self.text("A: play  Up/Down: WPM", 12, 192);
        self.text("Left: prev sentence  B: back", 12, 216);
    }

    fn drawScroll(self: *Renderer, view: *const reader_view.ScrollView) void {
        if (view.restoring) {
            if (view.mode_switch_loading) self.drawModeSwitchBackground() else self.drawLoadingScene("Finding your place", "Restoring reading position");
            return;
        }
        self.drawProgressRails(view.progress, view.progress_visibility, view.progress_position, view.progress_scope);
        const top: c_int = @intCast(reader_layout.text_y);
        const height: c_int = @intCast(reader_layout.screen_height - reader_layout.text_y - reader_layout.reserved_edge_rows);
        self.playdate.graphics.setClipRect(@intCast(reader_layout.text_x), top, @intCast(reader_layout.text_width), height);
        const font = self.pages_font;
        const font_height = self.readingFontHeight(font);
        const advance: i32 = @intCast(reader_layout.lineAdvance(font_height));
        // Moving forward lifts the chapter; moving backward at its start
        // lowers it and reveals the continuation affordance above.
        const overscroll: i32 = @as(i32, @intCast(view.chapter_end_overscroll_px)) - @as(i32, @intCast(view.chapter_start_overscroll_px));
        for (view.window.tiles[0..view.window.tile_count]) |tile| switch (tile) {
            .page => |page| {
                for (0..page.cache.line_count) |line_index| {
                    const y: i32 = @as(i32, page.origin_y) + @as(i32, @intCast(line_index)) * advance - overscroll;
                    if (invalidation.lineVisible(y, font_height, top, height))
                        self.readingText(font, page.cache.line(line_index), @intCast(reader_layout.text_x), @intCast(y));
                }
            },
            .loading_before, .loading_after, .unavailable_before, .unavailable_after => |origin_y| {
                const last_y: i32 = @intCast(reader_layout.screen_height - reader_layout.reserved_edge_rows - font_height);
                const y = std.math.clamp(@as(i32, origin_y) - overscroll, @as(i32, reader_layout.text_y), last_y);
                self.text("...", @intCast(reader_layout.text_x), @intCast(y));
            },
        };
        self.playdate.graphics.setClipRect(0, 0, @intCast(reader_layout.screen_width), @intCast(reader_layout.screen_height));
        if (view.chapter_start_overscroll_px >= 24) self.text("Keep turning to go back", 120, 12);
        if (view.chapter_end_overscroll_px >= 24) self.text("Keep turning to continue", 112, 216);
    }

    fn drawProgressRails(
        self: *Renderer,
        metrics: ?reader_view.ProgressView,
        visibility: reader_view.ProgressVisibility,
        position: reader_view.ProgressPosition,
        scope: reader_view.ProgressScope,
    ) void {
        const rails = progress_rail.layout(metrics, visibility, position, scope);
        if (rails.chapter) |rail| self.drawProgressRail(rail);
        if (rails.book) |rail| self.drawProgressRail(rail);
    }

    fn drawProgressRail(self: *Renderer, rail: progress_rail.Rail) void {
        if (rail.width == 0) return;
        self.playdate.graphics.fillRect(0, rail.y, rail.width, 1, solidColor(self.foregroundColor()));
    }

    fn rule(self: *Renderer, x1: usize, y1: usize, x2: usize, y2: usize) void {
        self.playdate.graphics.drawLine(@intCast(x1), @intCast(y1), @intCast(x2), @intCast(y2), 1, solidColor(self.foregroundColor()));
    }

    fn drawFailure(self: *Renderer, view: *const reader_view.ErrorView, allocator_stats: AllocatorStats) void {
        switch (view.*) {
            .unavailable => self.emphasizedText("EPUB unavailable", 12, 12),
            .invalid_archive => |detail| self.drawOpeningFailure(detail, allocator_stats),
            .missing_mimetype => self.emphasizedText("mimetype entry missing", 12, 12),
            .invalid_mimetype => self.emphasizedText("Invalid mimetype entry", 12, 12),
            .chapter => |chapter| {
                const reason: []const u8 = switch (chapter.reason) {
                    .archive => "ZIP or DEFLATE error",
                    .tokenizer => "XHTML tokenizer error",
                    .page_limit => "Page limit exceeded",
                    .no_supported_text => "No supported text",
                };
                self.emphasizedText("Chapter unavailable", 12, 12);
                self.text(reason, 12, 36);
                if (chapter.path) |path| self.text(path, 12, 60);
                self.text("Left/Right: another chapter", 12, 100);
            },
        }
        if (view.* != .chapter) self.text("B: library", 12, 216);
    }

    fn drawOpeningFailure(self: *Renderer, detail: reader_view.OpeningFailure, allocator_stats: AllocatorStats) void {
        self.emphasizedText("EPUB opening failed", 12, 12);
        var buffer: [96]u8 = undefined;
        switch (detail) {
            .opening_allocation => |bytes| self.drawAllocationFailure("Opening state allocation", bytes, allocator_stats, &buffer),
            .archive_initialization => |err| self.drawOpeningError("Archive initialization", err, &buffer),
            .archive_scan => |failure| {
                self.drawOpeningError("Archive scan", failure.cause, &buffer);
                const size_line = std.fmt.bufPrint(&buffer, "File size: {d} bytes", .{failure.file_size}) catch return;
                self.text(size_line, 12, 90);
                const tail_line = std.fmt.bufPrint(&buffer, "Tail: {X:0>2} {X:0>2} {X:0>2} {X:0>2}", .{
                    failure.tail_signature[0],
                    failure.tail_signature[1],
                    failure.tail_signature[2],
                    failure.tail_signature[3],
                }) catch return;
                self.text(tail_line, 12, 114);
                if (failure.nonzero_through) |offset| {
                    const readable_line = std.fmt.bufPrint(&buffer, "Non-zero through: {d}", .{offset}) catch return;
                    self.text(readable_line, 12, 138);
                }
                if (failure.zero_from) |offset| {
                    const zero_line = std.fmt.bufPrint(&buffer, "Zero from: {d}", .{offset}) catch return;
                    self.text(zero_line, 12, 162);
                }
            },
            .directory_validation => |err| self.drawOpeningError("Directory validation", err, &buffer),
            .directory_index => self.text("Stage: directory index", 12, 42),
            .container_lookup => |err| self.drawOpeningError("Container lookup", err, &buffer),
            .container_stream => |err| self.drawOpeningError("Container stream", err, &buffer),
            .container_read => |err| self.drawOpeningError("Container read", err, &buffer),
            .container_buffer => self.text("Stage: container buffer", 12, 42),
            .container_finish => |err| self.drawOpeningError("Container checksum", err, &buffer),
            .container_parse => |err| self.drawOpeningError("Container parse", err, &buffer),
            .package_lookup => |err| self.drawOpeningError("OPF lookup", err, &buffer),
            .package_size => |bytes| {
                const line = std.fmt.bufPrint(&buffer, "Stage: OPF size ({d} bytes)", .{bytes}) catch return;
                self.text(line, 12, 42);
                self.text("Cause: outside supported range", 12, 66);
            },
            .package_allocation => |bytes| self.drawAllocationFailure("OPF allocation", bytes, allocator_stats, &buffer),
            .package_stream => |err| self.drawOpeningError("OPF stream", err, &buffer),
            .package_read => |err| self.drawOpeningError("OPF read/inflate", err, &buffer),
            .package_buffer => self.text("Stage: OPF buffer", 12, 42),
            .package_finish => |err| self.drawOpeningError("OPF checksum", err, &buffer),
            .package_parse => |err| self.drawOpeningError("OPF parse", err, &buffer),
        }
    }

    fn drawOpeningError(self: *Renderer, stage: []const u8, err: anyerror, buffer: *[96]u8) void {
        const stage_line = std.fmt.bufPrint(buffer, "Stage: {s}", .{stage}) catch return;
        self.text(stage_line, 12, 42);
        const cause_line = std.fmt.bufPrint(buffer, "Cause: {s}", .{@errorName(err)}) catch return;
        self.text(cause_line, 12, 66);
    }

    fn drawAllocationFailure(self: *Renderer, stage: []const u8, requested: usize, stats: AllocatorStats, buffer: *[96]u8) void {
        const stage_line = std.fmt.bufPrint(buffer, "Stage: {s}", .{stage}) catch return;
        self.text(stage_line, 12, 42);
        const request_line = std.fmt.bufPrint(buffer, "Requested: {d} bytes", .{requested}) catch return;
        self.text(request_line, 12, 66);
        const memory_line = std.fmt.bufPrint(buffer, "Live: {d}  Peak: {d}", .{ stats.live_bytes, stats.peak_live_bytes }) catch return;
        self.text(memory_line, 12, 90);
    }
};

fn solidColor(color: pdapi.LCDSolidColor) pdapi.LCDColor {
    return @intCast(@intFromEnum(color));
}

const library_body_pattern_light = pdapi.LCDPattern{
    0b11110111,
    0b11011111,
    0b01111111,
    0b11111101,
    0b11110111,
    0b11011111,
    0b01111111,
    0b11111101,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
};

const library_body_pattern_dark = pdapi.LCDPattern{
    0b00001000,
    0b00100000,
    0b10000000,
    0b00000010,
    0b00001000,
    0b00100000,
    0b10000000,
    0b00000010,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
};

const loading_rule_pattern_light = pdapi.LCDPattern{
    0b11101110,
    0b10111011,
    0b11101110,
    0b10111011,
    0b11101110,
    0b10111011,
    0b11101110,
    0b10111011,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
};

const loading_rule_pattern_dark = pdapi.LCDPattern{
    0b00010001,
    0b01000100,
    0b00010001,
    0b01000100,
    0b00010001,
    0b01000100,
    0b00010001,
    0b01000100,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
};

const loading_rail_pattern_light = pdapi.LCDPattern{
    0b10101010,
    0b01010101,
    0b10101010,
    0b01010101,
    0b10101010,
    0b01010101,
    0b10101010,
    0b01010101,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
};

const loading_rail_pattern_dark = pdapi.LCDPattern{
    0b01010101,
    0b10101010,
    0b01010101,
    0b10101010,
    0b01010101,
    0b10101010,
    0b01010101,
    0b10101010,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
};

fn patternColor(pattern: *const pdapi.LCDPattern) pdapi.LCDColor {
    return @intFromPtr(pattern);
}

const RenderViewKind = enum {
    library,
    book_actions,
    opening,
    paged,
    scroll,
    rsvp,
    settings,
    statistics,
    chapters,
    failure,
};

fn renderViewKind(model: *const reader_view.RenderModel) RenderViewKind {
    return switch (model.*) {
        .library => .library,
        .book_actions => .book_actions,
        .opening => .opening,
        .paged => .paged,
        .scroll => .scroll,
        .rsvp => .rsvp,
        .settings => .settings,
        .statistics => .statistics,
        .chapters => .chapters,
        .failure => .failure,
    };
}

fn transitionsBetween(previous: RenderViewKind, next: RenderViewKind) bool {
    if (previous == .settings or next == .settings) {
        const other = if (previous == .settings) next else previous;
        return other == .library or isReadingView(other);
    }
    if (previous == .library or next == .library) return isReadingView(if (previous == .library) next else previous);
    return (previous == .rsvp and isPagedView(next)) or (next == .rsvp and isPagedView(previous));
}

fn entersLibrary(next: RenderViewKind, previous: ?RenderViewKind) bool {
    if (next != .library) return false;
    const prior = previous orelse return true;
    // Dismissing book actions restores the existing Library frame without replaying its
    // entrance.
    return prior != .library and prior != .book_actions;
}

fn isReadingView(view: RenderViewKind) bool {
    return view == .opening or isPagedView(view) or view == .rsvp;
}

fn isPagedView(view: RenderViewKind) bool {
    return view == .paged or view == .scroll;
}

fn entranceOffset(start: c_int, progress: u16) c_int {
    return @intCast(@divTrunc(@as(i32, start) * @as(i32, library_transition.complete - progress), library_transition.complete));
}

test "screen fade only covers the selected navigation boundaries" {
    try std.testing.expect(transitionsBetween(.library, .opening));
    try std.testing.expect(transitionsBetween(.paged, .rsvp));
    try std.testing.expect(transitionsBetween(.rsvp, .scroll));
    try std.testing.expect(transitionsBetween(.settings, .library));
    try std.testing.expect(transitionsBetween(.paged, .settings));
    try std.testing.expect(!transitionsBetween(.paged, .paged));
    try std.testing.expect(!transitionsBetween(.opening, .paged));
    try std.testing.expect(!transitionsBetween(.paged, .statistics));
    try std.testing.expect(!transitionsBetween(.chapters, .paged));
}

test "dismissing book actions does not re-enter the library" {
    try std.testing.expect(!entersLibrary(.library, .book_actions));
    try std.testing.expect(entersLibrary(.library, .opening));
}

fn fontName(font: reader_view.ReadingFont) []const u8 {
    return switch (font) {
        .newsleak_serif => "Newsleak Serif",
        .sasser_slab => "Sasser Slab",
        .asheville_sans_14_bold => "Asheville Sans 14 Bold",
        .roobert_11_bold => "Roobert 11 Bold",
        .roobert_20_medium => "Roobert 20 Medium",
        .roobert_24_medium => "Roobert 24 Medium",
        .espy_serif_3 => "Espy Serif 3",
        .espy_serif_4 => "Espy Serif 4",
        .espy_sans_5 => "Espy Sans 5",
        .literata_36pt_medium_30 => "Literata 30 Medium",
    };
}

test "page bands submit only intersecting font cells in both directions" {
    const Fake = struct {
        const Call = struct { x: c_int, y: c_int, top: c_int, height: c_int };
        var calls: [220]Call = undefined;
        var count: usize = 0;
        var top: c_int = 0;
        var height: c_int = 0;
        var cleared: bool = false;
        fn clip(_: c_int, y: c_int, _: c_int, h: c_int) callconv(.c) void {
            top = y;
            height = h;
        }
        fn clearClip() callconv(.c) void {
            cleared = true;
        }
        fn font(_: ?*pdapi.LCDFont) callconv(.c) void {}
        fn text(_: ?*const anyopaque, _: usize, _: pdapi.PDStringEncoding, x: c_int, y: c_int) callconv(.c) c_int {
            calls[count] = .{ .x = x, .y = y, .top = top, .height = height };
            count += 1;
            return 1;
        }
    };
    var graphics: pdapi.PlaydateGraphics = undefined;
    graphics.setClipRect = Fake.clip;
    graphics.clearClipRect = Fake.clearClip;
    graphics.setFont = Fake.font;
    graphics.drawText = Fake.text;
    var api: pdapi.PlaydateAPI = undefined;
    api.graphics = &graphics;
    const renderer = try std.testing.allocator.create(Renderer);
    defer std.testing.allocator.destroy(renderer);
    const face: *pdapi.LCDFont = @ptrFromInt(4);
    renderer.initInPlace(&api, face, face, face, face, face, face, face, face, face, face, face);
    var view = reader_view.PagedView{ .lines = @splat("incoming"), .line_count = 11, .selected_span = null, .page_index = 1, .waiting = false, .reconstructing = false };
    var transition = reader_view.PageTransitionView{ .lines = @splat("outgoing"), .line_count = 11, .direction = .forward, .elapsed_ms = 0 };
    for ([_]usize{ 11, 14, 20, 24, 30 }) |font_height| {
        const advance = reader_layout.lineAdvance(font_height);
        view.line_count = reader_layout.pageLineLimit(font_height, pagination.max_lines);
        transition.line_count = view.line_count;
        for ([_]page_transition.Direction{ .forward, .backward }) |direction| {
            transition.direction = direction;
            // Cover settled endpoints and both sides of stagger boundaries.
            for ([_]u16{ 0, 1, 14, 15, 16, 135, 150, 299, 300, 1 }) |elapsed| {
                transition.elapsed_ms = elapsed;
                Fake.count = 0;
                Fake.cleared = false;
                renderer.drawPageTransition(&view, &transition, .newsleak_serif, font_height, advance);
                var expected_count: usize = 0;
                for (0..page_transition.band_count) |band| {
                    const top: c_int = @intCast(band * 24);
                    const offset: c_int = @intCast(page_transition.bandOffset(elapsed, @intCast(band), direction, 400));
                    const positions: [2]c_int = if (direction == .forward) .{ -offset, 400 - offset } else .{ offset, -400 + offset };
                    for (positions) |x_offset| {
                        for (0..view.line_count) |line| {
                            const y: c_int = @intCast(reader_layout.text_y + line * advance);
                            // Check whether any row of the font cell survives the SDK
                            // band clip.
                            var visible = false;
                            for (0..font_height) |pixel_row| {
                                const row = y + @as(c_int, @intCast(pixel_row));
                                if (row >= top and row < top + 24) visible = true;
                            }
                            if (!visible) continue;
                            try std.testing.expect(expected_count < Fake.count);
                            try std.testing.expectEqualDeep(Fake.Call{ .x = 8 + x_offset, .y = y, .top = top, .height = 24 }, Fake.calls[expected_count]);
                            expected_count += 1;
                        }
                    }
                }
                try std.testing.expectEqual(expected_count, Fake.count);
                try std.testing.expect(Fake.cleared);
                try std.testing.expect(Fake.count < @as(usize, view.line_count) * 20);
                if (font_height == 20) try std.testing.expectEqual(@as(usize, 36), Fake.count);
            }
        }
    }
}
