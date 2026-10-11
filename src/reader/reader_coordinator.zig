const reading_location = @import("reading_location.zig");
const book_session = @import("book_session.zig");
const chapter_pump = @import("chapter_pump.zig");
const reader_view = @import("../ui/reader_view.zig");
const publication_descriptors = @import("../publication/descriptors.zig");
const std = @import("std");
const sound = @import("../audio/sound.zig");
const input = @import("reader_input.zig");
const chapter_browser = @import("../ui/chapter_browser.zig");
const library_storage = @import("../storage/library.zig");
const reading_pace = @import("../storage/pace.zig");
const reading_progress = @import("../storage/progress.zig");
const progress_indexer = @import("progress_indexer.zig");
const reading_statistics = @import("../ui/reading_statistics.zig");
const settings_menu = @import("../ui/settings_menu.zig");
const paged_reader = @import("paged_reader.zig");
const rsvp_reader = @import("rsvp_reader.zig");
const pagination = @import("../content/pagination.zig");
const rsvp = @import("../content/rsvp.zig");
const cache_policy = @import("../content/cache_policy.zig");
const decode_workspace = @import("decode_workspace.zig");
const opening_session = @import("opening_session.zig");
const persistence = @import("../storage/persistence.zig");
const zip = @import("../archive/zip.zig");
const epub = @import("../publication/epub.zig");
const deflate = @import("../archive/deflate.zig");
const limits = @import("limits").reader;
const publication_cache = @import("../storage/publication_cache.zig");
const builtin = @import("builtin");
const telemetry = if (builtin.is_test) @import("../telemetry.zig") else struct {};
const reader_host = @import("reader_host.zig");
const reader_transitions = @import("reader_transitions.zig");
const reader_layout = @import("../ui/reader_layout.zig");
const scroll_geometry = @import("scroll_geometry.zig");
const page_transition = @import("../ui/animation/page_transition.zig");
const manual_wpm = @import("manual_wpm.zig");

const prefetch_directory_records_per_step: usize = 8;
const layout_revision: u16 = 1;
const save_debounce_ms: u32 = 2000;
const save_max_dirty_ms: u32 = 10000;
const word_semantics_revision: u16 = 2;
const crank_degrees_per_word: f32 = 15;
const scroll_millidegrees_per_pixel: i32 = 1_250;
const scroll_chapter_transition_threshold_px: u16 = reader_layout.screen_height / 2;
/// RSVP may be far ahead of page layout. Spend more of the hidden restoration frame
/// rebuilding the target instead of showing intermediate pages.
const rsvp_return_reconstruction_bytes_per_update: usize = 6 * 1024;
const rsvp_return_page_completions_per_update: u8 = 3;
pub const reset_hold_duration_ms = reader_view.reset_hold_duration_ms;
pub const default_checkpoint_byte_budget = cache_policy.capacity * @sizeOf(cache_policy.Entry);
pub const page_pool_reserved_bytes = paged_reader.PagedReader.page_pool_reserved_bytes;
pub const word_pool_reserved_bytes = rsvp_reader.RsvpReader.word_pool_reserved_bytes;
pub const reader_cache_reserved_bytes = page_pool_reserved_bytes + word_pool_reserved_bytes;

fn paginationMeasure(self: *const ReaderCoordinator) pagination.Measure {
    const measure = self.host.?.measure;
    const font_height = measure.font_height(measure.context, self.pages_font);
    return .{
        .context = @constCast(self),
        .width = paginationWidth,
        .line_limit = reader_layout.pageLineLimit(font_height, pagination.max_lines),
    };
}

fn paginationWidth(context: *anyopaque, text: []const u8) usize {
    const self: *const ReaderCoordinator = @ptrCast(@alignCast(context));
    return self.host.?.measure.width(self.host.?.measure.context, self.pages_font, text);
}

pub const Screen = reader_view.Screen;
pub const ReadingMode = reader_view.ReadingMode;
pub const BookAction = reader_view.BookAction;
pub const SoundLevel = reader_view.SoundLevel;
pub const Theme = reader_view.Theme;
pub const ReadingFont = reader_view.ReadingFont;
pub const library_visible_rows = reader_view.library_visible_rows;
pub const ProgressVisibility = reader_view.ProgressVisibility;
pub const ProgressPosition = reader_view.ProgressPosition;
pub const ProgressScope = reader_view.ProgressScope;
pub const PagedPresentation = reader_view.PagedPresentation;
pub const ProgressView = reader_view.ProgressView;
pub const SettingsRow = reader_view.SettingsRow;
pub const OpeningFailure = reader_view.OpeningFailure;
pub const ChapterFailure = reader_view.ChapterFailure;
pub const LibraryView = reader_view.LibraryView;
pub const BookActionsView = reader_view.BookActionsView;
pub const ChapterRowView = reader_view.ChapterRowView;
pub const ChaptersView = reader_view.ChaptersView;
pub const PagedView = reader_view.PagedView;
pub const PageTransitionView = reader_view.PageTransitionView;
pub const ScrollView = reader_view.ScrollView;
pub const ByteSpan = reader_view.ByteSpan;
pub const RsvpView = reader_view.RsvpView;
pub const ChapterErrorView = reader_view.ChapterErrorView;
pub const RenderModel = reader_view.RenderModel;
pub const StatisticsBackdrop = reader_view.StatisticsBackdrop;
pub const StatisticsView = reader_view.StatisticsView;
pub const SettingsView = reader_view.SettingsView;
pub const ErrorView = reader_view.ErrorView;
pub const Readiness = enum { opening, ready, opening_failure, chapter_error };
pub const Lifecycle = enum {
    opening,
    ready,
    unavailable,
    invalid_archive,
    missing_mimetype,
    invalid_mimetype,
    chapter_error,
};

pub const ChapterOpenAction = reading_location.ChapterOpenAction;

pub const ChapterOpenJob = chapter_pump.OpenJob;

pub const ChapterStep = struct {
    worked: bool = false,
    position_changed: bool = false,
    request_prefetch: bool = false,
};

pub const FrameInput = struct {
    buttons: input.Buttons = .{},
    a_held: bool = false,
    crank_change: f32 = 0,
    crank_docked: bool = false,
    reduce_flashing: bool = false,
};

pub const SystemAction = enum { settings, toggle_reading_mode };
const PagedSelectionMove = enum { advanced, waiting_for_page, at_limit };
const ScrollRestoreTarget = reading_location.ScrollRestoreTarget;

