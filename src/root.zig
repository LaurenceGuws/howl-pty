//! Responsibility: export the howl-session owner surface.
//! Ownership: package boundary for session/pty orchestration.
//! Reason: keep exports boring, stable, and object-first.

const session_mod = @import("session.zig");
const pty_mod = @import("pty.zig");
const SessionApi = session_mod.SessionApi;
const PtyApi = pty_mod.PtyApi;

/// Canonical howl-session package owner.
pub const HowlSession = struct {
    /// Session runtime facade.
    pub const Session = SessionApi.Session;
    /// Session config payload.
    pub const SessionConfig = SessionApi.Config;
    /// Session lifecycle state enum.
    pub const SessionStatus = SessionApi.Status;
    /// Serializable session snapshot payload.
    pub const SessionSnapshot = SessionApi.Snapshot;
    /// Session operation counters for deterministic assertions.
    pub const SessionOps = SessionApi.Ops;

    /// PTY transport interface.
    pub const Pty = PtyApi.Pty;
    /// PTY implementation class enum.
    pub const PtyClass = PtyApi.PtyClass;
    /// Build-selected PTY owner.
    pub const OwnedPty = PtyApi.OwnedPty;
    /// Build-selected PTY class value.
    pub const pty_class = PtyApi.pty_class;

    /// Test/dummy PTY variants.
    pub const MemPty = PtyApi.Mem;
    pub const PartialPty = PtyApi.Partial;
    pub const FailPty = PtyApi.Fail;
    pub const AndroidPty = PtyApi.AndroidPty;
    pub const UnixPty = PtyApi.UnixPty;

    /// Create build-selected PTY transport.
    pub fn initPty(allocator: @import("std").mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !OwnedPty {
        return PtyApi.initPty(allocator, shell_path, command);
    }
};

test {
    _ = @import("test/session.zig");
}
