const std = @import("std");
const cache_policy = @import("../content/cache_policy.zig");
const navigation = @import("../content/navigation.zig");
const pagination = @import("../content/pagination.zig");
const reader_transitions = @import("reader_transitions.zig");
const xhtml = @import("../content/xhtml.zig");
const prefetch_session = @import("prefetch_session.zig");
const scroll_geometry = @import("scroll_geometry.zig");

/// Owns page caches and construction; the caller supplies decoded input.
pub const PagedReader = struct {
    pub const page_capacity: usize = 10;
    pub const max_scroll_detents_per_update: u8 = 8;
    pub const SlotIndex = u8;
    pub const page_pool_reserved_bytes = page_capacity * @sizeOf(pagination.PageCache);
    pub const page_pool_byte_budget = 44 * 1024;
    pub const SelectionTarget = reader_transitions.PagedSelectionTarget;

    pub const SlotRole = enum { free, displayed, stream_front, history, building, ready_ahead, prefetch };
    pub const SlotState = struct {
        role: SlotRole = .free,
        chapter: u8 = 0,
        page: u32 = 0,
    };
    pub const PrefetchPage = struct {
        slot: SlotIndex,
        page: *pagination.PageCache,
    };

    comptime {
        std.debug.assert(page_capacity == 10);
        std.debug.assert(page_capacity <= @as(usize, std.math.maxInt(SlotIndex)) + 1);
        std.debug.assert(page_pool_reserved_bytes <= page_pool_byte_budget);
    }

    pub const BuildState = union(enum) {
        idle,
        building: SlotIndex,
        ready: SlotIndex,
    };

    /// Rescans restart at the chapter beginning; targets are semantic locations, not
    /// file offsets.
    pub const Rescan = union(enum) {
        none,
        page: struct { target: u32, scanning: u32 },
        last_page: struct { scanning: u32, last_completed: SlotIndex },
    };

    pub const Move = enum {
        moved,
        waiting,
        needs_reconstruction,
        needs_previous_chapter,
        needs_next_chapter,
        at_limit,
    };

    pub const RenderState = struct {
        page: ?*const pagination.PageCache,
        selected_word_ordinal: ?u32,
        page_index: u32,
        waiting_for_page: bool,
        reconstructing: bool,
    };

    pub const ScrollMove = enum { moved, waiting, at_start, at_end, needs_reconstruction };

    const ScrollRescan = struct {
        target: u32,
        scanning: u32,
        resume_page: u32,
    };

    /// Tiles borrow page caches for one frame. Placeholders have coordinates but no
    /// text or words.
    pub const ScrollTile = union(enum) {
        page: struct {
            cache: *const pagination.PageCache,
            origin_y: i16,
        },
        loading_before: i16,
        loading_after: i16,
        unavailable_before: i16,
        unavailable_after: i16,
    };

    pub const ScrollRenderState = struct {
        tiles: [3]ScrollTile = [_]ScrollTile{.{ .loading_after = 0 }} ** 3,
        tile_count: u2 = 0,
        at_chapter_start: bool = false,
        at_chapter_end: bool = false,
    };

    pages: [page_capacity]pagination.PageCache = [_]pagination.PageCache{.{}} ** page_capacity,
    slots: [page_capacity]SlotState = [_]SlotState{.{}} ** page_capacity,
    /// Pin visible history slots until the next render window replaces the pins.
    scroll_pins: [page_capacity]bool = [_]bool{false} ** page_capacity,
    scroll_position: scroll_geometry.Position = .{},
    scroll_rescan: ?ScrollRescan = null,
    scroll_previous_unavailable: bool = false,
    prefetch_page: ?SlotIndex = null,
    current_page: SlotIndex = 0,
    next_page: SlotIndex = 1,
    current_ready: bool = false,
    next_ready: bool = false,
    build: BuildState = .idle,
    builder: ?pagination.EventPageBuilder = null,
    extractor: ?xhtml.StreamExtractor = null,
    selected_word_ordinal: ?u32 = null,
    pending_selection: ?SelectionTarget = null,
    detent_backlog: i16 = 0,
    chapter_index: u8 = 0,
    page_index: u32 = 0,
    chapter_end: bool = false,
    chapter_last_page: ?u32 = null,
    rescan: Rescan = .none,
    reconstructing: bool = false,
    navigation_state: navigation.State = .{},
    checkpoints: cache_policy.Policy,
    prefetch: prefetch_session.Session = .{},

    /// Initialize in place to keep a temporary page pool off the device stack.
    pub fn initInPlace(self: *PagedReader, checkpoint_byte_budget: usize) void {
        self.* = undefined;
        for (&self.pages) |*page| page.clear();
        self.slots = [_]SlotState{.{}} ** page_capacity;
        self.scroll_pins = [_]bool{false} ** page_capacity;
        self.scroll_position = .{};
        self.scroll_rescan = null;
        self.scroll_previous_unavailable = false;
        self.prefetch_page = null;
        self.current_page = 0;
        self.next_page = 1;
        self.current_ready = false;
        self.next_ready = false;
        self.build = .idle;
        self.builder = null;
        self.extractor = null;
        self.selected_word_ordinal = null;
        self.pending_selection = null;
        self.detent_backlog = 0;
        self.chapter_index = 0;
        self.page_index = 0;
        self.chapter_end = false;
        self.chapter_last_page = null;
        self.rescan = .none;
        self.reconstructing = false;
        self.navigation_state = .{};
        self.checkpoints = cache_policy.Policy.init(checkpoint_byte_budget);
        self.prefetch = .{};
    }

    /// Host-test convenience only. Device startup must use `initInPlace`.
    pub fn init(checkpoint_byte_budget: usize) PagedReader {
        var reader: PagedReader = undefined;
        reader.initInPlace(checkpoint_byte_budget);
        return reader;
    }

    /// Keep the configured checkpoint budget across books.
    pub fn resetForBook(self: *PagedReader) void {
        const checkpoint_byte_budget = self.checkpoints.byte_budget;
        self.initInPlace(checkpoint_byte_budget);
    }

    pub fn begin(self: *PagedReader, chapter: u8, width: usize, measure: pagination.Measure) void {
        self.chapter_index = chapter;
        self.page_index = 0;
        self.current_page = 0;
        self.next_page = 1;
        self.current_ready = false;
        self.next_ready = false;
        self.selected_word_ordinal = null;
        self.pending_selection = null;
        self.detent_backlog = 0;
        self.chapter_end = false;
        self.chapter_last_page = null;
        self.rescan = .none;
        self.reconstructing = false;
        self.navigation_state.opened(0);
        for (&self.pages) |*page| page.clear();
        self.slots = [_]SlotState{.{}} ** page_capacity;
        self.scroll_pins = [_]bool{false} ** page_capacity;
        self.scroll_position = .{};
        self.scroll_rescan = null;
        self.scroll_previous_unavailable = false;
        self.prefetch_page = null;
        self.setSlot(self.current_page, .building, chapter, 0);
        self.builder = pagination.EventPageBuilder.init(&self.pages[self.current_page], width, measure);
        self.extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitEvent });
        self.build = .{ .building = self.current_page };
    }

    pub fn beginRescan(self: *PagedReader, target: u32) void {
        self.reconstructing = true;
        self.navigation_state.beginRescan(target);
        self.rescan = .{ .page = .{ .target = target, .scanning = 0 } };
        self.current_ready = false;
        self.next_ready = false;
    }

    pub fn beginRescanToLastPage(self: *PagedReader) void {
        self.reconstructing = true;
        self.rescan = .{ .last_page = .{ .scanning = 0, .last_completed = 0 } };
        self.current_ready = false;
        self.next_ready = false;
    }

    pub fn beginWordRescan(self: *PagedReader, target: u32) void {
        self.reconstructing = true;
        self.pending_selection = .{ .ordinal = target };
    }

    pub fn current(self: *const PagedReader) ?*const pagination.PageCache {
        if (!self.current_ready) return null;
        return &self.pages[self.current_page];
    }

    /// The returned page is borrowed but not pinned; consume it before cache mutation.
    pub fn cachedPage(self: *const PagedReader, page: u32) ?*const pagination.PageCache {
        const slot = self.findCachedPage(page) orelse return null;
        return &self.pages[slot];
    }

    /// Hide provisional pages until reconstruction reaches the requested destination.
    pub fn renderState(self: *const PagedReader) RenderState {
        return .{
            .page = if (self.reconstructing) null else self.current(),
            .selected_word_ordinal = self.selected_word_ordinal,
            .page_index = self.page_index,
            .waiting_for_page = !self.current_ready or self.pending_selection != null,
            .reconstructing = self.reconstructing,
        };
    }

    /// Borrow cached Scroll tiles and replace their eviction pins; text and stream
    /// state stay unchanged.
    pub fn scrollRenderState(self: *PagedReader, position: scroll_geometry.Position, geometry: scroll_geometry.Geometry) ScrollRenderState {
        self.clearScrollPins();
        var result = ScrollRenderState{};
        const top_slot = self.findDrawablePage(position.top_page) orelse {
            self.appendScrollTile(&result, .{ .loading_after = @intCast(geometry.viewport.top_y) });
            return result;
        };

        const waiting_before: u16 = if (position.waiting_px < 0) @intCast(-@as(i32, position.waiting_px)) else 0;
        const origin = scrollTopOrigin(geometry.viewport.top_y, position.offset_px, waiting_before);
        if (waiting_before != 0) self.appendScrollTile(&result, if (self.scroll_previous_unavailable)
            .{ .unavailable_before = scrollTopOrigin(geometry.viewport.top_y, position.offset_px, 0) }
        else
            .{ .loading_before = scrollTopOrigin(geometry.viewport.top_y, position.offset_px, 0) });
        self.appendScrollPage(&result, top_slot, origin);

        var page = position.top_page;
        var page_slot = top_slot;
        var page_origin = origin;
        while (result.tile_count < 3) {
            const bottom = advanceScrollOrigin(page_origin, pageExtent(geometry, &self.pages[page_slot]));
            // Include a line cell beyond the clip so new text is ready offscreen.
            if (bottom >= @as(i16, @intCast(geometry.viewport.bottom_y + geometry.line_advance))) break;
            if (self.chapter_end and self.chapter_last_page != null and page >= self.chapter_last_page.?) break;
            page += 1;
            const next_slot = self.findDrawablePage(page) orelse {
                self.appendScrollTile(&result, .{ .loading_after = bottom });
                break;
            };
            self.appendScrollPage(&result, next_slot, bottom);
            page_slot = next_slot;
            page_origin = bottom;
        }
        result.at_chapter_start = position.top_page == 0 and position.offset_px == 0 and position.waiting_px >= 0;
        result.at_chapter_end = self.chapter_end and self.chapter_last_page != null and page >= self.chapter_last_page.?;
        return result;
    }

    /// Scroll starts from the current Paged page when no semantic cursor is
    /// available (for example, while the first page is still being built).
    pub fn beginScroll(self: *PagedReader) void {
        self.scroll_position = .{ .top_page = self.page_index };
    }

    /// Use cached pages only; aligning a word does not start decoding.
    pub fn beginScrollAtWord(self: *PagedReader, ordinal: u32, geometry: scroll_geometry.Geometry) void {
        var candidate: ?usize = null;
        for (self.slots, 0..) |state, index| {
            if (state.chapter != self.chapter_index or ordinal < self.pages[index].first_word_ordinal or ordinal >= self.pages[index].first_word_ordinal + self.pages[index].word_count) continue;
            switch (state.role) {
                .displayed, .stream_front, .history => {
                    // Keep the displayed fragment when a split word spans pages.
                    if (state.role == .displayed) {
                        candidate = index;
                        break;
                    }
                    if (candidate == null or state.page < self.slots[candidate.?].page) candidate = index;
                },
                .free, .building, .ready_ahead, .prefetch => {},
            }
        }
        if (candidate) |index| {
            const line = if (self.pages[index].wordSpan(ordinal)) |span| span.line_index else 0;
            const page = self.slots[index].page;
            self.scroll_position = .{ .top_page = page, .offset_px = @as(u16, line) * geometry.line_advance };
            if (self.chapter_end and self.chapter_last_page != null and page == self.chapter_last_page.?) self.clampScrollAtChapterEnd(geometry);
            return;
        }
        self.beginScroll();
    }

    /// The first source word on or below the viewport's top edge is the
    /// semantic Scroll cursor used for resume, progress, and mode transfer.
    pub fn scrollFirstVisibleWord(self: *const PagedReader, geometry: scroll_geometry.Geometry) ?u32 {
        const slot = self.findDrawablePage(self.scroll_position.top_page) orelse return null;
        const page = &self.pages[slot];
        var line: u8 = @intCast(@min(@as(u16, page.line_count), self.scroll_position.offset_px / geometry.line_advance));
        while (line < page.line_count) : (line += 1) {
            if (page.line_word_counts[line] != 0) return page.lineFirstWordOrdinal(line);
        }
        return null;
    }

    /// Require the final word's last fragment; a carried fragment alone cannot
    /// establish the ending.
    pub fn pageContainsEnding(page: *const pagination.PageCache, words: u32) bool {
        return words != 0 and page.line_count != 0 and page.word_count != 0 and
            !page.last_word_continues and page.first_word_ordinal < words and
            page.completedWordCount() == words - page.first_word_ordinal;
    }

    /// Read-only counterpart of the three-tile render window. A short tail
    /// can be fully visible while the viewport still begins on the prior page.
    pub fn scrollEndingVisible(self: *const PagedReader, geometry: scroll_geometry.Geometry, words: u32) bool {
        if (self.reconstructing or self.scroll_position.waiting_px != 0) return false;
        var page_index = self.scroll_position.top_page;
        var origin = scrollTopOrigin(geometry.viewport.top_y, self.scroll_position.offset_px, 0);
        for (0..3) |_| {
            const slot = self.findDrawablePage(page_index) orelse return false;
            const page = &self.pages[slot];
            const bottom = advanceScrollOrigin(origin, pageExtent(geometry, page));
            if (pageContainsEnding(page, words)) return bottom > geometry.viewport.top_y and bottom <= geometry.viewport.bottom_y;
            if (bottom >= geometry.viewport.bottom_y) return false;
            page_index += 1;
            origin = bottom;
        }
        return false;
    }

    /// Discard queued motion without changing the reading location.
    pub fn clearScrollTransient(self: *PagedReader) void {
        self.scroll_position.waiting_px = 0;
        self.scroll_position.pending_detents = 0;
    }

    pub fn scrollViewport(self: *PagedReader, direction: scroll_geometry.Direction, geometry: scroll_geometry.Geometry) ScrollMove {
        return switch (direction) {
            .forward => self.scrollForwardPixels(geometry, geometry.viewport.height()),
            .backward => self.scrollBackwardPixels(geometry, geometry.viewport.height()),
        };
    }

    /// The caller supplies pixels; page-relative geometry handles cache boundaries and
    /// waits.
    pub fn scrollPixels(self: *PagedReader, direction: scroll_geometry.Direction, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        if (pixels == 0) return .moved;
        return switch (direction) {
            .forward => self.scrollForwardRequested(geometry, pixels),
            .backward => self.scrollBackwardRequested(geometry, pixels),
        };
    }

    /// Transfer Scroll's first visible word using cached pages only.
    pub fn showScrollTopPage(self: *PagedReader) bool {
        return self.showCachedPage(self.scroll_position.top_page);
    }

    pub fn scrollPosition(self: *const PagedReader) scroll_geometry.Position {
        return self.scroll_position;
    }

    pub fn queueScrollDetents(self: *PagedReader, detents: i16) void {
        self.scroll_position.queueDetents(detents);
    }

    pub fn scrollPreviousRescanTarget(self: *const PagedReader) ?u32 {
        if (self.scroll_rescan != null or self.scroll_previous_unavailable or self.scroll_position.top_page == 0) return null;
        const target = self.scroll_position.top_page - 1;
        return if (self.findDrawablePage(target) == null) target else null;
    }

    /// Resets only the decode-side builder for a Scroll reconstruction. The
    /// current viewport slots remain intact and pinned by the render window.
    pub fn beginScrollRescan(self: *PagedReader, width: usize, measure: pagination.Measure, target: u32) bool {
        if (self.scroll_rescan != null or target >= self.scroll_position.top_page) return false;
        if (self.findDrawablePage(target) != null) return false;
        switch (self.build) {
            .building => |slot| self.releaseSlot(slot),
            .ready => |slot| if (!self.scroll_pins[slot]) self.releaseSlot(slot),
            .idle => {},
        }
        if (self.next_ready and !self.scroll_pins[self.next_page]) self.releaseSlot(self.next_page);
        const slot = self.allocateSlot() orelse return false;
        self.pages[slot].clear();
        self.setSlot(slot, .building, self.chapter_index, 0);
        self.builder = pagination.EventPageBuilder.init(&self.pages[slot], width, measure);
        self.extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitEvent });
        self.build = .{ .building = slot };
        self.next_ready = false;
        self.reconstructing = true;
        self.scroll_rescan = .{ .target = target, .scanning = 0, .resume_page = self.page_index };
        self.scroll_previous_unavailable = false;
        return true;
    }

    pub fn markScrollPreviousUnavailable(self: *PagedReader) void {
        self.scroll_rescan = null;
        self.reconstructing = false;
        self.scroll_previous_unavailable = true;
        self.scroll_position.pending_detents = 0;
    }

    pub fn isScrollRescanning(self: *const PagedReader) bool {
        return self.scroll_rescan != null;
    }

    /// An unavailable neighbor consumes one detent into placeholder space. Keep later
    /// detents queued until it is ready.
    pub fn drainScrollForward(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        var drained: u8 = 0;
        while (self.scroll_position.pending_detents > 0 and drained < max_scroll_detents_per_update) {
            const already_waiting = self.scroll_position.waiting_px > 0;
            switch (self.scrollForwardDetent(geometry)) {
                .moved => {
                    self.scroll_position.pending_detents -= 1;
                    drained += 1;
                },
                .waiting => {
                    if (!already_waiting) {
                        self.scroll_position.pending_detents -= 1;
                        drained += 1;
                    }
                    return .waiting;
                },
                .at_end => {
                    self.scroll_position.pending_detents = 0;
                    return .at_end;
                },
                else => |outcome| return outcome,
            }
        }
        return .moved;
    }

    /// On a cache miss, keep visible text and request a predecessor rescan from the
    /// chapter beginning.
    pub fn drainScrollBackward(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        var drained: u8 = 0;
        while (self.scroll_position.pending_detents < 0 and drained < max_scroll_detents_per_update) {
            const already_waiting = self.scroll_position.waiting_px < 0;
            switch (self.scrollBackwardDetent(geometry)) {
                .moved => {
                    self.scroll_position.pending_detents += 1;
                    drained += 1;
                },
                .at_start => {
                    self.scroll_position.pending_detents = 0;
                    return .at_start;
                },
                .needs_reconstruction => {
                    if (!already_waiting) {
                        self.scroll_position.pending_detents += 1;
                        drained += 1;
                    }
                    return .needs_reconstruction;
                },
                else => |outcome| return outcome,
            }
        }
        return .moved;
    }

    /// Apply existing placeholder displacement when the predecessor becomes available.
    pub fn resumeScrollBackward(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        if (self.scroll_position.waiting_px >= 0) return .moved;
        return self.scrollBackwardDetent(geometry);
    }

    /// Bottom-align the verified ending. Missing history becomes placeholder space, not
    /// a guessed page.
    pub fn clampScrollAtChapterEnd(self: *PagedReader, geometry: scroll_geometry.Geometry) void {
        self.scroll_position = self.chapterEndPosition(geometry) orelse return;
    }

    fn chapterEndPosition(self: *const PagedReader, geometry: scroll_geometry.Geometry) ?scroll_geometry.Position {
        const last = self.chapter_last_page orelse return null;
        var reverse_tail: [page_capacity]scroll_geometry.PageExtent = undefined;
        var reverse_count: usize = 0;
        var page = last;
        while (true) {
            const slot = self.findDrawablePage(page) orelse break;
            const extent = pageExtent(geometry, &self.pages[slot]);
            if (extent == 0) break;
            reverse_tail[reverse_count] = .{ .index = page, .extent_px = extent };
            reverse_count += 1;
            if (page == 0 or reverse_count == reverse_tail.len) break;
            page -= 1;
        }
        if (reverse_count == 0) return null;

        var tail: [page_capacity]scroll_geometry.PageExtent = undefined;
        for (0..reverse_count) |index| tail[index] = reverse_tail[reverse_count - index - 1];
        const clamp = scroll_geometry.chapterEndClamp(geometry.viewport, tail[0..reverse_count]);
        var position = clamp.position;
        if (clamp.needs_previous_page) {
            var known_height: u16 = 0;
            for (tail[0..reverse_count]) |cached| known_height += cached.extent_px;
            position.waiting_px = -@as(i16, @intCast(geometry.viewport.height() - known_height));
        }
        return position;
    }

    fn scrollForwardDetent(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        return self.scrollForwardRequested(geometry, scroll_geometry.scroll_pixels_per_detent);
    }

    fn scrollBackwardDetent(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        return self.scrollBackwardRequested(geometry, scroll_geometry.scroll_pixels_per_detent);
    }

    fn scrollForwardRequested(self: *PagedReader, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        if (self.scroll_position.waiting_px > 0) {
            const waiting: u16 = @intCast(self.scroll_position.waiting_px);
            self.scroll_position.waiting_px = 0;
            switch (self.scrollForwardPixels(geometry, waiting)) {
                .moved => {},
                else => |outcome| return outcome,
            }
        }
        return self.scrollForwardPixels(geometry, pixels);
    }

    fn scrollBackwardRequested(self: *PagedReader, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        if (self.scroll_position.waiting_px < 0) {
            const waiting: u16 = @intCast(-@as(i32, self.scroll_position.waiting_px));
            self.scroll_position.waiting_px = 0;
            return self.scrollBackwardPixels(geometry, waiting);
        }
        return self.scrollBackwardPixels(geometry, pixels);
    }

    /// Cross only ready cached pages; the fixed pool bounds the loop.
    fn scrollForwardPixels(self: *PagedReader, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        const coverage = self.scrollCoverage(geometry);
        // Stop before missing text would enter the viewport. Waiting motion is
        // queued input, not displacement that replaces already drawable text.
        const permitted: u16 = if (coverage.at_end) pixels else @intCast(@min(pixels, coverage.pixels -| geometry.viewport.height()));
        var remaining = permitted;
        var crossings: usize = 0;
        while (remaining != 0 and crossings < page_capacity) {
            const current_slot = self.findDrawablePage(self.scroll_position.top_page) orelse return .waiting;
            const extent = pageExtent(geometry, &self.pages[current_slot]);
            if (extent == 0) return .waiting;
            const current_page = self.scroll_position.top_page;
            const next = self.scrollForwardNeighbor(geometry);
            const at_end = self.chapter_end and self.chapter_last_page != null and self.scroll_position.top_page == self.chapter_last_page.?;
            const result = scroll_geometry.move(
                &self.scroll_position,
                .forward,
                remaining,
                geometry.viewport,
                .{ .index = current_page, .extent_px = extent },
                next,
                at_end,
            );
            if (result.page_changed) {
                if (current_page == self.page_index and !self.promoteScrollReadyAhead()) return .waiting;
                crossings += 1;
            }
            if (self.chapter_end) if (self.chapterEndPosition(geometry)) |end_position| {
                if (scrollPositionAtOrBeyond(self.scroll_position, end_position)) {
                    self.scroll_position = end_position;
                    return .at_end;
                }
            };
            if (result.at_chapter_limit) {
                self.clampScrollAtChapterEnd(geometry);
                return .at_end;
            }
            if (result.waiting_for_neighbor) return .waiting;
            remaining = result.remaining_px;
        }
        if (remaining != 0) {
            // The pool is exhausted for this update. Retain bounded waiting motion
            // instead of scanning further.
            self.scroll_position.waiting_px = @intCast(@min(remaining, geometry.viewport.height()));
            return .waiting;
        }
        if (permitted < pixels) {
            self.scroll_position.waiting_px = @intCast(@min(pixels - permitted, geometry.viewport.height()));
            return .waiting;
        }
        return .moved;
    }

    const ScrollCoverage = struct { pixels: u32 = 0, at_end: bool = false };

    fn scrollCoverage(self: *const PagedReader, geometry: scroll_geometry.Geometry) ScrollCoverage {
        var result = ScrollCoverage{};
        var page = self.scroll_position.top_page;
        for (0..page_capacity) |_| {
            const slot = self.findDrawablePage(page) orelse break;
            const extent = pageExtent(geometry, &self.pages[slot]);
            if (extent == 0) break;
            result.pixels += extent;
            if (self.chapter_end and self.chapter_last_page != null and page == self.chapter_last_page.?) {
                result.at_end = true;
                break;
            }
            page += 1;
        }
        result.pixels -|= self.scroll_position.offset_px;
        return result;
    }

    fn scrollBackwardPixels(self: *PagedReader, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        var remaining = pixels;
        var crossings: usize = 0;
        while (remaining != 0 and crossings < page_capacity) {
            const current_page = self.scroll_position.top_page;
            const current_slot = self.findDrawablePage(current_page) orelse return .needs_reconstruction;
            const extent = pageExtent(geometry, &self.pages[current_slot]);
            if (extent == 0) return .needs_reconstruction;
            const previous = self.scrollBackwardNeighbor(geometry);
            const result = scroll_geometry.move(
                &self.scroll_position,
                .backward,
                remaining,
                geometry.viewport,
                .{ .index = current_page, .extent_px = extent },
                previous,
                current_page == 0,
            );
            if (result.at_chapter_limit) return .at_start;
            if (result.waiting_for_neighbor) return if (self.scroll_previous_unavailable) .at_start else .needs_reconstruction;
            remaining = result.remaining_px;
            if (result.page_changed) crossings += 1;
        }
        return if (remaining == 0) .moved else .needs_reconstruction;
    }

    fn scrollForwardNeighbor(self: *const PagedReader, geometry: scroll_geometry.Geometry) ?scroll_geometry.PageExtent {
        const next_page = self.scroll_position.top_page +| 1;
        const slot = self.findDrawablePage(next_page) orelse return null;
        const extent = pageExtent(geometry, &self.pages[slot]);
        if (extent == 0) return null;
        return .{ .index = next_page, .extent_px = extent };
    }

    fn scrollBackwardNeighbor(self: *const PagedReader, geometry: scroll_geometry.Geometry) ?scroll_geometry.PageExtent {
        if (self.scroll_position.top_page == 0) return null;
        const previous_page = self.scroll_position.top_page - 1;
        const slot = self.findDrawablePage(previous_page) orelse return null;
        const extent = pageExtent(geometry, &self.pages[slot]);
        if (extent == 0) return null;
        return .{ .index = previous_page, .extent_px = extent };
    }

    fn promoteScrollReadyAhead(self: *PagedReader) bool {
        return self.nextPage() == .moved;
    }

    pub fn builderPtr(self: *PagedReader) ?*pagination.EventPageBuilder {
        return if (self.builder) |*builder| builder else null;
    }

    /// Incomplete tokenizer and builder state survive feeds.
    pub fn feed(self: *PagedReader, input: []const u8) anyerror!xhtml.StreamExtractor.FeedResult {
        if (self.builder.?.page_full) return .{ .page_full = 0 };
        return self.extractor.?.feed(input);
    }

    pub fn finishInput(self: *PagedReader) anyerror!void {
        try self.extractor.?.finish();
    }

    pub fn wordCount(self: *const PagedReader) u32 {
        return if (self.builder) |builder| builder.wordCount() else 0;
    }

    /// Rebind prefetched tokenizer callbacks to the active builder.
    pub fn adoptExtractor(self: *PagedReader, extractor: xhtml.StreamExtractor) void {
        self.extractor = extractor;
        self.extractor.?.sink = .{ .context = self, .emit = emitEvent };
    }

    pub fn sourceOffset(self: *const PagedReader) u32 {
        return if (self.extractor) |extractor| extractor.source_offset else 0;
    }

    pub fn pageCompleted(self: *PagedReader, normalized_event: u32, decoded_offset: u32) void {
        if (self.scroll_rescan != null) {
            self.scrollRescanPageCompleted(normalized_event, decoded_offset);
            return;
        }
        const completed_page = switch (self.rescan) {
            .page => |state| state.scanning,
            .last_page => |state| state.scanning,
            .none => if (self.current_ready) self.page_index + 1 else self.page_index,
        };
        self.recordCheckpoint(completed_page, normalized_event, decoded_offset);

        switch (self.rescan) {
            .last_page => |*state| {
                state.last_completed = self.buildingPage();
                self.setSlot(state.last_completed, .history, self.chapter_index, state.scanning);
                state.scanning += 1;
                self.beginBuilding(self.freePage(), state.scanning);
            },
            .page => |*state| {
                if (state.scanning == state.target) {
                    self.setSlot(self.buildingPage(), .displayed, self.chapter_index, state.target);
                    self.current_ready = true;
                    self.current_page = self.buildingPage();
                    self.page_index = state.target;
                    self.navigation_state.beginRescan(state.target);
                    self.rescan = .none;
                    self.reconstructing = false;
                    self.beginBuilding(self.freePage(), state.target + 1);
                } else {
                    self.setSlot(self.buildingPage(), .history, self.chapter_index, state.scanning);
                    state.scanning += 1;
                    self.beginBuilding(self.freePage(), state.scanning);
                }
            },
            .none => if (!self.current_ready) {
                self.setSlot(self.current_page, .displayed, self.chapter_index, self.page_index);
                self.current_ready = true;
                self.beginBuilding(self.next_page, self.page_index + 1);
            } else {
                self.setSlot(self.next_page, .ready_ahead, self.chapter_index, self.page_index + 1);
                self.next_ready = true;
                self.build = .{ .ready = self.next_page };
            },
        }
    }

    /// Finalize EOF after the caller has asked the builder to flush its line.
    pub fn finishChapter(self: *PagedReader) Move {
        self.chapter_end = true;
        if (self.scroll_rescan != null) {
            if (self.pages[self.buildingPage()].line_count != 0) self.scrollRescanPageCompleted(0, 0);
            if (self.build == .building) self.releaseSlot(self.buildingPage());
            self.scroll_rescan = null;
            self.reconstructing = false;
            self.build = .idle;
            return .moved;
        }
        switch (self.rescan) {
            .last_page => |state| {
                if (self.pages[self.buildingPage()].line_count != 0) {
                    self.current_page = self.buildingPage();
                    self.page_index = state.scanning;
                } else if (state.scanning != 0) {
                    self.releaseSlot(self.buildingPage());
                    self.current_page = state.last_completed;
                    self.page_index = state.scanning - 1;
                } else return .at_limit;
                self.setSlot(self.current_page, .displayed, self.chapter_index, self.page_index);
                self.current_ready = true;
                self.navigation_state.beginRescan(self.page_index);
                self.rescan = .none;
                self.reconstructing = false;
                self.chapter_last_page = self.page_index;
                self.build = .idle;
                self.trimHistory(8);
            },
            .page => |state| {
                const completed = self.buildingPage();
                if (state.scanning != state.target or self.pages[completed].line_count == 0) return .at_limit;
                self.current_page = completed;
                self.setSlot(self.current_page, .displayed, self.chapter_index, state.target);
                self.current_ready = true;
                self.page_index = state.target;
                self.navigation_state.beginRescan(state.target);
                self.rescan = .none;
                self.reconstructing = false;
                self.chapter_last_page = state.target;
                self.build = .idle;
                self.trimHistory(8);
            },
            .none => {
                if (!self.current_ready and self.pages[self.current_page].line_count != 0) {
                    self.current_ready = true;
                    self.setSlot(self.current_page, .displayed, self.chapter_index, self.page_index);
                    self.build = .idle;
                } else if (self.pages[self.next_page].line_count != 0) {
                    self.next_ready = true;
                    self.setSlot(self.next_page, .ready_ahead, self.chapter_index, self.page_index + 1);
                    self.build = .{ .ready = self.next_page };
                } else if (self.slots[self.next_page].role == .building) {
                    self.releaseSlot(self.next_page);
                    self.build = .idle;
                }
                self.chapter_last_page = self.page_index + (if (self.next_ready) @as(u32, 1) else 0);
            },
        }
        return .moved;
    }

    fn scrollRescanPageCompleted(self: *PagedReader, normalized_event: u32, decoded_offset: u32) void {
        const state = &self.scroll_rescan.?;
        const completed_page = state.scanning;
        const completed_slot = self.buildingPage();
        self.recordCheckpoint(completed_page, normalized_event, decoded_offset);
        // Keep visible cached text; retain only the missing predecessor from the
        // rescan.
        if (self.findDrawablePage(completed_page) == null) {
            self.setSlot(completed_slot, .history, self.chapter_index, completed_page);
            // Pin the requested predecessor through the next builder allocation. A full
            // pool could otherwise evict it before waiting motion makes it visible.
            if (completed_page == state.target) self.scroll_pins[completed_slot] = true;
        } else self.releaseSlot(completed_slot);

        state.scanning += 1;
        if (state.scanning > state.resume_page) {
            const next = self.freePage();
            self.beginBuilding(next, state.scanning);
            self.scroll_rescan = null;
            self.reconstructing = false;
            return;
        }
        self.beginBuilding(self.freePage(), state.scanning);
    }

    pub fn isRescanning(self: *const PagedReader) bool {
        return self.rescan != .none;
    }

    pub fn isReconstructing(self: *const PagedReader) bool {
        return self.reconstructing;
    }

    pub fn nextPage(self: *PagedReader) Move {
        if (self.navigation_state.viewing_cached_history) {
            const target = self.navigation_state.forwardFromCache() orelse return .waiting;
            return if (self.showCachedPage(target)) .moved else .needs_reconstruction;
        }
        if (self.chapter_end) {
            const target = self.page_index + 1;
            if (self.chapter_last_page) |last| {
                if (target > last) return .needs_next_chapter;
                // EOF may leave the final page ready in the next slot; enter it as a
                // normal forward move.
                if (!self.next_ready) return if (self.showCachedPage(target)) .moved else .needs_reconstruction;
            } else return .waiting;
        }
        if (!self.next_ready) return .waiting;
        const old_current = self.current_page;
        const old_next = self.next_page;
        self.setSlot(old_current, .history, self.chapter_index, self.page_index);
        self.current_page = old_next;
        self.setSlot(old_next, .displayed, self.chapter_index, self.page_index + 1);
        self.current_ready = true;
        self.next_ready = false;
        self.page_index += 1;
        self.navigation_state.advancedStream();
        // At verified EOF, do not allocate another builder; prefetch may need that
        // slot.
        if (self.chapter_end) {
            self.build = .idle;
            self.trimHistory(8);
            return .moved;
        }
        self.beginBuilding(self.freePage(), self.page_index + 1);
        return .moved;
    }

    pub fn previousPage(self: *PagedReader) Move {
        if (self.rescan != .none) return .waiting;
        if (self.page_index == 0) return .needs_previous_chapter;
        const target = self.navigation_state.beginCachedBack() orelse return .at_limit;
        return if (self.showCachedPage(target)) .moved else .needs_reconstruction;
    }

    pub fn moveSelection(self: *PagedReader, direction: i8, has_previous_chapter: bool, has_next_chapter: bool) Move {
        const page = self.current() orelse return .waiting;
        const selected = page.moveSelection(self.selected_word_ordinal, 0) orelse return .at_limit;
        if (direction > 0 and selected - page.first_word_ordinal + 1 == page.word_count) {
            if (self.chapter_end and !self.next_ready and self.chapter_last_page != null and self.page_index == self.chapter_last_page.?) {
                if (!has_next_chapter) return .at_limit;
                self.pending_selection = .{ .ordinal = 0 };
                return .needs_next_chapter;
            }
            self.pending_selection = .{ .ordinal = selected + 1 };
            return self.nextPage();
        }
        if (direction < 0 and selected == page.first_word_ordinal) {
            if (self.page_index == 0 or selected == 0) {
                if (!has_previous_chapter) return .at_limit;
                self.pending_selection = .last_word;
                return .needs_previous_chapter;
            }
            self.pending_selection = .{ .ordinal = selected - 1 };
            return self.previousPage();
        }
        self.selected_word_ordinal = page.moveSelection(selected, direction);
        return .moved;
    }

    pub fn fulfillPendingSelection(self: *PagedReader) bool {
        const target = self.pending_selection orelse return false;
        // At most the resident cache can be crossed per update; no recursion.
        for (0..self.slots.len) |_| {
            const page = self.current() orelse return false;
            switch (target) {
                .ordinal => |ordinal| {
                    if (page.wordSpan(ordinal) != null) {
                        self.selected_word_ordinal = ordinal;
                        self.pending_selection = null;
                        self.reconstructing = false;
                        return true;
                    }
                    if (ordinal < page.first_word_ordinal and self.page_index != 0) {
                        if (self.previousPage() == .moved) continue;
                        return false;
                    }
                    if ((self.navigation_state.viewing_cached_history and self.findCachedPage(self.page_index + 1) != null) or
                        (self.next_ready and (self.pages[self.next_page].wordSpan(ordinal) != null or self.pages[self.next_page].word_count == 0 or ordinal >= self.pages[self.next_page].first_word_ordinal)))
                    {
                        if (self.nextPage() == .moved) continue;
                        return false;
                    }
                },
                .last_word => if (self.chapter_end and page.word_count != 0) {
                    self.selected_word_ordinal = page.first_word_ordinal + page.word_count - 1;
                    self.pending_selection = null;
                    self.reconstructing = false;
                    return true;
                },
            }
            // An edited book can invalidate a saved ordinal. Clamp to the last word at
            // verified EOF so restoration completes.
            if (self.reconstructing and self.chapter_end and page.word_count != 0) {
                self.selected_word_ordinal = page.first_word_ordinal + page.word_count - 1;
                self.pending_selection = null;
                self.reconstructing = false;
                return true;
            }
            return false;
        }
        return false;
    }

    pub fn queueDetents(self: *PagedReader, detents: i16) void {
        const sum: i32 = @as(i32, self.detent_backlog) + detents;
        self.detent_backlog = @intCast(std.math.clamp(sum, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    /// Coalesce motion until a page/chapter needs construction; keep only the remaining
    /// movement queued.
    pub fn drainDetents(self: *PagedReader, has_previous_chapter: bool, has_next_chapter: bool) Move {
        while (self.detent_backlog != 0) {
            if (self.pending_selection != null) return .waiting;
            const direction: i8 = if (self.detent_backlog > 0) 1 else -1;
            switch (self.moveSelection(direction, has_previous_chapter, has_next_chapter)) {
                .moved => {
                    self.detent_backlog -= direction;
                    _ = self.fulfillPendingSelection();
                },
                .at_limit => {
                    self.detent_backlog = 0;
                    return .at_limit;
                },
                else => |outcome| return outcome,
            }
        }
        return .moved;
    }

    fn beginBuilding(self: *PagedReader, slot: SlotIndex, page: u32) void {
        std.debug.assert(self.slots[slot].role == .free or self.slots[slot].role == .building or self.slots[slot].role == .history);
        self.next_page = slot;
        self.setSlot(slot, .building, self.chapter_index, page);
        self.builder.?.beginNextPage(&self.pages[slot]);
        self.build = .{ .building = slot };
    }

    pub fn buildingPage(self: *const PagedReader) SlotIndex {
        return switch (self.build) {
            .building => |slot| slot,
            .ready => |slot| slot,
            .idle => self.current_page,
        };
    }

    pub fn freePage(self: *PagedReader) SlotIndex {
        return self.allocateSlot() orelse unreachable;
    }

    fn showCachedPage(self: *PagedReader, target: u32) bool {
        const target_slot = self.findCachedPage(target) orelse return false;
        const old_current = self.current_page;
        const old_page = self.page_index;
        self.current_page = target_slot;
        self.setSlot(self.current_page, .displayed, self.chapter_index, target);
        self.setSlot(old_current, if (old_page == self.navigation_state.stream_front) .stream_front else .history, self.chapter_index, old_page);
        self.page_index = target;
        self.navigation_state.page = target;
        self.current_ready = true;
        return true;
    }

    fn findCachedPage(self: *const PagedReader, page: u32) ?SlotIndex {
        for (self.slots, 0..) |state, index| {
            if (state.chapter != self.chapter_index or state.page != page) continue;
            switch (state.role) {
                .displayed, .stream_front, .history => return @intCast(index),
                .free, .building, .ready_ahead, .prefetch => {},
            }
        }
        return null;
    }

    fn findDrawablePage(self: *const PagedReader, page: u32) ?SlotIndex {
        for (self.slots, 0..) |state, index| {
            if (state.chapter != self.chapter_index or state.page != page) continue;
            switch (state.role) {
                .displayed, .stream_front, .history, .ready_ahead => return @intCast(index),
                .free, .building, .prefetch => {},
            }
        }
        return null;
    }

    pub fn reservePrefetchPage(self: *PagedReader, chapter: u8) ?PrefetchPage {
        if (self.prefetch_page != null) return null;
        const slot = self.allocateSlot() orelse return null;
        self.setSlot(slot, .prefetch, chapter, 0);
        self.pages[slot].clear();
        self.prefetch_page = slot;
        return .{ .slot = slot, .page = &self.pages[slot] };
    }

    pub fn releasePrefetchPage(self: *PagedReader) void {
        const slot = self.prefetch_page orelse return;
        if (self.slots[slot].role == .prefetch) self.releaseSlot(slot);
        self.prefetch_page = null;
    }

    pub fn activatePrefetchedPage(self: *PagedReader, slot: SlotIndex, chapter: u8, ended: bool) void {
        std.debug.assert(self.prefetch_page == slot);
        std.debug.assert(self.slots[slot].role == .prefetch);
        for (&self.slots, 0..) |*state, index| {
            if (index != slot) state.* = .{};
        }
        self.clearScrollPins();
        self.prefetch_page = null;
        self.chapter_index = chapter;
        self.page_index = 0;
        self.scroll_position = .{};
        self.scroll_rescan = null;
        self.scroll_previous_unavailable = false;
        self.current_page = slot;
        self.setSlot(slot, .displayed, chapter, 0);
        self.current_ready = true;
        self.selected_word_ordinal = null;
        self.next_ready = false;
        self.chapter_end = ended;
        self.chapter_last_page = if (ended) 0 else null;
        self.navigation_state.opened(0);
        if (ended) {
            self.build = .idle;
        } else {
            self.next_page = self.freePage();
            self.beginBuilding(self.next_page, 1);
        }
    }

    fn allocateSlot(self: *PagedReader) ?SlotIndex {
        for (self.slots, 0..) |state, index| {
            if (state.role == .free) return @intCast(index);
        }
        var oldest: ?SlotIndex = null;
        for (self.slots, 0..) |state, index| {
            if (state.role != .history or self.scroll_pins[index]) continue;
            if (oldest == null or state.page < self.slots[oldest.?].page) oldest = @intCast(index);
        }
        if (oldest) |slot| {
            self.releaseSlot(slot);
        }
        return oldest;
    }

    fn trimHistory(self: *PagedReader, maximum: usize) void {
        while (true) {
            var count: usize = 0;
            var oldest: ?SlotIndex = null;
            for (self.slots, 0..) |state, index| {
                if (state.role != .history) continue;
                count += 1;
                if (self.scroll_pins[index]) continue;
                if (oldest == null or state.page < self.slots[oldest.?].page) oldest = @intCast(index);
            }
            if (count <= maximum or oldest == null) return;
            self.releaseSlot(oldest.?);
        }
    }

    fn setSlot(self: *PagedReader, slot: SlotIndex, role: SlotRole, chapter: u8, page: u32) void {
        self.slots[slot] = .{ .role = role, .chapter = chapter, .page = page };
    }

    fn releaseSlot(self: *PagedReader, slot: SlotIndex) void {
        self.slots[slot] = .{};
        self.scroll_pins[slot] = false;
    }

    fn clearScrollPins(self: *PagedReader) void {
        @memset(&self.scroll_pins, false);
    }

    fn appendScrollPage(self: *PagedReader, result: *ScrollRenderState, slot: SlotIndex, origin_y: i16) void {
        self.scroll_pins[slot] = true;
        self.appendScrollTile(result, .{ .page = .{ .cache = &self.pages[slot], .origin_y = origin_y } });
    }

    fn appendScrollTile(_: *PagedReader, result: *ScrollRenderState, tile: ScrollTile) void {
        if (result.tile_count == result.tiles.len) return;
        result.tiles[result.tile_count] = tile;
        result.tile_count += 1;
    }

    fn pageExtent(geometry: scroll_geometry.Geometry, page: *const pagination.PageCache) u16 {
        return geometry.pageExtent(page.line_count);
    }

    fn scrollTopOrigin(top_y: u16, offset_px: u16, waiting_before: u16) i16 {
        return clampScrollOrigin(@as(i32, top_y) - @as(i32, offset_px) + @as(i32, waiting_before));
    }

    fn advanceScrollOrigin(origin_y: i16, extent_px: u16) i16 {
        return clampScrollOrigin(@as(i32, origin_y) + @as(i32, extent_px));
    }

    fn clampScrollOrigin(value: i32) i16 {
        return @intCast(std.math.clamp(value, @as(i32, std.math.minInt(i16)), @as(i32, std.math.maxInt(i16))));
    }

    fn scrollPositionAtOrBeyond(position: scroll_geometry.Position, limit: scroll_geometry.Position) bool {
        return position.top_page > limit.top_page or (position.top_page == limit.top_page and position.offset_px >= limit.offset_px);
    }

    /// Checkpoints track cache accounting, not compressed stream positions.
    pub fn recordCheckpoint(self: *PagedReader, page: u32, normalized_event: u32, decoded_offset: u32) void {
        _ = self.checkpoints.admit(self.chapter_index, page, normalized_event, decoded_offset, @sizeOf(cache_policy.Entry));
    }

    fn emitEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
        const self: *PagedReader = @ptrCast(@alignCast(context));
        try self.builderPtr().?.consume(event);
    }
};

fn makePage(first: u32, count: u32) pagination.PageCache {
    var result = pagination.PageCache{};
    result.line_count = 1;
    result.first_word_ordinal = first;
    result.word_count = count;
    result.line_word_counts[0] = @intCast(count);
    for (0..count) |index| {
        result.lines[0][index * 2] = 'w';
        if (index + 1 < count) result.lines[0][index * 2 + 1] = ' ';
    }
    result.lengths[0] = @intCast(count * 2 - 1);
    return result;
}

test "scroll window borrows ordered cached pages and pins their slots" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 2;
    reader.pages[0].line_count = 11;
    reader.pages[1].line_count = 11;
    reader.setSlot(0, .displayed, 2, 4);
    reader.setSlot(1, .history, 2, 5);

    const window = reader.scrollRenderState(.{ .top_page = 4, .offset_px = 10 }, scroll_geometry.Geometry.init(20));
    try std.testing.expectEqual(@as(u2, 2), window.tile_count);
    switch (window.tiles[0]) {
        .page => |tile| {
            try std.testing.expect(tile.cache == &reader.pages[0]);
            try std.testing.expectEqual(@as(i16, -6), tile.origin_y);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (window.tiles[1]) {
        .page => |tile| {
            try std.testing.expect(tile.cache == &reader.pages[1]);
            try std.testing.expectEqual(@as(i16, 225), tile.origin_y);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(reader.scroll_pins[0]);
    try std.testing.expect(reader.scroll_pins[1]);
    try std.testing.expectEqual(@as(usize, PagedReader.page_capacity * @sizeOf(pagination.PageCache)), PagedReader.page_pool_reserved_bytes);
}

test "scroll window describes missing sides without copying or constructing text" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.pages[0].line_count = 1;
    reader.setSlot(0, .displayed, 0, 0);
    const build_before = reader.build;

    const after = reader.scrollRenderState(.{}, scroll_geometry.Geometry.init(20));
    try std.testing.expectEqual(@as(u2, 2), after.tile_count);
    switch (after.tiles[0]) {
        .page => |tile| try std.testing.expect(tile.cache == &reader.pages[0]),
        else => return error.TestUnexpectedResult,
    }
    switch (after.tiles[1]) {
        .loading_after => |origin_y| try std.testing.expectEqual(@as(i16, 25), origin_y),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.meta.eql(build_before, reader.build));

    reader.slots[0].page = 1;
    reader.chapter_end = true;
    reader.chapter_last_page = 1;
    const before = reader.scrollRenderState(.{ .top_page = 1, .waiting_px = -12 }, scroll_geometry.Geometry.init(20));
    try std.testing.expectEqual(@as(u2, 2), before.tile_count);
    switch (before.tiles[0]) {
        .loading_before => |origin_y| try std.testing.expectEqual(@as(i16, 4), origin_y),
        else => return error.TestUnexpectedResult,
    }
    switch (before.tiles[1]) {
        .page => |tile| try std.testing.expectEqual(@as(i16, 16), tile.origin_y),
        else => return error.TestUnexpectedResult,
    }
}

test "pinned history slots are excluded from page-pool eviction" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    for (&reader.slots, 0..) |*slot, index| slot.* = .{ .role = .history, .page = @intCast(index) };
    reader.scroll_pins[0] = true;

    const allocated = reader.allocateSlot().?;
    try std.testing.expectEqual(@as(PagedReader.SlotIndex, 1), allocated);
    try std.testing.expectEqual(PagedReader.SlotRole.history, reader.slots[0].role);
    try std.testing.expectEqual(PagedReader.SlotRole.free, reader.slots[allocated].role);
}

test "Scroll holds at the cached viewport boundary without dropping the ready next page" {
    var reader = PagedReader.init(128);
    var context: u8 = 0;
    const Measure = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    };
    reader.begin(0, 384, .{ .context = &context, .width = Measure.width });
    reader.pages[0].line_count = 11;
    reader.pageCompleted(0, 0);
    reader.pages[reader.next_page].line_count = 11;
    reader.pageCompleted(0, 0);
    reader.beginScroll();
    const geometry = scroll_geometry.Geometry.init(20);
    try std.testing.expectEqual(PagedReader.ScrollMove.waiting, reader.scrollPixels(.forward, geometry, 400));
    try std.testing.expectEqual(@as(u32, 0), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 230), reader.scrollPosition().offset_px);
    const view = reader.scrollRenderState(reader.scrollPosition(), geometry);
    try std.testing.expect(view.tiles[1] == .page);
    try std.testing.expectEqual(@as(i16, 5), view.tiles[1].page.origin_y);
    try std.testing.expectEqual(@as(i16, 236), view.tiles[2].loading_after);
}

