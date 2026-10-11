const persistence = @import("../storage/settings.zig");
const library_storage = @import("../storage/library.zig");
const reading_progress = @import("../storage/progress.zig");
const settings_menu = @import("settings_menu.zig");
const chapter_browser = @import("chapter_browser.zig");
const pagination = @import("../content/pagination.zig");
const paged_reader = @import("../reader/paged_reader.zig");
const page_transition = @import("animation/page_transition.zig");
const reading_statistics = @import("reading_statistics.zig");
const zip = @import("../archive/zip.zig");
const epub = @import("../publication/epub.zig");

/// Consume borrowed text/cache views before the next coordinator update.
pub const Screen = enum {
    library,
    book_actions,
    opening,
    reading,
    settings,
    statistics,
    chapter_browser,
    unsupported_book,
    malformed_book,
    chapter_error,
};

pub const ReadingMode = enum { paged, rsvp };
pub const BookAction = enum { start_or_resume, chapters };
pub const SoundLevel = persistence.SoundLevel;
pub const Theme = persistence.Theme;
pub const ReadingFont = persistence.ReadingFont;
pub const library_visible_rows = library_storage.visible_rows;
pub const ProgressVisibility = persistence.ProgressVisibility;
pub const ProgressPosition = persistence.ProgressPosition;
pub const ProgressScope = persistence.ProgressScope;
pub const PagedPresentation = persistence.PagedPresentation;
pub const ProgressView = reading_progress.View;
pub const SettingsRow = settings_menu.Row;
pub const OpeningFailure = union(enum) {
    opening_allocation: usize,
    archive_initialization: zip.Error,
    archive_scan: struct {
        cause: zip.Error,
        file_size: u32,
        tail_signature: [4]u8,
        nonzero_through: ?u32,
        zero_from: ?u32,
    },
    directory_validation: zip.Error,
    directory_index,
    container_lookup: zip.Error,
    container_stream: zip.Error,
    container_read: zip.Error,
    container_buffer,
    container_finish: zip.Error,
    container_parse: epub.Error,
    package_lookup: zip.Error,
    package_size: u32,
    package_allocation: u32,
    package_stream: zip.Error,
    package_read: zip.Error,
    package_buffer,
    package_finish: zip.Error,
    package_parse: epub.Error,
};
pub const ChapterFailure = enum { archive, tokenizer, page_limit, no_supported_text };

pub const reset_hold_duration_ms: u16 = 3000;
pub const LibraryView = struct {
    paths: [library_visible_rows][]const u8,
    progress: [library_visible_rows]?u8,
    omitted_capacity: u32 = 0,
    omitted_names: u32 = 0,
    listing_failed: bool = false,
    count: u8,
    selected: u8,
    first_visible: u8,
};

pub const BookActionsView = struct {
    library: LibraryView,
    title: []const u8,
    has_resume: bool,
    selected: BookAction,
};

pub const ChapterRowView = struct {
    index: u8 = 0,
    selected: bool = false,
    label: []const u8 = "",
    path: []const u8 = "",
};

pub const ChaptersView = struct {
    selected: u8,
    entries: u8,
    rows: [chapter_browser.visible_rows]ChapterRowView,
    row_count: u8,
    first_visible: u8,
};

pub const PagedView = struct {
    lines: [pagination.max_lines][]const u8,
    line_count: u8,
    restoring: bool = false,
    mode_switch_loading: bool = false,
    selected_span: ?pagination.PageCache.WordSpan,
    spotlight_nonce: u32 = 0,
    dismiss_span: ?pagination.PageCache.WordSpan = null,
    dismiss_nonce: u32 = 0,
    page_index: u32,
    waiting: bool,
    reconstructing: bool,
    transition: ?PageTransitionView = null,
    progress: ?reading_progress.View = null,
    progress_visibility: ProgressVisibility = .on,
    progress_position: ProgressPosition = .bottom,
    progress_scope: ProgressScope = .both,
};

pub const PageTransitionView = struct {
    lines: [pagination.max_lines][]const u8,
    line_count: u8,
    style: page_transition.Style = .bands,
    direction: page_transition.Direction,
    elapsed_ms: u16,
};

/// Scroll tiles borrow page-cache storage for this frame.
pub const ScrollView = struct {
    window: paged_reader.PagedReader.ScrollRenderState,
    restoring: bool = false,
    mode_switch_loading: bool = false,
    chapter_end_overscroll_px: u16 = 0,
    chapter_start_overscroll_px: u16 = 0,
    chapter_transition_nonce: u32 = 0,
    progress: ?reading_progress.View = null,
    progress_visibility: ProgressVisibility = .on,
    progress_position: ProgressPosition = .bottom,
    progress_scope: ProgressScope = .both,
};

pub const ByteSpan = struct { start: usize, end: usize };

pub const RsvpView = struct {
    word: ?[]const u8,
    anchor: ?ByteSpan = null,
    waiting: bool,
    reconstructing: bool = false,
    mode_switch_loading: bool = false,
    playing: bool,
    wpm: u16,
    manual_wpm: ?u16 = null,
    progress: ?reading_progress.View = null,
    progress_visibility: ProgressVisibility = .on,
    progress_position: ProgressPosition = .bottom,
    progress_scope: ProgressScope = .both,
};

pub const ChapterErrorView = struct {
    reason: ChapterFailure,
    path: ?[]const u8,
};

pub const RenderModel = union(enum) {
    library: LibraryView,
    book_actions: BookActionsView,
    opening,
    paged: PagedView,
    scroll: ScrollView,
    rsvp: RsvpView,
    settings: SettingsView,
    statistics: StatisticsView,
    chapters: ChaptersView,
    failure: ErrorView,
};

pub const StatisticsBackdrop = union(enum) {
    paged: PagedView,
    scroll: ScrollView,
};

pub const StatisticsView = struct {
    content: reading_statistics.View,
    backdrop: StatisticsBackdrop,
    phase: reading_statistics.SheetPhase,
    elapsed_ms: u16,
};

pub const SettingsView = struct {
    selected: SettingsRow,
    first_visible: u4,
    row_count: u4,
    total_rows: u4,
    paged_presentation: PagedPresentation,
    sound: SoundLevel = .full,
    page_animation: page_transition.Style = .bands,
    theme: Theme,
    pages_font: ReadingFont,
    rsvp_font: ReadingFont,
    progress_visibility: ProgressVisibility,
    progress_position: ProgressPosition,
    progress_scope: ProgressScope,
    reset_hold_ms: u16,
};

pub const ErrorView = union(enum) {
    unavailable,
    invalid_archive: OpeningFailure,
    missing_mimetype,
    invalid_mimetype,
    chapter: ChapterErrorView,
};
