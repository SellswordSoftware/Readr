const std = @import("std");
const transition = @import("page_transition.zig");

/// Borrowed, opaque, MSB-first monochrome pixels. Stride may include LCD padding.
pub const Raster = struct {
    bytes: []u8,
    width: u16,
    height: u16,
    stride: usize,

    fn pixel(self: Raster, x: i32, y: i32) bool {
        std.debug.assert(x >= 0 and x < self.width and y >= 0 and y < self.height);
        const column: usize = @intCast(x);
        return self.bytes[@as(usize, @intCast(y)) * self.stride + column / 8] & (@as(u8, 0x80) >> @as(u3, @intCast(column % 8))) != 0;
    }
};

/// Integer cubic ease-out, with exact endpoints and no device floating point.
pub fn progress(elapsed: u16, duration: u16) i32 {
    const remaining: i32 = 1024 - @as(i32, @intCast(@as(u32, @min(elapsed, duration)) * 1024 / duration));
    return 1024 - @divTrunc(remaining * remaining * remaining, 1024 * 1024);
}

const Row = struct {
    style: transition.Style,
    direction: transition.Direction,
    outgoing: Raster,
    incoming: Raster,
    top: i32,
    y: i32,
    width: i32,
    height: i32,
    travel: i32,
    lift: i32,
    fold: i32,
    paper: bool,

    fn incomingPixel(self: Row, x: i32) bool {
        return self.incoming.pixel(x, self.top + self.y);
    }

    fn pixel(self: Row, x: i32) bool {
        // Mirroring the spatial policy reverses motion without mirroring text.
        const u = if (self.direction == .forward) x else self.width - 1 - x;
        switch (self.style) {
            .bands, .slide => {
                const old_u = u + self.travel;
                const is_old = old_u < self.width;
                const sample_u = if (is_old) old_u else old_u - self.width;
                const sample_x = if (self.direction == .forward) sample_u else self.width - 1 - sample_u;
                return (if (is_old) self.outgoing else self.incoming).pixel(sample_x, self.top + self.y);
            },
            .paper_lift => {
                const old_u = u + self.travel;
                const old_y = self.y - self.lift;
                if (old_u < self.width and old_y >= 0 and old_y < self.height) {
                    const old_x = if (self.direction == .forward) old_u else self.width - 1 - old_u;
                    return self.outgoing.pixel(old_x, self.top + old_y);
                }
                // A sparse shadow follows the trailing and lower paper edges.
                if (old_u >= 2 and old_u < self.width + 3 and old_y >= 2 and old_y < self.height + 3 and
                    (old_u >= self.width or old_y >= self.height) and @mod(u + self.y, 3) == 0) return !self.paper;
                return self.incomingPixel(x);
            },
            .edge_wipe => {
                const boundary = self.width - self.travel;
                if (u >= boundary) return self.incomingPixel(x);
                if (u >= boundary - 3 and @mod(u + self.y, 3) == 0) return !self.paper;
                return self.outgoing.pixel(x, self.top + self.y);
            },
            .corner_peel => {
                const distance = self.width - 1 - u + self.height - 1 - self.y;
                if (distance < self.travel - self.fold) return self.incomingPixel(x);
                if (distance < self.travel) {
                    // Blank folded paper with a stippled underside and crease.
                    if (distance >= self.travel - 2 or @mod(u + self.y, 4) == 0) return !self.paper;
                    return self.paper;
                }
                return self.outgoing.pixel(x, self.top + self.y);
            },
        }
    }
};

/// Compose only the reader viewport; rails and framebuffer padding stay intact.
/// Inputs must not alias the destination. Work and memory are bounded by the LCD.
pub fn paint(output: Raster, outgoing: Raster, incoming: Raster, style: transition.Style, direction: transition.Direction, elapsed_ms: u16, top: u16, bottom: u16, dark: bool) void {
    std.debug.assert(output.width == outgoing.width and output.width == incoming.width);
    std.debug.assert(output.height == outgoing.height and output.height == incoming.height);
    std.debug.assert(output.width % 8 == 0 and top < bottom and bottom <= output.height);
    const width: i32 = output.width;
    const height: i32 = bottom - top;
    const p = progress(elapsed_ms, style.duration());
    // Paper first lifts/settles slightly, then leaves sideways. The envelope
    // vanishes at both endpoints so neither page jumps on arrival.
    const envelope = @min(p * 4, @min(1024, (1024 - p) * 4));
    for (top..bottom) |screen_y| {
        if (elapsed_ms == 0 or elapsed_ms >= style.duration()) {
            const source = if (elapsed_ms == 0) outgoing else incoming;
            @memcpy(output.bytes[screen_y * output.stride ..][0 .. output.width / 8], source.bytes[screen_y * source.stride ..][0 .. output.width / 8]);
            continue;
        }
        const row = Row{
            .style = style,
            .direction = direction,
            .outgoing = outgoing,
            .incoming = incoming,
            .top = top,
            .y = @intCast(screen_y - top),
            .width = width,
            .height = height,
            .travel = switch (style) {
                .bands => transition.bandOffset(elapsed_ms, @intCast(@min(9, screen_y * 10 / output.height)), direction, output.width),
                .corner_peel => @divTrunc((width + height + 24) * p, 1024),
                .paper_lift => @divTrunc(width * @max(0, p - 128), 896),
                else => @divTrunc(width * p, 1024),
            },
            .lift = @divTrunc(envelope * -14, 1024),
            .fold = @divTrunc(envelope * 24, 1024),
            .paper = !dark,
        };
        for (0..output.width / 8) |column| {
            var pixels: u8 = 0;
            for (0..8) |bit| {
                if (row.pixel(@intCast(column * 8 + bit))) pixels |= @as(u8, 0x80) >> @as(u3, @intCast(bit));
            }
            output.bytes[screen_y * output.stride + column] = pixels;
        }
    }
}