test "forward Scroll consumes ready-ahead pages and resumes the existing builder" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pages[0].line_count = 11;
    reader.pageCompleted(0, 0);
    reader.pages[reader.next_page] = makePage(1, 1);
    reader.pages[reader.next_page].line_count = 11;
    reader.pageCompleted(0, 0);
    reader.beginScroll();
    reader.scroll_position.offset_px = 225;
    reader.queueScrollDetents(1);

    try std.testing.expectEqual(PagedReader.ScrollMove.moved, reader.drainScrollForward(scroll_geometry.Geometry.init(20)));
    try std.testing.expectEqual(@as(u32, 1), reader.page_index);
    try std.testing.expectEqual(@as(u32, 1), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 6), reader.scrollPosition().offset_px);
    try std.testing.expectEqual(PagedReader.SlotRole.history, reader.slots[reader.findCachedPage(0).?].role);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.next_page].role);
}

test "fast forward Scroll input waits once then drains a bounded backlog" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pages[0].line_count = 11;
    reader.pageCompleted(0, 0);
    reader.beginScroll();
    reader.scroll_position.offset_px = 225;
    reader.queueScrollDetents(100);

    try std.testing.expectEqual(PagedReader.ScrollMove.waiting, reader.drainScrollForward(scroll_geometry.Geometry.init(20)));
    try std.testing.expectEqual(@as(i16, 6), reader.scrollPosition().waiting_px);
    try std.testing.expectEqual(@as(i16, 63), reader.scrollPosition().pending_detents);

    reader.pages[reader.next_page] = makePage(1, 1);
    reader.pages[reader.next_page].line_count = 11;
    reader.pageCompleted(0, 0);
    try std.testing.expectEqual(PagedReader.ScrollMove.moved, reader.drainScrollForward(scroll_geometry.Geometry.init(20)));
    try std.testing.expectEqual(@as(u32, 1), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(i16, 55), reader.scrollPosition().pending_detents);
    try std.testing.expectEqual(@as(u16, 102), reader.scrollPosition().offset_px);
}