pub const ReaderCoordinator = struct {
    screen: Screen = .library,
    screen_before_settings: Screen = .reading,
    mode: ReadingMode = .paged,
    paged_presentation: PagedPresentation = .pages,
    settings_menu_state: settings_menu.Model = .{},
    sound_level: SoundLevel = .full,
    sound_events: sound.Buffer = .{},
    sound_navigation: ?SoundNavigation = null,
    sound_opening_started: ?u32 = null,
    sound_library_seen: bool = false,
    sound_reset_milestone: u8 = 0,
    sound_reset_completed: bool = false,
    theme: Theme = .light,
    pages_font: ReadingFont = .newsleak_serif,
    rsvp_font: ReadingFont = .roobert_20_medium,
    progress_visibility: ProgressVisibility = .on,
    progress_position: ProgressPosition = .bottom,
    progress_scope: ProgressScope = .both,
    library: library_storage.Library,
    library_preview: persistence.LibraryPreview,
    library_refresh_pending: bool = false,
    library_progress_loaded: [library_storage.capacity]bool = [_]bool{false} ** library_storage.capacity,
    library_progress: [library_storage.capacity]?u8 = [_]?u8{null} ** library_storage.capacity,
    book_action_selected: BookAction = .start_or_resume,
    book_action_has_resume: bool = false,
    active_book: library_storage.Book = .{},
    pace: reading_pace.Stats = .{ .book_id = 0 },
    manual_pace: reading_pace.ManualSampler = .{},
    manual_rsvp_wpm: manual_wpm.Tracker = .{},
    progress_worker: progress_indexer.Indexer,
    pending_mode_word_ordinal: ?u32 = null,
    chapter_browser: chapter_browser.Model = .{},
    chapter_browser_from_library: bool = false,
    open_chapter_browser_after_opening: bool = false,
    book_session: book_session.Session,
    chapter_pump: chapter_pump.Pump,
    paged: paged_reader.PagedReader,
    rsvp_reader: rsvp_reader.RsvpReader,
    pending_publication_cache: ?[]u8 = null,
    cache_retry_at_ms: u32 = 0,
    /// Pending chapter after metadata loads; the caller supplies a stable file slot.
    opening_chapter_request: ?u8 = null,
    persistence: ?persistence.Service = null,
    chapter_index: u8 = 0,
    chapter_end: bool = false,
    pending_prefetch_transition: ?u8 = null,
    scroll_align_chapter_end: bool = false,
    lifecycle: Lifecycle = .opening,
    opening_failure: OpeningFailure = .{ .archive_scan = .{
        .cause = error.InvalidCentralDirectory,
        .file_size = 0,
        .tail_signature = [_]u8{0} ** 4,
        .nonzero_through = null,
        .zero_from = null,
    } },
    chapter_failure: ChapterFailure = .archive,
    // Loading controls cancellation and restoration independently of diagnostics.
    book_loading: bool = false,
    // Keep measurements for host regression tests only; normal builds use no storage.
    telemetry: if (builtin.is_test) telemetry.Telemetry else void = if (builtin.is_test) .{} else {},
    crank_accumulated: f32 = 0,
    scroll_crank_millidegrees: i32 = 0,
    /// Overscroll is visual until the user crosses the chapter-transition threshold.
    scroll_chapter_end_overscroll_px: u16 = 0,
    scroll_chapter_start_overscroll_px: u16 = 0,
    /// Request a Scroll chapter fade even though the view kind stays unchanged.
    scroll_chapter_transition_nonce: u32 = 0,
    page_animation: page_transition.Style = .bands,
    page_transition_state: page_transition.State = .{},
    restore_transition_pending: bool = false,
    scroll_restore_pending: ?ScrollRestoreTarget = null,
    /// Use a compact veil for the brief Pages/Scroll-to-RSVP handoff.
    mode_switch_loading: bool = false,
    /// Use the larger restore budget only when returning from RSVP.
    rsvp_return_fast_restore: bool = false,
    word_spotlight_nonce: u32 = 0,
    word_highlight_dismiss_nonce: u32 = 0,
    frame_now_ms: u32 = 0,
    last_at_book_end: bool = false,
    /// Last readable destination while forward RSVP probes an uncounted tail.
    rsvp_tail_return: ?struct { chapter: u8, word: u32 } = null,
    statistics_opened_at: u32 = 0,
    statistics_closing: bool = false,
    reduce_flashing: bool = false,
    crank_docked: bool = false,
    reset_hold_started_at: ?u32 = null,
    reset_hold_elapsed_ms: u16 = 0,
    position_save_suppressed: bool = false,
    reset_failed: bool = false,
    host: ?reader_host.ReaderHost = null,
    allocator: ?std.mem.Allocator = null,

    /// Initialize in place; returning this heap-sized state would overflow the device
    /// stack.
    pub fn initInPlace(self: *ReaderCoordinator, checkpoint_byte_budget: usize) void {
        inline for (@typeInfo(ReaderCoordinator).@"struct".fields) |field| {
            if (field.default_value_ptr) |value| {
                @field(self, field.name) = @as(*const field.type, @ptrCast(@alignCast(value))).*;
            }
        }
        self.library.reset();
        self.book_session.initInPlace();
        self.chapter_pump.initInPlace();
        self.progress_worker.initInPlace();
        self.paged.initInPlace(checkpoint_byte_budget);
        self.rsvp_reader.initInPlace();
    }

    /// The host context must outlive this coordinator.
    pub fn attachHost(self: *ReaderCoordinator, host: reader_host.ReaderHost) void {
        self.host = host;
    }

    /// The allocator owns temporary opening storage; ReaderHost supplies I/O.
    pub fn attachAllocator(self: *ReaderCoordinator, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
    }

    pub fn measureText(self: *const ReaderCoordinator, text: []const u8) usize {
        const measure = self.host.?.measure;
        return measure.width(measure.context, self.pages_font, text);
    }

    pub fn discoverLibrary(self: *ReaderCoordinator) void {
        const host = self.host orelse return;
        const files = host.files orelse return;
        // A single filename is small; the complete catalog remains heap-owned.
        const selected: ?library_storage.Book = if (self.library.selectedBook()) |book| book.* else null;
        const old_index = self.library.selected;
        self.library.reset();
        files.list_epubs(files.context, &self.library);
        if (self.library.listing_failed) self.library.len = 0;
        self.library.sort();
        self.library.select(if (selected) |book| self.library.find(book.slice()) orelse old_index else 0);
        self.library_refresh_pending = false;
        if (!self.sound_library_seen and self.screen == .library and self.library.len == 0) self.emitSound(.empty_library);
        self.sound_library_seen = true;
        self.refreshLibraryProgress();
    }

    fn refreshLibraryProgress(self: *ReaderCoordinator) void {
        self.library_progress = [_]?u8{null} ** library_storage.capacity;
        self.library_progress_loaded = [_]bool{false} ** library_storage.capacity;
    }

    /// Only one visible card's sidecars are read per Library update.
    fn stepLibraryProgress(self: *ReaderCoordinator) void {
        if (self.screen != .library and self.screen != .book_actions) return;
        const service = if (self.persistence) |*value| value else return;
        const end = @min(@as(usize, self.library.len), @as(usize, self.library.first_visible) + library_visible_rows);
        for (self.library.first_visible..end) |index| {
            if (self.library_progress_loaded[index]) continue;
            self.library_progress_loaded[index] = true;
            const book = &self.library.books[index];
            const book_id = persistence.Service.bookIdentity(book.slice());
            const restored = service.loadPosition(book.slice(), book_id, layout_revision) orelse return;
            const snapshot = switch (restored) {
                .snapshot => |value| value,
                .legacy_paged_page => return,
            };
            if (snapshot.chapter > std.math.maxInt(u8)) return;
            if (!service.loadLibraryProgressInto(book.slice(), book_id, &self.library_preview)) return;
            const progress = &self.library_preview.index;
            if (progress.key.word_semantics_revision != word_semantics_revision) return;
            self.library_progress[index] = progress.bookPercent(.{ .chapter = @intCast(snapshot.chapter), .word_ordinal = snapshot.word_ordinal, .at_book_end = snapshot.at_book_end });
            return;
        }
    }

    /// Use the resident progress index; leaving a book must not reopen every library
    /// sidecar.
    fn refreshActiveLibraryProgress(self: *ReaderCoordinator) void {
        const selected: usize = self.library.find(self.active_book.slice()) orelse return;
        if (self.position_save_suppressed) {
            self.library_progress[selected] = null;
            return;
        }
        const progress = self.progress_worker.snapshot() orelse return;
        const snapshot = self.positionSnapshot();
        self.library_progress[selected] = progress.bookPercent(.{
            .chapter = @intCast(snapshot.chapter),
            .word_ordinal = snapshot.word_ordinal,
            .at_book_end = snapshot.at_book_end,
        });
    }

    pub fn attachPersistence(self: *ReaderCoordinator, service: persistence.Service) void {
        self.persistence = service;
    }

    pub fn loadSettings(self: *ReaderCoordinator) void {
        const settings = self.persistence.?.loadSettings();
        self.mode = if (settings.reading_mode == .rsvp) .rsvp else .paged;
        self.rsvp_reader.wpm = settings.rsvp_wpm;
        self.sound_level = settings.sound;
        self.page_animation = settings.page_animation;
        self.theme = settings.theme;
        self.pages_font = persistence.normalizePagesFont(settings.pages_font);
        self.rsvp_font = persistence.normalizeRsvpFont(settings.rsvp_font);
        self.progress_visibility = settings.progress_visibility;
        self.progress_position = settings.progress_position;
        self.progress_scope = settings.progress_scope;
        self.paged_presentation = settings.paged_presentation;
    }

    pub fn saveSettings(self: *ReaderCoordinator) void {
        const service = &(self.persistence orelse return);
        _ = service.saveSettings(.{
            .reading_mode = if (self.mode == .rsvp) .rsvp else .paged,
            .rsvp_wpm = self.rsvp_reader.wpm,
            .sound = self.sound_level,
            .page_animation = self.page_animation,
            .theme = self.theme,
            .pages_font = self.pages_font,
            .rsvp_font = self.rsvp_font,
            .progress_visibility = self.progress_visibility,
            .progress_position = self.progress_position,
            .progress_scope = self.progress_scope,
            .paged_presentation = self.paged_presentation,
        }, self.frame_now_ms);
    }

    pub fn requestPositionSave(self: *ReaderCoordinator) void {
        if (self.lifecycle != .ready or self.position_save_suppressed) return;
        if (self.persistence) |*service| {
            service.pending_position = self.positionSnapshot();
            service.requestWrite(.position, self.frame_now_ms, save_debounce_ms, save_max_dirty_ms);
        }
    }

    fn requestPositionSaveAfterReadingMovement(self: *ReaderCoordinator) void {
        self.position_save_suppressed = false;
        self.reset_failed = false;
        self.requestPositionSave();
    }

    pub fn requestPaceSave(self: *ReaderCoordinator) void {
        if (self.persistence) |*service| service.requestWrite(.pace, self.frame_now_ms, save_debounce_ms, save_max_dirty_ms);
    }

    fn stopAutoplayAccounting(self: *ReaderCoordinator, now_ms: u32) void {
        const before = self.pace;
        self.rsvp_reader.stopAutoplay(now_ms, &self.pace);
        if (!std.meta.eql(before, self.pace)) self.requestPaceSave();
    }

    pub fn persistenceNotice(self: *const ReaderCoordinator) ?[]const u8 {
        if (self.reset_failed) return if (self.screen == .settings) "Reset failed. Hold A to retry." else "Reset failed. Retry in Settings.";
        if (self.persistence) |*service| {
            if (service.hasSaveFailure()) return "Save failed. Retrying...";
        }
        return null;
    }

    pub fn flushPersistence(self: *ReaderCoordinator) void {
        if (self.persistence) |*service| {
            if (self.lifecycle == .ready and !self.position_save_suppressed) {
                _ = service.flushPositionIfDue(self.active_book.slice(), self.positionSnapshot(), self.frame_now_ms);
            } else if (!self.position_save_suppressed) {
                _ = service.retryPendingPosition(self.active_book.slice(), self.frame_now_ms);
            }
            _ = service.flushSettingsIfDue(self.frame_now_ms);
            _ = service.flushPaceIfDue(self.active_book.slice(), self.pace, self.frame_now_ms);
            if (self.progress_worker.snapshot()) |index| {
                if (service.flushProgressIfDue(self.active_book.slice(), index, self.frame_now_ms)) self.progress_worker.clearDirty();
            }
        }
    }

    pub fn flushPositionNow(self: *ReaderCoordinator) void {
        if (self.position_save_suppressed) return;
        if (self.persistence) |*service| _ = service.flushPositionNow(self.active_book.slice(), self.positionSnapshot(), self.frame_now_ms);
    }

    pub fn flushPaceNow(self: *ReaderCoordinator) void {
        if (self.persistence) |*service| _ = service.flushPendingPace(self.active_book.slice(), self.pace, self.frame_now_ms);
    }

    pub fn flushProgressNow(self: *ReaderCoordinator) void {
        if (!self.progress_worker.status().dirty) return;
        const index = self.progress_worker.snapshot() orelse return;
        if (self.persistence) |*service| {
            if (!service.writePending(.progress)) service.requestWrite(.progress, self.frame_now_ms, 0, save_max_dirty_ms);
            if (service.flushPendingProgress(self.active_book.slice(), index, self.frame_now_ms)) self.progress_worker.clearDirty();
        }
    }

    pub fn restorePosition(self: *ReaderCoordinator) void {
        if (self.lifecycle != .ready) return;
        const service = &(self.persistence orelse return);
        const restored = service.loadPosition(self.active_book.slice(), self.bookIdentity(), layout_revision) orelse return;
        const plan = reading_location.restorePlan(restored, if (self.mode == .rsvp) .rsvp else .paged, self.paged_presentation, self.book_session.publication.spine_len) orelse return;
        self.restore_transition_pending = plan.transition;
        self.scroll_restore_pending = plan.scroll_target;
        if (plan.pending_word) |word| {
            self.pending_mode_word_ordinal = word;
            if (self.mode == .paged) self.paged.pending_selection = .{ .ordinal = word };
        }
        self.openChapter(plan.chapter, plan.action);
    }

    pub fn positionSnapshot(self: *const ReaderCoordinator) persistence.ReadingSnapshot {
        if (self.rsvp_tail_return) |destination| return .{
            .book_id = self.bookIdentity(),
            .layout_revision = layout_revision,
            .chapter = destination.chapter,
            .word_ordinal = destination.word,
            .mode = .rsvp,
        };
        return (reading_location.Location{
            .book_id = self.bookIdentity(),
            .layout_revision = layout_revision,
            .chapter = self.chapter_index,
            .requested_chapter = if (self.chapter_pump.chapter_open) |job| job.index else null,
            .pending_word = self.pending_mode_word_ordinal,
            .visible_word = if (self.pending_mode_word_ordinal != null) 0 else if (self.mode == .rsvp) self.rsvp_reader.position().word else self.currentPagedWordOrdinal(),
            .mode = if (self.mode == .rsvp) .rsvp else .paged,
            .at_book_end = self.atBookEnd(),
        }).snapshot();
    }

    fn currentPagedWordOrdinal(self: *const ReaderCoordinator) u32 {
        if (self.paged_presentation == .scroll) {
            if (self.paged.scrollFirstVisibleWord(self.scrollGeometry())) |ordinal| return ordinal;
        }
        const page = self.paged.current() orelse return self.paged.selected_word_ordinal orelse 0;
        return page.moveSelection(self.paged.selected_word_ordinal, 0) orelse 0;
    }

    fn scrollGeometry(self: *const ReaderCoordinator) scroll_geometry.Geometry {
        const measure = if (self.host) |host| host.measure else return scroll_geometry.Geometry.init(20);
        const font_height = measure.font_height(measure.context, self.pages_font);
        return scroll_geometry.Geometry.init(font_height);
    }

    fn bookIdentity(self: *const ReaderCoordinator) u32 {
        return persistence.Service.bookIdentity(self.active_book.slice());
    }

    /// Discard motion from the previous controls, including queued Scroll input. Keep
    /// semantic destinations and visible positions.
    fn clearTransientCrank(self: *ReaderCoordinator) void {
        self.crank_accumulated = 0;
        self.scroll_crank_millidegrees = 0;
        self.paged.detent_backlog = 0;
        self.paged.clearScrollTransient();
        self.scroll_chapter_end_overscroll_px = 0;
        self.scroll_chapter_start_overscroll_px = 0;
        self.manual_rsvp_wpm.clear();
    }

    fn changeScreen(self: *ReaderCoordinator, screen: Screen) void {
        if (self.screen == screen) return;
        self.clearTransientCrank();
        self.screen = screen;
        if (screen == .library) self.library_refresh_pending = true;
    }

    const CrankContext = struct {
        screen: Screen,
        mode: ReadingMode,
        presentation: persistence.PagedPresentation,
        autoplay: bool,
    };

    fn crankContext(self: *const ReaderCoordinator) CrankContext {
        return .{ .screen = self.screen, .mode = self.mode, .presentation = self.paged_presentation, .autoplay = self.rsvp_reader.timer.running };
    }

    pub fn beginOpening(self: *ReaderCoordinator) void {
        self.manual_pace.discard();
        self.manual_rsvp_wpm.clear();
        self.changeScreen(.opening);
    }

    pub fn returnToLibrary(self: *ReaderCoordinator) void {
        if (self.screen != .library) {
            self.emitSound(.surface_closed);
            if (self.library.len == 0) self.emitSound(.empty_library);
        }
        self.sound_navigation = null;
        self.sound_opening_started = null;
        self.changeScreen(.library);
    }

    pub fn leaveBook(self: *ReaderCoordinator, now_ms: u32) void {
        self.leaveBookWithPositionPolicy(now_ms, false);
    }

    /// A browser opened from Library has a provisional chapter-zero position.
    /// Cancelling it must preserve the saved reading position.
    fn leaveBookPreservingPosition(self: *ReaderCoordinator, now_ms: u32) void {
        self.leaveBookWithPositionPolicy(now_ms, true);
    }

    fn leaveBookWithPositionPolicy(self: *ReaderCoordinator, now_ms: u32, preserve_position: bool) void {
        self.frame_now_ms = now_ms;
        self.manual_pace.discard();
        self.manual_rsvp_wpm.clear();
        self.stopAutoplayAccounting(now_ms);
        self.flushPaceNow();
        if (!preserve_position and self.lifecycle == .ready) self.flushPositionNow();
        self.flushProgressNow();
        // Keep failed exit saves pending so the frame scheduler can retry them after
        // the book closes.
        if (self.persistence) |*service| {
            if (service.writePending(.position) or service.writePending(.pace) or service.writePending(.progress)) return;
        }
        if (!preserve_position) self.refreshActiveLibraryProgress();
        self.progress_worker.close();
        self.last_at_book_end = false;
        self.rsvp_tail_return = null;
        self.discardPublicationCacheWrite();
        self.book_loading = false;
        if (builtin.is_test) self.telemetry.loading.cancel();
        self.book_session.descriptors.ready = false;
        self.book_session.browser_map.ready = false;
        self.cancelOpening();
        self.open_chapter_browser_after_opening = false;
        self.chapter_browser_from_library = false;
        self.cancelPrefetch();
        self.cancelChapter();
        self.paged.builder = null;
        self.book_session.archive_index = null;
        self.paged.rescan = .none;
        self.paged.pending_selection = null;
        self.pending_mode_word_ordinal = null;
        self.pending_prefetch_transition = null;
        self.paged.detent_backlog = 0;
        self.paged.clearScrollTransient();
        self.scroll_crank_millidegrees = 0;
        self.scroll_chapter_end_overscroll_px = 0;
        self.scroll_chapter_start_overscroll_px = 0;
        self.page_transition_state.cancel();
        self.restore_transition_pending = false;
        self.scroll_restore_pending = null;
        self.mode_switch_loading = false;
        self.rsvp_return_fast_restore = false;
        self.clearResetHold();
        self.returnToLibrary();
        self.lifecycle = .opening;
    }

    pub fn openSettings(self: *ReaderCoordinator) bool {
        if (self.screen != .reading and self.screen != .library) return false;
        self.manual_pace.discard();
        self.screen_before_settings = self.screen;
        self.settings_menu_state.setAvailableRows(if (self.screen == .library) settings_menu.global_row_count else settings_menu.row_count);
        self.changeScreen(.settings);
        self.emitSound(.surface_opened);
        return true;
    }

    pub fn closeSettings(self: *ReaderCoordinator) bool {
        if (self.screen != .settings) return false;
        self.clearResetHold();
        self.changeScreen(self.screen_before_settings);
        self.emitSound(.surface_closed);
        return true;
    }

    pub fn openReadingStatistics(self: *ReaderCoordinator, now_ms: u32) bool {
        if (self.screen != .reading or self.mode != .paged) return false;
        self.manual_pace.discard();
        self.stopAutoplayAccounting(now_ms);
        self.page_transition_state.cancel();
        self.statistics_opened_at = now_ms;
        self.statistics_closing = false;
        self.changeScreen(.statistics);
        self.sound_events.push(.{ .kind = .surface_opened, .immediate = self.reduce_flashing, .duration_ms = reading_statistics.sheet_enter_ms });
        return true;
    }

    pub fn closeStatistics(self: *ReaderCoordinator, now_ms: u32) bool {
        if (self.screen != .statistics or self.statistics_closing) return false;
        self.sound_events.push(.{ .kind = .surface_closed, .immediate = self.reduce_flashing, .duration_ms = reading_statistics.sheet_exit_ms });
        if (self.reduce_flashing) {
            self.changeScreen(.reading);
            return true;
        }
        self.statistics_closing = true;
        self.statistics_opened_at = now_ms;
        return true;
    }

    fn advanceStatisticsTransition(self: *ReaderCoordinator, now_ms: u32) void {
        if (self.screen != .statistics or !self.statistics_closing) return;
        if (!self.reduce_flashing and now_ms -% self.statistics_opened_at < reading_statistics.sheet_exit_ms) return;
        self.statistics_closing = false;
        self.changeScreen(.reading);
    }

    pub fn openChapterBrowser(self: *ReaderCoordinator) bool {
        if (self.screen != .reading) return false;
        self.manual_pace.discard();
        self.chapter_browser_from_library = false;
        self.changeScreen(.chapter_browser);
        self.emitSound(.surface_opened);
        return true;
    }

    pub fn closeChapterBrowser(self: *ReaderCoordinator, now_ms: u32) bool {
        if (self.screen != .chapter_browser) return false;
        if (self.chapter_browser_from_library) {
            self.chapter_browser_from_library = false;
            self.leaveBookPreservingPosition(now_ms);
            return true;
        }
        self.changeScreen(.reading);
        self.emitSound(.surface_closed);
        return true;
    }

    pub fn beginReading(self: *ReaderCoordinator) void {
        self.changeScreen(.reading);
    }

    pub fn toggleMode(self: *ReaderCoordinator) void {
        self.clearTransientCrank();
        self.mode = switch (self.mode) {
            .paged => .rsvp,
            .rsvp => .paged,
        };
    }

    pub fn moveSettingsSelection(self: *ReaderCoordinator, direction: i8) void {
        if (self.screen != .settings or direction == 0) return;
        self.clearResetHold();
        const selected = self.settings_menu_state.selected;
        self.settings_menu_state.move(direction);
        if (selected == self.settings_menu_state.selected) return;
        self.sound_events.push(.{ .kind = .selection, .direction = direction });
    }

    fn clearResetHold(self: *ReaderCoordinator) void {
        if (self.reset_hold_started_at != null and !self.sound_reset_completed) self.emitSound(.reset_cancelled);
        self.sound_reset_milestone = 0;
        self.reset_hold_started_at = null;
        self.reset_hold_elapsed_ms = 0;
    }

    fn updateResetHold(self: *ReaderCoordinator, a_held: bool, a_pressed: bool, now_ms: u32) void {
        if (self.screen != .settings or self.settings_menu_state.selected != .reset_progress or !a_held) {
            self.clearResetHold();
            return;
        }
        if (self.reset_hold_started_at == null) {
            if (!a_pressed) return;
            self.reset_hold_started_at = now_ms;
            self.sound_reset_completed = false;
            self.reset_failed = false;
            self.emitSound(.reset_started);
        }

        const elapsed = @min(now_ms -% self.reset_hold_started_at.?, reset_hold_duration_ms);
        self.reset_hold_elapsed_ms = @intCast(elapsed);
        if (elapsed < reset_hold_duration_ms) {
            const milestone: u8 = @intCast(elapsed / 1000);
            if (milestone > self.sound_reset_milestone) {
                self.sound_reset_milestone = milestone;
                self.sound_events.push(.{ .kind = .reset_milestone, .direction = @intCast(milestone) });
            }
            return;
        }

        if (self.persistence) |*service| {
            if (!service.deletePosition(self.active_book.slice(), self.bookIdentity())) {
                self.reset_failed = true;
                self.emitSound(.failure);
                self.clearResetHold();
                return;
            }
        }
        self.reset_failed = false;
        self.position_save_suppressed = true;
        self.sound_reset_completed = true;
        self.emitSound(.reset_completed);
        self.clearResetHold();
        self.leaveBook(now_ms);
    }

    pub fn openChapters(self: *ReaderCoordinator, entry_count: u8, current: u8) bool {
        if (entry_count == 0 or !self.openChapterBrowser()) return false;
        self.chapter_browser = chapter_browser.Model.init(entry_count, current);
        return true;
    }

    fn visibleChapterCount(self: *const ReaderCoordinator) u8 {
        if (self.book_session.browser_map.ready) return self.book_session.browser_map.count;
        const visibility = chapter_browser.Visibility.init(&self.book_session.publication);
        var count: u8 = 0;
        for (0..self.book_session.publication.spine_len) |index| {
            if (visibility.includes(&self.book_session.publication, @intCast(index))) count += 1;
        }
        return count;
    }

    fn browserPositionForSpine(self: *const ReaderCoordinator, spine_index: u8) u8 {
        if (self.book_session.browser_map.ready) return self.book_session.browser_map.position(spine_index);
        const visibility = chapter_browser.Visibility.init(&self.book_session.publication);
        var position: u8 = 0;
        var last_visible: u8 = 0;
        for (0..self.book_session.publication.spine_len) |index| {
            if (!visibility.includes(&self.book_session.publication, @intCast(index))) continue;
            if (index >= spine_index) return position;
            last_visible = position;
            position += 1;
        }
        return last_visible;
    }

    fn spineIndexForBrowserPosition(self: *const ReaderCoordinator, wanted: u8) ?u8 {
        if (self.book_session.browser_map.ready) return self.book_session.browser_map.spineIndex(wanted);
        const visibility = chapter_browser.Visibility.init(&self.book_session.publication);
        var position: u8 = 0;
        for (0..self.book_session.publication.spine_len) |index| {
            if (!visibility.includes(&self.book_session.publication, @intCast(index))) continue;
            if (position == wanted) return @intCast(index);
            position += 1;
        }
        return null;
    }

    pub fn selectBook(self: *ReaderCoordinator) ?*const library_storage.Book {
        const selected = self.library.selectedBook() orelse return null;
        self.active_book = selected.*;
        return &self.active_book;
    }

    pub fn openBookActions(self: *ReaderCoordinator) bool {
        if (self.screen != .library) return false;
        const selected = self.library.selectedBook() orelse return false;
        const book_id = persistence.Service.bookIdentity(selected.slice());
        self.book_action_has_resume = if (self.persistence) |*service|
            service.loadPosition(selected.slice(), book_id, layout_revision) != null
        else
            false;
        self.book_action_selected = .start_or_resume;
        self.changeScreen(.book_actions);
        self.emitSound(.surface_opened);
        return true;
    }

    pub fn closeBookActions(self: *ReaderCoordinator) bool {
        if (self.screen != .book_actions) return false;
        self.changeScreen(.library);
        self.emitSound(.surface_closed);
        return true;
    }

    pub fn moveBookAction(self: *ReaderCoordinator, direction: i8) void {
        if (self.screen != .book_actions or direction == 0) return;
        self.emitSound(.selection);
        self.book_action_selected = switch (self.book_action_selected) {
            .start_or_resume => .chapters,
            .chapters => .start_or_resume,
        };
    }

    fn openSelectedBookAtChapters(self: *ReaderCoordinator) bool {
        if (!self.openSelectedBook()) return false;
        self.open_chapter_browser_after_opening = true;
        return true;
    }

    pub fn openSelectedBook(self: *ReaderCoordinator) bool {
        _ = self.selectBook() orelse return false;
        self.open_chapter_browser_after_opening = false;
        self.chapter_browser_from_library = false;
        self.book_session.descriptors.ready = false;
        self.book_session.browser_map.ready = false;
        const allocator = self.allocator orelse return false;
        const opening_job = allocator.create(opening_session.Session) catch {
            self.opening_failure = .{ .opening_allocation = @sizeOf(opening_session.Session) };
            self.lifecycle = .invalid_archive;
            self.sound_navigation = null;
            self.sound_opening_started = null;
            self.emitSound(.failure);
            self.beginOpening();
            return true;
        };
        self.sound_navigation = null;
        self.sound_opening_started = self.frame_now_ms;
        self.emitSound(.accepted);
        opening_job.initInPlace();
        self.progress_worker.close();
        self.last_at_book_end = false;
        self.rsvp_tail_return = null;
        self.paged.resetForBook();
        self.rsvp_reader.resetForBook();
        self.page_transition_state.cancel();
        self.restore_transition_pending = false;
        self.scroll_restore_pending = null;
        self.position_save_suppressed = false;
        self.reset_failed = false;
        self.clearResetHold();
        const book_id = persistence.Service.bookIdentity(self.active_book.slice());
        self.pace = if (self.persistence) |*service| service.loadPace(self.active_book.slice(), book_id) else .{ .book_id = book_id };
        self.discardPublicationCacheWrite();
        self.book_loading = true;
        if (builtin.is_test) self.telemetry.loading.begin(self.clockMilliseconds());
        self.lifecycle = .opening;
        self.beginOpening();
        self.book_session.archive_index = null;
        self.book_session.opening_job = opening_job;
        self.opening_chapter_request = null;
        return true;
    }

    /// Advance one opening phase per update.
    pub fn advanceOpening(self: *ReaderCoordinator) void {
        const job = self.book_session.opening_job orelse return;
        const started = self.clockMilliseconds();
        if (builtin.is_test) self.telemetry.loading.stepStarted(openingTelemetryPhase(job), started);
        defer if (builtin.is_test) self.telemetry.loading.stepFinished(self.clockMilliseconds());
        switch (job.phase) {
            .open => {
                const files = self.host.?.files orelse {
                    self.failOpening(.unavailable);
                    return;
                };
                const reader = files.open(files.context, .opening, self.active_book.zSlice()) catch {
                    self.failOpening(.unavailable);
                    return;
                };
                job.beginArchiveScan(.{ .context = self, .close = closeOpeningHostLease }, reader) catch |err| {
                    self.failInvalidOpening(.{ .archive_initialization = err });
                };
            },
            .scan_archive => {
                _ = job.stepArchiveScan() catch |err| {
                    self.failInvalidOpening(.{ .archive_scan = .{
                        .cause = err,
                        .file_size = job.scanner.?.reader.size,
                        .tail_signature = job.scanner.?.tail_signature,
                        .nonzero_through = if (job.scanner.?.read_boundary) |boundary| boundary.nonzero else null,
                        .zero_from = if (job.scanner.?.read_boundary) |boundary| boundary.zero else null,
                    } });
                };
            },
            .validate_directory => {
                for (0..limits.opening_directory_records_per_update) |_| {
                    const complete = job.stepDirectoryValidation() catch |err| {
                        self.failInvalidOpening(.{ .directory_validation = err });
                        return;
                    };
                    if (!complete) {
                        if (self.openingBudgetExpired(started) or (job.validator.?.entry_index == job.archive.?.entry_count and job.validator.?.local_index == 0)) break;
                        continue;
                    }
                    self.book_session.archive_index = job.directoryIndex() catch {
                        self.failInvalidOpening(.directory_index);
                        return;
                    };
                    break;
                }
            },
            .hash_directory => {
                for (0..limits.opening_hash_chunks_per_update) |_| {
                    const complete = job.stepDirectoryHash() catch |err| {
                        self.failInvalidOpening(.{ .directory_validation = err });
                        return;
                    };
                    if (complete or self.openingBudgetExpired(started)) break;
                }
            },
            .load_publication_cache => {
                if (self.loadPublicationCache(job)) {
                    job.cache_hit = true;
                    if (builtin.is_test) self.telemetry.loading.cache_hit = true;
                    job.succeed();
                    self.finishOpening();
                } else job.phase = .find_container;
            },
            .find_mimetype => {
                const entry = self.book_session.archive_index.?.find("mimetype") catch {
                    self.failOpening(.missing_mimetype);
                    return;
                };
                self.beginMetadataRead(job, entry, .mimetype) catch {
                    self.failOpening(.invalid_mimetype);
                };
            },
            .read_mimetype => if (self.advanceMetadataReadBatch(job, .mimetype)) {
                if (!job.mimetypeIsValid()) {
                    self.failOpening(.invalid_mimetype);
                    return;
                }
                job.finishMetadataRead(.mimetype);
                job.phase = .load_publication_cache;
            },
            .find_container => {
                const entry = self.book_session.archive_index.?.find("META-INF/container.xml") catch |err| {
                    self.failInvalidOpening(.{ .container_lookup = err });
                    return;
                };
                self.beginMetadataRead(job, entry, .container) catch |err| {
                    self.failInvalidOpening(.{ .container_stream = err });
                };
            },
            .read_container => if (self.advanceMetadataReadBatch(job, .container)) {
                job.finishMetadataRead(.container);
            },
            .parse_container => job.parseContainer() catch |err| {
                self.failInvalidOpening(.{ .container_parse = err });
            },
            .find_package => {
                const entry = self.book_session.archive_index.?.find(job.packagePath()) catch |err| {
                    self.failInvalidOpening(.{ .package_lookup = err });
                    return;
                };
                if (entry.uncompressed_size == 0 or entry.uncompressed_size > epub.max_package_document_bytes) {
                    self.failInvalidOpening(.{ .package_size = entry.uncompressed_size });
                    return;
                }
                const allocator = self.allocator orelse {
                    self.failInvalidOpening(.{ .package_allocation = entry.uncompressed_size });
                    return;
                };
                job.package_xml = allocator.alloc(u8, entry.uncompressed_size) catch {
                    self.failInvalidOpening(.{ .package_allocation = entry.uncompressed_size });
                    return;
                };
                self.beginMetadataRead(job, entry, .package) catch |err| {
                    self.failInvalidOpening(.{ .package_stream = err });
                };
            },
            .read_package => if (self.advanceMetadataReadBatch(job, .package)) {
                job.finishMetadataRead(.package);
            },
            .parse_package => {
                const package_xml = job.package_xml orelse {
                    self.failInvalidOpening(.package_buffer);
                    return;
                };
                const allocator = self.allocator orelse {
                    self.failInvalidOpening(.{ .package_allocation = @intCast(package_xml.len) });
                    return;
                };
                epub.parseOpf(package_xml[0..job.output_len], job.packagePath(), &self.book_session.publication, &job.opf_workspace) catch |err| {
                    self.failInvalidOpening(.{ .package_parse = err });
                    return;
                };
                job.finishPackageParsing(allocator);
            },
            .find_navigation => self.beginNavigationRead(job, .epub3),
            .read_navigation => self.advanceNavigationReadBatch(job, .epub3),
            .find_ncx => self.beginNavigationRead(job, .ncx),
            .read_ncx => self.advanceNavigationReadBatch(job, .ncx),
        }
    }

    fn beginNavigationRead(self: *ReaderCoordinator, job: *opening_session.Session, source: opening_session.NavigationSource) void {
        const path = switch (source) {
            .epub3 => self.book_session.publication.navigation_document.slice(),
            .ncx => self.book_session.publication.ncx_document.slice(),
        };
        if (path.len == 0) {
            self.navigationSourceFinished(source, false);
            return;
        }
        const entry = self.book_session.archive_index.?.find(path) catch {
            self.navigationSourceFinished(source, false);
            return;
        };
        if (entry.uncompressed_size == 0 or entry.uncompressed_size > limits.max_navigation_document_bytes) {
            self.navigationSourceFinished(source, false);
            return;
        }
        self.chapter_pump.opening_storage = zip.StreamStorage.init(&self.chapter_pump.deflate_input_buffer, &self.chapter_pump.deflate_window, &self.chapter_pump.deflate_workspace);
        job.stream = job.archive.?.begin(entry, &self.chapter_pump.opening_storage) catch {
            self.navigationSourceFinished(source, false);
            return;
        };
        job.beginNavigationRead(source, &self.book_session.publication, path);
    }

    fn advanceNavigationRead(self: *ReaderCoordinator, job: *opening_session.Session, source: opening_session.NavigationSource, decoder_budget: *zip.WorkBudget) void {
        const result = job.stream.?.readWithBudget(&job.output, decoder_budget) catch {
            self.navigationSourceFinished(source, false);
            return;
        };
        switch (result) {
            .bytes => |count| {
                if (count > limits.max_navigation_document_bytes - job.output_len) {
                    self.navigationSourceFinished(source, false);
                    return;
                }
                job.output_len += count;
                job.navigation_parser.?.feed(job.output[0..count]) catch self.navigationSourceFinished(source, false);
            },
            .end => {
                job.stream.?.finish() catch {
                    self.navigationSourceFinished(source, false);
                    return;
                };
                job.stream = null;
                const parser = &(job.navigation_parser orelse {
                    self.navigationSourceFinished(source, false);
                    return;
                });
                parser.finish() catch {
                    self.navigationSourceFinished(source, false);
                    return;
                };
                self.navigationSourceFinished(source, parser.labelCount() != 0);
            },
            .yielded => {},
            .needs_input => self.navigationSourceFinished(source, false),
        }
    }

    fn advanceNavigationReadBatch(self: *ReaderCoordinator, job: *opening_session.Session, source: opening_session.NavigationSource) void {
        var decoder_budget = zip.WorkBudget{};
        const reading_phase: opening_session.Phase = if (source == .epub3) .read_navigation else .read_ncx;
        for (0..limits.opening_metadata_chunks_per_update) |_| {
            self.advanceNavigationRead(job, source, &decoder_budget);
            const active = self.book_session.opening_job orelse return;
            if (active.phase != reading_phase) return;
        }
    }

    fn navigationSourceFinished(self: *ReaderCoordinator, source: opening_session.NavigationSource, has_labels: bool) void {
        const completion = self.book_session.opening_job.?.finishNavigation(source, has_labels);
        if (!has_labels) self.clearChapterLabels();
        if (completion == .opened) self.finishOpening();
    }

    fn clearChapterLabels(self: *ReaderCoordinator) void {
        self.book_session.browser_map.ready = false;
        for (self.book_session.publication.chapter_labels[0..self.book_session.publication.spine_len]) |*label| label.len = 0;
    }

    fn finishOpening(self: *ReaderCoordinator) void {
        const job = self.book_session.opening_job orelse return;
        const result = job.takeResult() orelse return;
        switch (result) {
            .opened => {},
            .failed => unreachable,
        }
        const fingerprint = if (job.cache_hit)
            publication_cache.cachedFingerprint(job.cache_bytes.?)
        else if (self.book_session.archive_index) |*directory|
            publicationFingerprint(&self.book_session.publication, directory)
        else
            [_]u8{0} ** 16;
        self.book_session.resolvePublication() catch |err| {
            self.failInvalidOpening(.{ .directory_validation = err });
            return;
        };
        if (!job.cache_hit and self.persistence != null) {
            if (job.cache_bytes == null) {
                if (self.allocator) |allocator| job.cache_bytes = allocator.alloc(u8, publication_cache.encoded_size) catch null;
            }
            if (job.cache_bytes) |bytes| {
                publication_cache.encode(bytes, self.publicationCacheKey(job), &self.book_session.publication, &self.book_session.archive_index.?, fingerprint);
                self.pending_publication_cache = bytes;
                self.cache_retry_at_ms = self.frame_now_ms;
                job.cache_bytes = null;
            }
        }
        if (builtin.is_test) self.telemetry.loading.metadataFinished(self.clockMilliseconds());
        self.releaseOpeningJob();
        self.chapter_index = 0;
        self.startProgressIndexing(fingerprint);
        self.lifecycle = .ready;
        if (self.open_chapter_browser_after_opening) {
            self.open_chapter_browser_after_opening = false;
            self.chapter_browser_from_library = true;
            self.chapter_browser = chapter_browser.Model.init(self.visibleChapterCount(), 0);
            self.changeScreen(.chapter_browser);
        } else {
            self.beginReading();
            self.opening_chapter_request = 0;
        }
    }

    fn publicationCacheKey(self: *const ReaderCoordinator, job: *const opening_session.Session) publication_cache.Key {
        return .{ .book_id = self.bookIdentity(), .file_size = job.archive.?.reader.size, .directory_digest = job.directory_digest };
    }

    fn loadPublicationCache(self: *ReaderCoordinator, job: *opening_session.Session) bool {
        const service = if (self.persistence) |*value| value else return false;
        const allocator = self.allocator orelse return false;
        job.cache_bytes = allocator.alloc(u8, publication_cache.encoded_size) catch return false;
        const bytes = job.cache_bytes.?;
        if (!service.loadPublicationCache(self.active_book.slice(), bytes)) return false;
        return publication_cache.decode(bytes, self.publicationCacheKey(job), &self.book_session.archive_index.?, &self.book_session.publication);
    }

    fn discardPublicationCacheWrite(self: *ReaderCoordinator) void {
        if (self.pending_publication_cache) |bytes| {
            if (self.allocator) |allocator| allocator.free(bytes);
        }
        self.pending_publication_cache = null;
    }

    fn flushPublicationCache(self: *ReaderCoordinator, foreground_worked: bool) void {
        if (foreground_worked or self.book_loading or self.lifecycle != .ready) return;
        const bytes = self.pending_publication_cache orelse return;
        if (self.frame_now_ms -% self.cache_retry_at_ms >= 0x80000000) return;
        if (self.persistence) |*service| {
            const started = if (builtin.is_test) self.clockMilliseconds() else 0;
            const saved = service.savePublicationCache(self.active_book.slice(), bytes);
            if (builtin.is_test) self.telemetry.loading.cache_write_ms = self.clockMilliseconds() -% started;
            if (builtin.is_test) self.telemetry.loading.cache_write_attempts +%= 1;
            if (builtin.is_test) self.telemetry.loading.cache_write_report_pending = true;
            if (saved) {
                self.discardPublicationCacheWrite();
                return;
            }
        }
        // Derived cache writes are optional and do not block exiting a book.
        self.cache_retry_at_ms = self.frame_now_ms +% 30000;
    }

    fn clockMilliseconds(self: *const ReaderCoordinator) u32 {
        if (self.host) |host| if (host.clock) |clock| return clock.milliseconds(clock.context);
        return self.frame_now_ms;
    }

    fn openingBudgetExpired(self: *const ReaderCoordinator, started: u32) bool {
        return self.clockMilliseconds() -% started >= limits.opening_work_ms_per_update;
    }

    fn startProgressIndexing(self: *ReaderCoordinator, fingerprint: [16]u8) void {
        const host = self.host orelse return;
        const files = host.files orelse return;
        const key = reading_progress.Key{
            .book_id = self.bookIdentity(),
            .publication_fingerprint = fingerprint,
            .word_semantics_revision = word_semantics_revision,
            .spine_len = self.book_session.publication.spine_len,
        };
        const fresh = reading_progress.Index.init(key) catch return;
        const index = if (self.persistence) |*service| service.loadProgress(self.active_book.slice(), key) orelse fresh else fresh;
        const reader = files.open(files.context, .progress, self.active_book.zSlice()) catch return;
        self.progress_worker.openWithDescriptors(index, &self.book_session.publication, self.chapter_index, reader, .{
            .context = self,
            .close = closeProgressHostLease,
        }, if (self.book_session.descriptors.ready) &self.book_session.descriptors else null) catch return;
    }

    /// Consume the chapter request once; the caller supplies only its file slot.
    pub fn takeOpeningChapterRequest(self: *ReaderCoordinator) ?u8 {
        const request = self.opening_chapter_request;
        self.opening_chapter_request = null;
        return request;
    }

    pub fn cancelOpening(self: *ReaderCoordinator) void {
        self.sound_opening_started = null;
        self.releaseOpeningJob();
        self.opening_chapter_request = null;
    }

    fn releaseOpeningJob(self: *ReaderCoordinator) void {
        self.book_session.cancelOpening(self.allocator);
    }

    /// Release the previous stream and lease before replacing a chapter request.
    pub fn openChapter(self: *ReaderCoordinator, index: u8, action: ChapterOpenAction) void {
        self.rsvp_tail_return = null;
        self.manual_pace.discard();
        self.pending_prefetch_transition = null;
        self.cancelPrefetch();
        self.cancelChapterWork();
        self.scroll_chapter_end_overscroll_px = 0;
        self.scroll_chapter_start_overscroll_px = 0;
        self.mode_switch_loading = false;
        self.rsvp_return_fast_restore = false;
        self.chapter_pump.chapter_open = .{ .index = index, .action = action };
        self.scroll_align_chapter_end = self.mode == .paged and self.paged_presentation == .scroll and action == .rescan_to_last_page;
        if (action != .scroll_rescan) {
            self.paged.builder = null;
            self.paged.current_ready = false;
            self.paged.next_ready = false;
            self.paged.selected_word_ordinal = null;
        }
        self.chapter_end = false;
        self.paged.chapter_end = false;
    }

    /// Building cached pages is not user movement and must not produce pace samples.
    pub fn stepChapter(self: *ReaderCoordinator, now_ms: u32) ChapterStep {
        if (self.chapter_pump.chapter_open == null) return self.stepChapterStream(now_ms);
        return switch (self.chapter_pump.stepLookup(
            if (self.host) |host| host.files else null,
            self.active_book.zSlice(),
            &self.book_session.publication,
            &self.book_session.descriptors,
        )) {
            .working => .{ .worked = true },
            .failed => blk: {
                self.failChapter(.archive);
                break :blk .{ .worked = true };
            },
            .found => |found| self.beginChapterRequest(found.archive, found.entry, found.index, found.action, now_ms),
        };
    }

    fn beginChapterRequest(self: *ReaderCoordinator, archive: zip.Archive, entry: zip.Entry, index: u8, action: ChapterOpenAction, now_ms: u32) ChapterStep {
        self.chapter_pump.chapter_open = null;
        const scroll_target = switch (action) {
            .scroll_rescan => |target| target,
            else => null,
        };
        self.beginOpenedChapter(archive, index, entry, now_ms, scroll_target) catch {
            self.failChapter(.archive);
            return .{ .worked = true };
        };
        switch (action) {
            .normal => {},
            .rescan => |target| self.paged.beginRescan(target),
            .word_rescan => |target| self.paged.beginWordRescan(target),
            .rsvp_rescan => |target| self.rsvp_reader.reconstruct(target),
            .rescan_to_last_page => self.paged.beginRescanToLastPage(),
            .scroll_rescan => {},
        }
        return .{ .worked = true };
    }

    fn stepChapterStream(self: *ReaderCoordinator, now_ms: u32) ChapterStep {
        if (self.lifecycle != .ready or self.paged.next_ready or self.chapter_end or self.chapter_pump.chapter_stream == null) return .{};
        if (self.mode == .rsvp and self.rsvp_reader.hasWord()) return .{};

        const reconstructing = self.chapterIsReconstructing();
        const saved_restore = self.book_loading and self.mode == .paged and reconstructing;
        const restoration_started_ms = if (saved_restore) self.clockMilliseconds() else 0;
        var decoder_budget = zip.WorkBudget{};
        var budget = self.chapterWorkBudget();
        var completed_pages: u8 = 0;
        while (budget != 0 and !self.paged.next_ready and !self.chapter_end) {
            if (self.chapter_pump.chapter_output_start != self.chapter_pump.chapter_output_end) {
                const available = self.chapter_pump.available();
                const input_bytes = available[0..if (self.mode == .rsvp) 1 else @min(available.len, budget)];
                const progress = (if (self.mode == .rsvp) self.rsvp_reader.feed(input_bytes) else self.paged.feed(input_bytes)) catch {
                    self.failChapter(.tokenizer);
                    return .{ .worked = true };
                };
                var page_completed = false;
                const consumed = switch (progress) {
                    .consumed => |count| count,
                    .page_full => |count| blk: {
                        self.pageCompleted(now_ms);
                        page_completed = true;
                        break :blk count;
                    },
                };
                self.chapter_pump.consume(consumed);
                budget -= consumed;
                if (page_completed) {
                    completed_pages += 1;
                    if (saved_restore) {
                        // Consume provisional pages now to avoid waiting a frame per
                        // restored page.
                        self.fulfillPendingPagedSelection();
                        if (!self.chapterIsReconstructing() or
                            completed_pages >= limits.restoration_pages_per_update or
                            self.clockMilliseconds() -% restoration_started_ms >= limits.restoration_work_ms_per_update)
                            return .{ .worked = true };
                    } else if (reconstructing and (!self.isFastRsvpReturnRestore() or completed_pages >= rsvp_return_page_completions_per_update)) return .{ .worked = true };
                }
                if (self.mode == .rsvp and self.rsvp_reader.hasWord()) {
                    self.rsvp_tail_return = null;
                    if (builtin.is_test) self.telemetry.setChapterEvents(self.rsvp_reader.event_count);
                    if (self.pending_mode_word_ordinal == self.rsvp_reader.position().word) {
                        self.pending_mode_word_ordinal = null;
                        self.mode_switch_loading = false;
                    }
                    self.rsvp_reader.wordBecameDrawable(now_ms);
                    return .{ .worked = true, .position_changed = true };
                }
                continue;
            }

            const stream = &self.chapter_pump.chapter_stream.?;
            const result = self.chapter_pump.read(budget, &decoder_budget) catch {
                self.failChapter(.archive);
                return .{ .worked = true };
            };
            switch (result) {
                .bytes => |count| {
                    if (builtin.is_test) self.telemetry.decodedBytes(count);
                },
                .end => {
                    if (self.mode != .rsvp) self.paged.finishInput() catch {
                        self.failChapter(.tokenizer);
                        return .{ .worked = true };
                    };
                    if (self.mode == .rsvp) {
                        self.rsvp_reader.finishInput() catch {
                            self.failChapter(.tokenizer);
                            return .{ .worked = true };
                        };
                        self.chapter_end = true;
                        stream.finish() catch {
                            self.failChapter(.archive);
                            return .{ .worked = true };
                        };
                        self.observeVerifiedChapterTotal(self.rsvp_reader.wordCount());
                        if (builtin.is_test) self.telemetry.setChapterEvents(self.rsvp_reader.event_count);
                        var position_changed = false;
                        if (self.rsvp_reader.hasWord()) {
                            self.rsvp_tail_return = null;
                            if (self.pending_mode_word_ordinal == self.rsvp_reader.position().word) {
                                self.pending_mode_word_ordinal = null;
                                self.mode_switch_loading = false;
                            }
                            self.rsvp_reader.wordBecameDrawable(now_ms);
                            if (self.nextReadableChapter() == null) self.stopRsvpAtBookEnd(now_ms);
                            position_changed = true;
                        }
                        if (self.rsvp_reader.targetUnresolved()) {
                            self.failChapter(.page_limit);
                        } else if (!self.rsvp_reader.hasWord()) {
                            self.advancePastEmptyRsvpChapter(now_ms);
                        }
                        return .{ .worked = true, .position_changed = position_changed };
                    }
                    self.paged.builderPtr().?.end() catch |err| {
                        if (err == error.PageFull) self.pageCompleted(now_ms) else self.failChapter(.page_limit);
                        return .{ .worked = true };
                    };
                    self.chapter_end = true;
                    self.paged.chapter_end = true;
                    if (self.paged.finishChapter() == .at_limit) {
                        self.failChapter(.page_limit);
                        return .{ .worked = true };
                    }
                    if (self.scroll_align_chapter_end) {
                        self.paged.clampScrollAtChapterEnd(self.scrollGeometry());
                        self.scroll_align_chapter_end = false;
                    }
                    stream.finish() catch {
                        self.failChapter(.archive);
                        return .{ .worked = true };
                    };
                    self.observeVerifiedChapterTotal(self.paged.wordCount());
                    self.chapter_pump.decode_workspace.markActiveVerifiedEof();
                    if (!self.paged.isRescanning() and !self.paged.current_ready and !self.paged.next_ready) {
                        if (self.nextReadableChapter()) |next| {
                            self.openChapter(next, .normal);
                        } else self.failChapter(.no_supported_text);
                        return .{ .worked = true };
                    }
                    return .{ .worked = true, .request_prefetch = !self.paged.isRescanning() };
                },
                .yielded => return .{ .worked = true },
                .needs_input => {
                    self.failChapter(.archive);
                    return .{ .worked = true };
                },
            }
        }
        return .{ .worked = true };
    }

    fn chapterIsReconstructing(self: *const ReaderCoordinator) bool {
        return switch (self.mode) {
            .paged => self.paged.isReconstructing(),
            .rsvp => self.rsvp_reader.isReconstructing(),
        };
    }

    fn chapterWorkBudget(self: *const ReaderCoordinator) usize {
        if (self.isFastRsvpReturnRestore()) return rsvp_return_reconstruction_bytes_per_update;
        return if (self.chapterIsReconstructing()) limits.reconstruction_bytes_per_update else limits.forward_chapter_bytes_per_update;
    }

    fn isFastRsvpReturnRestore(self: *const ReaderCoordinator) bool {
        return self.rsvp_return_fast_restore and self.mode == .paged and self.paged.isReconstructing();
    }

    fn pageCompleted(self: *ReaderCoordinator, now_ms: u32) void {
        if (builtin.is_test) self.telemetry.pageCompleted(now_ms);
        self.paged.pageCompleted(if (builtin.is_test) self.telemetry.chapter_events else 0, self.paged.sourceOffset());
    }

    fn nextReadableChapter(self: *const ReaderCoordinator) ?u8 {
        var next: usize = @as(usize, self.chapter_index) + 1;
        while (next < self.book_session.publication.spine_len) : (next += 1) {
            if (self.progress_worker.index) |*index| {
                if (index.exact.contains(@intCast(next)) and index.chapter_words[next] == 0) continue;
            }
            return @intCast(next);
        }
        return null;
    }

    fn openRsvpContinuation(self: *ReaderCoordinator, next: u8) void {
        const destination = self.rsvp_tail_return;
        self.openChapter(next, .normal);
        self.rsvp_tail_return = destination;
    }

    fn stopRsvpAtBookEnd(self: *ReaderCoordinator, now_ms: u32) void {
        self.rsvp_reader.stopAutoplay(now_ms, &self.pace);
        self.requestPaceSave();
        self.sound_navigation = null;
    }

    /// An empty suffix is valid. Restore the last readable word through the normal
    /// bounded rebuild.
    fn advancePastEmptyRsvpChapter(self: *ReaderCoordinator, now_ms: u32) void {
        if (self.nextReadableChapter()) |next| {
            self.openRsvpContinuation(next);
        } else if (self.rsvp_tail_return) |destination| {
            self.stopRsvpAtBookEnd(now_ms);
            self.openChapter(destination.chapter, .{ .rsvp_rescan = .{ .word = destination.word } });
            self.pending_mode_word_ordinal = destination.word;
        } else self.failChapter(.no_supported_text);
    }

    /// Reading follows the full spine, regardless of browser filtering. Skip a leading
    /// wrap0000 by filename only; later matches remain readable.
    fn isReadingDestination(self: *const ReaderCoordinator, index: u8) bool {
        if (self.book_session.publication.spine_len > self.book_session.publication.spine.len or index >= self.book_session.publication.spine_len) return false;
        return index != 0 or !chapter_browser.isCoverWrapper(self.book_session.publication.spine[index].slice());
    }

    fn previousReadableChapter(self: *const ReaderCoordinator) ?u8 {
        if (self.chapter_index == 0 or self.chapter_index >= self.book_session.publication.spine_len or self.book_session.publication.spine_len > self.book_session.publication.spine.len) return null;
        var index = self.chapter_index;
        while (index != 0) {
            index -= 1;
            if (self.isReadingDestination(index)) return index;
        }
        return null;
    }

    fn beginOpenedChapter(self: *ReaderCoordinator, archive: zip.Archive, index: u8, entry: zip.Entry, now_ms: u32, scroll_rescan_target: ?u32) !void {
        try self.chapter_pump.begin(archive, entry);
        self.chapter_index = index;
        self.progress_worker.setCurrentChapter(index) catch {};
        if (scroll_rescan_target) |target| {
            if (!self.paged.beginScrollRescan(reader_layout.text_width, paginationMeasure(self), target)) return error.ScrollRescanUnavailable;
        } else self.paged.begin(index, reader_layout.text_width, paginationMeasure(self));
        self.chapter_end = false;
        if (builtin.is_test) self.telemetry.chapterStarted(now_ms);
        if (self.mode == .rsvp) {
            self.paged.builder = null;
            self.paged.extractor = null;
            self.rsvp_reader.begin(index);
        }
    }

    fn observeVerifiedChapterTotal(self: *ReaderCoordinator, words: u32) void {
        const changed = self.progress_worker.observeChapterTotal(self.chapter_index, words) catch return;
        if (!changed) return;
        if (self.persistence) |*service| service.requestWrite(.progress, self.frame_now_ms, save_debounce_ms, save_max_dirty_ms);
    }

    pub fn cancelChapter(self: *ReaderCoordinator) void {
        self.rsvp_tail_return = null;
        self.sound_navigation = null;
        self.cancelChapterWork();
    }

    fn cancelChapterWork(self: *ReaderCoordinator) void {
        self.chapter_pump.chapter_open = null;
        self.chapter_pump.cancel(if (self.host) |host| host.files else null);
    }

    /// Verified EOF releases the file and shared decode buffers for prefetch.
    pub fn releaseChapterLease(self: *ReaderCoordinator) void {
        self.chapter_pump.releaseChapterLease(if (self.host) |host| host.files else null);
    }

    pub fn startPrefetch(self: *ReaderCoordinator) bool {
        if (!self.paged.next_ready or self.chapter_index + 1 >= self.book_session.publication.spine_len or self.paged.prefetch.isPrefetching()) return false;
        if (self.chapter_pump.decode_workspace.beginPrefetch() != .acquired) return false;
        self.releaseActivePrefetch();
        self.releaseChapterLease();
        const files = self.host.?.files orelse {
            self.chapter_pump.decode_workspace.release(.prefetch);
            return false;
        };
        const reader = files.open(files.context, .prefetch, self.active_book.zSlice()) catch {
            self.chapter_pump.decode_workspace.release(.prefetch);
            return false;
        };
        self.paged.prefetch.attachFile(.{ .context = self, .close = closePrefetchHostLease });
        if (self.book_session.descriptors.ready) {
            const archive = self.book_session.descriptors.bind(reader) catch {
                self.cancelPrefetch();
                return false;
            };
            const entry = self.book_session.descriptors.chapter(self.chapter_index + 1) catch {
                self.cancelPrefetch();
                return false;
            };
            self.paged.prefetch.startResolvedLookup(self.chapter_index + 1, archive, entry) catch {
                self.cancelPrefetch();
                return false;
            };
            return true;
        }
        self.paged.prefetch.startLookup(self.chapter_index + 1, reader) catch {
            self.cancelPrefetch();
            return false;
        };
        return true;
    }

    pub fn cancelPrefetch(self: *ReaderCoordinator) void {
        if (self.paged.prefetch.state == .active) {
            self.releaseActivePrefetch();
            return;
        }
        self.paged.prefetch.cancel();
        self.paged.releasePrefetchPage();
        if (self.chapter_pump.decode_workspace.owner == .prefetch) self.chapter_pump.decode_workspace.release(.prefetch);
    }

    /// Prefetch failure is recoverable: open the chapter normally when the boundary is
    /// requested.
    pub fn stepPrefetch(self: *ReaderCoordinator) void {
        if (self.paged.prefetch.state == .looking_up) {
            const next = self.chapter_index + 1;
            if (next >= self.book_session.publication.spine_len) {
                self.cancelPrefetch();
                self.openPendingPrefetchTransition();
                return;
            }
            switch (self.paged.prefetch.stepLookup(&self.chapter_pump.archive_scan_buffer, &self.chapter_pump.archive_filename_buffer, self.book_session.publication.spine[next].slice(), prefetch_directory_records_per_step)) {
                .working => return,
                .missing, .failed => {
                    self.cancelPrefetch();
                    self.openPendingPrefetchTransition();
                    return;
                },
                .found => |found| {
                    const reserved = self.paged.reservePrefetchPage(found.chapter) orelse {
                        self.cancelPrefetch();
                        self.openPendingPrefetchTransition();
                        return;
                    };
                    self.paged.prefetch.begin(
                        found.archive,
                        found.entry,
                        found.chapter,
                        reserved.slot,
                        reserved.page,
                        &self.chapter_pump.deflate_input_buffer,
                        &self.chapter_pump.deflate_window,
                        &self.chapter_pump.deflate_workspace,
                        reader_layout.text_width,
                        paginationMeasure(self),
                    ) catch {
                        self.cancelPrefetch();
                        self.openPendingPrefetchTransition();
                        return;
                    };
                },
            }
        }
        if (!self.paged.prefetch.isPrefetching()) return;
        switch (self.paged.prefetch.step(&self.chapter_pump.chapter_output, limits.prefetch_bytes_per_update)) {
            .working => {},
            .ready => {
                if (self.pending_prefetch_transition != null) _ = self.activatePrefetch();
            },
            .failed => {
                self.cancelPrefetch();
                self.openPendingPrefetchTransition();
            },
        }
    }

    pub fn prefetchedChapter(self: *const ReaderCoordinator) ?u8 {
        return self.paged.prefetch.readyChapter();
    }

    pub fn requestNextChapter(self: *ReaderCoordinator) void {
        if (self.chapter_index + 1 >= self.book_session.publication.spine_len) return;
        if (self.sound_navigation == null) self.beginSoundNavigation(1, false);
        const next = self.chapter_index + 1;
        if (self.paged.prefetch.isReady()) {
            _ = self.activatePrefetch();
        } else if (self.paged.prefetch.isPrefetching()) {
            self.pending_prefetch_transition = next;
        } else {
            self.openChapter(next, .normal);
        }
    }

    pub fn requestedChapter(self: *const ReaderCoordinator) ?u8 {
        return if (self.chapter_pump.chapter_open) |job| job.index else null;
    }

    /// Promote without moving the file handle; the ZIP reader borrows its address.
    pub fn activatePrefetch(self: *ReaderCoordinator) bool {
        const prepared = self.paged.prefetch.activate() orelse return false;
        self.pending_prefetch_transition = null;
        self.chapter_pump.adoptPrefetch(&self.paged.prefetch, if (self.host) |host| host.files else null);
        self.paged.builder = self.paged.prefetch.builder;
        self.paged.adoptExtractor(self.paged.prefetch.extractor.?);
        self.chapter_index = prepared.chapter;
        self.scroll_chapter_end_overscroll_px = 0;
        self.paged.activatePrefetchedPage(prepared.page, prepared.chapter, prepared.ended);
        self.chapter_end = prepared.ended;
        self.paged.recordCheckpoint(0, if (builtin.is_test) self.telemetry.chapter_events else 0, self.paged.sourceOffset());
        if (prepared.ended) self.chapter_pump.decode_workspace.markActiveVerifiedEof();
        return true;
    }

    fn openPendingPrefetchTransition(self: *ReaderCoordinator) void {
        const index = self.pending_prefetch_transition orelse return;
        self.pending_prefetch_transition = null;
        if (index < self.book_session.publication.spine_len and index == self.chapter_index + 1) self.openChapter(index, .normal);
    }

    fn releaseActivePrefetch(self: *ReaderCoordinator) void {
        if (self.paged.prefetch.state != .active) return;
        self.chapter_pump.releasePrefetchLease(if (self.host) |host| host.files else null);
        self.paged.prefetch.releaseActive();
        if (self.chapter_pump.decode_workspace.owner == .active) self.chapter_pump.decode_workspace.release(.active);
    }

    pub fn activeChapter(self: *const ReaderCoordinator) ?u8 {
        return if (self.chapter_pump.chapter_stream != null and self.chapter_pump.chapter_open == null) self.chapter_index else null;
    }

    fn failChapter(self: *ReaderCoordinator, failure: ChapterFailure) void {
        if (self.paged.isScrollRescanning() or (self.chapter_pump.chapter_open != null and self.chapter_pump.chapter_open.?.action == .scroll_rescan)) {
            self.paged.markScrollPreviousUnavailable();
            self.cancelChapter();
            return;
        }
        self.manual_pace.discard();
        self.sound_navigation = null;
        self.sound_opening_started = null;
        if (self.lifecycle != .chapter_error) self.emitSound(.failure);
        self.chapter_failure = failure;
        self.paged.current_ready = false;
        self.paged.next_ready = false;
        self.chapter_end = true;
        self.lifecycle = .chapter_error;
        self.cancelChapter();
    }

    /// Preserve the visible Scroll viewport while rebuilding the missing predecessor.
    pub fn beginScrollPreviousReconstruction(self: *ReaderCoordinator) bool {
        if (self.lifecycle != .ready or self.chapter_pump.chapter_open != null) return false;
        const target = self.paged.scrollPreviousRescanTarget() orelse return false;
        self.openChapter(self.chapter_index, .{ .scroll_rescan = target });
        return true;
    }

    fn beginMetadataRead(self: *ReaderCoordinator, job: *opening_session.Session, entry: zip.Entry, target: opening_session.MetadataTarget) zip.Error!void {
        self.chapter_pump.opening_storage = zip.StreamStorage.init(&self.chapter_pump.deflate_input_buffer, &self.chapter_pump.deflate_window, &self.chapter_pump.deflate_workspace);
        job.stream = try job.archive.?.begin(entry, &self.chapter_pump.opening_storage);
        job.beginMetadataRead(target);
    }

    fn advanceMetadataRead(self: *ReaderCoordinator, job: *opening_session.Session, target: opening_session.MetadataTarget, decoder_budget: *zip.WorkBudget) bool {
        const result = job.stream.?.readWithBudget(&job.output, decoder_budget) catch |err| {
            self.failMetadataOpening(target, .read, err);
            return false;
        };
        switch (result) {
            .bytes => |count| {
                job.appendMetadataBytes(job.output[0..count]) catch {
                    switch (target) {
                        .mimetype => self.failOpening(.invalid_mimetype),
                        .container => self.failInvalidOpening(.container_buffer),
                        .package => self.failInvalidOpening(.package_buffer),
                    }
                };
                return false;
            },
            .end => {
                job.stream.?.finish() catch |err| {
                    self.failMetadataOpening(target, .finish, err);
                    return false;
                };
                return true;
            },
            .yielded => return false,
            .needs_input => {
                self.failMetadataOpening(target, .read, error.InflateFailed);
                return false;
            },
        }
    }

    fn advanceMetadataReadBatch(self: *ReaderCoordinator, job: *opening_session.Session, target: opening_session.MetadataTarget) bool {
        var decoder_budget = zip.WorkBudget{};
        for (0..limits.opening_metadata_chunks_per_update) |_| {
            if (self.advanceMetadataRead(job, target, &decoder_budget)) return true;
            if (self.book_session.opening_job == null) return false;
        }
        return false;
    }

    const MetadataFailureOperation = enum { read, finish };

    fn failMetadataOpening(self: *ReaderCoordinator, target: opening_session.MetadataTarget, operation: MetadataFailureOperation, err: zip.Error) void {
        switch (target) {
            .mimetype => self.failOpening(.invalid_mimetype),
            .container => self.failInvalidOpening(if (operation == .read) .{ .container_read = err } else .{ .container_finish = err }),
            .package => self.failInvalidOpening(if (operation == .read) .{ .package_read = err } else .{ .package_finish = err }),
        }
    }

    fn failInvalidOpening(self: *ReaderCoordinator, detail: OpeningFailure) void {
        self.opening_failure = detail;
        self.failOpening(.invalid_archive);
    }

    fn failOpening(self: *ReaderCoordinator, failure: Lifecycle) void {
        self.manual_pace.discard();
        self.releaseOpeningJob();
        self.opening_chapter_request = null;
        self.sound_navigation = null;
        self.sound_opening_started = null;
        self.emitSound(.failure);
        self.lifecycle = failure;
    }

    /// Handle input before background work and due saves.
    pub fn update(self: *ReaderCoordinator, frame: FrameInput, now_ms: u32) void {
        if (self.library_refresh_pending and self.screen == .library) self.discoverLibrary();
        self.frame_now_ms = now_ms;
        self.reduce_flashing = frame.reduce_flashing;
        const transition_from = self.pagedFramePosition();
        const crank_context = self.crankContext();
        self.updateCrankDockState(frame.crank_docked);
        const intent = intentFor(.{
            .screen = self.screen,
            .readiness = if (self.lifecycle == .chapter_error) .chapter_error else if (self.lifecycle == .opening) .opening else if (self.lifecycle == .ready) .ready else .opening_failure,
            .mode = self.mode,
            .paged_presentation = if (self.paged_presentation == .scroll) .scroll else .pages,
            .buttons = frame.buttons,
            .book_loading = self.book_loading,
        });
        self.performIntent(intent, now_ms);
        self.advanceStatisticsTransition(now_ms);
        self.updateResetHold(frame.a_held, frame.buttons.a, now_ms);
        // An input action may have just entered Library. Scan before rendering its
        // first frame, while keeping discovery out of reader teardown.
        if (self.library_refresh_pending and self.screen == .library) self.discoverLibrary();
        // A screen-changing action can precede this frame's crank sample. That sample
        // still belongs to the previous controls.
        if (std.meta.eql(crank_context, self.crankContext())) self.handleCrank(frame.crank_change, now_ms);
        self.relaxScrollChapterEndOverscroll(frame.crank_change);
        self.advanceAutoplay(now_ms);

        self.advanceOpening();
        const measuring_chapter = builtin.is_test and self.book_loading and self.telemetry.loading.metadata_ms != null;
        if (measuring_chapter) self.telemetry.loading.stepStarted(if (self.chapterIsReconstructing() or self.scroll_restore_pending != null) .resume_rebuild else .chapter, self.clockMilliseconds());
        if (self.takeOpeningChapterRequest()) |chapter| {
            self.openChapter(chapter, .normal);
            self.restorePosition();
        }
        if (self.mode == .paged and self.paged_presentation == .scroll and self.paged.pending_selection == null) {
            self.paged.prepareScrollAhead(self.scrollGeometry());
        }
        const chapter = self.stepChapter(now_ms);
        if (chapter.position_changed) self.requestPositionSave();
        self.resumeScrollBackwardAfterChapterWork(chapter.worked);
        self.resumeScrollForwardAfterChapterWork(chapter.worked, now_ms);
        if (chapter.request_prefetch) _ = self.startPrefetch();
        self.fulfillPendingPagedSelection();
        self.resolveScrollRestoreBarrier();
        if (self.mode == .paged and !self.crank_docked) {
            if (self.paged_presentation == .scroll) self.drainScrollDetents(now_ms) else self.drainPagedDetents(now_ms);
        }
        const prefetch_worked = self.paged.prefetch.isPrefetching();
        self.stepPrefetch();
        if (measuring_chapter) self.telemetry.loading.stepFinished(self.clockMilliseconds());
        self.finishBookLoading();
        self.flushPublicationCache(chapter.worked or prefetch_worked);
        self.stepProgressIndex(chapter.worked or prefetch_worked);
        self.stepLibraryProgress();
        self.observeEndProgress();
        self.syncManualPace(now_ms);
        self.flushPersistence();
        self.updatePageTransition(transition_from, frame.reduce_flashing, now_ms);
        self.observeSoundDestination(now_ms);
    }

    const PagedFramePosition = struct { chapter: u8, page: u32 };

    fn pagedFramePosition(self: *const ReaderCoordinator) ?PagedFramePosition {
        if (self.screen != .reading or self.lifecycle != .ready or self.mode != .paged or self.paged_presentation != .pages or !self.paged.current_ready) return null;
        return .{ .chapter = self.chapter_index, .page = self.paged.page_index };
    }

    fn updatePageTransition(self: *ReaderCoordinator, before: ?PagedFramePosition, reduce_flashing: bool, now_ms: u32) void {
        if (self.restore_transition_pending) {
            if (self.screen != .reading or self.lifecycle != .ready or self.mode != .paged or self.paged_presentation != .pages) {
                self.restore_transition_pending = false;
                self.page_transition_state.cancel();
                return;
            }
            _ = self.pagedFramePosition() orelse return;
            if (self.chapter_pump.chapter_open != null or self.paged.isReconstructing() or self.paged.pending_selection != null) return;
            self.restore_transition_pending = false;
            if (reduce_flashing) {
                self.page_transition_state.cancel();
            } else self.page_transition_state.beginStyled(null, .forward, self.page_animation, now_ms);
            return;
        }
        const after = self.pagedFramePosition() orelse {
            self.page_transition_state.cancel();
            return;
        };
        if (reduce_flashing) {
            self.page_transition_state.cancel();
            return;
        }
        const from = before orelse return;
        if (from.chapter != after.chapter or from.page == after.page) return;
        if (self.paged.cachedPage(from.page) == null) return;
        self.page_transition_state.beginStyled(from.page, if (after.page > from.page) .forward else .backward, self.page_animation, now_ms);
    }

    fn finishBookLoading(self: *ReaderCoordinator) void {
        if (!self.book_loading or self.lifecycle != .ready) return;
        if (self.screen == .chapter_browser) {
            self.book_loading = false;
            if (builtin.is_test) self.telemetry.loading.destinationReady(self.clockMilliseconds());
            return;
        }
        const has_text = if (self.mode == .paged) self.paged.current_ready else self.rsvp_reader.hasWord();
        if (builtin.is_test and has_text) self.telemetry.loading.textAvailable(self.clockMilliseconds());
        if (self.mode == .paged and self.paged_presentation == .scroll and !self.paged.scrollViewportReady(self.scrollGeometry())) return;
        if (has_text and self.chapter_pump.chapter_open == null and !self.chapterIsReconstructing() and self.paged.pending_selection == null and self.scroll_restore_pending == null and self.pending_mode_word_ordinal == null) {
            self.book_loading = false;
            if (builtin.is_test) self.telemetry.loading.destinationReady(self.clockMilliseconds());
        }
    }

    fn stepProgressIndex(self: *ReaderCoordinator, foreground_worked: bool) void {
        const may_index_behind_screen = self.screen == .reading or self.screen == .statistics;
        if (foreground_worked or !may_index_behind_screen or self.lifecycle != .ready) return;
        if (self.chapterIsReconstructing()) return;
        if (self.paged.pending_selection != null or self.paged.detent_backlog != 0 or self.pending_prefetch_transition != null) return;

        switch (self.progress_worker.update(progress_indexer.default_byte_budget)) {
            .chapter_complete, .chapter_failed => {
                if (self.persistence) |*service| service.requestWrite(.progress, self.frame_now_ms, save_debounce_ms, save_max_dirty_ms);
            },
            else => {},
        }
    }

    fn visibleManualPaceAnchor(self: *const ReaderCoordinator) ?reading_pace.ManualAnchor {
        if (self.screen != .reading or self.lifecycle != .ready or self.chapter_pump.chapter_open != null) return null;
        return switch (self.mode) {
            .paged => blk: {
                if (self.paged.isReconstructing() or self.paged.pending_selection != null) break :blk null;
                if (self.paged_presentation == .scroll) {
                    const word = self.paged.scrollFirstVisibleWord(self.scrollGeometry()) orelse break :blk null;
                    break :blk .{ .scroll = .{ .chapter = self.chapter_index, .word = word } };
                }
                _ = self.paged.current() orelse break :blk null;
                break :blk .{ .paged = .{ .chapter = self.chapter_index, .page = self.paged.page_index } };
            },
            .rsvp => blk: {
                if (self.rsvp_reader.timer.running or self.rsvp_reader.isReconstructing() or !self.rsvp_reader.hasWord()) break :blk null;
                break :blk .{ .rsvp = .{ .chapter = self.chapter_index, .word = self.rsvp_reader.position().word } };
            },
        };
    }

    fn syncManualPace(self: *ReaderCoordinator, now_ms: u32) void {
        const anchor = self.visibleManualPaceAnchor() orelse {
            self.manual_pace.discard();
            return;
        };
        self.manual_pace.observe(anchor, now_ms);
    }

    fn recordManualPace(self: *ReaderCoordinator, anchor: ?reading_pace.ManualAnchor, now_ms: u32, completed_words: u32) void {
        const observed = anchor orelse return;
        if (!self.manual_pace.recordForward(&self.pace, observed, now_ms, completed_words)) return;
        self.requestPaceSave();
    }

    pub fn systemPaused(self: *ReaderCoordinator, now_ms: u32) void {
        self.sound_events.clear();
        self.sound_navigation = null;
        self.sound_opening_started = null;
        self.frame_now_ms = now_ms;
        self.manual_pace.discard();
        self.stopAutoplayAccounting(now_ms);
        self.clearTransientCrank();
        // Keep the Library browser's provisional chapter zero out of resume saves.
        // During restoration, save the target rather than the reconstruction cursor.
        if (self.hasPositionToFlushOnPause()) self.flushPositionNow();
        self.flushPaceNow();
        self.flushProgressNow();
    }

    fn hasPositionToFlushOnPause(self: *const ReaderCoordinator) bool {
        return (reading_location.SaveEligibility{
            .ready = self.lifecycle == .ready,
            .provisional_browser = self.chapter_browser_from_library,
            .suppressed = self.position_save_suppressed,
            .has_book = self.active_book.slice().len != 0,
            .chapter_in_spine = self.lifecycle == .ready and self.chapter_index < self.book_session.publication.spine_len,
            .pending_semantic_target = self.pending_mode_word_ordinal != null,
            .drawable_position = self.chapter_pump.chapter_open == null and switch (self.mode) {
                .paged => !self.paged.isReconstructing() and self.paged.current() != null,
                .rsvp => !self.rsvp_reader.isReconstructing() and self.rsvp_reader.hasWord(),
            },
        }).canFlush();
    }

    pub fn systemResumed(self: *ReaderCoordinator) void {
        self.library_refresh_pending = true;
        self.manual_pace.discard();
        self.clearTransientCrank();
    }

    pub fn canToggleReadingMode(self: *const ReaderCoordinator) bool {
        return self.screen == .reading and self.lifecycle == .ready and !self.book_loading and self.active_book.slice().len != 0;
    }

    pub fn handleSystemAction(self: *ReaderCoordinator, action: SystemAction, now_ms: u32) void {
        self.frame_now_ms = now_ms;
        switch (action) {
            .toggle_reading_mode => {
                if (self.canToggleReadingMode()) self.switchReadingMode(now_ms);
            },
            .settings => {
                if (self.screen == .reading) self.stopAutoplayAccounting(now_ms);
                _ = self.openSettings();
            },
        }
    }

    fn performIntent(self: *ReaderCoordinator, intent: input.Intent, now_ms: u32) void {
        const old_library = self.library.selected;
        const old_chapter = self.chapter_browser.selected;
        defer {
            if (self.screen == .library and self.library.selected != old_library) self.emitSound(.selection);
            if (self.screen == .chapter_browser and self.chapter_browser.selected != old_chapter) self.emitSound(.selection);
            if (intent == .activate_setting and self.settings_menu_state.selected != .reset_progress and self.settings_menu_state.selected != .paged_presentation) self.emitSound(.accepted);
        }
        switch (intent) {
            .none => {},
            .library_next => self.library.move(1),
            .library_previous => self.library.move(-1),
            .open_selected_book => _ = self.openBookActions(),
            .close_book_actions => _ = self.closeBookActions(),
            .book_action_next => self.moveBookAction(1),
            .book_action_previous => self.moveBookAction(-1),
            .activate_book_action => switch (self.book_action_selected) {
                .start_or_resume => _ = self.openSelectedBook(),
                .chapters => _ = self.openSelectedBookAtChapters(),
            },
            .return_to_library => {
                // Opening has no new position to save, including initial chapter
                // reconstruction.
                if (self.screen == .opening or self.book_loading) {
                    self.leaveBookPreservingPosition(now_ms);
                } else self.leaveBook(now_ms);
            },
            .open_settings => _ = self.openSettings(),
            .open_statistics => _ = self.openReadingStatistics(now_ms),
            .close_settings => _ = self.closeSettings(),
            .close_statistics => _ = self.closeStatistics(now_ms),
            .close_chapter_browser => _ = self.closeChapterBrowser(now_ms),
            .chapter_browser_next => self.chapter_browser.move(1),
            .chapter_browser_previous => self.chapter_browser.move(-1),
            .open_browser_chapter => {
                if (self.chapter_browser.entry_count == 0) return;
                const selected = self.spineIndexForBrowserPosition(self.chapter_browser.selected) orelse return;
                self.chapter_browser_from_library = false;
                self.beginReading();
                self.sound_navigation = null;
                self.sound_opening_started = null;
                self.emitSound(.chapter_changed);
                self.openChapter(selected, .normal);
                self.lifecycle = .ready;
            },
            .settings_next => self.moveSettingsSelection(1),
            .settings_previous => self.moveSettingsSelection(-1),
            .activate_setting => switch (self.settings_menu_state.selected) {
                .paged_presentation => self.switchPagedPresentation(),
                .page_animation => {
                    self.page_animation = self.page_animation.next();
                    self.page_transition_state.cancel();
                    self.saveSettings();
                },
                .sound => {
                    self.sound_level = switch (self.sound_level) {
                        .off => .subtle,
                        .subtle => .full,
                        .full => .off,
                    };
                    self.saveSettings();
                },
                .theme => {
                    self.theme = if (self.theme == .light) .dark else .light;
                    self.saveSettings();
                },
                .pages_font => self.switchPagesFont(),
                .rsvp_font => self.switchRsvpFont(),
                .progress_visibility => {
                    self.progress_visibility = if (self.progress_visibility == .off) .on else .off;
                    self.saveSettings();
                },
                .progress_position => {
                    self.progress_position = if (self.progress_position == .top) .bottom else .top;
                    self.saveSettings();
                },
                .progress_scope => {
                    self.progress_scope = switch (self.progress_scope) {
                        .chapter => .book,
                        .book => .both,
                        .both => .chapter,
                    };
                    self.saveSettings();
                },
                .reset_progress => {},
            },
            .toggle_reading_mode => self.switchReadingMode(now_ms),
            .rsvp_toggle_autoplay => if (self.screen == .reading and self.mode == .rsvp) {
                self.clearTransientCrank();
                self.rsvp_reader.toggleAutoplay(now_ms, &self.pace);
                self.emitSound(if (self.rsvp_reader.timer.running) .autoplay_started else .autoplay_paused);
            },
            .rsvp_wpm_up => self.adjustRsvpWpm(1, now_ms),
            .rsvp_wpm_down => self.adjustRsvpWpm(-1, now_ms),
            .rsvp_previous_sentence => self.previousRsvpSentence(now_ms),
            .next_page => {
                self.paged.pending_selection = null;
                if (self.lifecycle == .ready and self.chapter_pump.chapter_open == null) {
                    const pace_anchor = self.visibleManualPaceAnchor();
                    const completed_words = if (self.paged.current()) |page| page.completedWordCount() else 0;
                    self.beginSoundNavigation(1, false);
                    const move = self.paged.nextPage();
                    if (move == .moved or (move == .needs_next_chapter and self.chapter_index + 1 < self.book_session.publication.spine_len)) {
                        self.recordManualPace(pace_anchor, now_ms, completed_words);
                    }
                    const changes_position = switch (move) {
                        .moved, .needs_reconstruction => true,
                        .needs_next_chapter => self.chapter_index + 1 < self.book_session.publication.spine_len,
                        .needs_previous_chapter, .waiting, .at_limit => false,
                    };
                    self.handlePagedMove(move);
                    if (move == .waiting) self.sound_navigation = null;
                    if (changes_position) self.requestPositionSaveAfterReadingMovement();
                }
            },
            .previous_page => {
                self.manual_pace.discard();
                self.paged.pending_selection = null;
                if (self.lifecycle == .ready and self.chapter_pump.chapter_open == null) {
                    self.beginSoundNavigation(-1, false);
                    const move = self.paged.previousPage();
                    const changes_position = switch (move) {
                        .moved, .needs_reconstruction => true,
                        .needs_previous_chapter => self.previousReadableChapter() != null,
                        .needs_next_chapter, .waiting, .at_limit => false,
                    };
                    self.handlePagedMove(move);
                    if (move == .waiting) self.sound_navigation = null;
                    if (changes_position) self.requestPositionSaveAfterReadingMovement();
                }
            },
            .next_chapter => self.openAdjacentChapter(1),
            .previous_chapter => self.openAdjacentChapter(-1),
        }
    }

    fn switchReadingMode(self: *ReaderCoordinator, now_ms: u32) void {
        self.sound_navigation = null;
        self.sound_events.push(.{ .kind = .mode_changed, .direction = if (self.mode == .paged) 1 else -1 });
        const returning_from_rsvp = self.mode == .rsvp;
        const target_word = if (self.mode == .paged)
            reader_transitions.pagedModeSwitchOrdinal(self.currentPagedWordOrdinal(), self.paged.pending_selection)
        else
            self.rsvp_reader.position().word;
        self.toggleMode();
        self.stopAutoplayAccounting(now_ms);
        self.paged.pending_selection = null;
        self.manual_pace.discard();
        self.pending_mode_word_ordinal = target_word;
        self.restore_transition_pending = false;
        self.scroll_restore_pending = null;
        if (self.lifecycle == .ready) {
            switch (self.mode) {
                .paged => {
                    // Hide provisional pages until the RSVP word is drawable in Pages
                    // or Scroll.
                    self.restore_transition_pending = self.paged_presentation == .pages;
                    self.scroll_restore_pending = if (self.paged_presentation == .scroll) .{ .word = target_word } else null;
                    self.paged.pending_selection = .{ .ordinal = target_word };
                    self.openChapter(self.chapter_index, .{ .word_rescan = target_word });
                    self.mode_switch_loading = true;
                    self.rsvp_return_fast_restore = returning_from_rsvp;
                },
                .rsvp => {
                    self.openChapter(self.chapter_index, .{ .rsvp_rescan = .{ .word = target_word } });
                    self.mode_switch_loading = true;
                },
            }
            self.requestPositionSave();
        }
        self.saveSettings();
    }

    fn switchPagedPresentation(self: *ReaderCoordinator) void {
        self.sound_navigation = null;
        self.sound_events.push(.{ .kind = .presentation_changed, .direction = if (self.paged_presentation == .pages) 1 else -1 });
        const word = self.currentPagedWordOrdinal();
        self.clearTransientCrank();
        self.paged_presentation = switch (self.paged_presentation) {
            .pages => .scroll,
            .scroll => .pages,
        };
        self.manual_pace.discard();
        if (self.mode == .paged and self.lifecycle == .ready) {
            switch (self.paged_presentation) {
                .pages => {
                    _ = self.paged.showScrollTopPage();
                    self.paged.selected_word_ordinal = word;
                },
                .scroll => self.paged.beginScrollAtWord(word, self.scrollGeometry()),
            }
            self.requestPositionSave();
        }
        self.saveSettings();
    }

    fn switchPagesFont(self: *ReaderCoordinator) void {
        self.sound_navigation = null;
        self.pages_font = persistence.nextPagesFont(self.pages_font);
        self.saveSettings();
        if (self.lifecycle != .ready or self.mode != .paged) return;

        const target_word = reader_transitions.pagedModeSwitchOrdinal(self.currentPagedWordOrdinal(), self.paged.pending_selection);
        self.pending_mode_word_ordinal = target_word;
        self.paged.pending_selection = .{ .ordinal = target_word };
        self.paged.clearScrollTransient();
        self.scroll_crank_millidegrees = 0;
        self.openChapter(self.chapter_index, .{ .word_rescan = target_word });
        self.requestPositionSave();
    }

    fn switchRsvpFont(self: *ReaderCoordinator) void {
        self.rsvp_font = persistence.nextRsvpFont(self.rsvp_font);
        self.saveSettings();
        if (self.mode == .rsvp) self.manual_pace.discard();
    }

    fn adjustRsvpWpm(self: *ReaderCoordinator, direction: i8, now_ms: u32) void {
        if (self.screen != .reading or self.mode != .rsvp) return;
        self.manual_pace.discard();
        if (!self.rsvp_reader.adjustWpm(direction, now_ms, &self.pace)) return;
        self.sound_events.push(.{ .kind = .wpm_changed, .direction = direction });
        self.requestPaceSave();
        self.saveSettings();
    }

    fn advanceAutoplay(self: *ReaderCoordinator, now_ms: u32) void {
        if (self.screen != .reading or self.mode != .rsvp) return;
        if (self.rsvp_reader.autoplay(now_ms, &self.pace)) |move| {
            self.requestPaceSave();
            if (move == .needs_next_chapter) self.beginSoundNavigation(1, true);
            self.handleRsvpMove(move);
        }
    }

    fn previousRsvpSentence(self: *ReaderCoordinator, now_ms: u32) void {
        if (self.lifecycle != .ready or self.chapter_pump.chapter_open != null) return;
        self.manual_pace.discard();
        self.manual_rsvp_wpm.clear();
        self.rsvp_reader.recordAutoplay(now_ms, 0, &self.pace);
        self.requestPaceSave();
        self.rsvp_reader.timer.reset(now_ms);
        const move = self.rsvp_reader.previousSentence();
        if (move == .moved or move == .needs_rescan or move == .needs_word) self.emitSound(.sentence_rewind);
        if (move == .at_limit) self.emitSound(.at_boundary);
        self.sound_navigation = null;
        self.handleRsvpMove(move);
    }

    fn handleCrank(self: *ReaderCoordinator, change: f32, now_ms: u32) void {
        const old_library = self.library.selected;
        const old_chapter = self.chapter_browser.selected;
        defer {
            if (self.screen == .library and self.library.selected != old_library) self.emitSound(.selection);
            if (self.screen == .chapter_browser and self.chapter_browser.selected != old_chapter) self.emitSound(.selection);
        }
        if (self.screen == .library) {
            self.library.move(crankDetents(&self.crank_accumulated, change));
            return;
        }
        if (self.screen == .chapter_browser) {
            self.chapter_browser.move(crankDetents(&self.crank_accumulated, change));
            return;
        }
        if (self.crank_docked) return;
        if (self.screen != .reading or self.lifecycle != .ready or self.chapter_pump.chapter_open != null or self.paged.isRescanning()) return;
        if (self.mode == .rsvp) {
            if (self.rsvp_reader.timer.running) return;
            const direction = crankDirection(&self.crank_accumulated, change);
            const pace_anchor = self.visibleManualPaceAnchor();
            const move = switch (direction) {
                1 => self.rsvp_reader.nextWord(),
                -1 => blk: {
                    self.manual_pace.discard();
                    self.manual_rsvp_wpm.clear();
                    break :blk self.rsvp_reader.previousWord();
                },
                else => return,
            };
            if (direction > 0) switch (move) {
                .moved => {
                    self.manual_rsvp_wpm.record(now_ms);
                    self.recordManualPace(pace_anchor, now_ms, 1);
                },
                .needs_word => {
                    // Forward RSVP input usually requests another streamed word because
                    // decoding stays just ahead of the displayed word.
                    self.manual_rsvp_wpm.record(now_ms);
                    self.recordManualPace(pace_anchor, now_ms, 1);
                },
                .needs_next_chapter => if (self.chapter_index + 1 < self.book_session.publication.spine_len) self.recordManualPace(pace_anchor, now_ms, 1),
                else => {},
            };
            if (move == .needs_next_chapter) self.beginSoundNavigation(1, false);
            if (move == .at_limit or (move == .needs_next_chapter and self.nextReadableChapter() == null)) self.emitSound(.at_boundary);
            self.handleRsvpMove(move);
            return;
        }
        if (self.paged_presentation == .scroll) {
            const pixels = scrollPixelsForCrank(&self.scroll_crank_millidegrees, change);
            if (pixels == 0) return;
            const direction: scroll_geometry.Direction = if (pixels > 0) .forward else .backward;
            const magnitude: u16 = @intCast(if (pixels < 0) -@as(i32, pixels) else pixels);
            self.moveScrollPixels(direction, magnitude, now_ms);
            return;
        }
        self.paged.detent_backlog = saturatingAddDetents(self.paged.detent_backlog, crankDetents(&self.crank_accumulated, change));
        self.drainPagedDetents(now_ms);
    }

    fn updateCrankDockState(self: *ReaderCoordinator, docked: bool) void {
        if (self.crank_docked == docked) return;
        self.crank_docked = docked;
        self.crank_accumulated = 0;
        self.scroll_crank_millidegrees = 0;
        self.manual_rsvp_wpm.clear();
        if (docked) {
            if (self.screen == .reading and self.lifecycle == .ready and self.mode == .paged and self.paged_presentation == .pages and self.paged.current_ready and self.paged.selected_word_ordinal != null) self.word_highlight_dismiss_nonce +%= 1;
            self.paged.detent_backlog = 0;
            self.paged.clearScrollTransient();
        } else self.requestWordSpotlight();
    }

    fn requestWordSpotlight(self: *ReaderCoordinator) void {
        if (self.screen != .reading or self.lifecycle != .ready or self.mode != .paged or self.paged_presentation != .pages or self.crank_docked) return;
        self.word_spotlight_nonce +%= 1;
    }

    fn handlePagedMove(self: *ReaderCoordinator, move: paged_reader.PagedReader.Move) void {
        switch (move) {
            .at_limit => {
                self.sound_navigation = null;
                self.emitSound(.at_boundary);
            },
            .needs_reconstruction => self.openChapter(self.chapter_index, .{ .rescan = self.paged.navigation_state.page }),
            .needs_previous_chapter => if (self.previousReadableChapter()) |previous| self.openChapter(previous, .rescan_to_last_page),
            .needs_next_chapter => self.requestNextChapter(),
            .moved, .waiting => {},
        }
        if ((move == .needs_previous_chapter and self.previousReadableChapter() == null) or (move == .needs_next_chapter and self.chapter_index + 1 >= self.book_session.publication.spine_len)) {
            self.sound_navigation = null;
            self.emitSound(.at_boundary);
        }
    }

    fn drainPagedDetents(self: *ReaderCoordinator, now_ms: u32) void {
        while (self.paged.detent_backlog != 0) {
            if (self.paged.pending_selection != null) return;
            const direction: i8 = if (self.paged.detent_backlog > 0) 1 else -1;
            switch (self.movePagedSelection(direction, now_ms)) {
                .advanced => self.paged.detent_backlog -= direction,
                .waiting_for_page => return,
                .at_limit => {
                    self.paged.detent_backlog = 0;
                    return;
                },
            }
        }
    }

    fn moveScrollPixels(self: *ReaderCoordinator, direction: scroll_geometry.Direction, pixels: u16, now_ms: u32) void {
        if (self.screen != .reading or self.mode != .paged or self.paged_presentation != .scroll or self.lifecycle != .ready or self.chapter_pump.chapter_open != null) return;
        var remaining = pixels;
        if (direction == .backward and self.scroll_chapter_end_overscroll_px != 0) {
            const cancelled = @min(remaining, self.scroll_chapter_end_overscroll_px);
            self.scroll_chapter_end_overscroll_px -= cancelled;
            remaining -= cancelled;
            if (remaining == 0) return;
        }
        if (direction == .forward and self.scroll_chapter_start_overscroll_px != 0) {
            const cancelled = @min(remaining, self.scroll_chapter_start_overscroll_px);
            self.scroll_chapter_start_overscroll_px -= cancelled;
            remaining -= cancelled;
            if (remaining == 0) return;
        }
        self.beginSoundNavigation(if (direction == .forward) 1 else -1, false);
        const anchor = self.visibleManualPaceAnchor();
        const before = self.currentPagedWordOrdinal();
        if (direction == .backward) self.manual_pace.discard();
        const move = self.paged.scrollPixels(direction, self.scrollGeometry(), remaining);
        self.handleScrollMove(move);
        if (direction == .forward and move == .at_end) self.extendScrollChapterEndOverscroll(remaining);
        if (direction == .backward and move == .at_start) self.extendScrollChapterStartOverscroll(remaining);
        if (direction == .forward) self.recordScrollForward(anchor, before, now_ms);
    }

    fn extendScrollChapterEndOverscroll(self: *ReaderCoordinator, pixels: u16) void {
        if (self.chapter_index + 1 >= self.book_session.publication.spine_len) return;
        self.scroll_chapter_end_overscroll_px = @min(scroll_chapter_transition_threshold_px, self.scroll_chapter_end_overscroll_px +| pixels);
        if (self.scroll_chapter_end_overscroll_px >= scroll_chapter_transition_threshold_px) {
            self.scroll_chapter_end_overscroll_px = 0;
            self.scroll_chapter_transition_nonce +%= 1;
            self.requestNextChapter();
        }
    }

    fn extendScrollChapterStartOverscroll(self: *ReaderCoordinator, pixels: u16) void {
        if (self.previousReadableChapter() == null) return;
        self.scroll_chapter_start_overscroll_px = @min(scroll_chapter_transition_threshold_px, self.scroll_chapter_start_overscroll_px +| pixels);
        if (self.scroll_chapter_start_overscroll_px >= scroll_chapter_transition_threshold_px) {
            self.scroll_chapter_start_overscroll_px = 0;
            self.scroll_chapter_transition_nonce +%= 1;
            self.openAdjacentChapter(-1);
        }
    }

    /// Decay overscroll without changing the reading position; fresh crank movement
    /// interrupts the return.
    fn relaxScrollChapterEndOverscroll(self: *ReaderCoordinator, crank_change: f32) void {
        if ((self.scroll_chapter_end_overscroll_px == 0 and self.scroll_chapter_start_overscroll_px == 0) or crank_change != 0) return;
        if (self.screen != .reading or self.mode != .paged or self.paged_presentation != .scroll or self.chapter_pump.chapter_open != null) {
            self.scroll_chapter_end_overscroll_px = 0;
            self.scroll_chapter_start_overscroll_px = 0;
            return;
        }
        if (self.scroll_chapter_end_overscroll_px != 0) self.scroll_chapter_end_overscroll_px -|= @max(@as(u16, 1), self.scroll_chapter_end_overscroll_px / 3);
        if (self.scroll_chapter_start_overscroll_px != 0) self.scroll_chapter_start_overscroll_px -|= @max(@as(u16, 1), self.scroll_chapter_start_overscroll_px / 3);
    }

    /// When the missing predecessor arrives, apply the retained displacement to it
    /// without resetting the viewport.
    fn resumeScrollBackwardAfterChapterWork(self: *ReaderCoordinator, worked: bool) void {
        if (!worked or self.screen != .reading or self.lifecycle != .ready or self.mode != .paged or self.paged_presentation != .scroll) return;
        if (self.paged.scrollPosition().waiting_px >= 0) return;
        switch (self.paged.resumeScrollBackward(self.scrollGeometry())) {
            .moved, .at_start => self.requestPositionSaveAfterReadingMovement(),
            .waiting, .at_end, .needs_reconstruction => {},
        }
    }

    fn resumeScrollForwardAfterChapterWork(self: *ReaderCoordinator, worked: bool, now_ms: u32) void {
        if (!worked or self.screen != .reading or self.lifecycle != .ready or self.mode != .paged or self.paged_presentation != .scroll or self.paged.scrollPosition().waiting_px <= 0) return;
        const anchor = self.visibleManualPaceAnchor();
        const before = self.currentPagedWordOrdinal();
        self.handleScrollMove(self.paged.resumeScrollForward(self.scrollGeometry()));
        self.recordScrollForward(anchor, before, now_ms);
    }

    fn drainScrollDetents(self: *ReaderCoordinator, now_ms: u32) void {
        if (self.screen != .reading or self.mode != .paged or self.paged_presentation != .scroll or self.lifecycle != .ready or self.chapter_pump.chapter_open != null) return;
        const pending_detents = self.paged.scrollPosition().pending_detents;
        if (pending_detents == 0) return;
        const forward = pending_detents > 0;
        const anchor = self.visibleManualPaceAnchor();
        const before = self.currentPagedWordOrdinal();
        if (!forward) self.manual_pace.discard();
        const move = if (!forward)
            self.paged.drainScrollBackward(self.scrollGeometry())
        else
            self.paged.drainScrollForward(self.scrollGeometry());
        self.handleScrollMove(move);
        if (forward) self.recordScrollForward(anchor, before, now_ms);
    }

    fn recordScrollForward(self: *ReaderCoordinator, anchor: ?reading_pace.ManualAnchor, before: u32, now_ms: u32) void {
        const after = self.currentPagedWordOrdinal();
        if (after <= before) return;
        self.requestPositionSaveAfterReadingMovement();
        self.recordManualPace(anchor, now_ms, after - before);
    }

    fn handleScrollMove(self: *ReaderCoordinator, move: paged_reader.PagedReader.ScrollMove) void {
        switch (move) {
            .moved, .at_start, .at_end => self.requestPositionSaveAfterReadingMovement(),
            .waiting => {},
            .needs_reconstruction => _ = self.beginScrollPreviousReconstruction(),
        }
    }

    fn movePagedSelection(self: *ReaderCoordinator, direction: i8, now_ms: u32) PagedSelectionMove {
        self.beginSoundNavigation(direction, false);
        const pace_anchor = self.visibleManualPaceAnchor();
        const page_before = self.paged.page_index;
        const completed_words = if (self.paged.current()) |page| page.word_count else 0;
        if (direction < 0) self.manual_pace.discard();
        const has_previous_chapter = direction < 0 and self.previousReadableChapter() != null;
        const move = self.paged.moveSelection(direction, has_previous_chapter, self.chapter_index + 1 < self.book_session.publication.spine_len);
        if (direction > 0 and (self.paged.page_index > page_before or (move == .needs_next_chapter and self.chapter_index + 1 < self.book_session.publication.spine_len))) {
            self.recordManualPace(pace_anchor, now_ms, completed_words);
        }
        self.handlePagedMove(move);
        return switch (move) {
            .moved => blk: {
                self.fulfillPendingPagedSelection();
                if (self.paged.pending_selection == null) {
                    self.requestPositionSaveAfterReadingMovement();
                    break :blk .advanced;
                }
                break :blk .waiting_for_page;
            },
            .at_limit => .at_limit,
            .needs_reconstruction => blk: {
                self.requestPositionSaveAfterReadingMovement();
                break :blk .waiting_for_page;
            },
            .needs_previous_chapter => blk: {
                if (self.previousReadableChapter() != null) self.requestPositionSaveAfterReadingMovement();
                break :blk .waiting_for_page;
            },
            .needs_next_chapter => blk: {
                if (self.chapter_index + 1 < self.book_session.publication.spine_len) self.requestPositionSaveAfterReadingMovement();
                break :blk .waiting_for_page;
            },
            .waiting => .waiting_for_page,
        };
    }

    fn fulfillPendingPagedSelection(self: *ReaderCoordinator) void {
        if (self.mode != .paged or !self.paged.current_ready) return;
        if (!self.paged.fulfillPendingSelection()) {
            if (self.paged.pending_selection) |target| switch (target) {
                .ordinal => |ordinal| if (self.paged.current()) |page| {
                    if (ordinal < page.first_word_ordinal and self.chapter_pump.chapter_open == null) self.openChapter(self.chapter_index, .{ .word_rescan = ordinal });
                },
                .last_word => {},
            };
            return;
        }
        if (self.pending_mode_word_ordinal == self.paged.selected_word_ordinal) self.pending_mode_word_ordinal = null;
        self.mode_switch_loading = false;
        self.rsvp_return_fast_restore = false;
        if (self.paged_presentation == .scroll) self.paged.beginScrollAtWord(self.paged.selected_word_ordinal orelse self.currentPagedWordOrdinal(), self.scrollGeometry());
        self.requestPositionSave();
    }

    fn resolveScrollRestoreBarrier(self: *ReaderCoordinator) void {
        const target = self.scroll_restore_pending orelse return;
        switch (target) {
            .word => {
                // Clear pending selection after restoration, including the verified-EOF
                // last-word fallback.
                if (self.paged.current_ready and self.paged.pending_selection == null) self.scroll_restore_pending = null;
            },
            .page => |page| {
                if (self.paged.current_ready and self.paged.page_index == page) self.scroll_restore_pending = null;
            },
        }
    }

    fn handleRsvpMove(self: *ReaderCoordinator, move: rsvp_reader.RsvpReader.Move) void {
        switch (move) {
            .moved => self.requestPositionSaveAfterReadingMovement(),
            .needs_word => self.requestPositionSaveAfterReadingMovement(),
            .waiting, .at_limit => {},
            .needs_rescan => |target| {
                self.requestPositionSaveAfterReadingMovement();
                self.openChapter(self.chapter_index, .{ .rsvp_rescan = target });
            },
            .needs_next_chapter => if (self.nextReadableChapter()) |next| {
                self.requestPositionSaveAfterReadingMovement();
                self.rsvp_tail_return = .{ .chapter = self.chapter_index, .word = self.rsvp_reader.position().word };
                self.openRsvpContinuation(next);
            } else self.stopRsvpAtBookEnd(self.frame_now_ms),
        }
    }

    fn openAdjacentChapter(self: *ReaderCoordinator, direction: i8) void {
        const candidate = if (direction < 0)
            self.previousReadableChapter()
        else if (self.chapter_index + 1 < self.book_session.publication.spine_len)
            @as(?u8, self.chapter_index + 1)
        else
            null;
        const index = candidate orelse {
            self.emitSound(.at_boundary);
            return;
        };
        self.beginSoundNavigation(direction, false);
        const action: ChapterOpenAction = if (self.mode == .paged and self.paged_presentation == .scroll and direction < 0) .rescan_to_last_page else .normal;
        self.openChapter(index, action);
        self.lifecycle = .ready;
    }

    const SoundNavigation = struct {
        chapter: u8,
        page: u32,
        word: ?u32,
        direction: i8,
        automatic: bool,
    };

    fn emitSound(self: *ReaderCoordinator, kind: sound.Kind) void {
        self.sound_events.push(.{ .kind = kind, .immediate = self.reduce_flashing });
    }

    fn beginSoundNavigation(self: *ReaderCoordinator, direction: i8, automatic: bool) void {
        if (self.sound_navigation) |*pending| {
            pending.direction = direction;
            // A delayed manual move still needs its cue even if autoplay ticks while it
            // loads.
            pending.automatic = pending.automatic and automatic;
            return;
        }
        self.sound_navigation = .{
            .chapter = self.chapter_index,
            .page = if (self.paged_presentation == .scroll) self.paged.scrollPosition().top_page else self.paged.page_index,
            .word = self.paged.selected_word_ordinal,
            .direction = direction,
            .automatic = automatic,
        };
    }

    fn observeSoundDestination(self: *ReaderCoordinator, now_ms: u32) void {
        if (self.lifecycle != .ready or self.chapter_pump.chapter_open != null or self.pending_prefetch_transition != null or self.pending_mode_word_ordinal != null or self.scroll_restore_pending != null or self.scroll_align_chapter_end) return;
        const visible = if (self.mode == .paged) self.paged.current_ready and !self.paged.isReconstructing() and self.paged.pending_selection == null else self.rsvp_reader.hasWord() and !self.rsvp_reader.isReconstructing();
        if (self.sound_opening_started) |started| {
            if (self.screen == .chapter_browser or (self.screen == .reading and visible)) {
                self.sound_opening_started = null;
                if (self.screen == .chapter_browser or now_ms -% started >= 500) self.emitSound(.surface_opened);
            }
        }
        if (self.screen != .reading or !visible) return;
        const navigation = self.sound_navigation orelse return;
        const page = if (self.paged_presentation == .scroll) self.paged.scrollPosition().top_page else self.paged.page_index;
        const kind: ?sound.Kind = if (navigation.chapter != self.chapter_index) .chapter_changed else if (self.mode == .rsvp) null else if (navigation.page != page) (if (self.paged_presentation == .scroll) null else .page_changed) else if (self.paged_presentation == .pages and navigation.word != self.paged.selected_word_ordinal) .word_selection else null;
        if (kind) |event| self.sound_events.push(.{ .kind = event, .direction = navigation.direction, .quiet = navigation.automatic });
        if (kind != null or (self.paged.detent_backlog == 0 and self.paged.scrollPosition().waiting_px == 0)) self.sound_navigation = null;
    }

    fn scrollView(self: *ReaderCoordinator) ScrollView {
        return .{
            .window = self.paged.scrollRenderState(self.paged.scrollPosition(), self.scrollGeometry()),
            // Hide the previous chapter's provisional beginning until its final Scroll
            // viewport is restored.
            .restoring = self.scroll_restore_pending != null or self.scroll_align_chapter_end or !self.paged.scrollViewportReady(self.scrollGeometry()),
            .mode_switch_loading = self.mode_switch_loading,
            .chapter_end_overscroll_px = self.scroll_chapter_end_overscroll_px,
            .chapter_start_overscroll_px = self.scroll_chapter_start_overscroll_px,
            .chapter_transition_nonce = self.scroll_chapter_transition_nonce,
            .progress = self.progressView(),
            .progress_visibility = self.progress_visibility,
            .progress_position = self.progress_position,
            .progress_scope = self.progress_scope,
        };
    }

    fn pagedView(self: *ReaderCoordinator) PagedView {
        const state = self.paged.renderState();
        const restoring = self.pending_mode_word_ordinal != null and self.paged.pending_selection != null;
        var lines = [_][]const u8{""} ** pagination.max_lines;
        var line_count: u8 = 0;
        var selected_span: ?pagination.PageCache.WordSpan = null;
        var dismiss_span: ?pagination.PageCache.WordSpan = null;
        if (state.page) |page| {
            line_count = page.line_count;
            for (0..page.line_count) |index| lines[index] = page.line(index);
            if (page.moveSelection(state.selected_word_ordinal, 0)) |selected| {
                self.paged.selected_word_ordinal = selected;
                if (!self.crank_docked) selected_span = page.wordSpan(selected);
            }
            if (self.crank_docked and self.word_highlight_dismiss_nonce != 0) {
                if (self.paged.selected_word_ordinal) |selected| dismiss_span = page.wordSpan(selected);
            }
        }
        var transition: ?PageTransitionView = null;
        if (self.page_transition_state.elapsed(self.frame_now_ms)) |elapsed_ms| {
            var outgoing_lines = [_][]const u8{""} ** pagination.max_lines;
            var outgoing_line_count: u8 = 0;
            var source_ready = true;
            if (self.page_transition_state.source_page) |source_page| {
                if (self.paged.cachedPage(source_page)) |outgoing| {
                    outgoing_line_count = outgoing.line_count;
                    for (0..outgoing.line_count) |index| outgoing_lines[index] = outgoing.line(index);
                } else source_ready = false;
            }
            if (source_ready) {
                transition = .{
                    .lines = outgoing_lines,
                    .line_count = outgoing_line_count,
                    .style = self.page_transition_state.style,
                    .direction = self.page_transition_state.direction,
                    .elapsed_ms = elapsed_ms,
                };
            } else self.page_transition_state.cancel();
        }
        return .{
            .lines = lines,
            .line_count = line_count,
            .restoring = restoring,
            .mode_switch_loading = self.mode_switch_loading,
            .selected_span = selected_span,
            .spotlight_nonce = self.word_spotlight_nonce,
            .dismiss_span = dismiss_span,
            .dismiss_nonce = self.word_highlight_dismiss_nonce,
            .page_index = state.page_index,
            .waiting = state.waiting_for_page,
            .reconstructing = state.reconstructing,
            .transition = transition,
            .progress = self.progressView(),
            .progress_visibility = self.progress_visibility,
            .progress_position = self.progress_position,
            .progress_scope = self.progress_scope,
        };
    }

    fn rsvpView(self: *ReaderCoordinator) RsvpView {
        const state = self.rsvp_reader.renderState();
        const anchor = if (state.word) |word| rsvp.anchorBytes(word) else null;
        return .{
            .word = state.word,
            .anchor = if (anchor) |span| .{ .start = span.start, .end = span.end } else null,
            .waiting = state.waiting,
            .reconstructing = self.rsvp_reader.isReconstructing(),
            .mode_switch_loading = self.mode_switch_loading,
            .playing = state.playing,
            .wpm = state.wpm,
            .manual_wpm = if (!state.playing and !self.crank_docked) self.manual_rsvp_wpm.wpm(self.frame_now_ms) else null,
            .progress = self.progressView(),
            .progress_visibility = self.progress_visibility,
            .progress_position = self.progress_position,
            .progress_scope = self.progress_scope,
        };
    }

    /// Fill heap-owned render storage; a temporary model would exceed the device stack
    /// budget.
    pub fn renderModelInto(self: *ReaderCoordinator, model: *RenderModel) void {
        switch (self.screen) {
            .library => return self.renderLibraryModelInto(model),
            .book_actions => return self.renderBookActionsModelInto(model),
            .settings => return self.renderSettingsModelInto(model),
            .statistics => return self.renderStatisticsModelInto(model),
            .chapter_browser => return self.renderChaptersModelInto(model),
            else => return self.renderReadingModelInto(model),
        }
    }

    fn renderLibraryModelInto(self: *ReaderCoordinator, model: *RenderModel) void {
        model.* = .{ .library = undefined };
        const view = &model.library;
        self.fillLibraryView(view);
    }

    fn fillLibraryView(self: *const ReaderCoordinator, view: *LibraryView) void {
        const first: usize = self.library.first_visible;
        const end = @min(@as(usize, self.library.len), first + library_visible_rows);
        const count = end - first;
        for (first..end, 0..) |index, row| {
            view.paths[row] = library_storage.displayTitle(self.library.books[index].slice());
            view.progress[row] = self.library_progress[index];
        }
        for (count..library_visible_rows) |row| {
            view.paths[row] = "";
            view.progress[row] = null;
        }
        view.count = self.library.len;
        view.selected = self.library.selected;
        view.first_visible = self.library.first_visible;
        view.omitted_capacity = self.library.omitted_capacity;
        view.omitted_names = self.library.omitted_names;
        view.listing_failed = self.library.listing_failed;
    }

    fn renderBookActionsModelInto(self: *ReaderCoordinator, model: *RenderModel) void {
        model.* = .{ .book_actions = undefined };
        const view = &model.book_actions;
        self.fillLibraryView(&view.library);
        view.title = if (self.library.selectedBook()) |book| library_storage.displayTitle(book.slice()) else "";
        view.has_resume = self.book_action_has_resume;
        view.selected = self.book_action_selected;
    }

    fn renderSettingsModelInto(self: *ReaderCoordinator, model: *RenderModel) void {
        model.* = .{ .settings = .{
            .selected = self.settings_menu_state.selected,
            .first_visible = self.settings_menu_state.first_visible,
            .row_count = self.settings_menu_state.displayedCount(),
            .total_rows = self.settings_menu_state.available_rows,
            .paged_presentation = self.paged_presentation,
            .sound = self.sound_level,
            .page_animation = self.page_animation,
            .theme = self.theme,
            .pages_font = self.pages_font,
            .rsvp_font = self.rsvp_font,
            .progress_visibility = self.progress_visibility,
            .progress_position = self.progress_position,
            .progress_scope = self.progress_scope,
            .reset_hold_ms = self.reset_hold_elapsed_ms,
        } };
    }

    fn renderStatisticsModelInto(self: *ReaderCoordinator, model: *RenderModel) void {
        const index = self.progress_worker.snapshot();
        const chapter_count = if (index) |value| value.key.spine_len else 0;
        const duration = if (self.statistics_closing) reading_statistics.sheet_exit_ms else reading_statistics.sheet_enter_ms;
        model.* = .{ .statistics = .{
            .content = reading_statistics.format(self.progressView(), self.pace, self.progress_worker.status(), chapter_count),
            .backdrop = if (self.paged_presentation == .scroll) .{ .scroll = self.scrollView() } else .{ .paged = self.pagedView() },
            .phase = if (self.statistics_closing) .exiting else .entering,
            .elapsed_ms = @intCast(if (self.reduce_flashing) duration else @min(self.frame_now_ms -% self.statistics_opened_at, duration)),
        } };
    }

    fn renderChaptersModelInto(self: *ReaderCoordinator, model: *RenderModel) void {
        model.* = .{ .chapters = undefined };
        const view = &model.chapters;
        const count = self.chapter_browser.displayedCount();
        var row_count: u8 = 0;
        for (0..count) |row_index| {
            const browser_index = self.chapter_browser.first_visible + @as(u8, @intCast(row_index));
            const spine_index = self.spineIndexForBrowserPosition(browser_index) orelse continue;
            view.rows[row_count] = .{
                .index = browser_index,
                .selected = browser_index == self.chapter_browser.selected,
                .label = self.book_session.publication.chapter_labels[spine_index].slice(),
                .path = self.book_session.publication.spine[spine_index].slice(),
            };
            row_count += 1;
        }
        view.selected = self.chapter_browser.selected;
        view.entries = self.chapter_browser.entry_count;
        view.row_count = row_count;
        view.first_visible = self.chapter_browser.first_visible;
    }

    fn renderReadingModelInto(self: *ReaderCoordinator, model: *RenderModel) void {
        model.* = switch (self.lifecycle) {
            .opening => .opening,
            .ready => switch (self.mode) {
                .paged => if (self.paged_presentation == .scroll)
                    .{ .scroll = self.scrollView() }
                else
                    .{ .paged = self.pagedView() },
                .rsvp => .{ .rsvp = self.rsvpView() },
            },
            .unavailable => .{ .failure = .unavailable },
            .invalid_archive => .{ .failure = .{ .invalid_archive = self.opening_failure } },
            .missing_mimetype => .{ .failure = .missing_mimetype },
            .invalid_mimetype => .{ .failure = .invalid_mimetype },
            .chapter_error => .{ .failure = .{ .chapter = .{
                .reason = self.chapter_failure,
                .path = if (self.chapter_index < self.book_session.publication.spine_len) self.book_session.publication.spine[self.chapter_index].slice() else null,
            } } },
        };
    }

    /// Host tests may return models by value. Device frames use renderModelInto to
    /// avoid a large temporary.
    pub fn renderModel(self: *ReaderCoordinator) RenderModel {
        var model: RenderModel = undefined;
        self.renderModelInto(&model);
        return model;
    }

    pub fn reduceFlashing(self: *const ReaderCoordinator) bool {
        return self.reduce_flashing;
    }

    /// Use the drawable position for rounding; verified counts establish EOF
    /// independently of cached pages.
    fn atBookEnd(self: *const ReaderCoordinator) bool {
        if (self.lifecycle != .ready or self.position_save_suppressed or self.chapter_browser_from_library or
            self.chapter_pump.chapter_open != null or self.pending_mode_word_ordinal != null or
            self.scroll_restore_pending != null or self.scroll_align_chapter_end or self.mode_switch_loading or
            self.chapterIsReconstructing()) return false;
        const index = if (self.progress_worker.index) |*value| value else return false;
        if (!index.isFinalTextChapter(self.chapter_index)) return false;
        const words = index.chapter_words[self.chapter_index];
        return switch (self.mode) {
            .rsvp => self.rsvp_reader.hasWord() and self.rsvp_reader.position().word == words - 1,
            .paged => blk: {
                if (self.paged.pending_selection != null) break :blk false;
                if (self.paged_presentation == .scroll) {
                    if (self.host == null) break :blk false;
                    break :blk self.paged.scrollEndingVisible(self.scrollGeometry(), words);
                }
                const page = self.paged.current() orelse break :blk false;
                break :blk paged_reader.PagedReader.pageContainsEnding(page, words);
            },
        };
    }

    fn observeEndProgress(self: *ReaderCoordinator) void {
        const at_end = self.atBookEnd();
        if (at_end == self.last_at_book_end) return;
        self.last_at_book_end = at_end;
        // Indexing may finish without another navigation input.
        if (self.hasPositionToFlushOnPause()) self.requestPositionSave();
    }

    fn progressView(self: *const ReaderCoordinator) ?reading_progress.View {
        const index = self.progress_worker.snapshot() orelse return null;
        if (self.chapter_index >= index.key.spine_len) return null;
        const word_ordinal = self.pending_mode_word_ordinal orelse switch (self.mode) {
            .paged => self.currentPagedWordOrdinal(),
            .rsvp => self.rsvp_reader.position().word,
        };
        return index.view(.{ .chapter = self.chapter_index, .word_ordinal = word_ordinal, .at_book_end = self.atBookEnd() }) catch null;
    }
};

