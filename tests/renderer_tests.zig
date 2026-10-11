const std = @import("std");
test {
    std.testing.refAllDecls(@import("../src/platform/playdate_renderer.zig"));
}