test "Scroll EOF bottom clamp uses cached history or loading-before space" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.pages[0].line_count = 11;
    reader.pages[1].line_count = 3;
    reader.setSlot(0, .history, 0, 0);
    reader.setSlot(1, .displayed, 0, 1);
    reader.current_page = 1;
    reader.page_index = 1;
    reader.chapter_end = true;
    reader.chapter_last_page = 1;
    reader.scroll_position = .{ .top_page = 1 };

    reader.clampScrollAtChapterEnd(geometry);
    try std.testing.expectEqual(@as(u32, 0), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 62), reader.scrollPosition().offset_px);
    try std.testing.expectEqual(@as(i16, 0), reader.scrollPosition().waiting_px);

    reader.slots[0] = .{};
    reader.scroll_position = .{ .top_page = 1 };
    reader.clampScrollAtChapterEnd(geometry);
    try std.testing.expectEqual(@as(u32, 1), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(i16, -169), reader.scrollPosition().waiting_px);
    const window = reader.scrollRenderState(reader.scrollPosition(), geometry);
    switch (window.tiles[0]) {
        .loading_before => |origin_y| try std.testing.expectEqual(@as(i16, 4), origin_y),
        else => return error.TestUnexpectedResult,
    }
    switch (window.tiles[1]) {
        .page => |tile| try std.testing.expectEqual(@as(i16, 173), tile.origin_y),
        else => return error.TestUnexpectedResult,
    }
}

