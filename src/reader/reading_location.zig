const std = @import("std");
const state = @import("../storage/reading_state.zig");
const settings = @import("../storage/settings.zig");
const rsvp_reader = @import("rsvp_reader.zig");

pub const ChapterOpenAction = union(enum) {
    normal,
    rescan: u32,
    word_rescan: u32,
    rsvp_rescan: rsvp_reader.RsvpReader.RescanTarget,
    rescan_to_last_page,
    scroll_rescan: u32,
};
pub const ScrollRestoreTarget = union(enum) { page: u32, word: u32 };

/// Keep semantic targets pending until their words are drawable.
pub const RestorePlan = struct {
    chapter: u8,
    action: ChapterOpenAction,
    pending_word: ?u32 = null,
    transition: bool = false,
    scroll_target: ?ScrollRestoreTarget = null,
};

pub fn restorePlan(restored: state.RestoredPosition, mode: state.Mode, presentation: settings.PagedPresentation, spine_len: u8) ?RestorePlan {
    const chapter = switch (restored) {
        .snapshot => |s| s.chapter,
        .legacy_paged_page => |s| s.chapter,
    };
    if (chapter >= spine_len) return null;
    var plan = RestorePlan{ .chapter = @intCast(chapter), .action = .normal };
    switch (restored) {
        .legacy_paged_page => |legacy| if (mode == .paged) {
            plan.action = if (legacy.page == 0) .normal else .{ .rescan = legacy.page };
            plan.transition = presentation == .pages;
            if (presentation == .scroll) plan.scroll_target = .{ .page = legacy.page };
        },
        .snapshot => |s| {
            plan.pending_word = s.word_ordinal;
            plan.action = if (mode == .rsvp) .{ .rsvp_rescan = .{ .word = s.word_ordinal } } else .{ .word_rescan = s.word_ordinal };
            plan.transition = mode == .paged and presentation == .pages;
            if (mode == .paged and presentation == .scroll) plan.scroll_target = .{ .word = s.word_ordinal };
        },
    }
    return plan;
}

pub const Location = struct {
    book_id: u32,
    layout_revision: u16,
    chapter: u8,
    requested_chapter: ?u8,
    pending_word: ?u32,
    visible_word: u32,
    mode: state.Mode,
    at_book_end: bool = false,

    /// Reconstruction cursors are provisional; persist the semantic destination.
    pub fn snapshot(self: Location) state.ReadingSnapshot {
        return .{
            .book_id = self.book_id,
            .layout_revision = self.layout_revision,
            .chapter = if (self.pending_word != null) self.requested_chapter orelse self.chapter else self.chapter,
            .word_ordinal = self.pending_word orelse self.visible_word,
            .mode = self.mode,
            .at_book_end = self.pending_word == null and self.at_book_end,
        };
    }
};

pub const SaveEligibility = struct {
    ready: bool,
    provisional_browser: bool,
    suppressed: bool,
    has_book: bool,
    chapter_in_spine: bool,
    pending_semantic_target: bool,
    drawable_position: bool,

    pub fn canFlush(self: SaveEligibility) bool {
        return self.ready and !self.provisional_browser and !self.suppressed and
            self.has_book and self.chapter_in_spine and
            (self.pending_semantic_target or self.drawable_position);
    }
};

test "restoration distinguishes semantic words from legacy pages in every presentation" {
    const saved = state.RestoredPosition{ .snapshot = .{ .book_id = 1, .layout_revision = 1, .chapter = 2, .word_ordinal = 93, .mode = .paged } };
    const pages = restorePlan(saved, .paged, .pages, 3).?;
    try std.testing.expectEqual(@as(u32, 93), pages.action.word_rescan);
    try std.testing.expect(pages.transition);
    const scroll = restorePlan(saved, .paged, .scroll, 3).?;
    try std.testing.expectEqual(@as(u32, 93), scroll.scroll_target.?.word);
    const rsvp = restorePlan(saved, .rsvp, .pages, 3).?;
    try std.testing.expectEqual(@as(u32, 93), rsvp.action.rsvp_rescan.word);
    try std.testing.expect(!rsvp.transition);
    try std.testing.expect(restorePlan(saved, .paged, .pages, 2) == null);
    const legacy = state.RestoredPosition{ .legacy_paged_page = .{ .chapter = 1, .page = 7 } };
    try std.testing.expectEqual(@as(u32, 7), restorePlan(legacy, .paged, .scroll, 3).?.scroll_target.?.page);
    try std.testing.expect(restorePlan(legacy, .rsvp, .pages, 3).?.action == .normal);
}

test "snapshot keeps pending destination and falls back to visible location after resolution" {
    var location = Location{ .book_id = 1, .layout_revision = 1, .chapter = 0, .requested_chapter = 2, .pending_word = 93, .visible_word = 4, .mode = .paged };
    try std.testing.expectEqual(@as(u16, 2), location.snapshot().chapter);
    try std.testing.expectEqual(@as(u32, 93), location.snapshot().word_ordinal);
    location.pending_word = null;
    try std.testing.expectEqual(@as(u16, 0), location.snapshot().chapter);
    try std.testing.expectEqual(@as(u32, 4), location.snapshot().word_ordinal);
}

test "save eligibility rejects provisional and unknown positions even with semantic targets" {
    const valid = SaveEligibility{ .ready = true, .provisional_browser = false, .suppressed = false, .has_book = true, .chapter_in_spine = true, .pending_semantic_target = true, .drawable_position = false };
    try std.testing.expect(valid.canFlush());
    inline for (.{ "ready", "has_book", "chapter_in_spine" }) |field| {
        var invalid = valid;
        @field(invalid, field) = false;
        try std.testing.expect(!invalid.canFlush());
    }
    inline for (.{ "provisional_browser", "suppressed" }) |field| {
        var invalid = valid;
        @field(invalid, field) = true;
        try std.testing.expect(!invalid.canFlush());
    }
    var unresolved = valid;
    unresolved.pending_semantic_target = false;
    try std.testing.expect(!unresolved.canFlush());
    unresolved.drawable_position = true;
    try std.testing.expect(unresolved.canFlush());
}
