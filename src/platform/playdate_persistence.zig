const std = @import("std");
const pdapi = @import("playdate_api_definitions.zig");
const generations = @import("../storage/generations.zig");
const publication_cache = @import("../storage/publication_cache.zig");
const cache_generations = @import("../storage/generation_record.zig").Codec(publication_cache.encoded_size);
const persistence = @import("../storage/persistence.zig");

/// Keep generation buffers on the heap to avoid large callback-stack allocations.
/// Operations are serial.
pub const Store = struct {
    file_api: *const pdapi.PlaydateFile,
    allocator: ?std.mem.Allocator = null,
    workspace: generations.Workspace = .{},

    fn rawFiles(self: *Store) generations.Files {
        return .{
            .workspace = &self.workspace,
            .context = @ptrCast(@constCast(self.file_api)),
            .read = rawRead,
            .write = rawWrite,
            .delete = rawDelete,
        };
    }
};

pub fn fileStore(store: *Store) persistence.FileStore {
    return .{
        .context = store,
        .read = read,
        .write = write,
        .delete = delete,
        .ensure_directory = ensureDirectory,
    };
}

/// Create the writable Data folder before the first save so users can sideload books.
/// Hide its marker from the library.
pub fn ensureDataRoot(file_api: *const pdapi.PlaydateFile) bool {
    const marker = ".readr-data";
    const file = file_api.open(marker, pdapi.FILE_APPEND) orelse return false;
    return file_api.close(file) == 0;
}

fn rawRead(context: *anyopaque, name: []const u8, output: []u8) generations.ReadResult {
    const file_api: *const pdapi.PlaydateFile = @ptrCast(@alignCast(context));
    var filename_buffer: [96]u8 = undefined;
    const filename = std.fmt.bufPrintZ(&filename_buffer, "{s}", .{name}) catch return .failure;
    const file = file_api.open(filename.ptr, pdapi.FILE_READ | pdapi.FILE_READ_DATA) orelse {
        const present = exists(file_api, name) orelse return .failure;
        return if (present) .failure else .missing;
    };
    const count = file_api.read(file, output.ptr, @intCast(output.len));
    const closed = file_api.close(file) == 0;
    if (count < 0 or !closed) return .failure;
    return if (count == @as(c_int, @intCast(output.len))) .ok else .invalid;
}

fn rawWrite(context: *anyopaque, name: []const u8, input: []const u8) bool {
    const file_api: *const pdapi.PlaydateFile = @ptrCast(@alignCast(context));
    var filename_buffer: [96]u8 = undefined;
    const filename = std.fmt.bufPrintZ(&filename_buffer, "{s}", .{name}) catch return false;
    const file = file_api.open(filename.ptr, pdapi.FILE_WRITE) orelse return false;
    const written = file_api.write(file, input.ptr, @intCast(input.len)) == @as(c_int, @intCast(input.len));
    const flushed = file_api.flush(file) >= 0;
    const closed = file_api.close(file) == 0;
    return written and flushed and closed;
}

fn rawDelete(context: *anyopaque, name: []const u8) bool {
    const file_api: *const pdapi.PlaydateFile = @ptrCast(@alignCast(context));
    var filename_buffer: [96]u8 = undefined;
    const filename = std.fmt.bufPrintZ(&filename_buffer, "{s}", .{name}) catch return false;
    const present = exists(file_api, name) orelse return false;
    return !present or file_api.unlink(filename.ptr, 0) == 0;
}

fn ensureDirectory(context: *anyopaque, name: []const u8) bool {
    const store: *Store = @ptrCast(@alignCast(context));
    const file_api = store.file_api;
    var filename_buffer: [96]u8 = undefined;
    const filename = std.fmt.bufPrintZ(&filename_buffer, "{s}", .{name}) catch return false;
    var stat: pdapi.FileStat = undefined;
    if (file_api.stat(filename.ptr, &stat) == 0) return stat.isdir != 0;
    return file_api.mkdir(filename.ptr) == 0;
}

fn read(context: *anyopaque, name: []const u8, output: []u8) bool {
    const store: *Store = @ptrCast(@alignCast(context));
    if (output.len > generations.payload_capacity) {
        const allocator = store.allocator orelse return false;
        const workspace = allocator.create(cache_generations.Workspace) catch return false;
        defer allocator.destroy(workspace);
        return cache_generations.read(.{ .workspace = workspace, .context = @ptrCast(@constCast(store.file_api)), .read = rawRead, .write = rawWrite, .delete = rawDelete }, name, output);
    }
    return generations.read(store.rawFiles(), name, output);
}
fn write(context: *anyopaque, name: []const u8, input: []const u8) bool {
    const store: *Store = @ptrCast(@alignCast(context));
    if (input.len > generations.payload_capacity) {
        const allocator = store.allocator orelse return false;
        const workspace = allocator.create(cache_generations.Workspace) catch return false;
        defer allocator.destroy(workspace);
        return cache_generations.write(.{ .workspace = workspace, .context = @ptrCast(@constCast(store.file_api)), .read = rawRead, .write = rawWrite, .delete = rawDelete }, name, input);
    }
    return generations.write(store.rawFiles(), name, input);
}
fn delete(context: *anyopaque, name: []const u8) bool {
    const store: *Store = @ptrCast(@alignCast(context));
    const files = store.rawFiles();
    // Absent legacy files need no generation tombstones.
    if (std.mem.indexOfScalar(u8, name, '/') == null) return rawDelete(files.context, name);
    const file_api = store.file_api;
    var any_present = exists(file_api, name) orelse return false;
    for ([_]u1{ 0, 1 }) |slot| {
        var buffer: [96]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}.{d}", .{ name, slot }) catch return false;
        any_present = (exists(file_api, path) orelse return false) or any_present;
    }
    if (!any_present) return true;
    if (std.mem.endsWith(u8, name, "/publication.bin")) {
        const allocator = store.allocator orelse return false;
        const workspace = allocator.create(cache_generations.Workspace) catch return false;
        defer allocator.destroy(workspace);
        return cache_generations.delete(.{ .workspace = workspace, .context = @ptrCast(@constCast(store.file_api)), .read = rawRead, .write = rawWrite, .delete = rawDelete }, name);
    }
    return generations.delete(files, name);
}

