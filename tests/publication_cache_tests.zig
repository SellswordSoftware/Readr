const std = @import("std");
test {
    std.testing.refAllDecls(@import("../src/storage/publication_cache.zig"));
}
