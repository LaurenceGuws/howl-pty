//! Responsibility: export the howl-session object surface.
//! Ownership: package boundary for session/pty orchestration.
//! Reason: keep exports boring, stable, and object-first.

const session_mod = @import("session.zig");
const pty_mod = @import("pty.zig");

/// Canonical howl-session package object.
pub const HowlSession = struct {
    /// Session runtime facade.
    pub const Session = session_mod.Session;
    /// Session config payload.
    pub const SessionConfig = session_mod.Config;
    /// Session lifecycle state enum.
    pub const SessionStatus = session_mod.Status;

    /// PTY transport interface.
    pub const Pty = pty_mod.Pty;
    /// Build-selected PTY implementation.
    pub const PtyImpl = pty_mod.PtyImpl;
    /// Build-selected PTY class value.
    pub const pty_class = pty_mod.pty_class;

    /// Test/dummy PTY variants.
    pub const MemPty = pty_mod.Mem;
    pub const PartialPty = pty_mod.Partial;
    pub const FailPty = pty_mod.Fail;
    pub const AndroidPty = pty_mod.AndroidPty;
    pub const UnixPty = pty_mod.UnixPty;

    /// Create build-selected PTY transport.
    pub fn initPty(allocator: @import("std").mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !PtyImpl {
        return pty_mod.init(allocator, shell_path, command);
    }
};