fn closeOpeningHostLease(context: *anyopaque) void {
    const self: *ReaderCoordinator = @ptrCast(@alignCast(context));
    const files = self.host.?.files orelse return;
    files.close(files.context, .opening);
}

fn closePrefetchHostLease(context: *anyopaque) void {
    const self: *ReaderCoordinator = @ptrCast(@alignCast(context));
    const files = self.host.?.files orelse return;
    files.close(files.context, .prefetch);
}

fn closeProgressHostLease(context: *anyopaque) void {
    const self: *ReaderCoordinator = @ptrCast(@alignCast(context));
    const files = self.host.?.files orelse return;
    files.close(files.context, .progress);
}

fn openingTelemetryPhase(job: *const opening_session.Session) telemetry.LoadingPhase {
    return switch (job.phase) {
        .open, .scan_archive => .archive,
        .validate_directory => if (job.validator.?.entry_index < job.archive.?.entry_count) .directory else .member_bounds,
        .hash_directory => .directory_hash,
        .load_publication_cache => .cache,
        .parse_container, .parse_package => .metadata_parse,
        .find_navigation, .read_navigation, .find_ncx, .read_ncx => .navigation,
        else => .metadata_read,
    };
}

fn publicationFingerprint(publication: *const epub.Publication, directory: *const zip.DirectoryIndex) [16]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (publication.spine[0..publication.spine_len]) |*spine| {
        const path = spine.slice();
        var path_length: [2]u8 = undefined;
        std.mem.writeInt(u16, &path_length, @intCast(path.len), .little);
        hasher.update(&path_length);
        hasher.update(path);
        const entry = directory.find(path) catch {
            hasher.update(&.{0});
            continue;
        };
        hasher.update(&.{1});
        var metadata: [12]u8 = undefined;
        std.mem.writeInt(u32, metadata[0..4], entry.crc32, .little);
        std.mem.writeInt(u32, metadata[4..8], entry.compressed_size, .little);
        std.mem.writeInt(u32, metadata[8..12], entry.uncompressed_size, .little);
        hasher.update(&metadata);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest[0..16].*;
}

