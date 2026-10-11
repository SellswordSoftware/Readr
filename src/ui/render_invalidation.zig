const std = @import("std");
const reader = @import("reader_view.zig");
const paged_reader = @import("../reader/paged_reader.zig");
const pagination = @import("../content/pagination.zig");
const statistics = @import("reading_statistics.zig");

// Use u32 to keep heap-owned application state at four-byte device alignment.
pub const Fingerprint = struct { lo: u32, hi: u32 };
pub const State = struct {
    previous: ?Fingerprint = null,
    pub fn invalidate(self: *State) void {
        self.previous = null;
    }
    pub fn shouldDraw(self: *State, next: Fingerprint, animated: bool) bool {
        if (!animated and self.previous != null and std.meta.eql(self.previous.?, next)) return false;
        self.previous = next;
        return true;
    }
};

pub fn fingerprint(model: *const reader.RenderModel, theme: reader.Theme, pages_font: reader.ReadingFont, rsvp_font: reader.ReadingFont, reduce_flashing: bool, notice: ?[]const u8) Fingerprint {
    var hash = std.hash.Wyhash.init(0);
    add(&hash, model);
    add(&hash, &theme);
    add(&hash, &pages_font);
    add(&hash, &rsvp_font);
    add(&hash, &reduce_flashing);
    add(&hash, &notice);
    const value = hash.final();
    return .{ .lo = @truncate(value), .hi = @truncate(value >> 32) };
}

// Hash initialized fields and text contents, excluding padding, unused slots, and
// pointer identities.
fn add(hash: *std.hash.Wyhash, value: anytype) void {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    if (T == statistics.Text) {
        add(hash, &value.slice());
    } else if (T == pagination.PageCache) {
        add(hash, &value.line_count);
        for (0..value.line_count) |index| add(hash, &value.line(index));
    } else if (T == reader.LibraryView) {
        addFieldsExcept(hash, value, &.{ "paths", "progress" });
        add(hash, &value.paths[0..@min(value.count - value.first_visible, reader.library_visible_rows)]);
        add(hash, &value.progress[0..@min(value.count - value.first_visible, reader.library_visible_rows)]);
    } else if (T == reader.ChaptersView) {
        addFieldsExcept(hash, value, &.{"rows"});
        add(hash, &value.rows[0..value.row_count]);
    } else if (T == reader.PagedView or T == reader.PageTransitionView) {
        addFieldsExcept(hash, value, &.{"lines"});
        add(hash, &value.lines[0..value.line_count]);
    } else if (T == paged_reader.PagedReader.ScrollRenderState) {
        addFieldsExcept(hash, value, &.{"tiles"});
        add(hash, &value.tiles[0..value.tile_count]);
    } else switch (@typeInfo(T)) {
        .@"struct" => addFieldsExcept(hash, value, &.{}),
        .@"union" => {
            const tag = std.meta.activeTag(value.*);
            std.hash.autoHash(hash, tag);
            switch (value.*) {
                inline else => |*payload| add(hash, payload),
            }
        },
        .optional => {
            std.hash.autoHash(hash, value.* != null);
            if (value.*) |*payload| add(hash, payload);
        },
        .pointer => |pointer| switch (pointer.size) {
            .one => add(hash, value.*),
            .slice => {
                std.hash.autoHash(hash, value.len);
                if (pointer.child == u8) hash.update(value.*) else for (value.*) |*item| add(hash, item);
            },
            else => @compileError("Unsupported render pointer"),
        },
        .array => for (value) |*item| add(hash, item),
        .void => {},
        else => std.hash.autoHash(hash, value.*),
    }
}
fn addFieldsExcept(hash: *std.hash.Wyhash, value: anytype, comptime excluded: []const []const u8) void {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        comptime var skip = false;
        inline for (excluded) |name| if (comptime std.mem.eql(u8, name, field.name)) {
            skip = true;
        };
        if (comptime !skip) add(hash, &@field(value.*, field.name));
    }
}

pub fn loadingAnimated(model: *const reader.RenderModel) bool {
    return switch (model.*) {
        .opening => true,
        .paged => |*view| !view.mode_switch_loading and (view.restoring or view.line_count == 0),
        .scroll => |*view| view.restoring and !view.mode_switch_loading,
        .rsvp => |*view| view.word == null and !view.mode_switch_loading,
        .statistics => |*view| switch (view.backdrop) {
            .paged => |*page| !page.mode_switch_loading and (page.restoring or page.line_count == 0),
            .scroll => |*scroll| scroll.restoring and !scroll.mode_switch_loading,
        },
        else => false,
    };
}

