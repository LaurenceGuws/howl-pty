//! Responsibility: publish the stable howl-session package API.
//! Ownership: module export boundary and package-level test wiring.
//! Reason: keep consumers decoupled from internal file topology.

const std = @import("std");

/// Session facade module.
pub const session = @import("session.zig");
/// Session type.
pub const Session = session.Session;
/// Session configuration type.
pub const SessionConfig = session.Config;
/// Control signal enum.
pub const ControlSignal = session.ControlSignal;
/// Session lifecycle status enum.
pub const SessionStatus = session.SessionStatus;
/// Transport portability class enum.
pub const TransportClass = session.TransportClass;
/// Transport facade module.
pub const transport = @import("transport.zig");
/// Transport vtable wrapper.
pub const Transport = transport.Transport;
/// In-memory deterministic transport implementation.
pub const MemTransport = transport.MemTransport;
/// Always-failing transport implementation.
pub const FailTransport = transport.FailTransport;
/// Android PTY transport implementation.
pub const AndroidPtyTransport = transport.AndroidPtyTransport;
/// POSIX PTY transport implementation.
pub const UnixPtyTransport = transport.UnixPtyTransport;
/// Transport selected by compile-time lane configuration.
pub const LaneTransport = transport.LaneTransport;
/// transport class selected by compile-time lane configuration.
pub const transport_class = transport.transport_class;
/// transport constructor selected by compile-time lane configuration.
pub const initTransport = transport.initTransport;
/// Host loop helper module.
pub const host_loop = @import("host_loop.zig");
/// Host loop tick summary type.
pub const HostLoopTick = host_loop.HostLoopTick;

test "host API: facade wiring — transport symbols match sub-module origins" {
    const t_iface = @import("transport.zig");
    const t_mem = @import("transport.zig");
    const t_fail = @import("transport.zig");
    const t_android_pty = @import("transport.zig");
    const t_pty = @import("transport.zig");
    comptime {
        std.debug.assert(Transport == t_iface.Transport);
        std.debug.assert(MemTransport == t_mem.MemTransport);
        std.debug.assert(FailTransport == t_fail.FailTransport);
        std.debug.assert(AndroidPtyTransport == t_android_pty.AndroidPtyTransport);
        std.debug.assert(UnixPtyTransport == t_pty.UnixPtyTransport);
    }
}

test "host API: facade wiring — session symbols match sub-module origins" {
    const s_core = @import("session.zig");
    comptime {
        std.debug.assert(Session == s_core.Session);
        std.debug.assert(SessionConfig == s_core.Config);
        std.debug.assert(ControlSignal == s_core.ControlSignal);
        std.debug.assert(SessionStatus == s_core.SessionStatus);
    }
}

const _host_integration_test = @import("testing/host_integration_test.zig");
const _api_tests = @import("testing/api_test.zig");
const _session_tests = @import("testing/session_test.zig");

test "root: import hooks" {
    _ = _host_integration_test;
    _ = _api_tests;
    _ = _session_tests;
}
