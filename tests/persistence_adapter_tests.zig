const std = @import("std");
test {
    std.testing.refAllDecls(@import("../src/platform/playdate_persistence.zig"));
    std.testing.refAllDecls(@import("../src/platform/playdate_file_reader.zig"));
}
