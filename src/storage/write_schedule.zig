const std = @import("std");

pub const Kind = enum { position, pace, progress, settings };

/// Movement extends the quiet deadline but not the maximum dirty age. Due requests
/// remain pending until I/O completes.
pub const WriteSchedule = struct {
    const Request = struct {
        first_ms: u32,
        latest_ms: u32,
        debounce_ms: u32,
        max_dirty_ms: u32,
        due_latched: bool = false,
        failed_at_ms: ?u32 = null,
        retry_ms: u32 = 0,

        fn due(self: Request, now_ms: u32) bool {
            if (self.failed_at_ms) |failed_at| {
                if (now_ms -% failed_at < self.retry_ms) return false;
            }
            return self.due_latched or now_ms -% self.latest_ms >= self.debounce_ms or
                now_ms -% self.first_ms >= self.max_dirty_ms;
        }
    };

    requests: [4]?Request = .{ null, null, null, null },

    /// Keep intervals below half the u32 range so wrapping subtraction handles clock
    /// rollover.
    pub fn request(self: *WriteSchedule, kind: Kind, now_ms: u32, debounce_ms: u32, max_dirty_ms: u32) void {
        std.debug.assert(debounce_ms < 0x80000000 and max_dirty_ms < 0x80000000);
        const slot = &self.requests[@intFromEnum(kind)];
        if (slot.*) |*pending_request| {
            // Once due, even a new movement before the flush must not hide it.
            pending_request.due_latched = pending_request.due_latched or pending_request.due(now_ms);
            pending_request.latest_ms = now_ms;
            pending_request.debounce_ms = debounce_ms;
        } else {
            slot.* = .{ .first_ms = now_ms, .latest_ms = now_ms, .debounce_ms = debounce_ms, .max_dirty_ms = max_dirty_ms };
        }
    }

    pub fn due(self: *const WriteSchedule, kind: Kind, now_ms: u32) bool {
        const pending_request = self.requests[@intFromEnum(kind)] orelse return false;
        return pending_request.due(now_ms);
    }

    pub fn failed(self: *WriteSchedule, kind: Kind, now_ms: u32) void {
        const slot = &self.requests[@intFromEnum(kind)];
        if (slot.* == null) self.request(kind, now_ms, 0, 10000);
        const pending_request = &slot.*.?;
        pending_request.due_latched = true;
        pending_request.failed_at_ms = now_ms;
        pending_request.retry_ms = if (pending_request.retry_ms == 0) 2000 else @min(pending_request.retry_ms * 2, 30000);
    }

    pub fn hasFailure(self: *const WriteSchedule) bool {
        for (self.requests) |slot| {
            if (slot) |pending_request| if (pending_request.failed_at_ms != null) return true;
        }
        return false;
    }

    pub fn clear(self: *WriteSchedule, kind: Kind) void {
        self.requests[@intFromEnum(kind)] = null;
    }

    pub fn pending(self: *const WriteSchedule, kind: Kind) bool {
        return self.requests[@intFromEnum(kind)] != null;
    }
};

test "quiet deadline uses elapsed time and repeated checks do not advance it" {
    var schedule = WriteSchedule{};
    schedule.request(.position, 100, 2000, 10000);
    for (0..120) |_| try std.testing.expect(!schedule.due(.position, 100));
    try std.testing.expect(!schedule.due(.position, 2099));
    try std.testing.expect(schedule.due(.position, 2100));
}

test "continuous updates cannot postpone maximum dirty age at different rates" {
    for ([_]u32{ 16, 33, 100, 1000 }) |interval_ms| {
        for ([_]Kind{ .position, .pace, .progress }) |kind| {
            var schedule = WriteSchedule{};
            var now_ms: u32 = 0;
            while (now_ms < 10000) : (now_ms += interval_ms) {
                schedule.request(kind, now_ms, 2000, 10000);
                try std.testing.expect(!schedule.due(kind, now_ms));
            }
            schedule.request(kind, 10000, 2000, 10000);
            try std.testing.expect(schedule.due(kind, 10000));
        }
    }
}

test "movement resets quiet deadline but a due request stays due" {
    var schedule = WriteSchedule{};
    schedule.request(.position, 0, 2000, 10000);
    schedule.request(.position, 1500, 2000, 10000);
    try std.testing.expect(!schedule.due(.position, 2000));
    try std.testing.expect(!schedule.due(.position, 3499));
    schedule.request(.position, 3500, 2000, 10000);
    try std.testing.expect(schedule.due(.position, 3500));
}

test "clock wraparound preserves both deadlines" {
    const start: u32 = std.math.maxInt(u32) - 999;
    var schedule = WriteSchedule{};
    schedule.request(.position, start, 2000, 10000);
    try std.testing.expect(!schedule.due(.position, start +% 1999));
    try std.testing.expect(schedule.due(.position, start +% 2000));
    var elapsed: u32 = 1000;
    while (elapsed <= 10000) : (elapsed += 1000) {
        schedule.request(.pace, start +% (elapsed - 1000), 2000, 10000);
        try std.testing.expect(!schedule.due(.pace, start +% (elapsed - 1000)));
    }
    schedule.request(.pace, start +% 10000, 2000, 10000);
    try std.testing.expect(schedule.due(.pace, start +% 10000));
}

test "clearing a save starts a fresh dirty interval and keeps kinds independent" {
    var schedule = WriteSchedule{};
    schedule.request(.position, 0, 2000, 10000);
    schedule.request(.pace, 500, 2000, 10000);
    schedule.request(.progress, 1500, 2000, 10000);
    schedule.clear(.position);
    try std.testing.expect(!schedule.pending(.position));
    schedule.request(.position, 2000, 2000, 10000);
    try std.testing.expect(!schedule.due(.position, 2500));
    try std.testing.expect(schedule.due(.pace, 2500));
    try std.testing.expect(!schedule.due(.progress, 2500));
}

test "failed writes back off despite fresh movement and clock wraparound" {
    for ([_]u32{ 0, 0xfffffff0 }) |start| {
        var schedule = WriteSchedule{};
        var now = start;
        for ([_]u32{ 2000, 4000, 8000, 16000, 30000, 30000 }) |delay| {
            schedule.failed(.position, now);
            for (0..delay) |elapsed| {
                const at = now +% @as(u32, @intCast(elapsed));
                schedule.request(.position, at, 2000, 10000);
                try std.testing.expect(!schedule.due(.position, at));
            }
            now +%= delay;
            try std.testing.expect(schedule.due(.position, now));
            try std.testing.expect(schedule.hasFailure());
        }
        schedule.clear(.position);
        try std.testing.expect(!schedule.hasFailure());
    }
}
