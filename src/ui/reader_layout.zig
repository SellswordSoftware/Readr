const std = @import("std");

pub const screen_width: usize = 400;
pub const screen_height: usize = 240;
/// Reserve progress lanes even when hidden so visibility and placement changes do not
/// affect pagination.
pub const reserved_edge_rows: usize = 4;
pub const top_rail_edge_y: usize = 0;
pub const top_rail_inner_y: usize = 2;
pub const bottom_rail_edge_y: usize = screen_height - 1;
pub const bottom_rail_inner_y: usize = screen_height - 3;
pub const text_x: usize = 8;
pub const text_y: usize = reserved_edge_rows;
pub const text_width: usize = screen_width - (text_x * 2);
pub const minimum_line_gap: usize = 1;
pub const highlight_padding_x: usize = 1;
/// Slightly left of center so the longer post-ORP suffix has more room.
pub const rsvp_anchor_x: usize = 180;

pub const HighlightRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const RsvpGeometry = struct {
    word_y: usize,
    guide_top_y: usize,
    guide_bottom_y: usize,
    top_tick_start_y: usize,
    bottom_tick_end_y: usize,
};

pub fn lineAdvance(font_height: usize) usize {
    return @max(font_height, 1) + minimum_line_gap;
}

pub fn pageLineLimit(font_height: usize, storage_capacity: usize) u8 {
    const available_height = screen_height - text_y - reserved_edge_rows;
    const fitting_lines = (available_height + minimum_line_gap) / lineAdvance(font_height);
    return @intCast(@max(@as(usize, 1), @min(fitting_lines, storage_capacity)));
}

/// Pad glyph edges without moving the text origin or baseline.
pub fn highlightRect(word_x: usize, line_y: usize, word_width: usize, font_height: usize) HighlightRect {
    const x = word_x -| highlight_padding_x;
    const right = @min(screen_width, word_x +| word_width +| highlight_padding_x);
    return .{
        .x = x,
        .y = line_y,
        .width = right - x,
        .height = @max(font_height, 1),
    };
}

pub fn rsvpGeometry(font_height_value: usize) RsvpGeometry {
    return rsvpGeometryInRect(font_height_value, 0, screen_height);
}

pub fn rsvpGeometryInRect(font_height_value: usize, top: usize, height: usize) RsvpGeometry {
    const font_height = @max(font_height_value, 1);
    const bottom = top + @max(height, 1) - 1;
    const word_y = top + (height -| font_height) / 2;
    const nominal_clearance = @max(@as(usize, 2), font_height / 4);
    const nominal_tick = @max(@as(usize, 4), font_height / 2);
    const headroom = (height -| font_height) / 2;
    // Small preview panels keep native word size. Fit both the clearance and
    // ticks into the surrounding space rather than losing the ticks to clipping.
    const clearance = if (headroom >= nominal_clearance + nominal_tick)
        nominal_clearance
    else
        @min(headroom, @max(@as(usize, 2), headroom * nominal_clearance / (nominal_clearance + nominal_tick)));
    const tick_length = @min(nominal_tick, headroom -| clearance);
    const guide_top_y = @max(top, word_y -| clearance);
    const guide_bottom_y = @min(bottom, word_y +| font_height +| clearance);
    return .{
        .word_y = word_y,
        .guide_top_y = guide_top_y,
        .guide_bottom_y = guide_bottom_y,
        .top_tick_start_y = @max(top, guide_top_y -| tick_length),
        .bottom_tick_end_y = @min(bottom, guide_bottom_y +| tick_length),
    };
}

test "font metrics leave a clear pixel between reader lines" {
    try std.testing.expectEqual(@as(usize, 21), lineAdvance(20));
    try std.testing.expectEqual(@as(u8, 11), pageLineLimit(20, 11));
}

test "RSVP guides derive clearance and ticks from the font cell" {
    const geometry = rsvpGeometry(20);
    try std.testing.expectEqual(@as(usize, 110), geometry.word_y);
    try std.testing.expectEqual(@as(usize, 105), geometry.guide_top_y);
    try std.testing.expectEqual(@as(usize, 135), geometry.guide_bottom_y);
    try std.testing.expectEqual(@as(usize, 95), geometry.top_tick_start_y);
    try std.testing.expectEqual(@as(usize, 145), geometry.bottom_tick_end_y);
}

test "RSVP preview keeps guides and ticks visible around the largest bundled font cell" {
    const geometry = rsvpGeometryInRect(59, 122, 84);
    try std.testing.expect(geometry.top_tick_start_y >= 122);
    try std.testing.expect(geometry.top_tick_start_y < geometry.guide_top_y);
    try std.testing.expect(geometry.guide_top_y < geometry.word_y);
    try std.testing.expect(geometry.word_y + 59 < geometry.guide_bottom_y);
    try std.testing.expect(geometry.guide_bottom_y < geometry.bottom_tick_end_y);
    try std.testing.expect(geometry.bottom_tick_end_y < 206);
}
