const pdapi = @import("playdate_api_definitions.zig");
const zip = @import("../archive/zip.zig");
const std = @import("std");
const builtin = @import("builtin");
const Clock = @import("../reader/reader_host.zig").Clock;

pub const Error = error{
    OpenFailed,
    SeekFailed,
    TellFailed,
    FileTooLarge,
    ReadFailed,
};

/// The caller must close the SDK handle once, after all ZIP reads finish.
pub const PlaydateFileReader = struct {
    loading: if (builtin.is_test) ?*@import("../telemetry.zig").Loading else void = if (builtin.is_test) null else {},
    clock: if (builtin.is_test) ?Clock else void = if (builtin.is_test) null else {},
    file_api: *const pdapi.PlaydateFile,
    file: *pdapi.SDFile,
    size: u32,
    current_offset: u32,
    position_known: bool = true,

    pub fn open(file_api: *const pdapi.PlaydateFile, path: [*:0]const u8) Error!PlaydateFileReader {
        const file = file_api.open(path, pdapi.FILE_READ | pdapi.FILE_READ_DATA) orelse return error.OpenFailed;
        errdefer _ = file_api.close(file);

        if (file_api.seek(file, 0, pdapi.SEEK_END) != 0) return error.SeekFailed;
        const end = file_api.tell(file);
        if (end < 0) return error.TellFailed;
        if (file_api.seek(file, 0, pdapi.SEEK_SET) != 0) return error.SeekFailed;

        return .{
            .file_api = file_api,
            .file = file,
            .size = @intCast(end),
            .current_offset = 0,
        };
    }

    pub fn close(self: *PlaydateFileReader) void {
        _ = self.file_api.close(self.file);
    }

    pub fn reader(self: *PlaydateFileReader) zip.Reader {
        return .{
            .context = self,
            .size = self.size,
            .read_at = readAt,
        };
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *PlaydateFileReader = @ptrCast(@alignCast(context));
        const sought = !self.position_known or offset != self.current_offset;
        if (builtin.is_test) if (self.loading) |loading| loading.recordRead(destination.len, sought);
        if (sought) {
            // Forward relative seeks reuse the tracked SDK cursor; failed I/O clears
            // that assumption.
            const forward = self.position_known and offset > self.current_offset;
            const position = std.math.cast(c_int, if (forward) offset - self.current_offset else offset) orelse return error.ReadFailed;
            const started = if (builtin.is_test) self.ioTime() else null;
            const result = self.file_api.seek(self.file, position, if (forward) pdapi.SEEK_CUR else pdapi.SEEK_SET);
            if (builtin.is_test) if (started) |time| self.loading.?.recordSeekTime(self.ioTime().? -% time);
            self.position_known = result == 0;
            if (result != 0) return error.ReadFailed;
            self.current_offset = offset;
        }
        const started = if (builtin.is_test) self.ioTime() else null;
        const bytes_read = self.file_api.read(self.file, destination.ptr, @intCast(destination.len));
        if (builtin.is_test) if (started) |time| self.loading.?.recordReadTime(self.ioTime().? -% time);
        if (bytes_read < 0) {
            self.position_known = false;
            return error.UnexpectedEof;
        }
        self.current_offset = offset + @as(u32, @intCast(bytes_read));
        if (@as(usize, @intCast(bytes_read)) != destination.len) return error.UnexpectedEof;
    }

    fn ioTime(self: *const PlaydateFileReader) ?u32 {
        const loading = self.loading orelse return null;
        if (!loading.active) return null;
        const clock = self.clock orelse return null;
        return clock.milliseconds(clock.context);
    }
};

