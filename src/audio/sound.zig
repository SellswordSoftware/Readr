const std = @import("std");
pub const Level = @import("../storage/settings.zig").SoundLevel;
pub const Cue = enum { ui_tick, ui_confirm, surface_open, surface_close, page_turn, chapter_turn, mode_change, play, pause, rewind, boundary, error_cue, reset_arm, reset_complete };
pub const Kind = enum {
    selection,
    word_selection,
    wpm_changed,
    accepted,
    surface_opened,
    surface_closed,
    page_changed,
    chapter_changed,
    mode_changed,
    presentation_changed,
    autoplay_started,
    autoplay_paused,
    sentence_rewind,
    at_boundary,
    empty_library,
    failure,
    reset_started,
    reset_milestone,
    reset_cancelled,
    reset_completed,
};
pub const Event = struct {
    kind: Kind,
    direction: i8 = 0,
    quiet: bool = false,
    immediate: bool = false,
    duration_ms: ?u16 = null,
};
pub const Request = struct {
    cue: Cue,
    gain: f32 = 1,
    pitch: f32 = 0,
    short: bool = false,
    direction: i8 = 0,
    duration_ms: ?u16 = null,
};

pub fn priority(cue: Cue) u8 {
    return switch (cue) {
        .error_cue, .reset_complete => 4,
        .chapter_turn, .rewind => 3,
        .ui_tick => 0,
        .boundary => 1,
        else => 2,
    };
}

pub fn map(event: Event, level: Level) ?Request {
    if (level == .off) return null;
    const full_only = switch (event.kind) {
        .selection, .word_selection, .wpm_changed, .empty_library, .reset_milestone, .reset_cancelled => true,
        else => false,
    };
    if (full_only and level != .full) return null;
    const cue: Cue = switch (event.kind) {
        .selection, .word_selection, .wpm_changed => .ui_tick,
        .accepted => .ui_confirm,
        .surface_opened => .surface_open,
        .surface_closed, .reset_cancelled => .surface_close,
        .page_changed => .page_turn,
        .chapter_changed => .chapter_turn,
        .mode_changed, .presentation_changed => .mode_change,
        .autoplay_started => .play,
        .autoplay_paused => .pause,
        .sentence_rewind => .rewind,
        .at_boundary, .empty_library => .boundary,
        .failure => .error_cue,
        .reset_started, .reset_milestone => .reset_arm,
        .reset_completed => .reset_complete,
    };
    return .{
        .cue = cue,
        .gain = if (event.quiet or event.kind == .word_selection) 0.3 else if (full_only or event.kind == .presentation_changed) 0.5 else 1,
        .pitch = if (event.kind == .reset_milestone) 3 * @as(f32, @floatFromInt(event.direction)) else @as(f32, @floatFromInt(event.direction)) * 1.5,
        .short = event.immediate or event.kind == .reset_milestone or event.kind == .reset_cancelled or event.kind == .presentation_changed,
        .direction = event.direction,
        .duration_ms = event.duration_ms,
    };
}

/// Coalesce low-priority events within a frame. Important events may evict a tick when
/// full.
pub const Buffer = struct {
    pub const capacity = 12;
    items: [capacity]Event = undefined,
    len: usize = 0,
    pub fn clear(self: *Buffer) void {
        self.len = 0;
    }
    pub fn push(self: *Buffer, event: Event) void {
        for (self.items[0..self.len]) |*item| {
            if (item.kind == event.kind) {
                item.* = event;
                return;
            }
        }
        if (self.len < capacity) {
            self.items[self.len] = event;
            self.len += 1;
            return;
        }
        const incoming = priority(map(event, .full).?.cue);
        var lowest: usize = 0;
        for (self.items[0..self.len], 0..) |item, i| {
            if (priority(map(item, .full).?.cue) < priority(map(self.items[lowest], .full).?.cue)) lowest = i;
        }
        if (incoming > priority(map(self.items[lowest], .full).?.cue)) self.items[lowest] = event;
    }
};

