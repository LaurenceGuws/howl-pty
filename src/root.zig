//! Responsibility: publish the stable howl-session package API.
//! Ownership: module export boundary and package-level test wiring.
//! Reason: keep consumers decoupled from internal file topology.

const std = @import("std");

/// Session facade module.
pub const session = @import("session.zig");
/// Terminal runtime/frame facade module.
pub const terminal_api = @import("terminal_api.zig");
/// Session runtime type.
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
/// Runtime transport selected by compile-time lane configuration.
pub const RuntimeTransport = transport.RuntimeTransport;
/// Runtime transport class selected by compile-time lane configuration.
pub const runtime_transport_class = transport.runtime_transport_class;
/// Runtime transport constructor selected by compile-time lane configuration.
pub const initRuntimeTransport = transport.initRuntimeTransport;
/// Terminal surface runtime type.
pub const TerminalSurface = terminal_api.TerminalSurface;
/// Terminal frame model type.
pub const TerminalFrameData = terminal_api.FrameData;
/// Host loop helper module.
pub const host_loop = @import("ops/host_loop.zig");
/// Host loop tick summary type.
pub const HostLoopTick = host_loop.HostLoopTick;

test "host API: facade wiring — transport symbols match sub-module origins" {
    const t_iface = @import("transport/interface.zig");
    const t_mem = @import("transport/mem.zig");
    const t_fail = @import("transport/fail.zig");
    const t_android_pty = @import("transport/android_pty.zig");
    const t_pty = @import("transport/unix_pty.zig");
    comptime {
        std.debug.assert(Transport == t_iface.Transport);
        std.debug.assert(MemTransport == t_mem.MemTransport);
        std.debug.assert(FailTransport == t_fail.FailTransport);
        std.debug.assert(AndroidPtyTransport == t_android_pty.AndroidPtyTransport);
        std.debug.assert(UnixPtyTransport == t_pty.UnixPtyTransport);
    }
}

test "host API: facade wiring — session symbols match sub-module origins" {
    const s_core = @import("session/core.zig");
    comptime {
        std.debug.assert(Session == s_core.Session);
        std.debug.assert(SessionConfig == s_core.Config);
        std.debug.assert(ControlSignal == s_core.ControlSignal);
        std.debug.assert(SessionStatus == s_core.SessionStatus);
    }
}

const _host_integration_test = @import("conformance/host_integration_test.zig");
const _api_api_tests = @import("test/api_api.zig");
const _session_api_tests = @import("test/session_api.zig");

test "root: import hooks" {
    _ = _host_integration_test;
    _ = _api_api_tests;
    _ = _session_api_tests;
}
