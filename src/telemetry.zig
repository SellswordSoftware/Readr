const std = @import("std");

pub const LoadingPhase = enum { archive, directory, member_bounds, directory_hash, cache, metadata_read, metadata_parse, navigation, chapter, resume_rebuild };
pub const LoadingPhaseStats = struct {
    updates: u32 = 0,
    elapsed_ms: u32 = 0,
    work_ms: u32 = 0,
    reads: u32 = 0,
    bytes: u32 = 0,
    seeks: u32 = 0,
    seek_ms: u32 = 0,
    read_ms: u32 = 0,
    max_seek_ms: u32 = 0,
    max_read_ms: u32 = 0,
};

/// Heap-resident measurements from selection through the restored destination.
/// I/O counts describe EPUB reads only, excluding persistence and font files.
pub const Loading = struct {
    active: bool = false,
    report_pending: bool = false,
    cache_hit: bool = false,
    max_frame_ms: u32 = 0,
    cache_write_ms: u32 = 0,
    cache_write_attempts: u32 = 0,
    cache_write_report_pending: bool = false,
    started_ms: u32 = 0,
    metadata_ms: ?u32 = null,
    first_text_ms: ?u32 = null,
    ready_ms: ?u32 = null,
    phase: LoadingPhase = .archive,
    phase_started_ms: u32 = 0,
    step_phase: LoadingPhase = .archive,
    step_started_ms: u32 = 0,
    step_active: bool = false,
    phases: [@typeInfo(LoadingPhase).@"enum".fields.len]LoadingPhaseStats = [_]LoadingPhaseStats{.{}} ** @typeInfo(LoadingPhase).@"enum".fields.len,

    pub fn begin(self: *Loading, now_ms: u32) void {
        self.* = .{ .active = true, .started_ms = now_ms, .phase_started_ms = now_ms };
    }
    pub fn cancel(self: *Loading) void {
        self.active = false;
    }
    fn changePhase(self: *Loading, phase: LoadingPhase, now_ms: u32) void {
        if (phase == self.phase) return;
        // Metadata can finish inside an opening step. Split that step at the
        // transition so its remaining work belongs to the new phase too.
        if (self.step_active) {
            self.stepFinished(now_ms);
            self.step_phase = phase;
            self.step_started_ms = now_ms;
            self.step_active = true;
            self.phases[@intFromEnum(phase)].updates +%= 1;
        }
        self.phases[@intFromEnum(self.phase)].elapsed_ms +%= now_ms -% self.phase_started_ms;
        self.phase = phase;
        self.phase_started_ms = now_ms;
    }
    pub fn stepStarted(self: *Loading, phase: LoadingPhase, now_ms: u32) void {
        if (!self.active) return;
        self.changePhase(phase, now_ms);
        self.step_phase = phase;
        self.step_started_ms = now_ms;
        self.step_active = true;
        self.phases[@intFromEnum(phase)].updates +%= 1;
    }
    pub fn stepFinished(self: *Loading, now_ms: u32) void {
        if (!self.step_active) return;
        self.phases[@intFromEnum(self.step_phase)].work_ms +%= now_ms -% self.step_started_ms;
        self.step_active = false;
    }
    pub fn recordRead(self: *Loading, bytes: usize, sought: bool) void {
        if (!self.active) return;
        const stats = &self.phases[@intFromEnum(self.phase)];
        stats.reads +%= 1;
        stats.bytes +%= @intCast(bytes);
        stats.seeks +%= @intFromBool(sought);
    }
    pub fn metadataFinished(self: *Loading, now_ms: u32) void {
        self.metadata_ms = now_ms -% self.started_ms;
        self.changePhase(.chapter, now_ms);
    }
    pub fn recordSeekTime(self: *Loading, duration_ms: u32) void {
        if (!self.active) return;
        const stats = &self.phases[@intFromEnum(self.phase)];
        stats.seek_ms +%= duration_ms;
        stats.max_seek_ms = @max(stats.max_seek_ms, duration_ms);
    }
    pub fn recordReadTime(self: *Loading, duration_ms: u32) void {
        if (!self.active) return;
        const stats = &self.phases[@intFromEnum(self.phase)];
        stats.read_ms +%= duration_ms;
        stats.max_read_ms = @max(stats.max_read_ms, duration_ms);
    }
    pub fn textAvailable(self: *Loading, now_ms: u32) void {
        if (self.first_text_ms == null) self.first_text_ms = now_ms -% self.started_ms;
    }
    pub fn destinationReady(self: *Loading, now_ms: u32) void {
        self.phases[@intFromEnum(self.phase)].elapsed_ms +%= now_ms -% self.phase_started_ms;
        self.ready_ms = now_ms -% self.started_ms;
        self.active = false;
        self.report_pending = true;
    }
};

