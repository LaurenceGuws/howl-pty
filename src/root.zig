//! Responsibility: export the howl-session package surface.
//! Ownership: package boundary for session/pty orchestration.
//! Reason: root.zig is already the package namespace.

const std = @import("std");
const session_mod = @import("session.zig");
const pty_mod = @import("pty.zig");
const SessionApi = session_mod;
const PtyApi = pty_mod;

pub const runtime = struct {
    pub const Session = SessionApi.Session;
    pub const Config = SessionApi.Config;
    pub const Status = SessionApi.Status;
    pub const Snapshot = SessionApi.Snapshot;
    pub const Ops = SessionApi.Ops;
};

pub const pty = struct {
    pub const Pty = PtyApi.Pty;
    pub const Class = PtyApi.PtyClass;
    pub const ControlSignal = PtyApi.ControlSignal;
    pub const Owned = PtyApi.OwnedPty;
    pub const LaunchConfig = PtyApi.LaunchConfig;
    pub const class = PtyApi.pty_class;

    pub fn init(allocator: std.mem.Allocator, launch: LaunchConfig) !Owned {
        return PtyApi.initPty(allocator, launch);
    }
};

pub const testing = struct {
    pub const Pty = struct {
        pub const Mem = PtyApi.Mem;
        pub const Partial = PtyApi.Partial;
        pub const Fail = PtyApi.Fail;
    };
};

/// Session runtime facade.
pub const Session = runtime.Session;
/// Session config payload.
pub const SessionConfig = runtime.Config;
/// Session lifecycle state enum.
pub const SessionStatus = runtime.Status;
/// Serializable session snapshot payload.
pub const SessionSnapshot = runtime.Snapshot;
/// Session operation counters for deterministic assertions.
pub const SessionOps = runtime.Ops;

/// PTY transport interface.
pub const Pty = pty.Pty;
/// PTY implementation class enum.
pub const PtyClass = pty.Class;
/// Typed control signal routed through the session/pty boundary.
pub const ControlSignal = pty.ControlSignal;
/// Build-selected PTY owner.
pub const OwnedPty = pty.Owned;
/// PTY child-process launch contract.
pub const PtyLaunchConfig = pty.LaunchConfig;
/// Build-selected PTY class value.
pub const pty_class = pty.class;

/// PTY variants for tests and deterministic transport assertions.
pub const TestPty = testing.Pty;

/// Create build-selected PTY transport.
pub fn initPty(allocator: @import("std").mem.Allocator, launch: PtyLaunchConfig) !OwnedPty {
    return pty.init(allocator, launch);
}

test {
    _ = @import("test/session.zig");
    _ = @import("test/pty.zig");
    std.testing.refAllDecls(@This());
}