const Listing = struct {
    target: []const u8,
    found: bool = false,
    fn visit(path: ?[*:0]const u8, context: ?*anyopaque) callconv(.c) void {
        const self: *Listing = @ptrCast(@alignCast(context.?));
        const entry = std.mem.trimEnd(u8, std.mem.span(path orelse return), "/");
        if (std.mem.eql(u8, entry, self.target)) self.found = true;
    }
};

// List parent components to distinguish missing paths from stat/I/O errors.
fn exists(file_api: *const pdapi.PlaydateFile, name: []const u8) ?bool {
    var start: usize = 0;
    while (start < name.len) {
        const end = if (std.mem.indexOfScalarPos(u8, name, start, '/')) |slash| slash else name.len;
        var listing = Listing{ .target = name[start..end] };
        var buffer: [96]u8 = undefined;
        const parent = std.fmt.bufPrintZ(&buffer, "{s}", .{if (start == 0) "" else name[0 .. start - 1]}) catch return null;
        if (file_api.listfiles(parent.ptr, Listing.visit, &listing, 1) != 0) return null;
        if (!listing.found) return false;
        start = end + 1;
    }
    return true;
}

const WriteFake = struct {
    var write_result: c_int = 3;
    var flush_result: c_int = 0;
    var close_result: c_int = 0;
    var closes: usize = 0;
    fn open(_: ?[*:0]const u8, _: pdapi.FileOptions) callconv(.c) ?*pdapi.SDFile {
        return @ptrFromInt(1);
    }
    fn write(_: ?*pdapi.SDFile, _: ?*const anyopaque, _: c_uint) callconv(.c) c_int {
        return write_result;
    }
    fn flush(_: ?*pdapi.SDFile) callconv(.c) c_int {
        return flush_result;
    }
    fn close(_: ?*pdapi.SDFile) callconv(.c) c_int {
        closes += 1;
        return close_result;
    }
};

test "SDK writes check short write flush and close and always close once" {
    var api: pdapi.PlaydateFile = undefined;
    api.open = WriteFake.open;
    api.write = WriteFake.write;
    api.flush = WriteFake.flush;
    api.close = WriteFake.close;
    for ([_][3]c_int{ .{ 2, 0, 0 }, .{ 3, -1, 0 }, .{ 3, 0, -1 }, .{ 3, 0, 0 }, .{ 3, 3, 0 } }, 0..) |results, i| {
        WriteFake.write_result = results[0];
        WriteFake.flush_result = results[1];
        WriteFake.close_result = results[2];
        WriteFake.closes = 0;
        try std.testing.expectEqual(i >= 3, rawWrite(&api, "record", "abc"));
        try std.testing.expectEqual(@as(usize, 1), WriteFake.closes);
    }
}

const DeleteFake = struct {
    var listing_fails: bool = false;
    var parent_missing: bool = false;
    var present: bool = false;
    var unlink_fails: bool = false;
    var unlinks: usize = 0;
    fn list(path: ?[*:0]const u8, callback: *const fn (?[*:0]const u8, ?*anyopaque) callconv(.c) void, context: ?*anyopaque, _: c_int) callconv(.c) c_int {
        if (listing_fails) return -1;
        const directory = std.mem.span(path.?);
        if (directory.len == 0) {
            if (!parent_missing) callback("book-data/", context);
        } else if (std.mem.eql(u8, directory, "book-data")) {
            callback("Example--7/", context);
        } else if (present) callback("resume.bin", context);
        return 0;
    }
    fn unlink(_: ?[*:0]const u8, _: c_int) callconv(.c) c_int {
        unlinks += 1;
        return if (unlink_fails) -1 else 0;
    }
};

test "deletion distinguishes absent files and folders from listing or unlink failure" {
    var api: pdapi.PlaydateFile = undefined;
    api.listfiles = DeleteFake.list;
    api.unlink = DeleteFake.unlink;
    var store = Store{ .file_api = &api };
    DeleteFake.listing_fails = false;
    DeleteFake.parent_missing = false;
    DeleteFake.present = false;
    DeleteFake.unlink_fails = false;
    DeleteFake.unlinks = 0;
    const name = "book-data/Example--7/resume.bin";
    try std.testing.expect(rawDelete(&api, name));
    try std.testing.expect(delete(&store, name));
    DeleteFake.parent_missing = true;
    try std.testing.expect(delete(&store, name));
    try std.testing.expectEqual(@as(usize, 0), DeleteFake.unlinks);
    DeleteFake.parent_missing = false;
    DeleteFake.listing_fails = true;
    try std.testing.expect(!rawDelete(&api, name));
    DeleteFake.listing_fails = false;
    DeleteFake.present = true;
    DeleteFake.unlink_fails = true;
    try std.testing.expect(!rawDelete(&api, name));
    DeleteFake.unlink_fails = false;
    try std.testing.expect(rawDelete(&api, name));
    try std.testing.expectEqual(@as(usize, 2), DeleteFake.unlinks);
}
