const std = @import("std");

pub const ReadStatus = enum { ok, missing, invalid, failure };
const SharedReadResult = ReadStatus;

pub fn Codec(comptime capacity: usize) type {
    return struct {
        // Write only the older checksum-protected slot so an interrupted write leaves
        // the current one intact. An empty payload is a deletion tombstone.
        pub const payload_capacity = capacity;
        pub const header_size = 16;
        const checksum_offset = header_size + payload_capacity;
        pub const encoded_size = checksum_offset + 4;
        pub const ReadResult = SharedReadResult;
        /// Keep both slot buffers on the heap; nested persistence reads exceed the
        /// device stack budget.
        pub const Workspace = struct {
            slots: [2][encoded_size]u8 = undefined,
        };
        pub const Files = struct {
            workspace: *Workspace,
            context: *anyopaque,
            read: *const fn (*anyopaque, []const u8, []u8) ReadResult,
            write: *const fn (*anyopaque, []const u8, []const u8) bool,
            delete: *const fn (*anyopaque, []const u8) bool,
        };
        const Record = struct { sequence: u32, length: u32 };

        const record_size = encoded_size;
        pub fn valid(bytes: *const [record_size]u8) ?Record {
            if (!std.mem.eql(u8, bytes[0..4], "RGEN")) return null;
            const length = std.mem.readInt(u32, bytes[8..12], .little);
            if (length > payload_capacity) return null;
            if (std.hash.Crc32.hash(bytes[0..checksum_offset]) != std.mem.readInt(u32, bytes[checksum_offset..][0..4], .little)) return null;
            return .{ .sequence = std.mem.readInt(u32, bytes[4..8], .little), .length = length };
        }
        pub fn latest(a: ?Record, b: ?Record) ?u1 {
            if (a) |first| {
                if (b) |second| return if (second.sequence -% first.sequence != 0 and second.sequence -% first.sequence < 0x80000000) 1 else 0;
                return 0;
            }
            return if (b != null) 1 else null;
        }
        fn slotName(buffer: []u8, name: []const u8, slot: u1) ?[]const u8 {
            return std.fmt.bufPrint(buffer, "{s}.{d}", .{ name, slot }) catch null;
        }
        const Loaded = struct { record: ?Record = null, failed: bool = false };
        fn load(files: Files, name: []const u8, slot: u1, bytes: *[record_size]u8) Loaded {
            var buffer: [96]u8 = undefined;
            const path = slotName(&buffer, name, slot) orelse return .{ .failed = true };
            return switch (files.read(files.context, path, bytes)) {
                .ok => .{ .record = valid(bytes) },
                .missing, .invalid => .{},
                .failure => .{ .failed = true },
            };
        }

        pub fn read(files: Files, name: []const u8, output: []u8) bool {
            const a = &files.workspace.slots[0];
            const b = &files.workspace.slots[1];
            const first = load(files, name, 0, a);
            const second = load(files, name, 1, b);
            const slot = latest(first.record, second.record) orelse {
                if (first.failed or second.failed) return false;
                return files.read(files.context, name, output) == .ok;
            };
            const record = if (slot == 0) first.record.? else second.record.?;
            if (record.length == 0 or record.length != output.len) return false;
            const bytes = if (slot == 0) a else b;
            @memcpy(output, bytes[header_size..][0..output.len]);
            return true;
        }

        pub fn write(files: Files, name: []const u8, input: []const u8) bool {
            if (input.len > payload_capacity) return false;
            const a = &files.workspace.slots[0];
            const b = &files.workspace.slots[1];
            const first = load(files, name, 0, a);
            const second = load(files, name, 1, b);
            // Never overwrite an unknown slot after an actual I/O error.
            if (first.failed or second.failed) return false;
            const current = latest(first.record, second.record);
            const target: u1 = if (current) |slot| slot ^ 1 else 0;
            const sequence: u32 = if (current) |slot| (if (slot == 0) first.record.?.sequence else second.record.?.sequence) +% 1 else 0;
            const bytes = if (target == 0) a else b;
            @memset(bytes, 0);
            @memcpy(bytes[0..4], "RGEN");
            std.mem.writeInt(u32, bytes[4..8], sequence, .little);
            std.mem.writeInt(u32, bytes[8..12], @intCast(input.len), .little);
            @memcpy(bytes[header_size..][0..input.len], input);
            std.mem.writeInt(u32, bytes[checksum_offset..][0..4], std.hash.Crc32.hash(bytes[0..checksum_offset]), .little);
            var buffer: [96]u8 = undefined;
            const path = slotName(&buffer, name, target) orelse return false;
            return files.write(files.context, path, bytes);
        }

        pub fn delete(files: Files, name: []const u8) bool {
            // Delete the old raw format first; a tombstone then masks both generations.
            if (!files.delete(files.context, name)) return false;
            return write(files, name, "");
        }
    };
}