pub const Batch = struct {
    items: [Buffer.capacity]Request = undefined,
    len: usize = 0,
};
pub const Policy = struct {
    last_tick: ?u32 = null,
    last_boundary: ?u32 = null,
    pub fn reset(self: *Policy) void {
        self.* = .{};
    }
    pub fn drain(self: *Policy, buffer: *Buffer, level: Level, now: u32) Batch {
        var result = Batch{};
        self.drainInto(buffer, level, now, &result);
        return result;
    }

    /// Use heap-owned batch scratch to preserve the device stack.
    pub fn drainInto(self: *Policy, buffer: *Buffer, level: Level, now: u32, result: *Batch) void {
        defer buffer.clear();
        result.len = 0;
        var chapter = false;
        var navigation = false;
        var reset_complete = false;
        var failure = false;
        var semantic = false;
        var empty = false;
        for (buffer.items[0..buffer.len]) |event| {
            const request = map(event, level) orelse continue;
            chapter = chapter or request.cue == .chapter_turn;
            navigation = navigation or request.cue == .page_turn or request.cue == .chapter_turn or request.cue == .rewind or request.cue == .mode_change;
            reset_complete = reset_complete or request.cue == .reset_complete;
            failure = failure or request.cue == .error_cue;
            empty = empty or event.kind == .empty_library;
            semantic = semantic or priority(request.cue) >= 2;
        }
        for (buffer.items[0..buffer.len]) |event| {
            const request = map(event, level) orelse continue;
            if (empty and request.cue == .surface_close) continue;
            if (chapter and request.cue == .page_turn) continue;
            if (navigation and (request.cue == .surface_open or request.cue == .surface_close)) continue;
            if (reset_complete and !failure and request.cue != .reset_complete) continue;
            if (failure and request.cue != .error_cue) continue;
            if (request.cue == .ui_tick) {
                if (semantic or (self.last_tick != null and now -% self.last_tick.? < 60)) continue;
                self.last_tick = now;
            }
            if (request.cue == .boundary) {
                if ((semantic and event.kind != .empty_library) or (self.last_boundary != null and now -% self.last_boundary.? < 300)) continue;
                self.last_boundary = now;
            }
            result.items[result.len] = request;
            result.len += 1;
        }
        // Admit important cues first so ticks cannot take their last voice. With at
        // most twelve requests, insertion sort avoids std.mem.sort's large stack cache.
        var i: usize = 1;
        while (i < result.len) : (i += 1) {
            const request = result.items[i];
            var j = i;
            while (j > 0 and priority(result.items[j - 1].cue) < priority(request.cue)) : (j -= 1) {
                result.items[j] = result.items[j - 1];
            }
            result.items[j] = request;
        }
    }
};

/// Late updates select the current step instead of replaying missed ones. Timing uses
/// wrapping subtraction.
pub const Slots = struct {
    pub const Slot = struct { request: Request, started: u32, duration: u16, step: ?u8 = null };
    items: [2]?Slot = .{ null, null },
    pub fn stop(self: *Slots) void {
        self.items = .{ null, null };
    }
    pub fn admit(self: *Slots, request: Request, now: u32, duration: u16) ?usize {
        var candidate: ?usize = null;
        for (self.items, 0..) |item, i| {
            if (item == null or now -% item.?.started >= item.?.duration) {
                candidate = i;
                break;
            }
            if (candidate == null or priority(item.?.request.cue) < priority(self.items[candidate.?].?.request.cue) or
                (priority(item.?.request.cue) == priority(self.items[candidate.?].?.request.cue) and now -% item.?.started > now -% self.items[candidate.?].?.started)) candidate = i;
        }
        const index = candidate.?;
        if (self.items[index]) |old| {
            const incoming = priority(request.cue);
            const existing = priority(old.request.cue);
            if (now -% old.started < old.duration and (incoming < existing or (incoming == existing and incoming < 2))) return null;
        }
        self.items[index] = .{ .request = request, .started = now, .duration = duration };
        return index;
    }
    pub fn due(self: *Slots, index: usize, now: u32, second_at: ?u16) ?u8 {
        const slot = &(self.items[index] orelse return null);
        const elapsed = now -% slot.started;
        if (elapsed >= slot.duration) {
            self.items[index] = null;
            return null;
        }
        const step: u8 = if (second_at != null and elapsed >= second_at.?) 1 else 0;
        if (slot.step == step) return null;
        self.items[index].?.step = step;
        return step;
    }
};

test "policy levels, replacement, tick coalescing and boundary wraparound" {
    var buffer = Buffer{};
    var policy = Policy{};
    buffer.push(.{ .kind = .selection });
    try std.testing.expectEqual(@as(usize, 0), policy.drain(&buffer, .subtle, 0).len);
    buffer.push(.{ .kind = .accepted });
    try std.testing.expectEqual(@as(usize, 0), policy.drain(&buffer, .off, 0).len);
    buffer.push(.{ .kind = .page_changed });
    buffer.push(.{ .kind = .chapter_changed });
    buffer.push(.{ .kind = .surface_closed });
    buffer.push(.{ .kind = .selection });
    const batch = policy.drain(&buffer, .full, 0);
    try std.testing.expectEqual(@as(usize, 1), batch.len);
    try std.testing.expectEqual(Cue.chapter_turn, batch.items[0].cue);
    buffer.push(.{ .kind = .selection });
    buffer.push(.{ .kind = .selection, .direction = -1 });
    try std.testing.expectEqual(@as(usize, 1), policy.drain(&buffer, .full, 1).len);
    buffer.push(.{ .kind = .word_selection });
    try std.testing.expectEqual(@as(usize, 0), policy.drain(&buffer, .full, 30).len);
    buffer.push(.{ .kind = .at_boundary });
    try std.testing.expectEqual(@as(usize, 1), policy.drain(&buffer, .subtle, std.math.maxInt(u32) - 100).len);
    buffer.push(.{ .kind = .at_boundary });
    try std.testing.expectEqual(@as(usize, 0), policy.drain(&buffer, .subtle, 20).len);
    buffer.push(.{ .kind = .at_boundary });
    try std.testing.expectEqual(@as(usize, 1), policy.drain(&buffer, .subtle, 300).len);
}

