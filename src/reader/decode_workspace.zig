const std = @import("std");

/// Tracks access to shared DEFLATE buffers. Callers must use these transitions to keep
/// active decoding and prefetch from overlapping.
pub const DecodeWorkspace = struct {
    pub const Owner = enum { none, active, prefetch };
    pub const Acquire = enum { acquired, busy, active_not_at_eof };

    owner: Owner = .none,
    active_verified_eof: bool = false,

    pub fn beginActive(self: *DecodeWorkspace) Acquire {
        if (self.owner != .none) return .busy;
        self.owner = .active;
        self.active_verified_eof = false;
        return .acquired;
    }

    /// Prefetch may reuse buffers only after active-entry EOF and CRC verification.
    pub fn markActiveVerifiedEof(self: *DecodeWorkspace) void {
        std.debug.assert(self.owner == .active);
        self.active_verified_eof = true;
    }

    pub fn beginPrefetch(self: *DecodeWorkspace) Acquire {
        if (self.owner == .prefetch) return .busy;
        if (self.owner != .active or !self.active_verified_eof) return .active_not_at_eof;
        self.owner = .prefetch;
        self.active_verified_eof = false;
        return .acquired;
    }

    /// Transfer ownership directly so no other decoder can acquire the buffers between
    /// streams.
    pub fn activatePrefetch(self: *DecodeWorkspace) void {
        std.debug.assert(self.owner == .prefetch);
        self.owner = .active;
        self.active_verified_eof = false;
    }

    pub fn release(self: *DecodeWorkspace, expected: Owner) void {
        std.debug.assert(self.owner == expected);
        self.owner = .none;
        self.active_verified_eof = false;
    }
};

test "prefetch cannot lease active decode storage before verified EOF" {
    var workspace = DecodeWorkspace{};
    try std.testing.expectEqual(DecodeWorkspace.Acquire.acquired, workspace.beginActive());
    try std.testing.expectEqual(DecodeWorkspace.Acquire.active_not_at_eof, workspace.beginPrefetch());
    workspace.markActiveVerifiedEof();
    try std.testing.expectEqual(DecodeWorkspace.Acquire.acquired, workspace.beginPrefetch());
    try std.testing.expectEqual(DecodeWorkspace.Owner.prefetch, workspace.owner);
}

test "activation transfers the only lease and cancellation releases it" {
    var workspace = DecodeWorkspace{};
    _ = workspace.beginActive();
    workspace.markActiveVerifiedEof();
    _ = workspace.beginPrefetch();
    workspace.activatePrefetch();
    try std.testing.expectEqual(DecodeWorkspace.Owner.active, workspace.owner);
    try std.testing.expectEqual(DecodeWorkspace.Acquire.busy, workspace.beginActive());
    workspace.release(.active);
    try std.testing.expectEqual(DecodeWorkspace.Acquire.acquired, workspace.beginActive());
}