test "Scroll stops at the bottom alignment before a partial final page exposes blank space" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.pages[0].line_count = 11;
    reader.pages[1].line_count = 3;
    reader.setSlot(0, .displayed, 0, 0);
    reader.setSlot(1, .history, 0, 1);
    reader.current_page = 0;
    reader.page_index = 0;
    reader.current_ready = true;
    reader.chapter_end = true;
    reader.chapter_last_page = 1;
    reader.scroll_position = .{ .top_page = 0, .offset_px = 50 };

    try std.testing.expectEqual(PagedReader.ScrollMove.at_end, reader.scrollPixels(.forward, geometry, 20));
    try std.testing.expectEqual(@as(u32, 0), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 62), reader.scrollPosition().offset_px);
}

test "Scroll presentation transfer uses the first visible normalized word" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.current_page = 0;
    reader.page_index = 4;
    reader.current_ready = true;
    reader.pages[0].first_word_ordinal = 20;
    reader.pages[0].word_count = 3;
    try reader.pages[0].appendLineWithMetadata("one", 0, 1);
    try reader.pages[0].appendLineWithMetadata("two", 0, 1);
    try reader.pages[0].appendLineWithMetadata("three", 0, 1);
    reader.setSlot(0, .displayed, 0, 4);

    reader.beginScrollAtWord(21, geometry);
    try std.testing.expectEqual(@as(u32, 4), reader.scrollPosition().top_page);
    try std.testing.expectEqual(geometry.line_advance, reader.scrollPosition().offset_px);
    try std.testing.expectEqual(@as(?u32, 21), reader.scrollFirstVisibleWord(geometry));
    try std.testing.expect(reader.showScrollTopPage());
    try std.testing.expectEqual(@as(u32, 4), reader.page_index);
}

