//! Responsibility: export the howl-session package surface.
//! Ownership: package boundary for session/pty orchestration.
//! Reason: root.zig is already the package namespace.

const session_mod = @import("session.zig");
const pty_mod = @import("pty.zig");
const SessionApi = session_mod;
const PtyApi = pty_mod;

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
/// Typed control signal routed through the session/pty boundary.
pub const ControlSignal = PtyApi.ControlSignal;
/// Build-selected PTY owner.
pub const OwnedPty = PtyApi.OwnedPty;
/// PTY child-process launch contract.
pub const PtyLaunchConfig = PtyApi.LaunchConfig;
/// Build-selected PTY class value.
pub const pty_class = PtyApi.pty_class;

/// Test/dummy PTY variants.
pub const MemPty = PtyApi.Mem;
pub const PartialPty = PtyApi.Partial;
pub const FailPty = PtyApi.Fail;

/// Create build-selected PTY transport.
pub fn initPty(allocator: @import("std").mem.Allocator, launch: PtyLaunchConfig) !OwnedPty {
    return PtyApi.initPty(allocator, launch);
}

test {
    _ = @import("test/session.zig");
    _ = @import("test/pty.zig");
}