test "reset and failures supersede ordinary confirmations" {
    var buffer = Buffer{};
    var policy = Policy{};
    buffer.push(.{ .kind = .reset_completed });
    buffer.push(.{ .kind = .reset_cancelled });
    buffer.push(.{ .kind = .surface_closed });
    try std.testing.expectEqual(Cue.reset_complete, policy.drain(&buffer, .full, 0).items[0].cue);
    buffer.push(.{ .kind = .accepted });
    buffer.push(.{ .kind = .failure });
    const batch = policy.drain(&buffer, .subtle, 0);
    try std.testing.expectEqual(@as(usize, 1), batch.len);
    try std.testing.expectEqual(Cue.error_cue, batch.items[0].cue);
}

test "voice admission, late steps, cancellation and timer wrap" {
    var slots = Slots{};
    const started = std.math.maxInt(u32) - 40;
    try std.testing.expectEqual(@as(?usize, 0), slots.admit(.{ .cue = .page_turn }, started, 200));
    try std.testing.expectEqual(@as(?usize, 1), slots.admit(.{ .cue = .chapter_turn }, started, 200));
    try std.testing.expect(slots.admit(.{ .cue = .ui_tick }, started, 20) == null);
    try std.testing.expectEqual(@as(?usize, 0), slots.admit(.{ .cue = .error_cue }, started, 200));
    try std.testing.expectEqual(@as(?u8, 1), slots.due(0, 60, 80));
    try std.testing.expect(slots.due(0, 61, 80) == null);
    try std.testing.expect(slots.due(0, 300, 80) == null);
    slots.stop();
    try std.testing.expect(slots.due(1, 60, 80) == null);
}

test "buffer overload preserves high priority feedback" {
    var buffer = Buffer{};
    for (std.enums.values(Kind)) |kind| buffer.push(.{ .kind = kind });
    var found = false;
    for (buffer.items[0..buffer.len]) |event| {
        found = found or event.kind == .reset_completed;
    }
    try std.testing.expect(found);
}

test "new meaningful feedback replaces the oldest equal-priority cue" {
    var slots = Slots{};
    _ = slots.admit(.{ .cue = .page_turn }, 0, 150);
    _ = slots.admit(.{ .cue = .surface_open }, 10, 150);
    try std.testing.expectEqual(@as(?usize, 0), slots.admit(.{ .cue = .page_turn, .direction = -1 }, 20, 150));
    try std.testing.expectEqual(@as(i8, -1), slots.items[0].?.request.direction);
    try std.testing.expect(slots.admit(.{ .cue = .ui_tick }, 30, 20) == null);
}

test "empty-library variant replaces close only in Full" {
    var buffer = Buffer{};
    var policy = Policy{};
    buffer.push(.{ .kind = .surface_closed });
    buffer.push(.{ .kind = .empty_library });
    try std.testing.expectEqual(Cue.surface_close, policy.drain(&buffer, .subtle, 0).items[0].cue);
    buffer.push(.{ .kind = .surface_closed });
    buffer.push(.{ .kind = .empty_library });
    const batch = policy.drain(&buffer, .full, 0);
    try std.testing.expectEqual(@as(usize, 1), batch.len);
    try std.testing.expectEqual(Cue.boundary, batch.items[0].cue);
}

test "caller-owned batch prioritizes cues stably and clears stale output" {
    var buffer = Buffer{};
    var policy = Policy{};
    var batch = Batch{};
    buffer.push(.{ .kind = .accepted });
    buffer.push(.{ .kind = .autoplay_started });
    buffer.push(.{ .kind = .sentence_rewind });
    buffer.push(.{ .kind = .autoplay_paused });
    policy.drainInto(&buffer, .full, 0, &batch);
    try std.testing.expectEqual(@as(usize, 4), batch.len);
    try std.testing.expectEqualSlices(Cue, &.{ .rewind, .ui_confirm, .play, .pause }, &.{ batch.items[0].cue, batch.items[1].cue, batch.items[2].cue, batch.items[3].cue });
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
    policy.drainInto(&buffer, .full, 1, &batch);
    try std.testing.expectEqual(@as(usize, 0), batch.len);
    buffer.push(.{ .kind = .accepted });
    policy.drainInto(&buffer, .off, 2, &batch);
    try std.testing.expectEqual(@as(usize, 0), batch.len);
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
}