pub const InputSnapshot = struct {
    screen: Screen,
    readiness: Readiness,
    mode: ReadingMode,
    paged_presentation: PagedPresentation = .pages,
    buttons: input.Buttons,
    book_loading: bool = false,
};

pub fn intentFor(snapshot: InputSnapshot) input.Intent {
    return input.intentFor(.{
        .screen = switch (snapshot.screen) {
            .library => .library,
            .book_actions => .book_actions,
            .opening, .unsupported_book, .malformed_book => .opening,
            .reading, .chapter_error => .reading,
            .settings => .settings,
            .statistics => .statistics,
            .chapter_browser => .chapter_browser,
        },
        .readiness = switch (snapshot.readiness) {
            .opening => .opening,
            .ready => .ready,
            .opening_failure => .opening_failure,
            .chapter_error => .chapter_error,
        },
        .mode = switch (snapshot.mode) {
            .paged => .paged,
            .rsvp => .rsvp,
        },
        .paged_presentation = switch (snapshot.paged_presentation) {
            .pages => .pages,
            .scroll => .scroll,
        },
        .buttons = snapshot.buttons,
        .book_loading = snapshot.book_loading,
    });
}

fn crankDirection(accumulated: *f32, change: f32) i8 {
    accumulated.* += change;
    if (accumulated.* >= crank_degrees_per_word) {
        accumulated.* -= crank_degrees_per_word;
        return 1;
    }
    if (accumulated.* <= -crank_degrees_per_word) {
        accumulated.* += crank_degrees_per_word;
        return -1;
    }
    return 0;
}

fn crankDetents(accumulated: *f32, change: f32) i16 {
    accumulated.* += change;
    var detents: i16 = 0;
    while (accumulated.* >= crank_degrees_per_word and detents != std.math.maxInt(i16)) {
        accumulated.* -= crank_degrees_per_word;
        detents += 1;
    }
    while (accumulated.* <= -crank_degrees_per_word and detents != std.math.minInt(i16)) {
        accumulated.* += crank_degrees_per_word;
        detents -= 1;
    }
    return detents;
}

/// Accumulate 1.25 degrees per Scroll pixel, retaining fractional movement between
/// updates.
fn scrollPixelsForCrank(remainder_millidegrees: *i32, change: f32) i16 {
    if (!std.math.isFinite(change)) return 0;
    const bounded_change = std.math.clamp(change, -360.0, 360.0);
    const delta_millidegrees: i32 = @intFromFloat(@round(bounded_change * 1_000.0));
    const total = remainder_millidegrees.* + delta_millidegrees;
    const pixels: i32 = @divTrunc(total, scroll_millidegrees_per_pixel);
    remainder_millidegrees.* = total - pixels * scroll_millidegrees_per_pixel;
    return @intCast(pixels);
}

fn saturatingAddDetents(existing: i16, incoming: i16) i16 {
    const total: i32 = @as(i32, existing) + @as(i32, incoming);
    return @intCast(@max(@as(i32, std.math.minInt(i16)), @min(@as(i32, std.math.maxInt(i16)), total)));
}

test "Scroll crank conversion keeps its speed while exposing pixel steps" {
    var remainder: i32 = 0;
    try std.testing.expectEqual(@as(i16, 0), scrollPixelsForCrank(&remainder, 1.0));
    try std.testing.expectEqual(@as(i16, 1), scrollPixelsForCrank(&remainder, 0.25));
    try std.testing.expectEqual(@as(i32, 0), remainder);
    try std.testing.expectEqual(@as(i16, 12), scrollPixelsForCrank(&remainder, 15.0));
    try std.testing.expectEqual(@as(i32, 0), remainder);
    try std.testing.expectEqual(@as(i16, -1), scrollPixelsForCrank(&remainder, -1.25));
}