test "Scroll backward reconstruction preserves the viewport and reconnects the builder" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.page_index = 5;
    reader.current_page = 0;
    reader.current_ready = true;
    reader.pages[0].line_count = 11;
    reader.pages[1].line_count = 11;
    reader.setSlot(0, .displayed, 0, 5);
    reader.setSlot(1, .ready_ahead, 0, 6);
    reader.next_page = 1;
    reader.next_ready = true;
    reader.beginScroll();

    reader.queueScrollDetents(-1);
    try std.testing.expectEqual(PagedReader.ScrollMove.needs_reconstruction, reader.drainScrollBackward(geometry));
    try std.testing.expectEqual(@as(i16, -12), reader.scrollPosition().waiting_px);
    const visible = &reader.pages[0];
    const loading = reader.scrollRenderState(reader.scrollPosition(), geometry);
    switch (loading.tiles[0]) {
        .loading_before => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(reader.scroll_pins[0]);

    try std.testing.expectEqual(@as(?u32, 4), reader.scrollPreviousRescanTarget());
    try std.testing.expect(reader.beginScrollRescan(10, .{ .context = &reader, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width }, 4));
    try std.testing.expect(reader.isScrollRescanning());
    try std.testing.expect(reader.pages[0].line_count == 11);
    try std.testing.expect(visible == &reader.pages[0]);

    for (0..5) |_| {
        reader.pages[reader.buildingPage()].line_count = 11;
        reader.pageCompleted(0, 0);
    }
    try std.testing.expect(reader.findDrawablePage(4) != null);
    try std.testing.expect(reader.isScrollRescanning());
    try std.testing.expectEqual(PagedReader.ScrollMove.moved, reader.resumeScrollBackward(geometry));
    try std.testing.expectEqual(@as(u32, 4), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 219), reader.scrollPosition().offset_px);
    try std.testing.expect(visible == &reader.pages[0]);

    reader.pages[reader.buildingPage()].line_count = 11;
    reader.pageCompleted(0, 0);
    try std.testing.expect(!reader.isScrollRescanning());
    try std.testing.expectEqual(@as(u32, 5), reader.page_index);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.next_page].role);
}

