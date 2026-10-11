const std = @import("std");
const codec = @import("generation_record.zig").Codec(576);
pub const payload_capacity = codec.payload_capacity;
pub const encoded_size = codec.encoded_size;
pub const ReadResult = codec.ReadResult;
pub const Workspace = codec.Workspace;
pub const Files = codec.Files;
pub const read = codec.read;
pub const write = codec.write;
pub const delete = codec.delete;
const record_size = encoded_size;
const header_size = codec.header_size;
const valid = codec.valid;
const latest = codec.latest;

const Fake = struct {
    const Entry = struct {
        name: [96]u8 = undefined,
        name_len: usize = 0,
        bytes: [record_size]u8 = undefined,
        len: usize = 0,
    };
    workspace: Workspace = .{},
    entries: [3]Entry = .{ .{}, .{}, .{} },
    short_write: bool = false,
    fail_commit: bool = false,
    fail_delete: bool = false,
    fail_reads: bool = false,

    fn files(self: *Fake) Files {
        return .{ .workspace = &self.workspace, .context = self, .read = readRaw, .write = writeRaw, .delete = deleteRaw };
    }
    fn find(self: *Fake, name: []const u8) ?*Entry {
        for (&self.entries) |*entry| if (std.mem.eql(u8, name, entry.name[0..entry.name_len])) return entry;
        return null;
    }
    fn readRaw(context: *anyopaque, name: []const u8, output: []u8) ReadResult {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (self.fail_reads) return .failure;
        const entry = self.find(name) orelse return .missing;
        if (entry.len != output.len) return .invalid;
        @memcpy(output, entry.bytes[0..entry.len]);
        return .ok;
    }
    fn writeRaw(context: *anyopaque, name: []const u8, input: []const u8) bool {
        const self: *Fake = @ptrCast(@alignCast(context));
        const entry = self.find(name) orelse blk: {
            for (&self.entries) |*entry| if (entry.name_len == 0) break :blk entry;
            return false;
        };
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;
        entry.len = if (self.short_write) input.len / 2 else input.len;
        @memcpy(entry.bytes[0..entry.len], input[0..entry.len]);
        return !self.short_write and !self.fail_commit;
    }
    fn deleteRaw(context: *anyopaque, name: []const u8) bool {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (self.fail_delete) return false;
        if (self.find(name)) |entry| entry.name_len = 0;
        return true;
    }
};

test "short writes and damaged newest generation recover the previous good record" {
    var fake = Fake{};
    const files = fake.files();
    try std.testing.expect(write(files, "resume.bin", "old"));
    fake.short_write = true;
    try std.testing.expect(!write(files, "resume.bin", "new"));
    var output: [3]u8 = undefined;
    try std.testing.expect(read(files, "resume.bin", &output));
    try std.testing.expectEqualStrings("old", &output);
    fake.short_write = false;
    try std.testing.expect(write(files, "resume.bin", "new"));
    try std.testing.expect(read(files, "resume.bin", &output));
    try std.testing.expectEqualStrings("new", &output);
    fake.find("resume.bin.1").?.bytes[header_size] ^= 1;
    try std.testing.expect(read(files, "resume.bin", &output));
    try std.testing.expectEqualStrings("old", &output);
}

test "flush or close failure keeps a valid generation and allows another attempt" {
    var fake = Fake{};
    const files = fake.files();
    try std.testing.expect(write(files, "pace.bin", "old"));
    fake.fail_commit = true;
    try std.testing.expect(!write(files, "pace.bin", "new"));
    // The write may have reached storage despite the failure; either way the
    // previous-good slot is untouched and the owner retains its pending save.
    try std.testing.expect(valid(@ptrCast(&fake.find("pace.bin.0").?.bytes)) != null);
    fake.fail_commit = false;
    try std.testing.expect(write(files, "pace.bin", "end"));
    var output: [3]u8 = undefined;
    try std.testing.expect(read(files, "pace.bin", &output));
    try std.testing.expectEqualStrings("end", &output);
}

test "legacy records migrate and reset tombstones survive reopening" {
    var fake = Fake{};
    const files = fake.files();
    try std.testing.expect(files.write(files.context, "resume.bin", "raw"));
    var output: [3]u8 = undefined;
    try std.testing.expect(read(files, "resume.bin", &output));
    try std.testing.expectEqualStrings("raw", &output);
    try std.testing.expect(write(files, "resume.bin", "new"));
    fake.fail_delete = true;
    try std.testing.expect(!delete(files, "resume.bin"));
    try std.testing.expect(read(files, "resume.bin", &output));
    fake.fail_delete = false;
    fake.short_write = true;
    try std.testing.expect(!delete(files, "resume.bin"));
    try std.testing.expect(read(files, "resume.bin", &output));
    fake.short_write = false;
    try std.testing.expect(delete(files, "resume.bin"));
    try std.testing.expect(!read(files, "resume.bin", &output));
    try std.testing.expect(write(files, "resume.bin", "end"));
    try std.testing.expect(read(files, "resume.bin", &output));
    try std.testing.expectEqualStrings("end", &output);
}

test "generation ordering wraps and maximum progress payload round trips" {
    try std.testing.expectEqual(@as(?u1, 1), latest(.{ .sequence = 0xffffffff, .length = 1 }, .{ .sequence = 0, .length = 1 }));
    var fake = Fake{};
    const input = [_]u8{0xa5} ** payload_capacity;
    var output: [payload_capacity]u8 = undefined;
    try std.testing.expect(write(fake.files(), "progress.bin", &input));
    try std.testing.expect(read(fake.files(), "progress.bin", &output));
    try std.testing.expectEqualSlices(u8, &input, &output);
}

test "a transient read error cannot overwrite the only valid generation" {
    var fake = Fake{};
    const files = fake.files();
    try std.testing.expect(write(files, "resume.bin", "old"));
    fake.fail_reads = true;
    try std.testing.expect(!write(files, "resume.bin", "new"));
    fake.fail_reads = false;
    var output: [3]u8 = undefined;
    try std.testing.expect(read(files, "resume.bin", &output));
    try std.testing.expectEqualStrings("old", &output);
}