test "Scroll chapter-end overscroll commits only after half a screen" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.chapter_index = 0;
    coordinator.book_session.publication.spine_len = 2;

    coordinator.extendScrollChapterEndOverscroll(scroll_chapter_transition_threshold_px - 1);
    try std.testing.expectEqual(scroll_chapter_transition_threshold_px - 1, coordinator.scroll_chapter_end_overscroll_px);
    try std.testing.expect(coordinator.requestedChapter() == null);

    coordinator.extendScrollChapterEndOverscroll(1);
    try std.testing.expectEqual(@as(?u8, 1), coordinator.requestedChapter());
    try std.testing.expectEqual(@as(u16, 0), coordinator.scroll_chapter_end_overscroll_px);
}

test "Scroll chapter-start overscroll returns to the prior chapter at its end" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    coordinator.chapter_index = 1;
    coordinator.book_session.publication.spine_len = 2;
    const prior_path = "chapter-0.xhtml";
    coordinator.book_session.publication.spine[0].path_len = @intCast(prior_path.len);
    @memcpy(coordinator.book_session.publication.spine[0].path[0..prior_path.len], prior_path);
    coordinator.mode = .paged;
    coordinator.paged_presentation = .scroll;

    coordinator.extendScrollChapterStartOverscroll(scroll_chapter_transition_threshold_px - 1);
    try std.testing.expect(coordinator.requestedChapter() == null);

    coordinator.extendScrollChapterStartOverscroll(1);
    try std.testing.expectEqual(@as(?u8, 0), coordinator.requestedChapter());
    try std.testing.expectEqual(@as(u32, 1), coordinator.scroll_chapter_transition_nonce);
    try std.testing.expectEqual(@as(u16, 0), coordinator.scroll_chapter_start_overscroll_px);
    try std.testing.expect(coordinator.chapter_pump.chapter_open.?.action == .rescan_to_last_page);
}

test "first readable chapter cannot navigate back into wrap0000" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    const paths = [_][]const u8{ "wrap0000.xhtml", "chapter-1.xhtml" };
    coordinator.book_session.publication.spine_len = @intCast(paths.len);
    for (paths, 0..) |path, index| {
        coordinator.book_session.publication.spine[index].path_len = @intCast(path.len);
        @memcpy(coordinator.book_session.publication.spine[index].path[0..path.len], path);
    }
    coordinator.chapter_index = 1;
    coordinator.mode = .paged;
    coordinator.paged_presentation = .scroll;

    try std.testing.expect(coordinator.previousReadableChapter() == null);
    coordinator.openAdjacentChapter(-1);
    try std.testing.expect(coordinator.chapter_pump.chapter_open == null);
    coordinator.extendScrollChapterStartOverscroll(scroll_chapter_transition_threshold_px);
    try std.testing.expectEqual(@as(u16, 0), coordinator.scroll_chapter_start_overscroll_px);
}

test "released Scroll chapter-end overscroll eases back and crank motion interrupts it" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.mode = .paged;
    coordinator.paged_presentation = .scroll;
    coordinator.scroll_chapter_end_overscroll_px = 90;

    coordinator.relaxScrollChapterEndOverscroll(0);
    try std.testing.expectEqual(@as(u16, 60), coordinator.scroll_chapter_end_overscroll_px);
    coordinator.relaxScrollChapterEndOverscroll(1);
    try std.testing.expectEqual(@as(u16, 60), coordinator.scroll_chapter_end_overscroll_px);
}

test "coordinator maps platform-free snapshots through existing input priority" {
    try std.testing.expectEqual(input.Intent.toggle_reading_mode, intentFor(.{
        .screen = .reading,
        .readiness = .ready,
        .mode = .paged,
        .buttons = .{ .a = true, .right = true },
    }));
    try std.testing.expectEqual(input.Intent.next_chapter, intentFor(.{
        .screen = .chapter_error,
        .readiness = .chapter_error,
        .mode = .rsvp,
        .buttons = .{ .right = true },
    }));
    try std.testing.expectEqual(input.Intent.none, intentFor(.{
        .screen = .opening,
        .readiness = .opening,
        .mode = .paged,
        .buttons = .{ .a = true },
    }));
}

test "library crank selects down clockwise and up counterclockwise" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("one.epub");
    coordinator.library.add("two.epub");
    coordinator.library.add("three.epub");

    coordinator.handleCrank(crank_degrees_per_word, 0);
    try std.testing.expectEqual(@as(u8, 1), coordinator.library.selected);

    coordinator.handleCrank(-crank_degrees_per_word, 0);
    try std.testing.expectEqual(@as(u8, 0), coordinator.library.selected);
}

test "docking hides paged focus without discarding its selected word" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 0;
    try coordinator.paged.pages[0].appendLineWithMetadata("one two", 0, 2);
    coordinator.paged.pages[0].word_count = 2;
    coordinator.paged.selected_word_ordinal = 1;

    coordinator.paged.detent_backlog = 3;
    coordinator.crank_accumulated = 7;
    coordinator.updateCrankDockState(true);
    try std.testing.expectEqual(@as(i16, 0), coordinator.paged.detent_backlog);
    try std.testing.expectEqual(@as(f32, 0), coordinator.crank_accumulated);
    switch (coordinator.renderModel()) {
        .paged => |view| {
            try std.testing.expect(view.selected_span == null);
            try std.testing.expect(view.dismiss_span != null);
            try std.testing.expectEqual(@as(u32, 1), view.dismiss_nonce);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(?u32, 1), coordinator.paged.selected_word_ordinal);

    coordinator.updateCrankDockState(false);
    switch (coordinator.renderModel()) {
        .paged => |view| {
            try std.testing.expect(view.selected_span != null);
            try std.testing.expectEqual(@as(u32, 1), view.spotlight_nonce);
        },
        else => return error.TestUnexpectedResult,
    }

    coordinator.paged.selected_word_ordinal = 0;
    try std.testing.expectEqual(PagedSelectionMove.advanced, coordinator.movePagedSelection(1, 0));
    try std.testing.expectEqual(@as(u32, 1), coordinator.word_spotlight_nonce);
}

test "cached same-chapter page movement starts a directional transition" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.chapter_index = 0;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 1;
    coordinator.paged.page_index = 1;
    coordinator.paged.slots[0] = .{ .role = .history, .chapter = 0, .page = 0 };
    coordinator.paged.slots[1] = .{ .role = .displayed, .chapter = 0, .page = 1 };

    coordinator.updatePageTransition(.{ .chapter = 0, .page = 0 }, false, 100);
    try std.testing.expect(coordinator.page_transition_state.active);
    try std.testing.expectEqual(page_transition.Direction.forward, coordinator.page_transition_state.direction);
    try std.testing.expectEqual(@as(?u32, 0), coordinator.page_transition_state.source_page);

    coordinator.updatePageTransition(.{ .chapter = 0, .page = 1 }, true, 101);
    try std.testing.expect(!coordinator.page_transition_state.active);
}

test "completed position restoration transitions from a blank source" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged.current_ready = true;
    coordinator.paged.slots[coordinator.paged.current_page] = .{ .role = .displayed, .chapter = 0, .page = 4 };
    coordinator.paged.page_index = 4;
    coordinator.restore_transition_pending = true;

    coordinator.updatePageTransition(null, false, 200);
    try std.testing.expect(coordinator.page_transition_state.active);
    try std.testing.expectEqual(@as(?u32, null), coordinator.page_transition_state.source_page);
}

test "Scroll presentation suppresses Paged selection and preserves its semantic word" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 0;
    coordinator.paged.page_index = 0;
    try coordinator.paged.pages[0].appendLineWithMetadata("one", 0, 1);
    try coordinator.paged.pages[0].appendLineWithMetadata("two", 0, 1);
    coordinator.paged.pages[0].word_count = 2;
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 0 };
    coordinator.paged.selected_word_ordinal = 1;

    coordinator.switchPagedPresentation();
    try std.testing.expectEqual(PagedPresentation.scroll, coordinator.paged_presentation);
    try std.testing.expectEqual(@as(u32, 1), coordinator.currentPagedWordOrdinal());
    switch (coordinator.renderModel()) {
        .scroll => |view| try std.testing.expectEqual(@as(u2, 2), view.window.tile_count),
        else => return error.TestUnexpectedResult,
    }

    coordinator.switchPagedPresentation();
    try std.testing.expectEqual(PagedPresentation.pages, coordinator.paged_presentation);
    try std.testing.expectEqual(@as(?u32, 1), coordinator.paged.selected_word_ordinal);
}

test "restored Scroll selection anchors its target page instead of stale history" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged_presentation = .scroll;
    coordinator.paged.chapter_index = 0;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 1;
    coordinator.paged.page_index = 5;
    coordinator.paged.pages[0].first_word_ordinal = 0;
    coordinator.paged.pages[0].word_count = 1;
    try coordinator.paged.pages[0].appendLineWithMetadata("old", 0, 1);
    coordinator.paged.pages[1].first_word_ordinal = 50;
    coordinator.paged.pages[1].word_count = 2;
    try coordinator.paged.pages[1].appendLineWithMetadata("target", 0, 1);
    try coordinator.paged.pages[1].appendLineWithMetadata("next", 0, 1);
    coordinator.paged.slots[0] = .{ .role = .history, .chapter = 0, .page = 0 };
    coordinator.paged.slots[1] = .{ .role = .displayed, .chapter = 0, .page = 5 };
    coordinator.paged.pending_selection = .{ .ordinal = 51 };

    coordinator.fulfillPendingPagedSelection();

    try std.testing.expectEqual(@as(u32, 5), coordinator.paged.scrollPosition().top_page);
    try std.testing.expectEqual(scroll_geometry.Geometry.init(20).line_advance, coordinator.paged.scrollPosition().offset_px);
}

test "Scroll restoration hides the provisional chapter start until its word resolves" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged_presentation = .scroll;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 0;
    coordinator.paged.page_index = 0;
    try coordinator.paged.pages[0].appendLineWithMetadata("provisional", 0, 1);
    coordinator.paged.pages[0].word_count = 1;
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 0 };
    coordinator.paged.pending_selection = .{ .ordinal = 20 };
    coordinator.scroll_restore_pending = .{ .word = 20 };

    switch (coordinator.renderModel()) {
        .scroll => |view| try std.testing.expect(view.restoring),
        else => return error.TestUnexpectedResult,
    }

    coordinator.paged.pending_selection = null;
    coordinator.paged.chapter_end = true;
    coordinator.paged.chapter_last_page = 0;
    coordinator.resolveScrollRestoreBarrier();
    switch (coordinator.renderModel()) {
        .scroll => |view| try std.testing.expect(!view.restoring),
        else => return error.TestUnexpectedResult,
    }
}

test "Scroll predecessor restoration hides text until its chapter end is aligned" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.mode = .paged;
    coordinator.paged_presentation = .scroll;
    coordinator.scroll_align_chapter_end = true;

    switch (coordinator.renderModel()) {
        .scroll => |view| try std.testing.expect(view.restoring),
        else => return error.TestUnexpectedResult,
    }

    coordinator.scroll_align_chapter_end = false;
    coordinator.paged.current_ready = true;
    try coordinator.paged.pages[0].appendLine("last line");
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 0 };
    coordinator.paged.chapter_end = true;
    coordinator.paged.chapter_last_page = 0;
    switch (coordinator.renderModel()) {
        .scroll => |view| try std.testing.expect(!view.restoring),
        else => return error.TestUnexpectedResult,
    }
}

test "RSVP handoff hides a provisional Pages view until its target word resolves" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.mode = .paged;
    coordinator.paged_presentation = .pages;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 0;
    try coordinator.paged.pages[0].appendLineWithMetadata("provisional", 0, 1);
    coordinator.paged.pages[0].word_count = 1;
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 0 };
    coordinator.pending_mode_word_ordinal = 20;
    coordinator.paged.pending_selection = .{ .ordinal = 20 };
    coordinator.mode_switch_loading = true;

    switch (coordinator.renderModel()) {
        .paged => |view| {
            try std.testing.expect(view.restoring);
            try std.testing.expect(view.mode_switch_loading);
        },
        else => return error.TestUnexpectedResult,
    }

    coordinator.pending_mode_word_ordinal = null;
    coordinator.paged.pending_selection = null;
    switch (coordinator.renderModel()) {
        .paged => |view| try std.testing.expect(!view.restoring),
        else => return error.TestUnexpectedResult,
    }
}

test "RSVP handoff installs a Scroll word restoration barrier" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.mode = .rsvp;
    coordinator.paged_presentation = .scroll;
    coordinator.rsvp_reader.begin(37);
    const target_word = coordinator.rsvp_reader.position().word;

    coordinator.switchReadingMode(0);
    try std.testing.expectEqual(ReadingMode.paged, coordinator.mode);
    try std.testing.expect(coordinator.mode_switch_loading);
    try std.testing.expectEqual(@as(?ScrollRestoreTarget, .{ .word = target_word }), coordinator.scroll_restore_pending);
}

test "coordinator enters a rebuilt Scroll predecessor after chapter work" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged_presentation = .scroll;
    coordinator.paged.chapter_index = 0;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 1;
    coordinator.paged.page_index = 5;
    coordinator.paged.pages[0].line_count = 11;
    coordinator.paged.pages[1].line_count = 11;
    coordinator.paged.slots[0] = .{ .role = .history, .chapter = 0, .page = 4 };
    coordinator.paged.slots[1] = .{ .role = .displayed, .chapter = 0, .page = 5 };
    coordinator.paged.scroll_position = .{ .top_page = 5, .waiting_px = -12 };

    coordinator.resumeScrollBackwardAfterChapterWork(true);

    try std.testing.expectEqual(@as(u32, 4), coordinator.paged.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 219), coordinator.paged.scrollPosition().offset_px);
    try std.testing.expectEqual(@as(i16, 0), coordinator.paged.scrollPosition().waiting_px);
}

test "Scroll starts building beyond the viewport before the user reaches a page boundary" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged_presentation = .scroll;
    var context: u8 = 0;
    const Measure = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    };
    coordinator.paged.begin(0, 384, .{ .context = &context, .width = Measure.width });
    for (0..11) |_| try coordinator.paged.pages[0].appendLineWithMetadata("visible text", 0, 2);
    coordinator.paged.pages[0].word_count = 22;
    coordinator.paged.pageCompleted(0, 0);
    for (0..11) |_| try coordinator.paged.pages[coordinator.paged.next_page].appendLineWithMetadata("buffered text", 0, 2);
    coordinator.paged.pageCompleted(0, 0);
    coordinator.paged.beginScroll();
    const position = coordinator.paged.scrollPosition();
    coordinator.update(.{ .crank_docked = true }, 0);
    try std.testing.expectEqual(position, coordinator.paged.scrollPosition());
    try std.testing.expectEqual(@as(u32, 0), coordinator.positionSnapshot().word_ordinal);
    try std.testing.expect(!coordinator.paged.next_ready);
    try std.testing.expectEqual(@as(u32, 2), coordinator.paged.slots[coordinator.paged.buildingPage()].page);
    const view = coordinator.renderModel();
    try std.testing.expectEqualStrings("visible text", view.scroll.window.tiles[0].page.cache.line(0));
}

test "Scroll render model borrows continuous cached page tiles" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged_presentation = .scroll;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 0;
    coordinator.paged.page_index = 0;
    coordinator.paged.pages[0].line_count = 11;
    coordinator.paged.pages[1].line_count = 11;
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 0 };
    coordinator.paged.slots[1] = .{ .role = .history, .chapter = 0, .page = 1 };
    coordinator.paged.scroll_position = .{ .top_page = 0, .offset_px = 100 };

    switch (coordinator.renderModel()) {
        .scroll => |view| {
            try std.testing.expectEqual(@as(u2, 2), view.window.tile_count);
            switch (view.window.tiles[0]) {
                .page => |tile| try std.testing.expect(tile.cache == &coordinator.paged.pages[0]),
                else => return error.TestUnexpectedResult,
            }
            switch (view.window.tiles[1]) {
                .page => |tile| {
                    try std.testing.expect(tile.cache == &coordinator.paged.pages[1]);
                    try std.testing.expectEqual(@as(i16, -96 + 11 * 21), tile.origin_y);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Scroll pace samples only forward first-visible-word progress" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged_presentation = .scroll;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 0;
    try coordinator.paged.pages[0].appendLineWithMetadata("one", 0, 1);
    try coordinator.paged.pages[0].appendLineWithMetadata("two", 0, 1);
    coordinator.paged.pages[0].word_count = 2;
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 0 };
    const anchor = coordinator.visibleManualPaceAnchor().?;
    coordinator.manual_pace.observe(anchor, 1_000);
    coordinator.paged.scroll_position.offset_px = scroll_geometry.Geometry.init(20).line_advance;
    coordinator.recordScrollForward(anchor, 0, 1_250);
    try std.testing.expectEqual(@as(u32, 1), coordinator.pace.completed_words);

    coordinator.paged.scroll_position.offset_px = 0;
    coordinator.recordScrollForward(anchor, 1, 1_500);
    try std.testing.expectEqual(@as(u32, 1), coordinator.pace.completed_words);
}

const MeasurementFake = struct {
    calls: u8 = 0,

    fn width(context: *anyopaque, _: @import("../storage/settings.zig").ReadingFont, text: []const u8) usize {
        const self: *MeasurementFake = @ptrCast(@alignCast(context));
        self.calls += 1;
        return text.len + 3;
    }
};

test "coordinator measures text through its typed host" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = MeasurementFake{};
    coordinator.attachHost(.{ .measure = .{ .context = &fake, .width = MeasurementFake.width, .font_height = testFontHeight } });
    try std.testing.expectEqual(@as(usize, 7), coordinator.measureText("EPUB"));
    try std.testing.expectEqual(@as(u8, 1), fake.calls);
}

test "pagination measurement selects the active reading font" {
    const FontMeasurementFake = struct {
        fn widthForFont(_: *anyopaque, font: ReadingFont, text: []const u8) usize {
            return text.len + switch (font) {
                .newsleak_serif => @as(usize, 10),
                .sasser_slab => @as(usize, 20),
                .asheville_sans_14_bold => @as(usize, 30),
                .roobert_11_bold => @as(usize, 40),
                .roobert_20_medium => @as(usize, 50),
                .roobert_24_medium => @as(usize, 60),
                .espy_serif_3 => @as(usize, 70),
                .espy_serif_4 => @as(usize, 80),
                .espy_sans_5 => @as(usize, 90),
                .literata_36pt_medium_30 => @as(usize, 100),
            };
        }

        fn heightForFont(_: *anyopaque, font: ReadingFont) usize {
            return switch (font) {
                .newsleak_serif => 10,
                .sasser_slab => 20,
                .asheville_sans_14_bold => 30,
                .roobert_11_bold => 40,
                .roobert_20_medium => 50,
                .roobert_24_medium => 60,
                .espy_serif_3 => 70,
                .espy_serif_4 => 80,
                .espy_sans_5 => 90,
                .literata_36pt_medium_30 => 100,
            };
        }
    };

    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.pages_font = .asheville_sans_14_bold;
    coordinator.attachHost(.{ .measure = .{
        .context = &coordinator,
        .width = FontMeasurementFake.widthForFont,
        .font_height = FontMeasurementFake.heightForFont,
    } });

    const measure = paginationMeasure(&coordinator);
    try std.testing.expectEqual(@as(usize, 33), measure.width(measure.context, "abc"));
    try std.testing.expectEqual(reader_layout.pageLineLimit(30, pagination.max_lines), measure.line_limit);
}

test "font settings rebuild only active Pages or Scroll layout" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.lifecycle = .ready;
    coordinator.mode = .paged;
    coordinator.chapter_index = 2;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 0;
    coordinator.paged.pages[0].first_word_ordinal = 17;
    try coordinator.paged.pages[0].appendLineWithMetadata("word", 0, 1);
    coordinator.paged.pages[0].word_count = 1;
    coordinator.paged.selected_word_ordinal = 17;

    coordinator.switchPagesFont();

    try std.testing.expectEqual(ReadingFont.sasser_slab, coordinator.pages_font);
    try std.testing.expect(!coordinator.paged.current_ready);
    switch (coordinator.chapter_pump.chapter_open.?.action) {
        .word_rescan => |word| try std.testing.expectEqual(@as(u32, 17), word),
        else => return error.TestUnexpectedResult,
    }

    coordinator.chapter_pump.chapter_open = null;
    coordinator.paged.current_ready = true;
    const pages_font = coordinator.pages_font;
    coordinator.mode = .rsvp;
    coordinator.switchRsvpFont();

    try std.testing.expectEqual(pages_font, coordinator.pages_font);
    try std.testing.expectEqual(ReadingFont.roobert_24_medium, coordinator.rsvp_font);
    try std.testing.expect(coordinator.paged.current_ready);
    try std.testing.expect(coordinator.chapter_pump.chapter_open == null);
}

test "coordinator raises only semantic reconstruction work to the reconstruction ceiling" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    try std.testing.expectEqual(limits.forward_chapter_bytes_per_update, coordinator.chapterWorkBudget());

    coordinator.paged.beginWordRescan(12);
    try std.testing.expectEqual(limits.reconstruction_bytes_per_update, coordinator.chapterWorkBudget());

    coordinator.rsvp_return_fast_restore = true;
    try std.testing.expectEqual(rsvp_return_reconstruction_bytes_per_update, coordinator.chapterWorkBudget());

    coordinator.mode = .rsvp;
    coordinator.rsvp_reader.reconstruct(.{ .word = 12 });
    try std.testing.expectEqual(limits.reconstruction_bytes_per_update, coordinator.chapterWorkBudget());
}

test "manual Paged and RSVP forward reading samples once while reverse movement is discarded" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.book_session.publication.spine_len = 1;
    coordinator.pace = .{ .book_id = 7 };

    coordinator.paged.current_ready = true;
    coordinator.paged.next_ready = true;
    coordinator.paged.current_page = 0;
    coordinator.paged.next_page = 1;
    coordinator.paged.chapter_end = true;
    coordinator.paged.chapter_last_page = 1;
    coordinator.paged.pages[0].first_word_ordinal = 0;
    coordinator.paged.pages[0].word_count = 10;
    coordinator.paged.pages[1].first_word_ordinal = 10;
    coordinator.paged.pages[1].word_count = 8;
    coordinator.syncManualPace(0);
    coordinator.performIntent(.next_page, 1_000);
    try std.testing.expectEqual(@as(u32, 10), coordinator.pace.completed_words);
    try std.testing.expectEqual(@as(u32, 1_000), coordinator.pace.active_ms);

    coordinator.syncManualPace(1_000);
    coordinator.performIntent(.previous_page, 1_500);
    try std.testing.expectEqual(@as(u32, 10), coordinator.pace.completed_words);
    try std.testing.expectEqual(@as(u32, 1_000), coordinator.pace.active_ms);

    coordinator.mode = .rsvp;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("<p>one two</p>");
    try coordinator.rsvp_reader.finishInput();
    try std.testing.expectEqual(rsvp_reader.RsvpReader.Move.moved, coordinator.rsvp_reader.previousWord());
    coordinator.syncManualPace(2_000);
    coordinator.handleCrank(crank_degrees_per_word, 2_500);
    try std.testing.expectEqual(@as(u32, 11), coordinator.pace.completed_words);
    try std.testing.expectEqual(@as(u32, 1_500), coordinator.pace.active_ms);

    coordinator.syncManualPace(2_500);
    coordinator.handleCrank(-crank_degrees_per_word, 3_000);
    try std.testing.expectEqual(@as(u32, 11), coordinator.pace.completed_words);
    try std.testing.expectEqual(@as(u32, 1_500), coordinator.pace.active_ms);
}

const LibraryHostFake = struct {
    fn open(_: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        return error.OpenFailed;
    }

    fn close(_: *anyopaque, _: reader_host.FileSlot) void {}

    fn list(_: *anyopaque, library: *reader_host.Library) void {
        library.add("first.epub");
        library.add("notes.txt");
        library.add("SECOND.EPUB");
    }

    fn width(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator discovers only EPUB paths through its typed host" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = LibraryHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = LibraryHostFake.open, .close = LibraryHostFake.close, .list_epubs = LibraryHostFake.list },
        .measure = .{ .context = &fake, .width = LibraryHostFake.width, .font_height = testFontHeight },
    });
    coordinator.discoverLibrary();
    try std.testing.expectEqual(@as(u8, 2), coordinator.library.len);
    try std.testing.expectEqualStrings("first.epub", coordinator.library.books[0].slice());
    try std.testing.expectEqualStrings("SECOND.EPUB", coordinator.library.books[1].slice());
    switch (coordinator.renderModel()) {
        .library => |view| {
            try std.testing.expectEqualStrings("first", view.paths[0]);
            try std.testing.expect(view.progress[0] == null);
        },
        else => return error.TestExpectedEqual,
    }
}

test "library refresh preserves selection by path defers during reading and reports enumeration failure" {
    const coordinator = try std.testing.allocator.create(ReaderCoordinator);
    defer std.testing.allocator.destroy(coordinator);
    coordinator.initInPlace(128);
    const Listing = struct {
        calls: usize = 0,
        changed: bool = false,
        fail: bool = false,
        fn list(context: *anyopaque, library: *reader_host.Library) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            library.add("zeta.epub");
            library.add("Beta.epub");
            if (self.changed) library.add("alpha.epub");
            library.listing_failed = self.fail;
        }
    };
    var listing: Listing = .{};
    coordinator.attachHost(.{ .files = .{ .context = &listing, .open = LibraryHostFake.open, .close = LibraryHostFake.close, .list_epubs = Listing.list }, .measure = .{ .context = &listing, .width = LibraryHostFake.width, .font_height = testFontHeight } });
    coordinator.discoverLibrary();
    coordinator.library.select(1);
    try std.testing.expectEqualStrings("zeta.epub", coordinator.library.selectedBook().?.slice());
    _ = coordinator.selectBook();
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    listing.changed = true;
    coordinator.systemResumed();
    coordinator.update(.{}, 0);
    try std.testing.expectEqual(@as(usize, 1), listing.calls);
    try std.testing.expect(coordinator.library_refresh_pending);
    coordinator.returnToLibrary();
    coordinator.update(.{}, 1);
    try std.testing.expectEqual(@as(usize, 2), listing.calls);
    try std.testing.expectEqual(@as(u8, 2), coordinator.library.selected);
    try std.testing.expectEqualStrings("zeta.epub", coordinator.library.selectedBook().?.slice());
    try std.testing.expectEqualStrings("zeta.epub", coordinator.active_book.slice());
    try std.testing.expect(coordinator.openBookActions());
    try std.testing.expect(coordinator.closeBookActions());
    try std.testing.expectEqual(Screen.library, coordinator.screen);
    listing.fail = true;
    coordinator.update(.{}, 2);
    try std.testing.expect(coordinator.library.listing_failed);
    try std.testing.expectEqual(@as(u8, 0), coordinator.library.len);
    listing.fail = false;
    try std.testing.expect(coordinator.openSettings());
    try std.testing.expectEqual(@as(usize, 3), listing.calls);
    coordinator.update(.{ .buttons = .{ .b = true } }, 3);
    try std.testing.expectEqual(Screen.library, coordinator.screen);
    try std.testing.expectEqual(@as(u8, 3), coordinator.library.len);
    try std.testing.expect(!coordinator.library.listing_failed);
    try std.testing.expectEqual(@as(usize, 4), listing.calls);
    coordinator.update(.{}, 4);
    try std.testing.expectEqual(@as(usize, 4), listing.calls);
}

test "large library models expose six rows and sidecar reads are limited to one visible book per update" {
    const coordinator = try std.testing.allocator.create(ReaderCoordinator);
    defer std.testing.allocator.destroy(coordinator);
    coordinator.initInPlace(128);
    const Store = struct {
        reads: usize = 0,
        fn read(context: *anyopaque, _: []const u8, _: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.reads += 1;
            return false;
        }
        fn write(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: *anyopaque, _: []const u8) bool {
            return true;
        }
        fn directory(_: *anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var store: Store = .{};
    coordinator.attachPersistence(persistence.Service.init(.{ .context = &store, .read = Store.read, .write = Store.write, .delete = Store.delete, .ensure_directory = Store.directory }));
    for (0..library_storage.capacity) |index| {
        var path: [24]u8 = undefined;
        coordinator.library.add(try std.fmt.bufPrint(&path, "book-{d:0>3}.epub", .{index}));
    }
    for (0..library_visible_rows) |index| {
        coordinator.stepLibraryProgress();
        try std.testing.expectEqual((index + 1) * 2, store.reads);
    }
    coordinator.stepLibraryProgress();
    try std.testing.expectEqual(@as(usize, 12), store.reads);
    coordinator.library.select(254);
    coordinator.stepLibraryProgress();
    try std.testing.expectEqual(@as(usize, 14), store.reads);
    const model = try std.testing.allocator.create(RenderModel);
    defer std.testing.allocator.destroy(model);
    coordinator.renderModelInto(model);
    try std.testing.expectEqual(@as(u8, 255), model.library.count);
    try std.testing.expectEqual(@as(u8, 249), model.library.first_visible);
    try std.testing.expectEqual(@as(usize, 6), model.library.paths.len);
    try std.testing.expectEqualStrings("book-249", model.library.paths[0]);
    try std.testing.expectEqualStrings("book-254", model.library.paths[5]);
}

test "coordinator opens the selected book into a fresh opening session" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    defer coordinator.cancelOpening();
    coordinator.library.add("book.epub");
    try std.testing.expect(coordinator.openSelectedBook());
    try std.testing.expectEqual(Screen.opening, coordinator.screen);
    try std.testing.expectEqual(Lifecycle.opening, coordinator.lifecycle);
    try std.testing.expect(coordinator.book_session.opening_job != null);
    try std.testing.expectEqualStrings("book.epub", coordinator.active_book.slice());
}

test "library book actions select a primary open action or chapter browser" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("book.epub");

    try std.testing.expect(coordinator.openBookActions());
    try std.testing.expectEqual(Screen.book_actions, coordinator.screen);
    try std.testing.expectEqual(BookAction.start_or_resume, coordinator.book_action_selected);
    switch (coordinator.renderModel()) {
        .book_actions => |view| {
            try std.testing.expectEqualStrings("book", view.title);
            try std.testing.expect(!view.has_resume);
            try std.testing.expectEqual(BookAction.start_or_resume, view.selected);
        },
        else => return error.TestUnexpectedResult,
    }

    coordinator.moveBookAction(1);
    try std.testing.expectEqual(BookAction.chapters, coordinator.book_action_selected);
    try std.testing.expect(coordinator.closeBookActions());
    try std.testing.expectEqual(Screen.library, coordinator.screen);
}

test "opening another book clears stale text and progress statistics" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    defer coordinator.cancelOpening();
    coordinator.library.add("new.epub");

    coordinator.paged.current_ready = true;
    try coordinator.paged.pages[0].appendLineWithMetadata("old book", 0, 2);
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 0 };
    coordinator.paged.recordCheckpoint(0, 10, 20);
    coordinator.rsvp_reader.wpm = 420;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("<p>old</p>");
    try coordinator.rsvp_reader.finishInput();
    coordinator.progress_worker.index = try reading_progress.Index.init(.{
        .book_id = 1,
        .publication_fingerprint = [_]u8{0xa5} ** 16,
        .word_semantics_revision = word_semantics_revision,
        .spine_len = 1,
    });

    try std.testing.expect(coordinator.openSelectedBook());

    try std.testing.expect(coordinator.paged.current() == null);
    try std.testing.expectEqual(@as(usize, 0), coordinator.paged.checkpoints.bytes_used);
    try std.testing.expect(!coordinator.rsvp_reader.hasWord());
    try std.testing.expectEqual(@as(u16, 420), coordinator.rsvp_reader.wpm);
    try std.testing.expect(coordinator.progress_worker.snapshot() == null);
    try std.testing.expectEqual(progress_indexer.Phase.idle, coordinator.progress_worker.status().phase);
}

const OpeningHostFake = struct {
    open_calls: u8 = 0,

    fn open(context: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        const self: *OpeningHostFake = @ptrCast(@alignCast(context));
        self.open_calls += 1;
        return error.OpenFailed;
    }

    fn close(_: *anyopaque, _: reader_host.FileSlot) void {}
    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator reports an unavailable book when opening slot acquisition fails" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    coordinator.library.add("missing.epub");
    _ = coordinator.openSelectedBook();
    var fake = OpeningHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = OpeningHostFake.open, .close = OpeningHostFake.close, .list_epubs = OpeningHostFake.list },
        .measure = .{ .context = &fake, .width = OpeningHostFake.width, .font_height = testFontHeight },
    });
    coordinator.advanceOpening();
    try std.testing.expectEqual(@as(u8, 1), fake.open_calls);
    try std.testing.expectEqual(Lifecycle.unavailable, coordinator.lifecycle);
    try std.testing.expect(coordinator.book_session.opening_job == null);
}