/// Reader measurements shared by the console report and optional overlay.
pub const Telemetry = struct {
    loading: Loading = .{},
    enabled: bool = false,
    frame_count: u32 = 0,
    update_time_ms: u32 = 0,
    max_update_time_ms: u32 = 0,
    chapter_bytes_decoded: u32 = 0,
    chapter_events: u32 = 0,
    page_build_started_ms: u32 = 0,
    last_page_build_ms: u32 = 0,
    max_page_build_ms: u32 = 0,

    pub const Snapshot = struct {
        loading: Loading,
        update_time_ms: u32,
        max_update_time_ms: u32,
        chapter_bytes_decoded: u32,
        chapter_events: u32,
        last_page_build_ms: u32,
        max_page_build_ms: u32,
    };

    pub fn setEnabled(self: *Telemetry, enabled: bool) void {
        if (enabled and !self.enabled) {
            self.update_time_ms = 0;
            self.max_update_time_ms = 0;
            self.last_page_build_ms = 0;
            self.max_page_build_ms = 0;
        }
        self.enabled = enabled;
    }

    pub fn frameFinished(self: *Telemetry, started_at_ms: u32, now_ms: u32) void {
        self.update_time_ms = now_ms -% started_at_ms;
        self.max_update_time_ms = @max(self.max_update_time_ms, self.update_time_ms);
        self.frame_count +%= 1;
    }

    pub fn chapterStarted(self: *Telemetry, now_ms: u32) void {
        self.chapter_bytes_decoded = 0;
        self.chapter_events = 0;
        self.page_build_started_ms = now_ms;
    }

    pub fn decodedBytes(self: *Telemetry, count: usize) void {
        self.chapter_bytes_decoded +%= @intCast(count);
    }

    pub fn setChapterEvents(self: *Telemetry, count: u32) void {
        self.chapter_events = count;
    }

    pub fn pageCompleted(self: *Telemetry, now_ms: u32) void {
        self.last_page_build_ms = now_ms -% self.page_build_started_ms;
        self.max_page_build_ms = @max(self.max_page_build_ms, self.last_page_build_ms);
        self.page_build_started_ms = now_ms;
    }

    pub fn snapshot(self: *const Telemetry) Snapshot {
        return .{
            .loading = self.loading,
            .update_time_ms = self.update_time_ms,
            .max_update_time_ms = self.max_update_time_ms,
            .chapter_bytes_decoded = self.chapter_bytes_decoded,
            .chapter_events = self.chapter_events,
            .last_page_build_ms = self.last_page_build_ms,
            .max_page_build_ms = self.max_page_build_ms,
        };
    }
};

test "telemetry resets chapter data and retains frame and page high water marks" {
    var telemetry = Telemetry{};
    telemetry.setEnabled(true);
    telemetry.frameFinished(100, 112);
    telemetry.frameFinished(200, 218);
    telemetry.chapterStarted(300);
    telemetry.decodedBytes(10);
    telemetry.setChapterEvents(4);
    telemetry.pageCompleted(325);
    telemetry.pageCompleted(340);
    const snapshot = telemetry.snapshot();
    try std.testing.expectEqual(@as(u32, 18), snapshot.max_update_time_ms);
    try std.testing.expectEqual(@as(u32, 18), snapshot.update_time_ms);
    try std.testing.expectEqual(@as(u32, 25), snapshot.max_page_build_ms);
    try std.testing.expectEqual(@as(u32, 10), snapshot.chapter_bytes_decoded);
    try std.testing.expectEqual(@as(u32, 4), snapshot.chapter_events);
    telemetry.setEnabled(false);
    telemetry.setEnabled(true);
    try std.testing.expectEqual(@as(u32, 0), telemetry.max_update_time_ms);
}

test "loading separates metadata first text and destination and survives clock wrap" {
    var loading: Loading = .{};
    loading.begin(0xfffffff0);
    loading.stepStarted(.directory, 0xfffffff2);
    loading.recordRead(4096, true);
    loading.stepFinished(0xfffffff4);
    loading.metadataFinished(4);
    loading.textAvailable(6);
    loading.textAvailable(8);
    loading.stepStarted(.resume_rebuild, 10);
    loading.stepFinished(12);
    loading.destinationReady(20);
    try std.testing.expectEqual(@as(?u32, 20), loading.metadata_ms);
    try std.testing.expectEqual(@as(?u32, 22), loading.first_text_ms);
    try std.testing.expectEqual(@as(?u32, 36), loading.ready_ms);
    const directory = loading.phases[@intFromEnum(LoadingPhase.directory)];
    try std.testing.expectEqual(@as(u32, 1), directory.updates);
    try std.testing.expectEqual(@as(u32, 1), directory.reads);
    try std.testing.expectEqual(@as(u32, 1), directory.seeks);
    try std.testing.expectEqual(@as(u32, 4096), directory.bytes);
    try std.testing.expectEqual(@as(u32, 2), directory.work_ms);
    try std.testing.expect(!loading.active);
    try std.testing.expect(loading.report_pending);
    loading.begin(100);
    try std.testing.expect(loading.ready_ms == null);
    try std.testing.expectEqual(@as(u32, 0), loading.phases[0].reads);
}

test "loading splits work when metadata finishes inside a step" {
    var loading: Loading = .{};
    loading.begin(100);
    loading.stepStarted(.cache, 110);
    loading.metadataFinished(120);
    loading.recordRead(22, true);
    loading.recordSeekTime(3);
    loading.recordReadTime(2);
    loading.stepFinished(130);
    loading.stepStarted(.chapter, 135);
    loading.stepFinished(140);
    loading.destinationReady(150);
    const cache = loading.phases[@intFromEnum(LoadingPhase.cache)];
    const chapter = loading.phases[@intFromEnum(LoadingPhase.chapter)];
    try std.testing.expectEqual(@as(u32, 10), cache.work_ms);
    try std.testing.expectEqual(@as(u32, 10), cache.elapsed_ms);
    try std.testing.expectEqual(@as(u32, 15), chapter.work_ms);
    try std.testing.expectEqual(@as(u32, 30), chapter.elapsed_ms);
    try std.testing.expectEqual(@as(u32, 3), chapter.seek_ms);
    try std.testing.expectEqual(@as(u32, 2), chapter.read_ms);
}