const TestFile = struct {
    position: u32 = 0,
    now: u32 = 0xfffffff0,
    seek_calls: u32 = 0,
    seek_position: c_int = 0,
    seek_whence: c_int = -1,
    seek_fails: bool = false,
    read_result: ?c_int = null,

    fn from(handle: ?*pdapi.SDFile) *TestFile {
        return @ptrCast(@alignCast(handle.?));
    }
    fn seek(handle: ?*pdapi.SDFile, position: c_int, whence: c_int) callconv(.c) c_int {
        const self = from(handle);
        self.seek_calls += 1;
        self.seek_position = position;
        self.seek_whence = whence;
        self.now +%= 19;
        if (self.seek_fails) return -1;
        self.position = if (whence == pdapi.SEEK_CUR) self.position + @as(u32, @intCast(position)) else @intCast(position);
        return 0;
    }
    fn read(handle: ?*pdapi.SDFile, buffer: ?*anyopaque, length: c_uint) callconv(.c) c_int {
        const self = from(handle);
        self.now +%= 7;
        const count = self.read_result orelse @as(c_int, @intCast(length));
        if (count < 0) return count;
        const bytes: [*]u8 = @ptrCast(buffer.?);
        for (bytes[0..@intCast(count)], 0..) |*byte, index| byte.* = @intCast((self.position + index) % 251);
        self.position += @intCast(count);
        return count;
    }
    fn milliseconds(context: *anyopaque) u32 {
        const self: *TestFile = @ptrCast(@alignCast(context));
        return self.now;
    }
    fn adapter(self: *TestFile, api: *pdapi.PlaydateFile) PlaydateFileReader {
        api.seek = seek;
        api.read = read;
        return .{ .file_api = api, .file = @ptrCast(self), .size = 4096, .current_offset = self.position };
    }
};

test "SDK reader uses relative forward seeks and preserves exact bytes and I/O timing" {
    var file: TestFile = .{};
    var api: pdapi.PlaydateFile = undefined;
    var adapter = file.adapter(&api);
    var loading: @import("../telemetry.zig").Loading = .{};
    loading.begin(file.now);
    loading.stepStarted(.member_bounds, file.now);
    adapter.loading = &loading;
    adapter.clock = .{ .context = &file, .milliseconds = TestFile.milliseconds };
    const reader = adapter.reader();
    var bytes: [4]u8 = undefined;
    try reader.readAt(100, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 100, 101, 102, 103 }, &bytes);
    try std.testing.expectEqual(pdapi.SEEK_CUR, file.seek_whence);
    try std.testing.expectEqual(@as(c_int, 100), file.seek_position);
    try reader.readAt(104, &bytes);
    try std.testing.expectEqual(@as(u32, 1), file.seek_calls);
    try reader.readAt(200, &bytes);
    try std.testing.expectEqual(@as(c_int, 92), file.seek_position);
    try std.testing.expectEqual(pdapi.SEEK_CUR, file.seek_whence);
    try reader.readAt(10, &bytes);
    try std.testing.expectEqual(pdapi.SEEK_SET, file.seek_whence);
    try std.testing.expectEqualSlices(u8, &.{ 10, 11, 12, 13 }, &bytes);
    loading.stepFinished(file.now);
    const stats = loading.phases[@intFromEnum(@import("../telemetry.zig").LoadingPhase.member_bounds)];
    try std.testing.expectEqual(@as(u32, 3), stats.seeks);
    try std.testing.expectEqual(@as(u32, 57), stats.seek_ms);
    try std.testing.expectEqual(@as(u32, 28), stats.read_ms);
    try std.testing.expectEqual(@as(u32, 19), stats.max_seek_ms);
    try std.testing.expectEqual(@as(u32, 7), stats.max_read_ms);
}

test "SDK reader recovers cursor tracking after short reads and failed I/O" {
    var file: TestFile = .{};
    var api: pdapi.PlaydateFile = undefined;
    var adapter = file.adapter(&api);
    const reader = adapter.reader();
    var bytes: [4]u8 = undefined;
    file.read_result = 2;
    try std.testing.expectError(error.UnexpectedEof, reader.readAt(100, &bytes));
    file.read_result = null;
    try reader.readAt(200, &bytes);
    try std.testing.expectEqual(@as(c_int, 98), file.seek_position);
    file.seek_fails = true;
    try std.testing.expectError(error.ReadFailed, reader.readAt(300, &bytes));
    file.seek_fails = false;
    try reader.readAt(204, &bytes);
    try std.testing.expectEqual(pdapi.SEEK_SET, file.seek_whence);
    try std.testing.expectEqual(@as(c_int, 204), file.seek_position);
    file.read_result = -1;
    try std.testing.expectError(error.UnexpectedEof, reader.readAt(208, &bytes));
    file.read_result = null;
    try reader.readAt(400, &bytes);
    try std.testing.expectEqual(pdapi.SEEK_SET, file.seek_whence);
    try std.testing.expectEqualSlices(u8, &.{ 149, 150, 151, 152 }, &bytes);
}
