const std = @import("std");
const pdapi = @import("playdate_api_definitions.zig");
const builtin = @import("builtin");

var global_playate: *pdapi.PlaydateAPI = undefined;
pub fn init(playdate: *pdapi.PlaydateAPI) void {
    global_playate = playdate;
}
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    return_address: ?usize,
) noreturn {
    _ = error_return_trace;
    _ = return_address;

    switch (comptime builtin.os.tag) {
        .freestanding => {
            // Device stack traces are unavailable here.
            global_playate.system.@"error"("PANIC: %s", msg.ptr);
        },
        else => {
            // Break into the debugger instead of relying on the simulator error API to
            // exit.
        },
    }

    @breakpoint();
    @trap();
}