test "Scroll reconstruction retains page zero through a full-pool builder allocation" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.page_index = 5;
    reader.current_page = 4;
    reader.current_ready = true;
    for (0..PagedReader.page_capacity) |index| {
        reader.pages[index].line_count = 11;
        reader.setSlot(@intCast(index), .history, 0, @intCast(index + 1));
    }
    reader.setSlot(4, .displayed, 0, 5);
    reader.scroll_position = .{ .top_page = 1, .waiting_px = -12 };
    _ = reader.scrollRenderState(reader.scrollPosition(), geometry);

    try std.testing.expect(reader.beginScrollRescan(10, .{ .context = &reader, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width }, 0));
    reader.pages[reader.buildingPage()].line_count = 11;
    reader.pageCompleted(0, 0);

    const page_zero = reader.findDrawablePage(0) orelse return error.TestExpectedEqual;
    try std.testing.expect(reader.scroll_pins[page_zero]);
    try std.testing.expectEqual(PagedReader.ScrollMove.moved, reader.resumeScrollBackward(geometry));
    try std.testing.expectEqual(@as(u32, 0), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 219), reader.scrollPosition().offset_px);
}

test "Scroll reconstruction failure changes only loading-before to unavailable" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.page_index = 1;
    reader.current_page = 0;
    reader.current_ready = true;
    reader.pages[0].line_count = 11;
    reader.setSlot(0, .displayed, 0, 1);
    reader.beginScroll();
    reader.queueScrollDetents(-1);
    try std.testing.expectEqual(PagedReader.ScrollMove.needs_reconstruction, reader.drainScrollBackward(geometry));
    try std.testing.expect(reader.beginScrollRescan(10, .{ .context = &reader, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width }, 0));

    reader.markScrollPreviousUnavailable();
    const window = reader.scrollRenderState(reader.scrollPosition(), geometry);
    switch (window.tiles[0]) {
        .unavailable_before => {},
        else => return error.TestUnexpectedResult,
    }
    switch (window.tiles[1]) {
        .page => |tile| try std.testing.expect(tile.cache == &reader.pages[0]),
        else => return error.TestUnexpectedResult,
    }
}