test "every animation preserves exact endpoints rails and padded rows in both directions" {
    var old = [_]u8{0x96} ** (4 * 8);
    var new = [_]u8{0x69} ** (4 * 8);
    const outgoing = Raster{ .bytes = &old, .width = 24, .height = 8, .stride = 4 };
    const incoming = Raster{ .bytes = &new, .width = 24, .height = 8, .stride = 4 };
    for (std.enums.values(transition.Style)) |style| for (std.enums.values(transition.Direction)) |direction| for ([_]bool{ false, true }) |dark| {
        for ([_]u16{ 0, style.duration() / 2, style.duration() }) |elapsed| {
            var result = [_]u8{0xa5} ** (4 * 8);
            paint(.{ .bytes = &result, .width = 24, .height = 8, .stride = 4 }, outgoing, incoming, style, direction, elapsed, 1, 7, dark);
            try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, result[0..4]);
            try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, result[28..32]);
            for (1..7) |y| {
                try std.testing.expectEqual(@as(u8, 0xa5), result[y * 4 + 3]);
                if (elapsed == 0 or elapsed == style.duration()) try std.testing.expectEqualSlices(u8, (if (elapsed == 0) outgoing else incoming).bytes[y * 4 ..][0..3], result[y * 4 ..][0..3]);
            }
        }
    };
}

test "backward motion mirrors wipe geometry" {
    var old = [_]u8{0} ** 32;
    var new = [_]u8{0xff} ** 32;
    const outgoing = Raster{ .bytes = &old, .width = 32, .height = 8, .stride = 4 };
    const incoming = Raster{ .bytes = &new, .width = 32, .height = 8, .stride = 4 };
    var forward = [_]u8{0} ** 32;
    var backward = [_]u8{0} ** 32;
    paint(.{ .bytes = &forward, .width = 32, .height = 8, .stride = 4 }, outgoing, incoming, .edge_wipe, .forward, 70, 1, 7, false);
    paint(.{ .bytes = &backward, .width = 32, .height = 8, .stride = 4 }, outgoing, incoming, .edge_wipe, .backward, 70, 1, 7, false);
    for (1..7) |y| for (0..32) |x| try std.testing.expectEqual((Raster{ .bytes = &forward, .width = 32, .height = 8, .stride = 4 }).pixel(@intCast(x), @intCast(y)), (Raster{ .bytes = &backward, .width = 32, .height = 8, .stride = 4 }).pixel(@intCast(31 - x), @intCast(y)));
}

test "all intermediate frames stay bounded and invert consistently with the theme" {
    var old_light = [_]u8{0x96} ** 32;
    var new_light = [_]u8{0x69} ** 32;
    var old_dark = [_]u8{0x69} ** 32;
    var new_dark = [_]u8{0x96} ** 32;
    const make = struct {
        fn raster(bytes: []u8) Raster {
            return .{ .bytes = bytes, .width = 32, .height = 8, .stride = 4 };
        }
    }.raster;
    for (std.enums.values(transition.Style)) |style| for (std.enums.values(transition.Direction)) |direction| {
        for (0..style.duration() + 1) |elapsed| {
            var light = [_]u8{0xff} ** 32;
            var dark = [_]u8{0} ** 32;
            paint(make(&light), make(&old_light), make(&new_light), style, direction, @intCast(elapsed), 1, 7, false);
            paint(make(&dark), make(&old_dark), make(&new_dark), style, direction, @intCast(elapsed), 1, 7, true);
            for (light, dark) |a, b| try std.testing.expectEqual(~a, b);
        }
    };
}
