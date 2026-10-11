const zip = @import("../archive/zip.zig");
const library_storage = @import("../storage/library.zig");
const settings = @import("../storage/settings.zig");

pub const Library = library_storage.Library;

/// The adapter keeps handle addresses stable; readers borrow them through named slots.
pub const FileSlot = enum { opening, chapter, prefetch, progress };
pub const FileError = error{OpenFailed};

pub const Files = struct {
    context: *anyopaque,
    open: *const fn (context: *anyopaque, slot: FileSlot, path: [:0]const u8) FileError!zip.Reader,
    close: *const fn (context: *anyopaque, slot: FileSlot) void,
    list_epubs: *const fn (context: *anyopaque, library: *Library) void,
};

/// Both metrics must use the requested font or pagination and drawing will disagree.
pub const TextMeasure = struct {
    context: *anyopaque,
    width: *const fn (context: *anyopaque, font: settings.ReadingFont, text: []const u8) usize,
    font_height: *const fn (context: *anyopaque, font: settings.ReadingFont) usize,
};

pub const Clock = struct {
    context: *anyopaque,
    milliseconds: *const fn (*anyopaque) u32,
};

pub const ReaderHost = struct {
    clock: ?Clock = null,
    files: ?Files = null,
    measure: TextMeasure,
};