test "paged reader assigns explicit roles while preserving cached navigation" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    try std.testing.expectEqual(@as(usize, 10), PagedReader.page_capacity);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.current_page].role);
    reader.pages[0] = makePage(0, 3);
    reader.pageCompleted(0, 0);
    try std.testing.expectEqual(PagedReader.SlotRole.displayed, reader.slots[reader.current_page].role);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.next_page].role);
    reader.pages[reader.next_page] = makePage(3, 3);
    reader.pageCompleted(0, 0);
    try std.testing.expectEqual(PagedReader.SlotRole.ready_ahead, reader.slots[reader.next_page].role);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqual(@as(usize, PagedReader.page_capacity), reader.pages.len);
    try std.testing.expectEqual(PagedReader.SlotRole.history, reader.slots[reader.findCachedPage(0).?].role);
    try std.testing.expectEqual(PagedReader.SlotRole.displayed, reader.slots[reader.current_page].role);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.next_page].role);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 0), reader.page_index);
    try std.testing.expectEqual(PagedReader.SlotRole.displayed, reader.slots[reader.current_page].role);
    try std.testing.expectEqual(PagedReader.SlotRole.stream_front, reader.slots[reader.findCachedPage(1).?].role);
}

test "eight cached pages navigate backward and forward around a parked builder" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pageCompleted(0, 0);
    for (1..10) |page| {
        reader.pages[reader.next_page] = makePage(@intCast(page), 1);
        reader.pageCompleted(0, 0);
        try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    }
    const parked_builder = reader.buildingPage();
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 1), reader.page_index);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[parked_builder].role);
    reader.selected_word_ordinal = 1;
    try std.testing.expectEqual(PagedReader.Move.moved, reader.moveSelection(1, false, false));
    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(u32, 2), reader.page_index);
    try std.testing.expectEqual(@as(?u32, 2), reader.selected_word_ordinal);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqual(@as(u32, 9), reader.page_index);
    try std.testing.expect(!reader.navigation_state.viewing_cached_history);
    try std.testing.expectEqual(parked_builder, reader.buildingPage());
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(PagedReader.Move.needs_reconstruction, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 0), reader.navigation_state.page);
}

test "EOF advances from the second-to-last page into a prepared final page" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pages[1] = makePage(1, 1);
    reader.pages[2] = makePage(99, 1);
    reader.current_ready = true;
    reader.next_ready = true;
    reader.page_index = 3;
    reader.chapter_end = true;
    reader.chapter_last_page = 4;
    reader.navigation_state.page = 3;

    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqual(@as(u32, 4), reader.page_index);
    try std.testing.expectEqual(@as(PagedReader.SlotIndex, 1), reader.current_page);
    try std.testing.expectEqual(@as(u8, 1), reader.pages[2].line_count);
    try std.testing.expectEqual(PagedReader.BuildState.idle, reader.build);
    try std.testing.expectEqual(PagedReader.Move.needs_next_chapter, reader.nextPage());
}

test "pending selection waits for a page then follows it without a word queue" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.current_ready = true;
    reader.pages[0] = makePage(10, 2);
    reader.current_page = 0;
    reader.next_page = 1;
    reader.selected_word_ordinal = 11;
    try std.testing.expectEqual(PagedReader.Move.waiting, reader.moveSelection(1, false, false));
    try std.testing.expect(reader.pending_selection != null);
    try std.testing.expect(!reader.isReconstructing());
    reader.pages[1] = makePage(12, 2);
    reader.next_ready = true;
    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(?u32, 12), reader.selected_word_ordinal);
}

test "chapter-boundary selection reports semantic transition requests" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.current_ready = true;
    reader.chapter_end = true;
    reader.chapter_last_page = 0;
    reader.pages[0] = makePage(0, 1);
    try std.testing.expectEqual(PagedReader.Move.needs_next_chapter, reader.moveSelection(1, false, true));
    try std.testing.expectEqual(PagedReader.Move.at_limit, reader.moveSelection(1, false, false));
    reader.pending_selection = null;
    try std.testing.expectEqual(PagedReader.Move.at_limit, reader.moveSelection(-1, false, false));
    try std.testing.expectEqual(PagedReader.Move.needs_previous_chapter, reader.moveSelection(-1, true, false));
}

