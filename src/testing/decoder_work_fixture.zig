//! Host-test fixtures with valid DEFLATE blocks that produce no text.
const std = @import("std");
const zip = @import("../archive/zip.zig");

pub const EmptyKind = enum { stored, fixed, dynamic };
pub const name = "chapter.xhtml";

const Bits = struct {
    bytes: []u8,
    count: usize = 0,

    fn write(self: *Bits, value: u32, count: u6) void {
        for (0..count) |shift| {
            if (self.count % 8 == 0) self.bytes[self.count / 8] = 0;
            self.bytes[self.count / 8] |= @as(u8, @intCast((value >> @intCast(shift)) & 1)) << @intCast(self.count % 8);
            self.count += 1;
        }
    }

    fn alignByte(self: *Bits) void {
        while (self.count % 8 != 0) self.write(0, 1);
    }
};

pub fn raw(output: []u8, kind: EmptyKind, blocks: usize, text: []const u8) []const u8 {
    std.debug.assert(text.len <= 65535);
    var bits = Bits{ .bytes = output };
    for (0..blocks) |_| {
        bits.write(0, 1); // Non-final block.
        switch (kind) {
            .stored => {
                bits.write(0, 2);
                bits.alignByte();
                bits.write(0, 16);
                bits.write(65535, 16);
            },
            .fixed => {
                bits.write(1, 2);
                bits.write(0, 7); // Fixed end-of-block code.
            },
            .dynamic => {
                bits.write(2, 2);
                bits.write(0, 5); // 257 literal/length codes.
                bits.write(0, 5); // One distance code.
                bits.write(14, 4); // 18 code-length codes, through symbol 1.
                const order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1 };
                for (order) |symbol| bits.write(if (symbol <= 1) 1 else 0, 3);
                // Code-length symbols 0 and 1 have canonical codes 0 and 1.
                for (0..256) |_| bits.write(0, 1);
                bits.write(1, 1); // End-of-block has length one.
                bits.write(1, 1); // Single distance code also has length one.
                bits.write(0, 1); // End of this empty block.
            },
        }
    }
    bits.write(1, 1);
    bits.write(0, 2); // Final stored block with the actual text.
    bits.alignByte();
    bits.write(@intCast(text.len), 16);
    bits.write(@as(u16, @intCast(text.len)) ^ 65535, 16);
    for (text) |byte| bits.write(byte, 8);
    return output[0 .. bits.count / 8];
}

pub fn archive(buffer: []u8, kind: EmptyKind, blocks: usize, text: []const u8) []const u8 {
    const data_offset = 30 + name.len;
    @memset(buffer[0..data_offset], 0);
    const compressed = raw(buffer[data_offset..], kind, blocks, text);
    const central = data_offset + compressed.len;
    const central_size = 46 + name.len;
    const end = central + central_size;
    @memset(buffer[central .. end + 22], 0);
    const crc = std.hash.Crc32.hash(text);
    put(u32, buffer, 0, 0x04034b50);
    put(u16, buffer, 4, 20);
    put(u16, buffer, 8, 8);
    put(u32, buffer, 14, crc);
    put(u32, buffer, 18, @intCast(compressed.len));
    put(u32, buffer, 22, @intCast(text.len));
    put(u16, buffer, 26, name.len);
    @memcpy(buffer[30..data_offset], name);
    put(u32, buffer, central, 0x02014b50);
    put(u16, buffer, central + 4, 20);
    put(u16, buffer, central + 6, 20);
    put(u16, buffer, central + 10, 8);
    put(u32, buffer, central + 16, crc);
    put(u32, buffer, central + 20, @intCast(compressed.len));
    put(u32, buffer, central + 24, @intCast(text.len));
    put(u16, buffer, central + 28, name.len);
    @memcpy(buffer[central + 46 .. end], name);
    put(u32, buffer, end, 0x06054b50);
    put(u16, buffer, end + 8, 1);
    put(u16, buffer, end + 10, 1);
    put(u32, buffer, end + 12, central_size);
    put(u32, buffer, end + 16, @intCast(central));
    return buffer[0 .. end + 22];
}

fn put(comptime T: type, buffer: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, buffer[offset..][0..@sizeOf(T)], value, .little);
}

pub const Source = struct {
    bytes: []const u8,
    bytes_read: usize = 0,

    pub fn reader(self: *Source) zip.Reader {
        return .{ .context = self, .size = @intCast(self.bytes.len), .read_at = readAt };
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *Source = @ptrCast(@alignCast(context));
        if (offset + destination.len > self.bytes.len) return error.UnexpectedEof;
        @memcpy(destination, self.bytes[offset..][0..destination.len]);
        self.bytes_read += destination.len;
    }
};