const MalformedArchiveHostFake = struct {
    close_calls: u8 = 0,

    fn readAt(_: *anyopaque, _: u32, destination: []u8) zip.Error!void {
        @memset(destination, 0);
    }

    fn open(_: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        return .{ .context = undefined, .size = 22, .read_at = readAt };
    }

    fn close(context: *anyopaque, _: reader_host.FileSlot) void {
        const self: *MalformedArchiveHostFake = @ptrCast(@alignCast(context));
        self.close_calls += 1;
    }

    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator closes the opening slot when archive scanning rejects a book" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    coordinator.library.add("broken.epub");
    _ = coordinator.openSelectedBook();
    var fake = MalformedArchiveHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = MalformedArchiveHostFake.open, .close = MalformedArchiveHostFake.close, .list_epubs = MalformedArchiveHostFake.list },
        .measure = .{ .context = &fake, .width = MalformedArchiveHostFake.width, .font_height = testFontHeight },
    });
    coordinator.advanceOpening();
    coordinator.advanceOpening();
    try std.testing.expectEqual(Lifecycle.invalid_archive, coordinator.lifecycle);
    try std.testing.expectEqual(std.meta.Tag(OpeningFailure).archive_scan, std.meta.activeTag(coordinator.opening_failure));
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
    try std.testing.expect(coordinator.book_session.opening_job == null);
}

const EmptyArchiveHostFake = struct {
    fn readAt(_: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const bytes = [_]u8{ 0x50, 0x4b, 0x05, 0x06 } ++ [_]u8{0} ** 18;
        const start: usize = @intCast(offset);
        if (start + destination.len > bytes.len) return error.UnexpectedEof;
        @memcpy(destination, bytes[start..][0..destination.len]);
    }

    fn open(_: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        return .{ .context = undefined, .size = 22, .read_at = readAt };
    }

    fn close(_: *anyopaque, _: reader_host.FileSlot) void {}
    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator validates a scanned archive before exposing its directory index" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    defer coordinator.cancelOpening();
    coordinator.library.add("empty.epub");
    _ = coordinator.openSelectedBook();
    var fake = EmptyArchiveHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = EmptyArchiveHostFake.open, .close = EmptyArchiveHostFake.close, .list_epubs = EmptyArchiveHostFake.list },
        .measure = .{ .context = &fake, .width = EmptyArchiveHostFake.width, .font_height = testFontHeight },
    });
    coordinator.advanceOpening();
    coordinator.advanceOpening();
    coordinator.advanceOpening();
    coordinator.advanceOpening();
    try std.testing.expectEqual(opening_session.Phase.find_mimetype, coordinator.book_session.opening_job.?.phase);
    try std.testing.expectEqual(@as(u16, 0), coordinator.book_session.archive_index.?.archive.entry_count);
}

test "coordinator reports a missing mimetype after validating an empty archive" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    coordinator.library.add("empty.epub");
    _ = coordinator.openSelectedBook();
    var fake = EmptyArchiveHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = EmptyArchiveHostFake.open, .close = EmptyArchiveHostFake.close, .list_epubs = EmptyArchiveHostFake.list },
        .measure = .{ .context = &fake, .width = EmptyArchiveHostFake.width, .font_height = testFontHeight },
    });
    for (0..5) |_| coordinator.advanceOpening();
    try std.testing.expectEqual(Lifecycle.missing_mimetype, coordinator.lifecycle);
    try std.testing.expect(coordinator.book_session.opening_job == null);
}

const StoredMimetypeHostFake = struct {
    bytes: [134]u8 = undefined,

    fn init() StoredMimetypeHostFake {
        var self: StoredMimetypeHostFake = undefined;
        @memset(&self.bytes, 0);
        const name = "mimetype";
        const contents = "application/epub+zip";
        const crc: u32 = 0x2cab_616f;
        const directory_offset = 58;
        const directory_size = 54;
        const end_offset = directory_offset + directory_size;

        std.mem.writeInt(u32, self.bytes[0..4], 0x0403_4b50, .little);
        std.mem.writeInt(u16, self.bytes[4..6], 20, .little);
        std.mem.writeInt(u32, self.bytes[14..18], crc, .little);
        std.mem.writeInt(u32, self.bytes[18..22], contents.len, .little);
        std.mem.writeInt(u32, self.bytes[22..26], contents.len, .little);
        std.mem.writeInt(u16, self.bytes[26..28], name.len, .little);
        @memcpy(self.bytes[30 .. 30 + name.len], name);
        @memcpy(self.bytes[30 + name.len .. directory_offset], contents);

        std.mem.writeInt(u32, self.bytes[directory_offset..][0..4], 0x0201_4b50, .little);
        std.mem.writeInt(u16, self.bytes[directory_offset + 4 ..][0..2], 20, .little);
        std.mem.writeInt(u16, self.bytes[directory_offset + 6 ..][0..2], 20, .little);
        std.mem.writeInt(u32, self.bytes[directory_offset + 16 ..][0..4], crc, .little);
        std.mem.writeInt(u32, self.bytes[directory_offset + 20 ..][0..4], contents.len, .little);
        std.mem.writeInt(u32, self.bytes[directory_offset + 24 ..][0..4], contents.len, .little);
        std.mem.writeInt(u16, self.bytes[directory_offset + 28 ..][0..2], name.len, .little);
        @memcpy(self.bytes[directory_offset + 46 .. end_offset], name);

        std.mem.writeInt(u32, self.bytes[end_offset..][0..4], 0x0605_4b50, .little);
        std.mem.writeInt(u16, self.bytes[end_offset + 8 ..][0..2], 1, .little);
        std.mem.writeInt(u16, self.bytes[end_offset + 10 ..][0..2], 1, .little);
        std.mem.writeInt(u32, self.bytes[end_offset + 12 ..][0..4], directory_size, .little);
        std.mem.writeInt(u32, self.bytes[end_offset + 16 ..][0..4], directory_offset, .little);
        return self;
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *StoredMimetypeHostFake = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start + destination.len > self.bytes.len) return error.UnexpectedEof;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
    }

    fn open(context: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        const self: *StoredMimetypeHostFake = @ptrCast(@alignCast(context));
        return .{ .context = self, .size = self.bytes.len, .read_at = readAt };
    }

    fn close(_: *anyopaque, _: reader_host.FileSlot) void {}
    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator reads and validates the EPUB mimetype before finding its container" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    defer coordinator.cancelOpening();
    coordinator.library.add("book.epub");
    _ = coordinator.openSelectedBook();
    var fake = StoredMimetypeHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = StoredMimetypeHostFake.open, .close = StoredMimetypeHostFake.close, .list_epubs = StoredMimetypeHostFake.list },
        .measure = .{ .context = &fake, .width = StoredMimetypeHostFake.width, .font_height = testFontHeight },
    });
    for (0..8) |_| coordinator.advanceOpening();
    try std.testing.expectEqual(opening_session.Phase.find_container, coordinator.book_session.opening_job.?.phase);
    try std.testing.expect(coordinator.book_session.opening_job.?.mimetypeIsValid());
}

test "coordinator parses container metadata before package lookup" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    defer coordinator.cancelOpening();
    const job = try std.testing.allocator.create(opening_session.Session);
    job.* = opening_session.Session.start();
    coordinator.book_session.opening_job = job;
    job.beginMetadataRead(.container);
    try job.appendMetadataBytes("<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>");
    job.finishMetadataRead(.container);

    coordinator.advanceOpening();

    try std.testing.expectEqual(opening_session.Phase.find_package, coordinator.book_session.opening_job.?.phase);
    try std.testing.expectEqualStrings("OPS/book.opf", coordinator.book_session.opening_job.?.packagePath());
}

test "coordinator failure releases opening package storage through its allocator" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    coordinator.book_session.opening_job = try std.testing.allocator.create(opening_session.Session);
    coordinator.book_session.opening_job.?.* = opening_session.Session.start();
    coordinator.book_session.opening_job.?.package_xml = try std.testing.allocator.alloc(u8, 12);

    coordinator.failOpening(.invalid_archive);

    try std.testing.expect(coordinator.book_session.opening_job == null);
    try std.testing.expectEqual(Lifecycle.invalid_archive, coordinator.lifecycle);
}

test "coordinator turns a successful navigation result into a chapter request" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    coordinator.book_session.opening_job = try std.testing.allocator.create(opening_session.Session);
    coordinator.book_session.opening_job.?.* = opening_session.Session.start();
    coordinator.book_session.opening_job.?.succeed();

    coordinator.finishOpening();

    try std.testing.expect(coordinator.book_session.opening_job == null);
    try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
    try std.testing.expectEqual(Screen.reading, coordinator.screen);
    try std.testing.expectEqual(@as(?u8, 0), coordinator.takeOpeningChapterRequest());
    try std.testing.expect(coordinator.takeOpeningChapterRequest() == null);
}

test "coordinator completes opening after both optional navigation sources are absent" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    coordinator.book_session.publication.spine_len = 1;
    coordinator.attachAllocator(std.testing.allocator);
    coordinator.book_session.opening_job = try std.testing.allocator.create(opening_session.Session);
    coordinator.book_session.opening_job.?.* = opening_session.Session.start();
    coordinator.book_session.opening_job.?.phase = .find_navigation;

    coordinator.advanceOpening();
    try std.testing.expectEqual(opening_session.Phase.find_ncx, coordinator.book_session.opening_job.?.phase);
    coordinator.advanceOpening();

    try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
    try std.testing.expectEqual(@as(?u8, 0), coordinator.takeOpeningChapterRequest());
}

test "coordinator cancellation clears an unconsumed opening chapter request" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.opening_chapter_request = 0;

    coordinator.cancelOpening();

    try std.testing.expect(coordinator.takeOpeningChapterRequest() == null);
}

test "coordinator rejects a validated archive without its container document" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    coordinator.library.add("empty.epub");
    _ = coordinator.openSelectedBook();
    var fake = EmptyArchiveHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = EmptyArchiveHostFake.open, .close = EmptyArchiveHostFake.close, .list_epubs = EmptyArchiveHostFake.list },
        .measure = .{ .context = &fake, .width = EmptyArchiveHostFake.width, .font_height = testFontHeight },
    });
    for (0..3) |_| coordinator.advanceOpening();
    coordinator.book_session.opening_job.?.phase = .find_container;
    coordinator.advanceOpening();
    try std.testing.expectEqual(Lifecycle.invalid_archive, coordinator.lifecycle);
    try std.testing.expect(coordinator.book_session.opening_job == null);
}

test "render models carry UI data only" {
    const model = RenderModel{ .rsvp = .{ .word = "word", .waiting = false, .playing = true, .wpm = 300 } };
    switch (model) {
        .rsvp => |view| {
            try std.testing.expectEqualStrings("word", view.word.?);
            try std.testing.expect(view.playing);
        },
        else => unreachable,
    }
}

test "RSVP render model exposes only a recent undocked manual WPM" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.mode = .rsvp;
    coordinator.frame_now_ms = 1_200;
    coordinator.manual_rsvp_wpm.record(1_000);
    coordinator.manual_rsvp_wpm.record(1_100);

    switch (coordinator.renderModel()) {
        .rsvp => |view| try std.testing.expectEqual(@as(?u16, 600), view.manual_wpm),
        else => return error.TestUnexpectedResult,
    }

    coordinator.crank_docked = true;
    switch (coordinator.renderModel()) {
        .rsvp => |view| try std.testing.expect(view.manual_wpm == null),
        else => return error.TestUnexpectedResult,
    }
}

test "a forward RSVP crank records a streamed next-word request" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.mode = .rsvp;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("<p>one ");
    try std.testing.expect(coordinator.rsvp_reader.hasWord());

    coordinator.handleCrank(crank_degrees_per_word, 1_000);
    try std.testing.expectEqual(@as(u4, 1), coordinator.manual_rsvp_wpm.count);
}

test "coordinator owns screen lifecycle without reader or platform state" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    try std.testing.expect(coordinator.openSettings());
    switch (coordinator.renderModel()) {
        .settings => |view| try std.testing.expectEqual(settings_menu.global_row_count, view.total_rows),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(coordinator.closeSettings());
    try std.testing.expectEqual(Screen.library, coordinator.screen);

    coordinator.beginOpening();
    try std.testing.expectEqual(Screen.opening, coordinator.screen);
    coordinator.beginReading();
    try std.testing.expect(coordinator.openSettings());
    switch (coordinator.renderModel()) {
        .settings => |view| try std.testing.expectEqual(settings_menu.row_count, view.total_rows),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(Screen.settings, coordinator.screen);
    try std.testing.expect(coordinator.closeSettings());
    try std.testing.expect(coordinator.openChapterBrowser());
    try std.testing.expect(coordinator.closeChapterBrowser(0));
    coordinator.returnToLibrary();
    try std.testing.expectEqual(Screen.library, coordinator.screen);
}

test "Scroll reconstruction request preserves cached text and a failure stays local" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.lifecycle = .ready;
    coordinator.chapter_index = 0;
    coordinator.paged.chapter_index = 0;
    coordinator.paged.page_index = 1;
    coordinator.paged.current_page = 0;
    coordinator.paged.current_ready = true;
    coordinator.paged.pages[0].line_count = 11;
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 1 };
    coordinator.paged.scroll_position = .{ .top_page = 1, .waiting_px = -12 };
    const visible = &coordinator.paged.pages[0];

    try std.testing.expect(coordinator.beginScrollPreviousReconstruction());
    switch (coordinator.chapter_pump.chapter_open.?.action) {
        .scroll_rescan => |target| try std.testing.expectEqual(@as(u32, 0), target),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(coordinator.paged.current_ready);
    try std.testing.expect(visible == &coordinator.paged.pages[0]);

    coordinator.failChapter(.archive);
    try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
    try std.testing.expect(coordinator.paged.current_ready);
    try std.testing.expect(coordinator.paged.scroll_previous_unavailable);
}

test "scrolling settings keeps every selection visible and reset hold uninterrupted" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.beginReading();
    coordinator.toggleMode();
    try std.testing.expectEqual(ReadingMode.rsvp, coordinator.mode);
    try std.testing.expect(coordinator.openSettings());
    for (1..settings_menu.row_count) |row| {
        coordinator.moveSettingsSelection(1);
        try std.testing.expectEqual(@as(u4, @intCast(row)), @intFromEnum(coordinator.settings_menu_state.selected));
        const first = coordinator.settings_menu_state.first_visible;
        try std.testing.expect(@intFromEnum(coordinator.settings_menu_state.selected) >= first);
        try std.testing.expect(@intFromEnum(coordinator.settings_menu_state.selected) < first + coordinator.settings_menu_state.displayedCount());
    }
    try std.testing.expectEqual(SettingsRow.reset_progress, coordinator.settings_menu_state.selected);

    coordinator.updateResetHold(true, true, 100);
    coordinator.updateResetHold(true, false, 2_000);
    coordinator.moveSettingsSelection(-1);
    try std.testing.expectEqual(@as(u16, 0), coordinator.reset_hold_elapsed_ms);
    coordinator.moveSettingsSelection(1);
    coordinator.updateResetHold(true, true, 2_100);
    coordinator.updateResetHold(true, false, 5_099);
    try std.testing.expectEqual(Screen.settings, coordinator.screen);
    coordinator.updateResetHold(true, false, 5_100);
    try std.testing.expectEqual(Screen.library, coordinator.screen);
}

test "Down opens reading statistics and dismissal animates before resuming" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.beginReading();

    coordinator.performIntent(intentFor(.{
        .screen = coordinator.screen,
        .readiness = .ready,
        .mode = coordinator.mode,
        .buttons = .{ .down = true },
    }), 10);
    try std.testing.expectEqual(Screen.statistics, coordinator.screen);
    coordinator.performIntent(intentFor(.{
        .screen = coordinator.screen,
        .readiness = .ready,
        .mode = coordinator.mode,
        .buttons = .{ .b = true },
    }), 11);
    try std.testing.expectEqual(Screen.statistics, coordinator.screen);
    try std.testing.expect(coordinator.statistics_closing);
    coordinator.advanceStatisticsTransition(11 + reading_statistics.sheet_exit_ms);
    try std.testing.expectEqual(Screen.reading, coordinator.screen);
}

test "coordinator retains bounded library and chapter-browser navigation state" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("one.epub");
    coordinator.library.add("two.epub");
    coordinator.library.move(1);
    try std.testing.expectEqual(@as(u8, 1), coordinator.library.selected);
    _ = coordinator.selectBook();
    try std.testing.expectEqualStrings("two.epub", coordinator.active_book.slice());
    coordinator.pending_mode_word_ordinal = 42;
    try std.testing.expectEqual(@as(?u32, 42), coordinator.pending_mode_word_ordinal);
    coordinator.beginReading();
    try std.testing.expect(coordinator.openChapters(3, 1));
    coordinator.chapter_browser.move(1);
    try std.testing.expectEqual(@as(u8, 2), coordinator.chapter_browser.selected);
}

test "chapter browser omits wrapper and trailing TOC suffix without changing spine indices" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    const paths = [_][]const u8{
        "OEBPS/wrap0000.xhtml",
        "OEBPS/chapter0001.xhtml",
        "OEBPS/unlisted-middle.xhtml",
        "OEBPS/chapter0003.xhtml",
        "OEBPS/image-wrapper-1.xhtml",
        "OEBPS/image-wrapper-2.xhtml",
    };
    coordinator.book_session.publication.spine_len = @intCast(paths.len);
    for (paths, 0..) |path, index| {
        coordinator.book_session.publication.spine[index].path_len = @intCast(path.len);
        @memcpy(coordinator.book_session.publication.spine[index].path[0..path.len], path);
    }
    coordinator.book_session.publication.chapter_labels[1].len = 1;
    coordinator.book_session.publication.chapter_labels[3].len = 1;
    coordinator.chapter_index = 5;
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;

    try std.testing.expect(coordinator.openChapters(coordinator.visibleChapterCount(), coordinator.browserPositionForSpine(coordinator.chapter_index)));
    try std.testing.expectEqual(@as(u8, 3), coordinator.chapter_browser.entry_count);
    try std.testing.expectEqual(@as(u8, 2), coordinator.chapter_browser.selected);
    switch (coordinator.renderModel()) {
        .chapters => |view| {
            try std.testing.expectEqualStrings("OEBPS/chapter0001.xhtml", view.rows[0].path);
            try std.testing.expectEqualStrings("OEBPS/unlisted-middle.xhtml", view.rows[1].path);
            try std.testing.expectEqualStrings("OEBPS/chapter0003.xhtml", view.rows[2].path);
        },
        else => return error.TestUnexpectedResult,
    }

    coordinator.performIntent(.open_browser_chapter, 0);
    try std.testing.expectEqual(@as(u8, 3), coordinator.chapter_pump.chapter_open.?.index);
}

const ChapterSlotHostFake = struct {
    open_calls: u8 = 0,
    close_calls: u8 = 0,
    last_slot: ?reader_host.FileSlot = null,

    fn readAt(_: *anyopaque, _: u32, destination: []u8) zip.Error!void {
        @memset(destination, 0);
    }

    fn open(context: *anyopaque, slot: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        const self: *ChapterSlotHostFake = @ptrCast(@alignCast(context));
        self.open_calls += 1;
        self.last_slot = slot;
        return .{ .context = self, .size = 22, .read_at = readAt };
    }

    fn close(context: *anyopaque, slot: reader_host.FileSlot) void {
        const self: *ChapterSlotHostFake = @ptrCast(@alignCast(context));
        self.close_calls += 1;
        self.last_slot = slot;
    }

    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont, text: []const u8) usize {
        return text.len;
    }
};

const StoredChapterHostFake = struct {
    const name = "chapter.xhtml";
    const contents = "<p>Hello chapter</p>";
    const local_size = 30 + name.len + contents.len;
    const directory_size = 46 + name.len;
    const archive_size = local_size + directory_size + 22;

    bytes: [archive_size]u8 = undefined,
    open_calls: u8 = 0,
    read_calls: usize = 0,
    directory_reads: usize = 0,
    close_calls: usize = 0,
    last_slot: ?reader_host.FileSlot = null,

    fn init() StoredChapterHostFake {
        var self: StoredChapterHostFake = undefined;
        @memset(&self.bytes, 0);
        self.open_calls = 0;
        self.read_calls = 0;
        self.directory_reads = 0;
        self.close_calls = 0;
        self.last_slot = null;
        const crc = std.hash.crc.Crc32.hash(contents);

        std.mem.writeInt(u32, self.bytes[0..4], 0x0403_4b50, .little);
        std.mem.writeInt(u16, self.bytes[4..6], 20, .little);
        std.mem.writeInt(u32, self.bytes[14..18], crc, .little);
        std.mem.writeInt(u32, self.bytes[18..22], contents.len, .little);
        std.mem.writeInt(u32, self.bytes[22..26], contents.len, .little);
        std.mem.writeInt(u16, self.bytes[26..28], name.len, .little);
        @memcpy(self.bytes[30 .. 30 + name.len], name);
        @memcpy(self.bytes[30 + name.len .. local_size], contents);

        std.mem.writeInt(u32, self.bytes[local_size..][0..4], 0x0201_4b50, .little);
        std.mem.writeInt(u16, self.bytes[local_size + 4 ..][0..2], 20, .little);
        std.mem.writeInt(u16, self.bytes[local_size + 6 ..][0..2], 20, .little);
        std.mem.writeInt(u32, self.bytes[local_size + 16 ..][0..4], crc, .little);
        std.mem.writeInt(u32, self.bytes[local_size + 20 ..][0..4], contents.len, .little);
        std.mem.writeInt(u32, self.bytes[local_size + 24 ..][0..4], contents.len, .little);
        std.mem.writeInt(u16, self.bytes[local_size + 28 ..][0..2], name.len, .little);
        @memcpy(self.bytes[local_size + 46 .. local_size + directory_size], name);

        const end = local_size + directory_size;
        std.mem.writeInt(u32, self.bytes[end..][0..4], 0x0605_4b50, .little);
        std.mem.writeInt(u16, self.bytes[end + 8 ..][0..2], 1, .little);
        std.mem.writeInt(u16, self.bytes[end + 10 ..][0..2], 1, .little);
        std.mem.writeInt(u32, self.bytes[end + 12 ..][0..4], directory_size, .little);
        std.mem.writeInt(u32, self.bytes[end + 16 ..][0..4], local_size, .little);
        return self;
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *StoredChapterHostFake = @ptrCast(@alignCast(context));
        self.read_calls += 1;
        if (offset >= local_size and offset < local_size + directory_size) self.directory_reads += 1;
        const start: usize = @intCast(offset);
        if (start + destination.len > self.bytes.len) return error.UnexpectedEof;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
    }

    fn reader(self: *StoredChapterHostFake) zip.Reader {
        return .{ .context = self, .size = archive_size, .read_at = readAt };
    }

    fn open(context: *anyopaque, slot: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        const self: *StoredChapterHostFake = @ptrCast(@alignCast(context));
        self.open_calls += 1;
        self.last_slot = slot;
        return .{ .context = self, .size = archive_size, .read_at = readAt };
    }

    fn close(context: *anyopaque, _: reader_host.FileSlot) void {
        const self: *StoredChapterHostFake = @ptrCast(@alignCast(context));
        self.close_calls += 1;
    }
    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont, text: []const u8) usize {
        return text.len * 8;
    }
};

test "coordinator idles indexing for foreground work and shares verified progress across modes" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = StoredChapterHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list },
        .measure = .{ .context = &fake, .width = StoredChapterHostFake.width, .font_height = testFontHeight },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    @memcpy(coordinator.book_session.publication.spine[0].path[0..StoredChapterHostFake.name.len], StoredChapterHostFake.name);
    coordinator.book_session.publication.spine[0].path_len = StoredChapterHostFake.name.len;
    coordinator.book_session.publication.spine_len = 1;

    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [64]u8 = undefined;
    const archive = try zip.Archive.open(fake.reader(), &scan_buffer);
    var entries = [_]zip.IndexedEntry{zip.indexedEntry(StoredChapterHostFake.name, try archive.find(StoredChapterHostFake.name, &filename_buffer))};
    const directory = zip.DirectoryIndex{ .archive = archive, .entries = &entries };
    coordinator.screen = .statistics;
    coordinator.lifecycle = .ready;
    coordinator.startProgressIndexing(publicationFingerprint(&coordinator.book_session.publication, &directory));
    coordinator.chapter_pump.chapter_open = .{ .index = 0, .action = .normal };

    const before = coordinator.progress_worker.status();
    coordinator.stepProgressIndex(true);
    try std.testing.expectEqual(before.phase, coordinator.progress_worker.status().phase);
    for (0..32) |_| {
        coordinator.stepProgressIndex(false);
        if (coordinator.progress_worker.status().phase == .counting) break;
    }
    try std.testing.expectEqual(progress_indexer.Phase.counting, coordinator.progress_worker.status().phase);

    coordinator.observeVerifiedChapterTotal(2);
    try std.testing.expect(coordinator.progress_worker.snapshot().?.exact.contains(0));
    try std.testing.expect(coordinator.progress_worker.status().target_chapter == null);

    coordinator.screen = .reading;
    switch (coordinator.renderModel()) {
        .paged => |view| try expectExactProgress(view.progress, 1, 2),
        else => return error.TestUnexpectedResult,
    }
    coordinator.mode = .rsvp;
    switch (coordinator.renderModel()) {
        .rsvp => |view| try expectExactProgress(view.progress, 1, 2),
        else => return error.TestUnexpectedResult,
    }
    coordinator.progress_worker.close();
}

fn expectExactProgress(view: ?reading_progress.View, reached: u32, total: u32) !void {
    const exact = (view orelse return error.TestExpectedEqual).chapter.exact;
    try std.testing.expectEqual(reading_progress.WideCount.fromU32(reached), exact.reached);
    try std.testing.expectEqual(reading_progress.WideCount.fromU32(total), exact.total);
}

fn resolveStoredFixture(coordinator: *ReaderCoordinator, opening: *StoredChapterHostFake) !void {
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    @memcpy(coordinator.book_session.publication.spine[0].path[0..StoredChapterHostFake.name.len], StoredChapterHostFake.name);
    coordinator.book_session.publication.spine[0].path_len = StoredChapterHostFake.name.len;
    coordinator.book_session.publication.spine_len = 1;
    var scan: [64]u8 = undefined;
    var filename: [64]u8 = undefined;
    const archive = try zip.Archive.open(opening.reader(), &scan);
    var entries = [_]zip.IndexedEntry{zip.indexedEntry(StoredChapterHostFake.name, try archive.find(StoredChapterHostFake.name, &filename))};
    const directory: zip.DirectoryIndex = .{ .archive = archive, .entries = &entries };
    try coordinator.book_session.descriptors.resolve(&coordinator.book_session.publication, &directory);
}

test "resolved chapters bind new leases without directory reads and preserve rescan actions" {
    const coordinator = try std.testing.allocator.create(ReaderCoordinator);
    defer std.testing.allocator.destroy(coordinator);
    coordinator.initInPlace(128);
    var opening = StoredChapterHostFake.init();
    var chapter = StoredChapterHostFake.init();
    try resolveStoredFixture(coordinator, &opening);
    coordinator.attachAllocator(std.testing.allocator);
    const job = try std.testing.allocator.create(opening_session.Session);
    job.* = opening_session.Session.start();
    var scan: [64]u8 = undefined;
    job.archive = try zip.Archive.open(opening.reader(), &scan);
    job.indexed_entries[0] = zip.indexedEntry(StoredChapterHostFake.name, try coordinator.book_session.descriptors.chapter(0));
    job.succeed();
    coordinator.book_session.opening_job = job;
    coordinator.book_session.archive_index = try job.directoryIndex();
    coordinator.book_session.descriptors.ready = false;
    coordinator.finishOpening();
    try std.testing.expect(coordinator.book_session.opening_job == null);
    try std.testing.expect(coordinator.book_session.descriptors.ready);
    try std.testing.expect(coordinator.book_session.browser_map.ready);
    const opening_reads = opening.read_calls;
    // Destroy the opening source: descriptors must contain no borrowed reader.
    @memset(&opening.bytes, 0);
    coordinator.attachHost(.{ .files = .{ .context = &chapter, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list }, .measure = .{ .context = &chapter, .width = StoredChapterHostFake.width, .font_height = testFontHeight } });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    coordinator.lifecycle = .ready;
    coordinator.screen = .reading;
    coordinator.book_session.descriptors.ready = false;
    coordinator.openChapter(0, .normal);
    var baseline_updates: usize = 0;
    while (coordinator.chapter_pump.chapter_open != null) : (baseline_updates += 1) _ = coordinator.stepChapter(0);
    try std.testing.expectEqual(@as(usize, 3), baseline_updates);
    try std.testing.expectEqual(@as(usize, 4), chapter.read_calls);
    try std.testing.expectEqual(@as(usize, 2), chapter.directory_reads);
    coordinator.cancelChapter();
    coordinator.book_session.descriptors.ready = true;
    chapter.read_calls = 0;
    chapter.directory_reads = 0;
    chapter.close_calls = 0;
    for ([_]ChapterOpenAction{ .normal, .{ .word_rescan = 1 }, .rescan_to_last_page }) |action| {
        coordinator.openChapter(0, action);
        _ = coordinator.stepChapter(0);
        try std.testing.expect(coordinator.chapter_pump.chapter_open == null);
        try std.testing.expect(coordinator.chapter_pump.chapter_stream != null);
        if (action == .word_rescan) try std.testing.expect(coordinator.paged.isReconstructing());
        // Each open reads one fixed EOCD and one local header, no directory.
    }
    try std.testing.expectEqual(@as(usize, 6), chapter.read_calls);
    try std.testing.expectEqual(@as(usize, 0), chapter.directory_reads);
    try std.testing.expectEqual(opening_reads, opening.read_calls);
    coordinator.cancelChapter();
    try std.testing.expectEqual(@as(usize, 3), chapter.close_calls);
}

test "resolved index and prefetch avoid lookup reads and reject changed file geometry" {
    const coordinator = try std.testing.allocator.create(ReaderCoordinator);
    defer std.testing.allocator.destroy(coordinator);
    coordinator.initInPlace(128);
    var opening = StoredChapterHostFake.init();
    var source = StoredChapterHostFake.init();
    try resolveStoredFixture(coordinator, &opening);
    const archive = try coordinator.book_session.descriptors.bind(source.reader());
    const entry = try coordinator.book_session.descriptors.chapter(0);
    coordinator.paged.prefetch.attachFile(.{ .context = coordinator, .close = closePrefetchHostLease });
    try coordinator.paged.prefetch.startResolvedLookup(0, archive, entry);
    const reads = source.read_calls;
    const lookup = coordinator.paged.prefetch.stepLookup(&coordinator.chapter_pump.archive_scan_buffer, &coordinator.chapter_pump.archive_filename_buffer, "ignored", 1);
    try std.testing.expect(lookup == .found);
    try std.testing.expectEqual(reads, source.read_calls);
    coordinator.paged.prefetch.detachFile();
    coordinator.paged.prefetch.cancel();

    const key: reading_progress.Key = .{ .book_id = 1, .publication_fingerprint = [_]u8{0} ** 16, .word_semantics_revision = word_semantics_revision, .spine_len = 1 };
    var closes: usize = 0;
    const Lease = struct {
        fn close(context: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
        }
    };
    try coordinator.progress_worker.openWithDescriptors(try reading_progress.Index.init(key), &coordinator.book_session.publication, 0, source.reader(), .{ .context = &closes, .close = Lease.close }, &coordinator.book_session.descriptors);
    try std.testing.expectEqual(progress_indexer.Phase.selecting_chapter, coordinator.progress_worker.phase);
    for (0..20) |_| {
        _ = coordinator.progress_worker.update(128);
        if (coordinator.progress_worker.phase == .complete) break;
    }
    try std.testing.expectEqual(progress_indexer.Phase.complete, coordinator.progress_worker.phase);
    try std.testing.expectEqual(@as(u32, 2), coordinator.progress_worker.index.?.chapter_words[0]);
    try std.testing.expectEqual(@as(usize, 0), source.directory_reads);
    try std.testing.expectEqual(@as(usize, 1), closes);

    var resized = source.reader();
    resized.size -= 1;
    try std.testing.expectError(error.InvalidCentralDirectory, coordinator.book_session.descriptors.bind(resized));
    source.bytes[StoredChapterHostFake.archive_size - 22 + 8] ^= 1;
    try std.testing.expectError(error.InvalidCentralDirectory, coordinator.book_session.descriptors.bind(source.reader()));
    try std.testing.expectError(error.InvalidCentralDirectory, coordinator.progress_worker.openWithDescriptors(try reading_progress.Index.init(key), &coordinator.book_session.publication, 0, source.reader(), .{ .context = &closes, .close = Lease.close }, &coordinator.book_session.descriptors));
    try std.testing.expectEqual(@as(usize, 2), closes);
    try std.testing.expectEqual(progress_indexer.Phase.idle, coordinator.progress_worker.phase);
    coordinator.progress_worker.close();
    try std.testing.expectEqual(@as(usize, 2), closes);
}