test "a cache miss requests reconstruction rather than a compressed seek" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.current_ready = true;
    reader.page_index = 4;
    reader.navigation_state.opened(4);
    try std.testing.expectEqual(PagedReader.Move.needs_reconstruction, reader.previousPage());
    reader.beginRescan(3);
    try std.testing.expect(reader.isReconstructing());
    try std.testing.expectEqual(@as(u32, 3), reader.rescan.page.target);
    try std.testing.expectEqual(@as(u32, 0), reader.rescan.page.scanning);
}

test "fast detents coalesce to the final word without retaining a backlog" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.current_ready = true;
    reader.pages[0] = makePage(0, 5);
    reader.queueDetents(4);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.drainDetents(false, false));
    try std.testing.expectEqual(@as(?u32, 4), reader.selected_word_ordinal);
    try std.testing.expectEqual(@as(i16, 0), reader.detent_backlog);
}

test "render state exposes only drawable page data and semantic selection" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    try std.testing.expect(reader.renderState().page == null);
    reader.current_ready = true;
    reader.pages[0] = makePage(7, 1);
    reader.selected_word_ordinal = 7;
    const render = reader.renderState();
    try std.testing.expect(render.page != null);
    try std.testing.expectEqual(@as(?u32, 7), render.selected_word_ordinal);
    try std.testing.expect(!render.waiting_for_page);

    reader.beginWordRescan(7);
    const restoring = reader.renderState();
    try std.testing.expect(restoring.page == null);
    try std.testing.expect(restoring.reconstructing);
}

test "word restoration clamps a stale ordinal at verified chapter end" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.current_ready = true;
    reader.chapter_end = true;
    reader.pages[0] = makePage(10, 2);
    reader.beginWordRescan(99);

    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(?u32, 11), reader.selected_word_ordinal);
    try std.testing.expect(!reader.isReconstructing());
    try std.testing.expect(reader.renderState().page != null);
}

test "bounded decoded input stays in the engine tokenizer and page builder" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    try std.testing.expectEqual(xhtml.StreamExtractor.FeedResult{ .consumed = 10 }, try reader.feed("<p>one</p>"));
    try reader.finishInput();
    try std.testing.expectEqual(@as(u32, 10), reader.sourceOffset());
    try std.testing.expectEqualStrings("one", reader.pages[0].line(0));
}

test "checkpoint storage remains capped at its three-entry metadata budget" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    for (0..4) |index| reader.recordCheckpoint(@intCast(index), @intCast(index), 0);
    try std.testing.expect(reader.checkpoints.findAndTouch(0, 0) == null);
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(cache_policy.Entry)), reader.checkpoints.bytes_used);
}

test "target rescan retains the eight pages preceding its requested page" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(2, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.beginRescan(9);
    for (0..10) |page| {
        reader.pages[reader.buildingPage()] = makePage(@intCast(page), 1);
        reader.pageCompleted(@intCast(page * 10), @intCast(page * 100));
    }
    try std.testing.expect(!reader.isRescanning());
    try std.testing.expect(reader.current_ready);
    try std.testing.expectEqual(@as(u32, 9), reader.page_index);
    try std.testing.expect(reader.checkpoints.findAndTouch(2, 0) == null);
    try std.testing.expect(reader.checkpoints.findAndTouch(2, 9) != null);
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 1), reader.page_index);
    try std.testing.expectEqual(PagedReader.Move.needs_reconstruction, reader.previousPage());
}

test "last-page rescan retains its preceding page window" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(1, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.beginRescanToLastPage();
    for (0..10) |page| {
        reader.pages[reader.buildingPage()] = makePage(@intCast(page), 1);
        reader.pageCompleted(@intCast(page), @intCast(page));
    }
    reader.pages[reader.buildingPage()] = makePage(10, 1);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.finishChapter());
    try std.testing.expect(!reader.isRescanning());
    try std.testing.expectEqual(@as(u32, 10), reader.page_index);
    try std.testing.expect(reader.current_ready);
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 2), reader.page_index);
    try std.testing.expectEqual(PagedReader.Move.needs_reconstruction, reader.previousPage());
}

test "selection skips cached continuation pages in both directions" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pageCompleted(0, 0);
    for (1..5) |page| {
        reader.pages[reader.next_page] = makePage(if (page == 4) 2 else 1, 1);
        reader.pageCompleted(0, 0);
        try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    }
    reader.selected_word_ordinal = 2;
    try std.testing.expectEqual(PagedReader.Move.moved, reader.moveSelection(-1, false, false));
    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(?u32, 1), reader.selected_word_ordinal);
    try std.testing.expectEqual(@as(u32, 3), reader.page_index);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.moveSelection(-1, false, false));
    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(?u32, 0), reader.selected_word_ordinal);
    try std.testing.expectEqual(@as(u32, 0), reader.page_index);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.moveSelection(1, false, false));
    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(?u32, 1), reader.selected_word_ordinal);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.moveSelection(1, false, false));
    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(?u32, 2), reader.selected_word_ordinal);
    try std.testing.expectEqual(@as(u32, 4), reader.page_index);
}

test "Scroll continuation lines keep the original word and prefer the displayed page" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.current_page = 1;
    reader.page_index = 1;
    reader.current_ready = true;
    reader.pages[0] = makePage(0, 1);
    reader.setSlot(0, .history, 0, 0);
    var context: u8 = 0;
    var builder = pagination.EventPageBuilder.init(&reader.pages[1], 3, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    try builder.consume(.{ .text = "abcdefghi xyz" });
    try builder.end();
    reader.setSlot(1, .displayed, 0, 1);
    reader.beginScrollAtWord(0, geometry);
    try std.testing.expectEqual(@as(u32, 1), reader.scrollPosition().top_page);
    reader.scroll_position.offset_px = geometry.line_advance * 2;
    try std.testing.expectEqual(@as(?u32, 0), reader.scrollFirstVisibleWord(geometry));
    reader.scroll_position.offset_px = geometry.line_advance * 3;
    try std.testing.expectEqual(@as(?u32, 1), reader.scrollFirstVisibleWord(geometry));
    reader.selected_word_ordinal = 0;
    try std.testing.expectEqual(PagedReader.Move.at_limit, reader.moveSelection(-1, false, false));
}

test "a carried split fills a page without consuming the next input byte" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 1, .{ .context = &context, .line_limit = 1, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    const source = "abcd z";
    const first = try reader.feed(source);
    try std.testing.expectEqual(xhtml.StreamExtractor.FeedResult{ .page_full = 5 }, first);
    reader.pageCompleted(0, reader.sourceOffset());
    try std.testing.expectEqualStrings("a", reader.current().?.line(0));
    try std.testing.expectEqual(xhtml.StreamExtractor.FeedResult{ .page_full = 0 }, try reader.feed(source[5..]));
    reader.pageCompleted(0, reader.sourceOffset());
    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqualStrings("b", reader.current().?.line(0));
    try std.testing.expectEqual(xhtml.StreamExtractor.FeedResult{ .page_full = 0 }, try reader.feed(source[5..]));
    reader.pageCompleted(0, reader.sourceOffset());
    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqualStrings("c", reader.current().?.line(0));
    try std.testing.expectEqual(xhtml.StreamExtractor.FeedResult{ .consumed = 1 }, try reader.feed(source[5..]));
    try reader.finishInput();
    try std.testing.expectError(error.PageFull, reader.builder.?.end());
    reader.pageCompleted(0, reader.sourceOffset());
    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqualStrings("d", reader.current().?.line(0));
    try reader.builder.?.end();
    try std.testing.expectEqualStrings("z", reader.pages[reader.buildingPage()].line(0));
    try std.testing.expectEqual(@as(u32, 2), reader.wordCount());
}

test "ending detection requires complete final words rather than continuation fragments" {
    var page = makePage(90, 10);
    try std.testing.expect(PagedReader.pageContainsEnding(&page, 100));
    try std.testing.expect(!PagedReader.pageContainsEnding(&page, 101));
    page.last_word_continues = true;
    try std.testing.expect(!PagedReader.pageContainsEnding(&page, 100));
    try std.testing.expect(!PagedReader.pageContainsEnding(&page, 0));
}

test "Scroll ending is positional and handles a short tail beginning on its predecessor" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(128);
    reader.pages[0] = makePage(0, 90);
    reader.pages[0].line_count = 11;
    reader.pages[1] = makePage(90, 10);
    reader.pages[1].line_count = 3;
    reader.setSlot(0, .history, 0, 0);
    reader.setSlot(1, .displayed, 0, 1);
    reader.current_page = 1;
    reader.current_ready = true;
    reader.page_index = 1;
    reader.chapter_end = true;
    reader.chapter_last_page = 1;
    reader.scroll_position = .{ .top_page = 0 };
    try std.testing.expect(!reader.scrollEndingVisible(geometry, 100));
    reader.clampScrollAtChapterEnd(geometry);
    try std.testing.expectEqual(@as(u32, 0), reader.scrollPosition().top_page);
    try std.testing.expect(reader.scrollEndingVisible(geometry, 100));
    reader.scroll_position.offset_px -= 1;
    try std.testing.expect(!reader.scrollEndingVisible(geometry, 100));
    reader.scroll_position.waiting_px = 10;
    try std.testing.expect(!reader.scrollEndingVisible(geometry, 100));
    reader.scroll_position = .{ .top_page = 1 };
    reader.reconstructing = true;
    try std.testing.expect(!reader.scrollEndingVisible(geometry, 100));
}
