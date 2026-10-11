const std = @import("std");
const zip = @import("../archive/zip.zig");
const epub = @import("../publication/epub.zig");
const publication_descriptors = @import("../publication/descriptors.zig");
const chapter_browser = @import("../ui/chapter_browser.zig");
const opening_session = @import("opening_session.zig");

/// The directory index borrows opening-job buffers. Resolve value-only descriptors
/// before freeing them; each stream binds its own reader.
pub const Session = struct {
    opening_job: ?*opening_session.Session = null,
    archive_index: ?zip.DirectoryIndex = null,
    descriptors: publication_descriptors.Descriptors = .{},
    browser_map: chapter_browser.SpineMap = .{},
    publication: epub.Publication = undefined,

    pub fn initInPlace(self: *Session) void {
        self.opening_job = null;
        self.archive_index = null;
        self.descriptors.ready = false;
        self.browser_map.ready = false;
    }

    /// Resolve retained metadata before releasing the borrowed directory index.
    pub fn resolvePublication(self: *Session) zip.Error!void {
        const directory = if (self.archive_index) |*index| index else return;
        try self.descriptors.resolve(&self.publication, directory);
        self.browser_map.build(&self.publication);
    }

    /// Drop the borrowed index before freeing opening storage. Repeated cancellation is
    /// safe.
    pub fn cancelOpening(self: *Session, allocator: ?std.mem.Allocator) void {
        self.archive_index = null;
        const job = self.opening_job orelse return;
        self.opening_job = null;
        if (allocator) |a| {
            job.cancel(a);
            a.destroy(job);
        } else job.closeFileLease();
    }
};

test "opening cancellation closes once and frees temporary storage" {
    const Probe = struct {
        closes: usize = 0,
        fn close(context: *anyopaque) void {
            const probe: *@This() = @ptrCast(@alignCast(context));
            probe.closes += 1;
        }
    };
    const allocator = std.testing.allocator;
    const session = try allocator.create(Session);
    defer allocator.destroy(session);
    session.initInPlace();
    const job = try allocator.create(opening_session.Session);
    job.initInPlace();
    var probe = Probe{};
    job.file = .{ .context = &probe, .close = Probe.close };
    job.package_xml = try allocator.alloc(u8, 1024);
    session.opening_job = job;
    session.cancelOpening(allocator);
    session.cancelOpening(allocator);
    try std.testing.expectEqual(@as(usize, 1), probe.closes);
    try std.testing.expect(session.archive_index == null);
    try std.testing.expect(session.opening_job == null);
}