test "resolved missing members stay chapter failures and changed local headers are rejected" {
    const coordinator = try std.testing.allocator.create(ReaderCoordinator);
    defer std.testing.allocator.destroy(coordinator);
    coordinator.initInPlace(128);
    var source = StoredChapterHostFake.init();
    try resolveStoredFixture(coordinator, &source);
    coordinator.attachHost(.{ .files = .{ .context = &source, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list }, .measure = .{ .context = &source, .width = StoredChapterHostFake.width, .font_height = testFontHeight } });
    coordinator.lifecycle = .ready;
    coordinator.screen = .reading;
    const entry = coordinator.book_session.descriptors.spine[0];
    coordinator.book_session.descriptors.spine[0] = null;
    coordinator.openChapter(0, .normal);
    _ = coordinator.stepChapter(0);
    try std.testing.expectEqual(Lifecycle.chapter_error, coordinator.lifecycle);
    try std.testing.expectEqual(@as(usize, 1), source.close_calls);
    coordinator.book_session.descriptors.spine[0] = entry;
    source.bytes[14] ^= 1; // Geometry still matches, local CRC metadata differs.
    coordinator.openChapter(0, .normal);
    _ = coordinator.stepChapter(0);
    try std.testing.expectEqual(Lifecycle.chapter_error, coordinator.lifecycle);
    try std.testing.expect(coordinator.chapter_pump.chapter_stream == null);
    try std.testing.expectEqual(@as(usize, 2), source.close_calls);
}

test "chapter work acquires and cancellation releases the typed chapter slot" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = ChapterSlotHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = ChapterSlotHostFake.open, .close = ChapterSlotHostFake.close, .list_epubs = ChapterSlotHostFake.list },
        .measure = .{ .context = &fake, .width = ChapterSlotHostFake.width, .font_height = testFontHeight },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();

    coordinator.openChapter(0, .normal);
    _ = coordinator.stepChapter(10);
    try std.testing.expectEqual(@as(u8, 1), fake.open_calls);
    try std.testing.expectEqual(reader_host.FileSlot.chapter, fake.last_slot.?);

    coordinator.cancelChapter();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
    coordinator.cancelChapter();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
}

test "prefetch acquires its typed slot only after verified chapter EOF and cancels once" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = ChapterSlotHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = ChapterSlotHostFake.open, .close = ChapterSlotHostFake.close, .list_epubs = ChapterSlotHostFake.list },
        .measure = .{ .context = &fake, .width = ChapterSlotHostFake.width, .font_height = testFontHeight },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    coordinator.book_session.publication.spine_len = 2;
    coordinator.chapter_index = 0;
    coordinator.paged.next_ready = true;

    try std.testing.expect(!coordinator.startPrefetch());
    try std.testing.expectEqual(@as(u8, 0), fake.open_calls);

    _ = coordinator.chapter_pump.decode_workspace.beginActive();
    coordinator.chapter_pump.decode_workspace.markActiveVerifiedEof();
    try std.testing.expect(coordinator.startPrefetch());
    try std.testing.expectEqual(@as(u8, 1), fake.open_calls);
    try std.testing.expectEqual(reader_host.FileSlot.prefetch, fake.last_slot.?);

    coordinator.cancelPrefetch();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
    coordinator.cancelPrefetch();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
}

test "bounded prefetch work prepares and activates the next chapter first page" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = StoredChapterHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list },
        .measure = .{ .context = &fake, .width = StoredChapterHostFake.width, .font_height = testFontHeight },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    for (coordinator.book_session.publication.spine[0..2]) |*spine| {
        @memcpy(spine.path[0..StoredChapterHostFake.name.len], StoredChapterHostFake.name);
        spine.path_len = StoredChapterHostFake.name.len;
    }
    coordinator.book_session.publication.spine_len = 2;
    coordinator.chapter_index = 0;
    coordinator.paged.next_ready = true;
    coordinator.lifecycle = .ready;
    coordinator.beginReading();
    _ = coordinator.chapter_pump.decode_workspace.beginActive();
    coordinator.chapter_pump.decode_workspace.markActiveVerifiedEof();

    try std.testing.expect(coordinator.startPrefetch());
    for (0..32) |_| {
        coordinator.stepPrefetch();
        if (coordinator.prefetchedChapter() != null) break;
    }
    try std.testing.expectEqual(@as(?u8, 1), coordinator.prefetchedChapter());
    try std.testing.expectEqual(reader_host.FileSlot.prefetch, fake.last_slot.?);
    const reserved = coordinator.paged.prefetch_page.?;
    try std.testing.expectEqual(paged_reader.PagedReader.SlotRole.prefetch, coordinator.paged.slots[reserved].role);

    try std.testing.expect(coordinator.activatePrefetch());
    try std.testing.expectEqual(@as(?u8, 1), coordinator.activeChapter());
    try std.testing.expect(coordinator.paged.prefetch_page == null);
    try std.testing.expectEqual(paged_reader.PagedReader.SlotRole.displayed, coordinator.paged.slots[coordinator.paged.current_page].role);
    try std.testing.expectEqual(paged_reader.PagedReader.BuildState.idle, coordinator.paged.build);
    switch (coordinator.renderModel()) {
        .paged => |view| try std.testing.expect(!view.waiting),
        else => return error.TestUnexpectedResult,
    }
}

test "failed prefetch converts a waiting boundary into a normal chapter request" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = ChapterSlotHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = ChapterSlotHostFake.open, .close = ChapterSlotHostFake.close, .list_epubs = ChapterSlotHostFake.list },
        .measure = .{ .context = &fake, .width = ChapterSlotHostFake.width, .font_height = testFontHeight },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    coordinator.book_session.publication.spine_len = 2;
    coordinator.chapter_index = 0;
    coordinator.paged.next_ready = true;
    _ = coordinator.chapter_pump.decode_workspace.beginActive();
    coordinator.chapter_pump.decode_workspace.markActiveVerifiedEof();

    try std.testing.expect(coordinator.startPrefetch());
    coordinator.requestNextChapter();
    coordinator.stepPrefetch();

    try std.testing.expectEqual(@as(?u8, 1), coordinator.requestedChapter());
}

test "bounded chapter work finds the requested spine entry and starts its stream" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = StoredChapterHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list },
        .measure = .{ .context = &fake, .width = StoredChapterHostFake.width, .font_height = testFontHeight },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    const path = StoredChapterHostFake.name;
    @memcpy(coordinator.book_session.publication.spine[0].path[0..path.len], path);
    coordinator.book_session.publication.spine[0].path_len = path.len;
    coordinator.book_session.publication.spine_len = 1;
    coordinator.lifecycle = .ready;

    coordinator.openChapter(0, .normal);
    for (0..32) |_| {
        _ = coordinator.stepChapter(20);
        if (coordinator.activeChapter() != null) break;
    }

    try std.testing.expectEqual(@as(?u8, 0), coordinator.activeChapter());
    try std.testing.expectEqual(@as(u8, 1), fake.open_calls);
}

test "bounded chapter work streams a requested chapter into the paged render view" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = StoredChapterHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list },
        .measure = .{ .context = &fake, .width = StoredChapterHostFake.width, .font_height = testFontHeight },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    const path = StoredChapterHostFake.name;
    @memcpy(coordinator.book_session.publication.spine[0].path[0..path.len], path);
    coordinator.book_session.publication.spine[0].path_len = path.len;
    coordinator.book_session.publication.spine_len = 1;
    coordinator.lifecycle = .ready;
    coordinator.beginReading();

    coordinator.openChapter(0, .normal);
    for (0..64) |_| _ = coordinator.stepChapter(20);

    switch (coordinator.renderModel()) {
        .paged => |view| try std.testing.expect(!view.waiting),
        else => return error.TestUnexpectedResult,
    }
}

const PauseStoreFake = struct {
    position: [@import("../storage/resume.zig").encoded_size]u8 = undefined,
    progress: [reading_progress.encoded_size]u8 = undefined,
    pace: [reading_pace.encoded_size]u8 = undefined,
    position_writes: usize = 0,
    progress_writes: usize = 0,
    pace_writes: usize = 0,
    fail_progress: bool = false,
    fail_position: bool = false,
    fail_delete: bool = false,
    position_attempts: usize = 0,

    fn port(self: *PauseStoreFake) persistence.FileStore {
        return .{ .context = self, .read = read, .write = write, .delete = delete, .ensure_directory = ensureDirectory };
    }

    fn read(context: *anyopaque, name: []const u8, output: []u8) bool {
        const self: *PauseStoreFake = @ptrCast(@alignCast(context));
        if (std.mem.endsWith(u8, name, "/resume.bin") and self.position_writes != 0 and output.len == self.position.len) {
            @memcpy(output, &self.position);
            return true;
        }
        if (std.mem.endsWith(u8, name, "/progress.bin") and self.progress_writes != 0 and output.len == self.progress.len) {
            @memcpy(output, &self.progress);
            return true;
        }
        if (std.mem.endsWith(u8, name, "/pace.bin") and self.pace_writes != 0 and output.len == self.pace.len) {
            @memcpy(output, &self.pace);
            return true;
        }
        return false;
    }

    fn write(context: *anyopaque, name: []const u8, bytes: []const u8) bool {
        const self: *PauseStoreFake = @ptrCast(@alignCast(context));
        if (std.mem.endsWith(u8, name, "/resume.bin")) {
            self.position_attempts += 1;
            if (self.fail_position) return false;
            @memcpy(&self.position, bytes);
            self.position_writes += 1;
        } else if (std.mem.endsWith(u8, name, "/progress.bin")) {
            if (self.fail_progress) return false;
            @memcpy(&self.progress, bytes);
            self.progress_writes += 1;
        } else if (std.mem.endsWith(u8, name, "/pace.bin")) {
            @memcpy(&self.pace, bytes);
            self.pace_writes += 1;
        }
        return true;
    }

    fn delete(context: *anyopaque, name: []const u8) bool {
        const self: *PauseStoreFake = @ptrCast(@alignCast(context));
        if (self.fail_delete) return false;
        if (std.mem.endsWith(u8, name, "/resume.bin")) self.position_writes = 0;
        return true;
    }

    fn ensureDirectory(_: *anyopaque, _: []const u8) bool {
        return true;
    }
};

fn initPauseTest(coordinator: *ReaderCoordinator, files: *PauseStoreFake) !void {
    coordinator.initInPlace(128);
    coordinator.attachPersistence(persistence.Service.init(files.port()));
    coordinator.library.add("Example.epub");
    _ = coordinator.selectBook();
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.book_session.publication.spine_len = 1;
    coordinator.paged.current_ready = true;
    try coordinator.paged.pages[0].appendLineWithMetadata("latest word", 0, 2);
    coordinator.paged.pages[0].first_word_ordinal = 40;
    coordinator.paged.pages[0].word_count = 2;
    coordinator.paged.selected_word_ordinal = 41;
}

test "lifecycle pause immediately round trips Pages Scroll and RSVP positions" {
    for (0..3) |presentation| {
        var files = PauseStoreFake{};
        var coordinator: ReaderCoordinator = undefined;
        try initPauseTest(&coordinator, &files);
        if (presentation == 1) coordinator.paged_presentation = .scroll;
        if (presentation == 2) {
            coordinator.mode = .rsvp;
            coordinator.rsvp_reader.begin(0);
            _ = try coordinator.rsvp_reader.feed("<p>one two three </p>");
        }
        const expected = coordinator.positionSnapshot();
        coordinator.requestPositionSave();
        coordinator.systemPaused(1);
        try std.testing.expectEqual(@as(usize, 1), files.position_writes);
        try std.testing.expect(!coordinator.persistence.?.writePending(.position));
        const restored = coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(expected, restored.snapshot);
    }
}

test "lifecycle pause preserves target words in both mode transfer directions" {
    for ([_]ReadingMode{ .paged, .rsvp }) |mode| {
        var files = PauseStoreFake{};
        var coordinator: ReaderCoordinator = undefined;
        try initPauseTest(&coordinator, &files);
        coordinator.mode = mode;
        if (mode == .rsvp) {
            coordinator.rsvp_reader.begin(0);
            _ = try coordinator.rsvp_reader.feed("<p>one two three </p>");
        }
        const target = coordinator.positionSnapshot().word_ordinal;
        coordinator.switchReadingMode(1);
        try std.testing.expect(coordinator.chapter_pump.chapter_open != null);
        coordinator.systemPaused(2);
        const restored = coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(target, restored.snapshot.word_ordinal);
        try std.testing.expectEqual(coordinator.positionSnapshot(), restored.snapshot);
    }
}

test "lifecycle pause does not recreate reset position or replace Library browser resume" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    coordinator.flushPositionNow();
    const saved = coordinator.positionSnapshot();
    coordinator.chapter_browser_from_library = true;
    coordinator.screen = .chapter_browser;
    coordinator.paged.selected_word_ordinal = 40;
    coordinator.systemPaused(1);
    try std.testing.expectEqual(@as(usize, 1), files.position_writes);
    const restored = coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(saved, restored.snapshot);

    coordinator.chapter_browser_from_library = false;
    coordinator.screen = .settings;
    coordinator.settings_menu_state.selected = .reset_progress;
    coordinator.updateResetHold(true, true, 2);
    coordinator.updateResetHold(true, false, 2 + reset_hold_duration_ms);
    coordinator.systemPaused(3 + reset_hold_duration_ms);
    try std.testing.expectEqual(@as(usize, 0), files.position_writes);
    try std.testing.expect(coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision) == null);
}

test "lifecycle pause skips unopened and unresolved nonsemantic positions" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    coordinator.lifecycle = .opening;
    coordinator.systemPaused(1);
    try std.testing.expectEqual(@as(usize, 0), files.position_writes);
    coordinator.lifecycle = .ready;
    coordinator.paged.beginRescan(5);
    coordinator.systemPaused(2);
    try std.testing.expectEqual(@as(usize, 0), files.position_writes);
}

test "lifecycle pause flushes dirty partial progress and pace and retains failed progress" {
    var files = PauseStoreFake{ .fail_progress = true };
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    const key = persistence.ProgressKey{ .book_id = coordinator.bookIdentity(), .publication_fingerprint = [_]u8{0xa5} ** 16, .word_semantics_revision = word_semantics_revision, .spine_len = 2 };
    coordinator.progress_worker.index = try reading_progress.Index.init(key);
    _ = try coordinator.progress_worker.observeChapterTotal(0, 42);
    coordinator.pace = .{ .book_id = coordinator.bookIdentity() };
    coordinator.requestPaceSave();
    coordinator.systemPaused(1);
    try std.testing.expect(coordinator.progress_worker.status().dirty);
    try std.testing.expect(coordinator.persistence.?.writePending(.progress));
    try std.testing.expectEqual(@as(usize, 1), files.pace_writes);
    files.fail_progress = false;
    coordinator.systemPaused(2);
    try std.testing.expect(!coordinator.progress_worker.status().dirty);
    const restored = coordinator.persistence.?.loadProgress(coordinator.active_book.slice(), key) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 42), restored.chapter_words[0]);
    try std.testing.expect(!restored.exact.contains(1));
    coordinator.systemPaused(3);
    try std.testing.expectEqual(@as(usize, 1), files.progress_writes);
    try std.testing.expectEqual(@as(usize, 1), files.pace_writes);
}

test "lifecycle pause during resume reconstruction retains the destination chapter and word" {
    for ([_]ReadingMode{ .paged, .rsvp }) |mode| {
        var files = PauseStoreFake{};
        var coordinator: ReaderCoordinator = undefined;
        try initPauseTest(&coordinator, &files);
        coordinator.mode = mode;
        coordinator.book_session.publication.spine_len = 2;
        const saved = persistence.ReadingSnapshot{ .book_id = coordinator.bookIdentity(), .layout_revision = layout_revision, .chapter = 1, .word_ordinal = 123, .mode = if (mode == .rsvp) .rsvp else .paged };
        try std.testing.expect(coordinator.persistence.?.savePosition(coordinator.active_book.slice(), saved));
        coordinator.restorePosition();
        try std.testing.expectEqual(@as(u8, 0), coordinator.chapter_index);
        try std.testing.expectEqual(@as(u8, 1), coordinator.chapter_pump.chapter_open.?.index);
        coordinator.systemPaused(1);
        const restored = coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(saved, restored.snapshot);
    }
}

test "active Pages and RSVP yield without archive errors on zero-output DEFLATE work" {
    const fixture = @import("../testing/decoder_work_fixture.zig");
    for ([_]ReadingMode{ .paged, .rsvp }) |mode| {
        var bytes: [90000]u8 = undefined;
        var source = fixture.Source{ .bytes = fixture.archive(&bytes, .dynamic, 200, "<p>one two</p>") };
        var scan: [128]u8 = undefined;
        var filename: [32]u8 = undefined;
        const archive = try zip.Archive.open(source.reader(), &scan);
        const entry = try archive.find(fixture.name, &filename);
        var coordinator: ReaderCoordinator = undefined;
        coordinator.initInPlace(128);
        const Measure = struct {
            fn width(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont, text: []const u8) usize {
                return text.len;
            }
        };
        coordinator.attachHost(.{ .measure = .{ .context = &source, .width = Measure.width, .font_height = testFontHeight } });
        coordinator.lifecycle = .ready;
        coordinator.screen = .reading;
        coordinator.mode = mode;
        coordinator.book_session.publication.spine_len = 1;
        try coordinator.beginOpenedChapter(archive, 0, entry, 0, null);
        var updates: usize = 0;
        for (0..2000) |frame| {
            source.bytes_read = 0;
            _ = coordinator.stepChapterStream(@intCast(frame));
            try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
            try std.testing.expect(source.bytes_read <= limits.decoder_input_bytes_per_update);
            if (if (mode == .paged) coordinator.paged.current_ready else coordinator.rsvp_reader.hasWord()) break;
            updates += 1;
        } else return error.TestUnexpectedResult;
        try std.testing.expect(updates > 10);
        if (mode == .paged) try std.testing.expectEqualStrings("one two", coordinator.paged.current().?.line(0));
        // Input handling still runs between decoder quanta.
        const old_wpm = coordinator.rsvp_reader.wpm;
        coordinator.update(.{ .buttons = .{ .up = true } }, 3000);
        if (mode == .rsvp) {
            try std.testing.expect(coordinator.rsvp_reader.wpm > old_wpm);
            coordinator.leaveBook(3001);
        }
        try std.testing.expectEqual(Screen.library, coordinator.screen);
        try std.testing.expect(coordinator.chapter_pump.chapter_stream == null);
    }
}

test "metadata opening shares one decoder budget across its chunk batch" {
    const fixture = @import("../testing/decoder_work_fixture.zig");
    var bytes: [90000]u8 = undefined;
    const text = "<container>test</container>";
    var source = fixture.Source{ .bytes = fixture.archive(&bytes, .stored, 10000, text) };
    var scan: [128]u8 = undefined;
    var filename: [32]u8 = undefined;
    const archive = try zip.Archive.open(source.reader(), &scan);
    const entry = try archive.find(fixture.name, &filename);
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var job = opening_session.Session.start();
    coordinator.book_session.opening_job = &job;
    job.archive = archive;
    try coordinator.beginMetadataRead(&job, entry, .container);
    var updates: usize = 0;
    for (0..2000) |_| {
        source.bytes_read = 0;
        if (coordinator.advanceMetadataReadBatch(&job, .container)) break;
        try std.testing.expect(source.bytes_read <= limits.decoder_input_bytes_per_update);
        try std.testing.expectEqual(Lifecycle.opening, coordinator.lifecycle);
        updates += 1;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(updates > 5);
    try std.testing.expectEqualStrings(text, job.container_xml[0..job.container_xml_len]);
    coordinator.book_session.opening_job = null;
}

test "navigation opening yields on table rebuilds without discarding TOC labels" {
    const fixture = @import("../testing/decoder_work_fixture.zig");
    var bytes: [90000]u8 = undefined;
    const text = "<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml\">Chapter One</a></li></ol></nav></body></html>";
    var source = fixture.Source{ .bytes = fixture.archive(&bytes, .dynamic, 200, text) };
    var scan: [128]u8 = undefined;
    var filename: [32]u8 = undefined;
    const archive = try zip.Archive.open(source.reader(), &scan);
    const entry = try archive.find(fixture.name, &filename);
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    coordinator.book_session.publication.spine_len = 1;
    coordinator.book_session.publication.spine[0].path_len = fixture.name.len;
    @memcpy(coordinator.book_session.publication.spine[0].path[0..fixture.name.len], fixture.name);
    var job = opening_session.Session.start();
    coordinator.book_session.opening_job = &job;
    job.archive = archive;
    coordinator.chapter_pump.opening_storage = zip.StreamStorage.init(&coordinator.chapter_pump.deflate_input_buffer, &coordinator.chapter_pump.deflate_window, &coordinator.chapter_pump.deflate_workspace);
    job.stream = try archive.begin(entry, &coordinator.chapter_pump.opening_storage);
    job.beginNavigationRead(.epub3, &coordinator.book_session.publication, "nav.xhtml");
    var updates: usize = 0;
    for (0..2000) |_| {
        source.bytes_read = 0;
        coordinator.advanceNavigationReadBatch(&job, .epub3);
        try std.testing.expect(source.bytes_read <= limits.decoder_input_bytes_per_update);
        if (coordinator.book_session.opening_job == null) break;
        try std.testing.expectEqual(opening_session.Phase.read_navigation, job.phase);
        updates += 1;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(updates > 10);
    try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
    try std.testing.expectEqualStrings("Chapter One", coordinator.book_session.publication.chapter_labels[0].slice());
}

test "new Unicode semantics rebuild progress while retaining old resume records" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    const snapshot = coordinator.positionSnapshot();
    coordinator.flushPositionNow();
    var key = persistence.ProgressKey{ .book_id = coordinator.bookIdentity(), .publication_fingerprint = [_]u8{0xa5} ** 16, .word_semantics_revision = 1, .spine_len = 1 };
    var progress = try reading_progress.Index.init(key);
    try progress.setExact(0, 100);
    try std.testing.expect(coordinator.persistence.?.saveProgress(coordinator.active_book.slice(), progress));
    key.word_semantics_revision = word_semantics_revision;
    try std.testing.expect(coordinator.persistence.?.loadProgress(coordinator.active_book.slice(), key) == null);
    coordinator.refreshLibraryProgress();
    coordinator.screen = .library;
    coordinator.stepLibraryProgress();
    try std.testing.expect(coordinator.library_progress[0] == null);
    const restored = coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision).?;
    try std.testing.expectEqual(snapshot, restored.snapshot);
    progress.key = key;
    try std.testing.expect(coordinator.persistence.?.saveProgress(coordinator.active_book.slice(), progress));
    coordinator.refreshLibraryProgress();
    coordinator.screen = .library;
    coordinator.stepLibraryProgress();
    try std.testing.expect(coordinator.library_progress[0] != null);
}

test "reading traversal retains trailing unlabeled spine destinations in both directions" {
    for ([_]ReadingMode{ .paged, .rsvp }) |mode| {
        for ([_]PagedPresentation{ .pages, .scroll }) |presentation| {
            var coordinator: ReaderCoordinator = undefined;
            coordinator.initInPlace(128);
            @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
            const paths = [_][]const u8{ "OPS/wrap0000.xhtml", "OPS/body.xhtml", "OPS/appendix-a.xhtml", "OPS/appendix-b.xhtml", "OPS/image-wrapper.xhtml" };
            coordinator.book_session.publication.spine_len = paths.len;
            for (paths, 0..) |path, index| {
                coordinator.book_session.publication.spine[index].path_len = @intCast(path.len);
                @memcpy(coordinator.book_session.publication.spine[index].path[0..path.len], path);
            }
            coordinator.book_session.publication.chapter_labels[1].len = 1;
            coordinator.mode = mode;
            coordinator.paged_presentation = presentation;
            // The browser retains its intentional TOC suffix filter.
            try std.testing.expectEqual(@as(u8, 1), coordinator.visibleChapterCount());
            for (1..paths.len - 1) |index| {
                coordinator.chapter_index = @intCast(index);
                const next = coordinator.nextReadableChapter().?;
                try std.testing.expectEqual(@as(u8, @intCast(index + 1)), next);
                coordinator.openAdjacentChapter(1);
                try std.testing.expectEqual(@as(?u8, next), coordinator.requestedChapter());
                coordinator.chapter_index = next;
                try std.testing.expectEqual(@as(?u8, @intCast(index)), coordinator.previousReadableChapter());
                coordinator.openAdjacentChapter(-1);
                try std.testing.expectEqual(@as(?u8, @intCast(index)), coordinator.requestedChapter());
                if (mode == .paged and presentation == .scroll) {
                    try std.testing.expect(coordinator.chapter_pump.chapter_open.?.action == .rescan_to_last_page);
                } else try std.testing.expect(coordinator.chapter_pump.chapter_open.?.action == .normal);
            }
            coordinator.chapter_index = 1;
            try std.testing.expect(coordinator.previousReadableChapter() == null);
            coordinator.chapter_index = paths.len - 1;
            try std.testing.expect(coordinator.nextReadableChapter() == null);
        }
    }
}

test "cover filename heuristic does not remove a non-leading reading destination" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    const paths = [_][]const u8{ "body.xhtml", "OPS/WRAP0000.XHTML", "appendix.xhtml" };
    coordinator.book_session.publication.spine_len = paths.len;
    for (paths, 0..) |path, index| {
        coordinator.book_session.publication.spine[index].path_len = @intCast(path.len);
        @memcpy(coordinator.book_session.publication.spine[index].path[0..path.len], path);
    }
    coordinator.chapter_index = 0;
    try std.testing.expectEqual(@as(?u8, 1), coordinator.nextReadableChapter());
    coordinator.chapter_index = 2;
    try std.testing.expectEqual(@as(?u8, 1), coordinator.previousReadableChapter());
}

test "reset failure stays in Settings retains pending position and needs a fresh hold" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    coordinator.flushPositionNow();
    coordinator.requestPositionSave();
    files.fail_delete = true;
    coordinator.screen = .settings;
    coordinator.settings_menu_state.selected = .reset_progress;
    coordinator.updateResetHold(true, true, 0);
    coordinator.updateResetHold(true, false, reset_hold_duration_ms);
    try std.testing.expectEqual(Screen.settings, coordinator.screen);
    try std.testing.expect(!coordinator.position_save_suppressed);
    try std.testing.expect(coordinator.persistence.?.writePending(.position));
    try std.testing.expectEqualStrings("Reset failed. Hold A to retry.", coordinator.persistenceNotice().?);
    var sound_policy = sound.Policy{};
    const sound_batch = sound_policy.drain(&coordinator.sound_events, .full, reset_hold_duration_ms);
    try std.testing.expectEqual(@as(usize, 1), sound_batch.len);
    try std.testing.expectEqual(sound.Cue.error_cue, sound_batch.items[0].cue);
    coordinator.updateResetHold(true, false, reset_hold_duration_ms + 1);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.updateResetHold(true, false, 6000);
    try std.testing.expect(coordinator.reset_hold_started_at == null);
    files.fail_delete = false;
    coordinator.updateResetHold(true, true, 7000);
    coordinator.updateResetHold(true, false, 10000);
    try std.testing.expectEqual(Screen.library, coordinator.screen);
    try std.testing.expect(coordinator.persistenceNotice() == null);
    try std.testing.expect(coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision) == null);
}

test "failed exit save keeps book data available and retries without frame by frame I/O" {
    var files = PauseStoreFake{ .fail_position = true };
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    coordinator.leaveBook(0);
    try std.testing.expectEqual(Screen.reading, coordinator.screen);
    try std.testing.expectEqualStrings("Save failed. Retrying...", coordinator.persistenceNotice().?);
    try std.testing.expect(coordinator.persistence.?.writePending(.position));
    files.fail_position = false;
    coordinator.paged.selected_word_ordinal = 40;
    for (1..2000) |now| {
        coordinator.frame_now_ms = @intCast(now);
        coordinator.flushPersistence();
    }
    try std.testing.expectEqual(@as(usize, 1), files.position_attempts);
    coordinator.frame_now_ms = 2000;
    coordinator.flushPersistence();
    try std.testing.expectEqual(@as(usize, 2), files.position_attempts);
    try std.testing.expect(coordinator.persistenceNotice() == null);
    const restored = coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision).?;
    try std.testing.expectEqual(@as(u32, 40), restored.snapshot.word_ordinal);
    coordinator.leaveBook(2001);
    try std.testing.expectEqual(Screen.library, coordinator.screen);
}

test "a chapter failure retries the last valid pending semantic position" {
    var files = PauseStoreFake{ .fail_position = true };
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    const expected = coordinator.positionSnapshot();
    coordinator.requestPositionSave();
    coordinator.flushPositionNow();
    coordinator.lifecycle = .chapter_error;
    coordinator.paged.selected_word_ordinal = 0;
    files.fail_position = false;
    coordinator.frame_now_ms = 2000;
    coordinator.flushPersistence();
    try std.testing.expectEqual(expected, coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision).?.snapshot);
    coordinator.leaveBook(2001);
    try std.testing.expectEqual(Screen.library, coordinator.screen);
}

test "turning past a continuing word does not count it as completed for pace" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.book_session.publication.spine_len = 1;
    coordinator.pace = .{ .book_id = 7 };
    coordinator.paged.current_ready = true;
    coordinator.paged.next_ready = true;
    coordinator.paged.current_page = 0;
    coordinator.paged.next_page = 1;
    coordinator.paged.chapter_end = true;
    coordinator.paged.chapter_last_page = 1;
    coordinator.paged.pages[0].word_count = 2;
    coordinator.paged.pages[0].last_word_continues = true;
    coordinator.paged.pages[1].first_word_ordinal = 1;
    coordinator.paged.pages[1].word_count = 1;
    coordinator.syncManualPace(0);
    coordinator.performIntent(.next_page, 1_000);
    try std.testing.expectEqual(@as(u32, 1), coordinator.pace.completed_words);
}

fn soundTestReadyPages(coordinator: *ReaderCoordinator) !void {
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    @memset(std.mem.asBytes(&coordinator.book_session.publication), 0);
    coordinator.book_session.publication.spine_len = 1;
    coordinator.paged.current_ready = true;
    coordinator.paged.next_ready = true;
    coordinator.paged.chapter_end = true;
    coordinator.paged.chapter_last_page = 1;
    coordinator.paged.current_page = 0;
    coordinator.paged.next_page = 1;
    for (0..2) |i| {
        try coordinator.paged.pages[i].appendLineWithMetadata(if (i == 0) "one two" else "three four", @intCast(i * 2), 2);
        coordinator.paged.pages[i].first_word_ordinal = @intCast(i * 2);
        coordinator.paged.pages[i].word_count = 2;
    }
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 0 };
    coordinator.paged.slots[1] = .{ .role = .ready_ahead, .chapter = 0, .page = 1 };
}