pub fn lineVisible(y: i32, font_height: usize, top: i32, height: i32) bool {
    return y < top + height and y + @as(i32, @intCast(font_height)) > top;
}

fn pageModel() reader.RenderModel {
    var model = reader.RenderModel{ .paged = .{ .lines = undefined, .line_count = 1, .selected_span = null, .page_index = 0, .waiting = false, .reconstructing = false } };
    model.paged.lines[0] = "one two";
    return model;
}
fn key(model: *const reader.RenderModel) Fingerprint {
    return fingerprint(model, .light, .newsleak_serif, .roobert_20_medium, false, null);
}

test "idle views stop drawing animations get a cleanup frame and resume invalidates" {
    var model = pageModel();
    var state = State{};
    try std.testing.expect(state.shouldDraw(key(&model), false));
    for (0..120) |_| try std.testing.expect(!state.shouldDraw(key(&model), false));
    try std.testing.expect(state.shouldDraw(key(&model), true));
    try std.testing.expect(state.shouldDraw(key(&model), true));
    try std.testing.expect(!state.shouldDraw(key(&model), false));
    state.invalidate();
    try std.testing.expect(state.shouldDraw(key(&model), false));
}

test "borrowed text changes selected words progress and transitions invalidate Pages" {
    var model = pageModel();
    var text = [_]u8{ 'o', 'n', 'e' };
    model.paged.lines[0] = &text;
    var before = key(&model);
    text[0] = 'O';
    try std.testing.expect(!std.meta.eql(before, key(&model)));
    before = key(&model);
    model.paged.selected_span = .{ .line_index = 0, .start = 0, .end = 3 };
    try std.testing.expect(!std.meta.eql(before, key(&model)));
    before = key(&model);
    model.paged.progress = .{ .chapter = .pending, .book = .pending };
    try std.testing.expect(!std.meta.eql(before, key(&model)));
    before = key(&model);
    model.paged.progress.?.chapter = .unavailable;
    try std.testing.expect(!std.meta.eql(before, key(&model)));
    var transition = reader.PageTransitionView{ .lines = undefined, .line_count = 1, .direction = .forward, .elapsed_ms = 10 };
    transition.lines[0] = "old page";
    model.paged.transition = transition;
    before = key(&model);
    model.paged.transition.?.elapsed_ms = 20;
    try std.testing.expect(!std.meta.eql(before, key(&model)));
}

test "theme both fonts Reduce Flashing and persistence notices invalidate" {
    const model = pageModel();
    const baseline = key(&model);
    try std.testing.expect(!std.meta.eql(baseline, fingerprint(&model, .dark, .newsleak_serif, .roobert_20_medium, false, null)));
    try std.testing.expect(!std.meta.eql(baseline, fingerprint(&model, .light, .sasser_slab, .roobert_20_medium, false, null)));
    try std.testing.expect(!std.meta.eql(baseline, fingerprint(&model, .light, .newsleak_serif, .roobert_24_medium, false, null)));
    try std.testing.expect(!std.meta.eql(baseline, fingerprint(&model, .light, .newsleak_serif, .roobert_20_medium, true, null)));
    try std.testing.expect(!std.meta.eql(baseline, fingerprint(&model, .light, .newsleak_serif, .roobert_20_medium, false, "Save failed")));
}

test "Scroll hashes initialized tile contents rather than a reusable cache address" {
    var page = pagination.PageCache{};
    try page.appendLine("one");
    var model = reader.RenderModel{ .scroll = .{ .window = .{} } };
    model.scroll.window.tile_count = 1;
    model.scroll.window.tiles[0] = .{ .page = .{ .cache = &page, .origin_y = 8 } };
    const before = key(&model);
    page.lines[0][0] = 'O';
    try std.testing.expect(!std.meta.eql(before, key(&model)));
    const after = key(&model);
    model.scroll.window.tiles[0].page.origin_y += 1;
    try std.testing.expect(!std.meta.eql(after, key(&model)));
}

test "loading stays animated and fully offscreen Scroll lines are omitted" {
    const opening: reader.RenderModel = .opening;
    try std.testing.expect(loadingAnimated(&opening));
    var page = pageModel();
    try std.testing.expect(!loadingAnimated(&page));
    page.paged.restoring = true;
    try std.testing.expect(loadingAnimated(&page));
    page.paged.mode_switch_loading = true;
    try std.testing.expect(!loadingAnimated(&page));
    try std.testing.expect(!lineVisible(-12, 20, 8, 220));
    try std.testing.expect(lineVisible(-11, 20, 8, 220));
    try std.testing.expect(lineVisible(227, 20, 8, 220));
    try std.testing.expect(!lineVisible(228, 20, 8, 220));
}