test "sounds follow visible page destinations and never repeat on idle frames" {
    var coordinator: ReaderCoordinator = undefined;
    try soundTestReadyPages(&coordinator);
    coordinator.performIntent(.next_page, 0);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.observeSoundDestination(0);
    try std.testing.expectEqual(sound.Kind.page_changed, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.observeSoundDestination(10);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.performIntent(.previous_page, 20);
    coordinator.observeSoundDestination(20);
    try std.testing.expectEqual(@as(i8, -1), coordinator.sound_events.items[0].direction);
    coordinator.sound_events.clear();
    coordinator.performIntent(.previous_page, 30);
    try std.testing.expectEqual(sound.Kind.at_boundary, coordinator.sound_events.items[0].kind);
}

test "reconstruction waits for a drawable destination and chapter replaces page" {
    var coordinator: ReaderCoordinator = undefined;
    try soundTestReadyPages(&coordinator);
    coordinator.beginSoundNavigation(1, false);
    coordinator.paged.current_ready = false;
    coordinator.paged.page_index = 4;
    coordinator.observeSoundDestination(10);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    try std.testing.expect(coordinator.sound_navigation != null);
    coordinator.paged.current_ready = true;
    coordinator.observeSoundDestination(20);
    try std.testing.expectEqual(sound.Kind.page_changed, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.beginSoundNavigation(1, false);
    coordinator.chapter_index = 1;
    coordinator.paged.page_index = 0;
    coordinator.observeSoundDestination(30);
    try std.testing.expectEqual(sound.Kind.chapter_changed, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.beginSoundNavigation(-1, false);
    coordinator.failChapter(.archive);
    coordinator.observeSoundDestination(40);
    try std.testing.expectEqual(@as(usize, 1), coordinator.sound_events.len);
    try std.testing.expectEqual(sound.Kind.failure, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.failChapter(.archive);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
}

test "Full crank selection coalesces and scrolling stays silent across page seams" {
    var coordinator: ReaderCoordinator = undefined;
    try soundTestReadyPages(&coordinator);
    coordinator.paged.selected_word_ordinal = 0;
    coordinator.handleCrank(crank_degrees_per_word, 0);
    coordinator.observeSoundDestination(0);
    try std.testing.expectEqual(sound.Kind.word_selection, coordinator.sound_events.items[0].kind);
    var policy = sound.Policy{};
    try std.testing.expectEqual(@as(usize, 0), policy.drain(&coordinator.sound_events, .subtle, 0).len);
    coordinator.paged_presentation = .scroll;
    coordinator.beginSoundNavigation(1, false);
    coordinator.paged.scroll_position.offset_px = 12;
    coordinator.observeSoundDestination(20);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.beginSoundNavigation(1, false);
    coordinator.paged.scroll_position.top_page = 1;
    coordinator.observeSoundDestination(30);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    try std.testing.expectEqual(@as(usize, 0), policy.drain(&coordinator.sound_events, .full, 30).len);
    coordinator.beginSoundNavigation(1, false);
    coordinator.chapter_index += 1;
    coordinator.observeSoundDestination(40);
    try std.testing.expectEqual(sound.Kind.chapter_changed, coordinator.sound_events.items[0].kind);
}

test "system menu surfaces and Sound changes use the new level" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    try std.testing.expectEqual(SoundLevel.full, coordinator.sound_level);
    coordinator.sound_level = .subtle;
    coordinator.handleSystemAction(.settings, 20);
    try std.testing.expectEqual(sound.Kind.surface_opened, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.settings_menu_state.selected = .sound;
    coordinator.performIntent(.activate_setting, 20);
    try std.testing.expectEqual(SoundLevel.full, coordinator.sound_level);
    var policy = sound.Policy{};
    try std.testing.expectEqual(sound.Cue.ui_confirm, policy.drain(&coordinator.sound_events, coordinator.sound_level, 20).items[0].cue);
    coordinator.performIntent(.activate_setting, 30);
    try std.testing.expectEqual(SoundLevel.off, coordinator.sound_level);
    try std.testing.expectEqual(@as(usize, 0), policy.drain(&coordinator.sound_events, coordinator.sound_level, 30).len);
    coordinator.performIntent(.activate_setting, 40);
    try std.testing.expectEqual(SoundLevel.subtle, coordinator.sound_level);
    try std.testing.expectEqual(@as(usize, 1), policy.drain(&coordinator.sound_events, coordinator.sound_level, 40).len);
    try std.testing.expect(coordinator.chapter_pump.chapter_open == null);
}

test "reset milestones coalesce missed pulses and completion replaces exit" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .settings;
    coordinator.settings_menu_state.selected = .reset_progress;
    coordinator.updateResetHold(true, true, 0);
    try std.testing.expectEqual(sound.Kind.reset_started, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.updateResetHold(true, false, 2100);
    try std.testing.expectEqual(@as(usize, 1), coordinator.sound_events.len);
    try std.testing.expectEqual(sound.Kind.reset_milestone, coordinator.sound_events.items[0].kind);
    try std.testing.expectEqual(@as(i8, 2), coordinator.sound_events.items[0].direction);
    coordinator.sound_events.clear();
    coordinator.updateResetHold(true, false, 2200);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.updateResetHold(true, false, 3000);
    var policy = sound.Policy{};
    const batch = policy.drain(&coordinator.sound_events, .full, 3000);
    try std.testing.expectEqual(@as(usize, 1), batch.len);
    try std.testing.expectEqual(sound.Cue.reset_complete, batch.items[0].cue);
    coordinator.updateResetHold(true, false, 3100);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.screen = .settings;
    coordinator.updateResetHold(true, true, 4000);
    coordinator.sound_events.clear();
    coordinator.updateResetHold(false, false, 4100);
    try std.testing.expectEqual(sound.Kind.reset_cancelled, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.updateResetHold(false, false, 4200);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
}

test "opening threshold, automatic RSVP silence and pause cancellation" {
    var coordinator: ReaderCoordinator = undefined;
    try soundTestReadyPages(&coordinator);
    coordinator.sound_opening_started = 0;
    coordinator.observeSoundDestination(499);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.sound_opening_started = 0;
    coordinator.observeSoundDestination(500);
    try std.testing.expectEqual(sound.Kind.surface_opened, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.mode = .rsvp;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("<p>one two three four.</p>");
    try coordinator.rsvp_reader.finishInput();
    _ = coordinator.rsvp_reader.previousSentence();
    coordinator.rsvp_reader.toggleAutoplay(0, &coordinator.pace);
    coordinator.advanceAutoplay(250);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.beginSoundNavigation(1, true);
    coordinator.chapter_index = 1;
    coordinator.observeSoundDestination(300);
    try std.testing.expectEqual(sound.Kind.chapter_changed, coordinator.sound_events.items[0].kind);
    try std.testing.expect(coordinator.sound_events.items[0].quiet);
    coordinator.sound_opening_started = 300;
    coordinator.beginSoundNavigation(1, false);
    coordinator.systemPaused(310);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    try std.testing.expect(coordinator.sound_navigation == null);
    try std.testing.expect(coordinator.sound_opening_started == null);
}

test "chapter-browser acceptance is cued once and cancellation clears pending movement" {
    var coordinator: ReaderCoordinator = undefined;
    try soundTestReadyPages(&coordinator);
    coordinator.chapter_browser = chapter_browser.Model.init(1, 0);
    coordinator.screen = .chapter_browser;
    coordinator.performIntent(.open_browser_chapter, 0);
    try std.testing.expectEqual(@as(usize, 1), coordinator.sound_events.len);
    try std.testing.expectEqual(sound.Kind.chapter_changed, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.cancelChapter();
    coordinator.paged.current_ready = true;
    coordinator.observeSoundDestination(10);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.beginSoundNavigation(1, false);
    coordinator.openChapter(0, .normal);
    try std.testing.expect(coordinator.sound_navigation != null);
    coordinator.cancelChapter();
    try std.testing.expect(coordinator.sound_navigation == null);
}

test "manual rewind is accepted once and unrelated restoration remains silent" {
    var coordinator: ReaderCoordinator = undefined;
    try soundTestReadyPages(&coordinator);
    coordinator.mode = .rsvp;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("<p>One two. Three four.</p>");
    try coordinator.rsvp_reader.finishInput();
    coordinator.previousRsvpSentence(0);
    try std.testing.expectEqual(@as(usize, 1), coordinator.sound_events.len);
    try std.testing.expectEqual(sound.Kind.sentence_rewind, coordinator.sound_events.items[0].kind);
    coordinator.sound_events.clear();
    coordinator.observeSoundDestination(10);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
    coordinator.mode = .paged;
    coordinator.paged.page_index = 5;
    coordinator.observeSoundDestination(20);
    try std.testing.expectEqual(@as(usize, 0), coordinator.sound_events.len);
}

test "B and Up cancel opening before another work step and release its lease once" {
    const Tracker = struct {
        closes: usize = 0,
        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closes += 1;
        }
    };
    for ([_]input.Buttons{ .{ .b = true }, .{ .up = true } }) |buttons| {
        const coordinator = try std.testing.allocator.create(ReaderCoordinator);
        defer std.testing.allocator.destroy(coordinator);
        coordinator.initInPlace(128);
        coordinator.attachAllocator(std.testing.allocator);
        coordinator.library.add("book.epub");
        try std.testing.expect(coordinator.openSelectedBook());
        var tracker = Tracker{};
        coordinator.book_session.opening_job.?.file = .{ .context = &tracker, .close = Tracker.close };
        coordinator.opening_chapter_request = 0;
        coordinator.update(.{ .buttons = buttons }, 10);
        try std.testing.expectEqual(Screen.library, coordinator.screen);
        try std.testing.expect(coordinator.book_session.opening_job == null);
        try std.testing.expect(coordinator.opening_chapter_request == null);
        try std.testing.expect(!coordinator.book_loading);
        try std.testing.expect(coordinator.sound_opening_started == null);
        try std.testing.expectEqual(@as(usize, 1), tracker.closes);
        coordinator.update(.{}, 20);
        try std.testing.expectEqual(Screen.library, coordinator.screen);
        try std.testing.expectEqual(@as(usize, 1), tracker.closes);
    }
}

test "B and Up cancel initial chapter preparation after metadata has opened" {
    const Saves = struct {
        writes: usize = 0,
        fn read(_: *anyopaque, _: []const u8, _: []u8) bool {
            return false;
        }
        fn write(context: *anyopaque, _: []const u8, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.writes += 1;
            return true;
        }
        fn succeed(_: *anyopaque, _: []const u8) bool {
            return true;
        }
    };
    for ([_]input.Buttons{ .{ .b = true }, .{ .up = true } }) |buttons| {
        for ([_]ReadingMode{ .paged, .rsvp }) |mode| {
            const coordinator = try std.testing.allocator.create(ReaderCoordinator);
            defer std.testing.allocator.destroy(coordinator);
            coordinator.initInPlace(128);
            var source = StoredChapterHostFake.init();
            try resolveStoredFixture(coordinator, &source);
            coordinator.attachHost(.{
                .files = .{ .context = &source, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list },
                .measure = .{ .context = &source, .width = StoredChapterHostFake.width, .font_height = testFontHeight },
            });
            var saves = Saves{};
            coordinator.attachPersistence(persistence.Service.init(.{
                .context = &saves,
                .read = Saves.read,
                .write = Saves.write,
                .delete = Saves.succeed,
                .ensure_directory = Saves.succeed,
            }));
            coordinator.lifecycle = .ready;
            coordinator.screen = .reading;
            coordinator.mode = mode;
            coordinator.book_loading = true;
            coordinator.telemetry.loading.begin(0);
            coordinator.openChapter(0, .normal);
            _ = coordinator.stepChapter(0);
            const reads = source.read_calls;
            const closes = source.close_calls;
            coordinator.update(.{ .buttons = buttons }, 10);
            try std.testing.expectEqual(Screen.library, coordinator.screen);
            try std.testing.expectEqual(mode, coordinator.mode);
            try std.testing.expect(coordinator.chapter_pump.chapter_open == null);
            try std.testing.expect(coordinator.chapter_pump.chapter_stream == null);
            try std.testing.expect(!coordinator.book_loading);
            try std.testing.expectEqual(@as(usize, 0), saves.writes);
            try std.testing.expectEqual(reads, source.read_calls);
            try std.testing.expectEqual(closes + 1, source.close_calls);
        }
    }
}

fn testFontHeight(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont) usize {
    return 20;
}

fn installEndProgressForTest(coordinator: *ReaderCoordinator, words: u32) !void {
    coordinator.book_session.publication.spine_len = 2;
    coordinator.progress_worker.index = try reading_progress.Index.init(.{
        .book_id = coordinator.bookIdentity(),
        .publication_fingerprint = @splat(0xa5),
        .word_semantics_revision = word_semantics_revision,
        .spine_len = 2,
    });
    try coordinator.progress_worker.index.?.setExact(0, words);
    try coordinator.progress_worker.index.?.setExact(1, 0);
}

test "last Pages viewport rounds to 100 docked or undocked without moving resume or pace" {
    for ([_]bool{ true, false }) |docked| {
        var files = PauseStoreFake{};
        var coordinator: ReaderCoordinator = undefined;
        try initPauseTest(&coordinator, &files);
        try installEndProgressForTest(&coordinator, 42);
        coordinator.paged.selected_word_ordinal = 40;
        coordinator.crank_docked = docked;
        const pace_before = coordinator.pace;
        try std.testing.expect(coordinator.atBookEnd());
        try std.testing.expectEqual(@as(u64, 42), coordinator.progressView().?.book.exact.reached.toU64());
        try std.testing.expectEqual(@as(u64, 0), coordinator.progressView().?.book.exact.remaining.toU64());
        try std.testing.expectEqual(@as(u32, 40), coordinator.positionSnapshot().word_ordinal);
        try std.testing.expect(coordinator.positionSnapshot().at_book_end);
        try std.testing.expectEqual(pace_before, coordinator.pace);
        // Returning to an earlier page immediately restores the normal ratio.
        coordinator.paged.pages[0].first_word_ordinal = 0;
        coordinator.paged.selected_word_ordinal = 0;
        try std.testing.expect(!coordinator.atBookEnd());
        try std.testing.expect(!coordinator.positionSnapshot().at_book_end);
        try std.testing.expectEqual(@as(u64, 1), coordinator.progressView().?.book.exact.reached.toU64());
    }
}

test "terminal adjustment round trips through saves and Library and clears on a backward position" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    try installEndProgressForTest(&coordinator, 42);
    coordinator.paged.selected_word_ordinal = 40;
    try std.testing.expect(coordinator.persistence.?.saveProgress(coordinator.active_book.slice(), coordinator.progress_worker.index.?));
    coordinator.systemPaused(1);
    const restored = coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision).?.snapshot;
    try std.testing.expect(restored.at_book_end);
    try std.testing.expectEqual(@as(u32, 40), restored.word_ordinal);
    coordinator.screen = .library;
    coordinator.refreshLibraryProgress();
    coordinator.stepLibraryProgress();
    try std.testing.expectEqual(@as(?u8, 100), coordinator.library_progress[0]);
    coordinator.screen = .reading;
    coordinator.paged.pages[0].first_word_ordinal = 0;
    coordinator.paged.selected_word_ordinal = 0;
    coordinator.systemPaused(2);
    coordinator.screen = .library;
    coordinator.refreshLibraryProgress();
    coordinator.stepLibraryProgress();
    try std.testing.expectEqual(@as(?u8, 2), coordinator.library_progress[0]);
    try std.testing.expect(!coordinator.persistence.?.loadPosition(coordinator.active_book.slice(), coordinator.bookIdentity(), layout_revision).?.snapshot.at_book_end);
}

test "end rounding excludes provisional positions continued words and unverified suffixes" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    try installEndProgressForTest(&coordinator, 42);
    coordinator.paged.selected_word_ordinal = 40;
    try std.testing.expect(coordinator.atBookEnd());
    coordinator.chapter_browser_from_library = true;
    try std.testing.expect(!coordinator.atBookEnd());
    coordinator.chapter_browser_from_library = false;
    coordinator.pending_mode_word_ordinal = 40;
    try std.testing.expect(!coordinator.atBookEnd());
    coordinator.pending_mode_word_ordinal = null;
    coordinator.scroll_restore_pending = .{ .word = 40 };
    try std.testing.expect(!coordinator.atBookEnd());
    coordinator.scroll_restore_pending = null;
    coordinator.paged.pages[0].last_word_continues = true;
    try std.testing.expect(!coordinator.atBookEnd());
    coordinator.paged.pages[0].last_word_continues = false;
    try coordinator.progress_worker.index.?.setFailed(1);
    try std.testing.expect(!coordinator.atBookEnd());
    try coordinator.progress_worker.index.?.setExact(1, 1);
    try std.testing.expect(!coordinator.atBookEnd());
}

test "indexing can discover the ending without movement and schedule one positional save" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    try installEndProgressForTest(&coordinator, 43);
    coordinator.paged.selected_word_ordinal = 40;
    coordinator.observeEndProgress();
    try std.testing.expect(!coordinator.persistence.?.writePending(.position));
    try coordinator.progress_worker.index.?.setExact(0, 42);
    coordinator.frame_now_ms = 100;
    coordinator.observeEndProgress();
    try std.testing.expect(coordinator.persistence.?.writePending(.position));
    coordinator.frame_now_ms = 2100;
    coordinator.flushPersistence();
    try std.testing.expectEqual(@as(usize, 1), files.position_writes);
    coordinator.observeEndProgress();
    try std.testing.expect(!coordinator.persistence.?.writePending(.position));
    coordinator.paged.pages[0].first_word_ordinal = 0;
    coordinator.paged.selected_word_ordinal = 0;
    coordinator.observeEndProgress();
    try std.testing.expect(coordinator.persistence.?.writePending(.position));
}

test "Scroll rounds only at its ending viewport and RSVP follows its displayed final word" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    var context: u8 = 0;
    const Measure = struct {
        fn height(_: *anyopaque, _: @import("../storage/settings.zig").ReadingFont) usize {
            return 21;
        }
    };
    coordinator.attachHost(.{ .measure = .{ .context = &context, .width = LibraryHostFake.width, .font_height = Measure.height } });
    try installEndProgressForTest(&coordinator, 42);
    coordinator.paged.slots[0] = .{ .role = .displayed, .chapter = 0, .page = 0 };
    coordinator.paged_presentation = .scroll;
    try std.testing.expect(coordinator.atBookEnd());
    coordinator.paged.pages[0].line_count = 11;
    // The last line extends ten pixels beyond the viewport.
    try std.testing.expect(!coordinator.atBookEnd());
    coordinator.paged.scroll_position.offset_px = 10;
    try std.testing.expect(coordinator.atBookEnd());
    coordinator.mode = .rsvp;
    try installEndProgressForTest(&coordinator, 2);
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("one ");
    try std.testing.expect(!coordinator.atBookEnd());
    _ = coordinator.rsvp_reader.nextWord();
    _ = try coordinator.rsvp_reader.feed("two ");
    try std.testing.expect(coordinator.atBookEnd());
    try std.testing.expectEqual(@as(u64, 2), coordinator.progressView().?.book.exact.reached.toU64());
    try std.testing.expectEqual(rsvp_reader.RsvpReader.Move.moved, coordinator.rsvp_reader.previousWord());
    try std.testing.expect(!coordinator.atBookEnd());
    try std.testing.expectEqual(@as(u64, 1), coordinator.progressView().?.book.exact.reached.toU64());
}

test "RSVP autoplay stops on the final word without requesting a nonexistent chapter" {
    var coordinator: ReaderCoordinator = undefined;
    try soundTestReadyPages(&coordinator);
    coordinator.mode = .rsvp;
    coordinator.book_session.publication.spine_len = 1;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("last ");
    try coordinator.rsvp_reader.finishInput();
    coordinator.rsvp_reader.toggleAutoplay(0, &coordinator.pace);
    coordinator.frame_now_ms = 1000;
    coordinator.advanceAutoplay(1000);
    try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
    try std.testing.expect(coordinator.chapter_pump.chapter_open == null);
    try std.testing.expectEqualStrings("last", coordinator.rsvp_reader.renderState().word.?);
    try std.testing.expect(!coordinator.rsvp_reader.timer.running);
    try std.testing.expect(coordinator.sound_navigation == null);
    const pace_after = coordinator.pace;
    coordinator.advanceAutoplay(2000);
    try std.testing.expectEqual(pace_after, coordinator.pace);
    coordinator.handleRsvpMove(coordinator.rsvp_reader.nextWord());
    try std.testing.expect(coordinator.chapter_pump.chapter_open == null);
}

test "RSVP skips verified empty suffixes but still enters a nonempty next chapter" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    try installEndProgressForTest(&coordinator, 1);
    coordinator.mode = .rsvp;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("last ");
    try coordinator.rsvp_reader.finishInput();
    coordinator.rsvp_reader.toggleAutoplay(0, &coordinator.pace);
    coordinator.handleRsvpMove(coordinator.rsvp_reader.nextWord());
    try std.testing.expect(coordinator.chapter_pump.chapter_open == null);
    try std.testing.expect(!coordinator.rsvp_reader.timer.running);
    try coordinator.progress_worker.index.?.setExact(1, 3);
    coordinator.handleRsvpMove(coordinator.rsvp_reader.nextWord());
    try std.testing.expectEqual(@as(u8, 1), coordinator.chapter_pump.chapter_open.?.index);
}

test "RSVP discovering an uncounted empty tail restores the last readable destination" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    coordinator.mode = .rsvp;
    coordinator.book_session.publication.spine_len = 3;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("last ");
    try coordinator.rsvp_reader.finishInput();
    coordinator.handleRsvpMove(coordinator.rsvp_reader.nextWord());
    try std.testing.expectEqual(@as(u8, 1), coordinator.chapter_pump.chapter_open.?.index);
    coordinator.chapter_index = 1;
    coordinator.rsvp_reader.begin(1);
    try coordinator.rsvp_reader.finishInput();
    coordinator.advancePastEmptyRsvpChapter(1000);
    try std.testing.expectEqual(@as(u8, 2), coordinator.chapter_pump.chapter_open.?.index);
    try std.testing.expectEqual(@as(u16, 0), coordinator.positionSnapshot().chapter);
    coordinator.chapter_index = 2;
    coordinator.rsvp_reader.begin(2);
    try coordinator.rsvp_reader.finishInput();
    coordinator.advancePastEmptyRsvpChapter(2000);
    try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
    const request = coordinator.chapter_pump.chapter_open.?;
    try std.testing.expectEqual(@as(u8, 0), request.index);
    try std.testing.expectEqual(@as(u32, 0), request.action.rsvp_rescan.word);
    try std.testing.expectEqual(@as(?u32, 0), coordinator.pending_mode_word_ordinal);
    try std.testing.expect(!coordinator.rsvp_reader.timer.running);
    try std.testing.expect(coordinator.rsvp_tail_return == null);
}

test "an entirely empty RSVP book still reports no supported text" {
    var coordinator: ReaderCoordinator = undefined;
    try soundTestReadyPages(&coordinator);
    coordinator.mode = .rsvp;
    coordinator.book_session.publication.spine_len = 1;
    coordinator.rsvp_reader.begin(0);
    try coordinator.rsvp_reader.finishInput();
    coordinator.advancePastEmptyRsvpChapter(0);
    try std.testing.expectEqual(Lifecycle.chapter_error, coordinator.lifecycle);
    try std.testing.expectEqual(ChapterFailure.no_supported_text, coordinator.chapter_failure);
}

test "streaming RSVP final-word forward request verifies EOF without an empty-chapter error" {
    var coordinator: ReaderCoordinator = undefined;
    try soundTestReadyPages(&coordinator);
    var source = StoredChapterHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &source, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list },
        .measure = .{ .context = &source, .width = StoredChapterHostFake.width, .font_height = testFontHeight },
    });
    coordinator.mode = .rsvp;
    coordinator.book_session.publication.spine_len = 1;
    var scan: [128]u8 = undefined;
    var filename: [32]u8 = undefined;
    const archive = try zip.Archive.open(source.reader(), &scan);
    const entry = try archive.find(StoredChapterHostFake.name, &filename);
    try coordinator.beginOpenedChapter(archive, 0, entry, 0, null);
    var steps: usize = 0;
    while (!coordinator.rsvp_reader.hasWord() and steps < 100) : (steps += 1) _ = coordinator.stepChapter(0);
    try std.testing.expectEqualStrings("Hello", coordinator.rsvp_reader.renderState().word.?);
    coordinator.handleRsvpMove(coordinator.rsvp_reader.nextWord());
    while (!coordinator.rsvp_reader.hasWord() and steps < 200) : (steps += 1) _ = coordinator.stepChapter(100);
    try std.testing.expectEqualStrings("chapter", coordinator.rsvp_reader.renderState().word.?);
    try std.testing.expect(!coordinator.rsvp_reader.chapter_end);
    coordinator.rsvp_reader.toggleAutoplay(100, &coordinator.pace);
    coordinator.frame_now_ms = 1000;
    coordinator.advanceAutoplay(1000);
    try std.testing.expect(!coordinator.rsvp_reader.hasWord());
    while (!coordinator.chapter_end and steps < 300) : (steps += 1) _ = coordinator.stepChapter(1000);
    try std.testing.expect(coordinator.chapter_end);
    try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
    try std.testing.expect(coordinator.chapter_pump.chapter_open == null);
    try std.testing.expectEqualStrings("chapter", coordinator.rsvp_reader.renderState().word.?);
    try std.testing.expect(!coordinator.rsvp_reader.timer.running);
    try std.testing.expectEqual(@as(u32, 1), coordinator.positionSnapshot().word_ordinal);
    coordinator.cancelChapter();
}

test "Settings cycles page animations and the page view carries the selected style" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    coordinator.screen = .settings;
    coordinator.settings_menu_state.selected = .page_animation;
    coordinator.performIntent(.activate_setting, 0);
    try std.testing.expectEqual(page_transition.Style.slide, coordinator.page_animation);
    coordinator.screen = .reading;
    coordinator.page_transition_state.beginStyled(null, .backward, coordinator.page_animation, 0);
    coordinator.frame_now_ms = 100;
    const view = coordinator.pagedView();
    try std.testing.expectEqual(page_transition.Style.slide, view.transition.?.style);
    try std.testing.expectEqual(page_transition.Direction.backward, view.transition.?.direction);
    coordinator.updatePageTransition(.{ .chapter = 0, .page = 0 }, true, 101);
    try std.testing.expect(!coordinator.page_transition_state.active);
    for (0..4) |_| coordinator.performIntent(.activate_setting, 0);
    try std.testing.expectEqual(page_transition.Style.bands, coordinator.page_animation);
}

fn seedCrankMotionForTest(coordinator: *ReaderCoordinator, degrees: f32) void {
    coordinator.crank_accumulated = degrees;
    coordinator.scroll_crank_millidegrees = 1000;
    coordinator.paged.detent_backlog = 5;
    coordinator.paged.scroll_position.waiting_px = 12;
    coordinator.paged.scroll_position.pending_detents = 3;
    coordinator.scroll_chapter_end_overscroll_px = 10;
    coordinator.scroll_chapter_start_overscroll_px = 9;
}

fn expectCrankMotionCleared(coordinator: *const ReaderCoordinator) !void {
    try std.testing.expectEqual(@as(f32, 0), coordinator.crank_accumulated);
    try std.testing.expectEqual(@as(i32, 0), coordinator.scroll_crank_millidegrees);
    try std.testing.expectEqual(@as(i16, 0), coordinator.paged.detent_backlog);
    try std.testing.expectEqual(@as(i16, 0), coordinator.paged.scroll_position.waiting_px);
    try std.testing.expectEqual(@as(i16, 0), coordinator.paged.scroll_position.pending_detents);
    try std.testing.expectEqual(@as(u16, 0), coordinator.scroll_chapter_end_overscroll_px);
    try std.testing.expectEqual(@as(u16, 0), coordinator.scroll_chapter_start_overscroll_px);
}

test "partial and fast crank motion cannot cross Settings chapter browser or statistics boundaries" {
    for ([_]f32{ 14, 74, -74 }) |degrees| {
        for ([_]Screen{ .settings, .chapter_browser, .statistics }) |screen| {
            var files = PauseStoreFake{};
            var coordinator: ReaderCoordinator = undefined;
            try initPauseTest(&coordinator, &files);
            coordinator.crank_docked = false;
            const selected = coordinator.paged.selected_word_ordinal;
            seedCrankMotionForTest(&coordinator, degrees);
            switch (screen) {
                .settings => try std.testing.expect(coordinator.openSettings()),
                .chapter_browser => try std.testing.expect(coordinator.openChapterBrowser()),
                .statistics => try std.testing.expect(coordinator.openReadingStatistics(0)),
                else => unreachable,
            }
            try expectCrankMotionCleared(&coordinator);
            try std.testing.expectEqual(selected, coordinator.paged.selected_word_ordinal);
            seedCrankMotionForTest(&coordinator, degrees);
            switch (screen) {
                .settings => try std.testing.expect(coordinator.closeSettings()),
                .chapter_browser => try std.testing.expect(coordinator.closeChapterBrowser(0)),
                .statistics => {
                    try std.testing.expect(coordinator.closeStatistics(0));
                    coordinator.advanceStatisticsTransition(reading_statistics.sheet_exit_ms);
                },
                else => unreachable,
            }
            try expectCrankMotionCleared(&coordinator);
            coordinator.handleCrank(1, 0);
            try std.testing.expectEqual(selected, coordinator.paged.selected_word_ordinal);
            try std.testing.expectEqual(@as(f32, 1), coordinator.crank_accumulated);
        }
    }
}

test "leaving a book and navigating Library actions clears old crank motion" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    _ = coordinator.library.add("Another.epub");
    seedCrankMotionForTest(&coordinator, 74);
    coordinator.leaveBook(0);
    try std.testing.expectEqual(Screen.library, coordinator.screen);
    try expectCrankMotionCleared(&coordinator);
    coordinator.handleCrank(1, 0);
    try std.testing.expectEqual(@as(u8, 0), coordinator.library.selected);
    coordinator.handleCrank(14, 0);
    try std.testing.expectEqual(@as(u8, 1), coordinator.library.selected);
    seedCrankMotionForTest(&coordinator, 14);
    try std.testing.expect(coordinator.openBookActions());
    try expectCrankMotionCleared(&coordinator);
    seedCrankMotionForTest(&coordinator, 74);
    try std.testing.expect(coordinator.closeBookActions());
    try expectCrankMotionCleared(&coordinator);
    seedCrankMotionForTest(&coordinator, 14);
    try std.testing.expect(coordinator.openSettings());
    try expectCrankMotionCleared(&coordinator);
    try std.testing.expect(coordinator.closeSettings());
    coordinator.handleCrank(-1, 0);
    try std.testing.expectEqual(@as(u8, 1), coordinator.library.selected);
}

test "system RSVP toggle preserves the selected word and Pages or Scroll presentation" {
    for ([_]PagedPresentation{ .pages, .scroll }) |presentation| {
        var files = PauseStoreFake{};
        var coordinator: ReaderCoordinator = undefined;
        try initPauseTest(&coordinator, &files);
        coordinator.paged_presentation = presentation;
        const word = coordinator.currentPagedWordOrdinal();
        coordinator.handleSystemAction(.toggle_reading_mode, 1);
        try std.testing.expectEqual(ReadingMode.rsvp, coordinator.mode);
        try std.testing.expectEqual(word, coordinator.pending_mode_word_ordinal.?);
        try std.testing.expectEqual(word, coordinator.chapter_pump.chapter_open.?.action.rsvp_rescan.word);
        coordinator.rsvp_reader.begin(0);
        _ = try coordinator.rsvp_reader.feed("one two ");
        const rsvp_word = coordinator.rsvp_reader.position().word;
        coordinator.handleSystemAction(.toggle_reading_mode, 2);
        try std.testing.expectEqual(ReadingMode.paged, coordinator.mode);
        try std.testing.expectEqual(presentation, coordinator.paged_presentation);
        try std.testing.expectEqual(rsvp_word, coordinator.chapter_pump.chapter_open.?.action.word_rescan);
    }
}

test "system RSVP toggle does not interrupt initial book loading" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.book_loading = true;
    coordinator.handleSystemAction(.toggle_reading_mode, 0);
    try std.testing.expectEqual(ReadingMode.paged, coordinator.mode);
    try std.testing.expect(coordinator.pending_mode_word_ordinal == null);
}

test "mode presentation and sleep boundaries discard motion without changing semantic position" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    const selected = coordinator.paged.selected_word_ordinal;
    seedCrankMotionForTest(&coordinator, 74);
    coordinator.switchReadingMode(0);
    try expectCrankMotionCleared(&coordinator);
    try std.testing.expectEqual(selected, coordinator.pending_mode_word_ordinal);
    // Semantic restoration remains intentional even though queued detents end.
    seedCrankMotionForTest(&coordinator, 14);
    coordinator.systemPaused(1);
    try expectCrankMotionCleared(&coordinator);
    try std.testing.expectEqual(selected, coordinator.pending_mode_word_ordinal);
    seedCrankMotionForTest(&coordinator, -74);
    coordinator.systemResumed();
    try expectCrankMotionCleared(&coordinator);
    coordinator.lifecycle = .opening;
    coordinator.toggleMode();
    seedCrankMotionForTest(&coordinator, 14);
    coordinator.switchPagedPresentation();
    try expectCrankMotionCleared(&coordinator);
}

test "a crank sample accompanying a screen change cannot move the destination controls" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    _ = coordinator.library.add("Another.epub");
    coordinator.update(.{ .buttons = .{ .up = true }, .crank_change = 30, .crank_docked = false }, 0);
    try std.testing.expectEqual(Screen.library, coordinator.screen);
    try std.testing.expectEqual(@as(u8, 0), coordinator.library.selected);
    try expectCrankMotionCleared(&coordinator);
    coordinator.update(.{ .buttons = .{}, .crank_change = 15, .crank_docked = false }, 1);
    try std.testing.expectEqual(@as(u8, 1), coordinator.library.selected);
}

test "a real fast RSVP turn cannot leave detents for chapter-browser navigation" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    coordinator.mode = .rsvp;
    coordinator.crank_docked = false;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("one ");
    _ = try coordinator.rsvp_reader.feed("two ");
    try std.testing.expectEqual(rsvp_reader.RsvpReader.Move.moved, coordinator.rsvp_reader.previousWord());
    coordinator.handleCrank(74, 0);
    try std.testing.expectEqual(@as(f32, 59), coordinator.crank_accumulated);
    try std.testing.expectEqual(@as(u32, 1), coordinator.rsvp_reader.position().word);
    try std.testing.expect(coordinator.openChapterBrowser());
    coordinator.chapter_browser = chapter_browser.Model.init(3, 0);
    coordinator.handleCrank(1, 0);
    try std.testing.expectEqual(@as(u8, 0), coordinator.chapter_browser.selected);
    coordinator.handleCrank(14, 0);
    try std.testing.expectEqual(@as(u8, 1), coordinator.chapter_browser.selected);
    try std.testing.expect(coordinator.closeChapterBrowser(1));
    try std.testing.expectEqual(@as(u32, 1), coordinator.rsvp_reader.position().word);
    coordinator.handleCrank(0, 1);
    try std.testing.expectEqual(@as(u32, 1), coordinator.rsvp_reader.position().word);
}

test "autoplay start and pause clear retained manual RSVP crank motion" {
    var files = PauseStoreFake{};
    var coordinator: ReaderCoordinator = undefined;
    try initPauseTest(&coordinator, &files);
    coordinator.mode = .rsvp;
    coordinator.rsvp_reader.begin(0);
    _ = try coordinator.rsvp_reader.feed("one ");
    seedCrankMotionForTest(&coordinator, 74);
    coordinator.performIntent(.rsvp_toggle_autoplay, 0);
    try expectCrankMotionCleared(&coordinator);
    try std.testing.expect(coordinator.rsvp_reader.timer.running);
    seedCrankMotionForTest(&coordinator, -74);
    coordinator.performIntent(.rsvp_toggle_autoplay, 1);
    try expectCrankMotionCleared(&coordinator);
    try std.testing.expect(!coordinator.rsvp_reader.timer.running);
    try std.testing.expectEqual(@as(u32, 0), coordinator.rsvp_reader.position().word);
}
