//! Responsibility: publish stable howl-session package API.
//! Ownership: package export boundary and test wiring.
//! Reason: keep consumers decoupled from internal file topology.

const std = @import("std");

pub const session = @import("session.zig");
pub const Session = session.Session;
pub const SessionConfig = session.Config;
pub const SessionStatus = session.SessionStatus;
pub const TransportClass = session.TransportClass;

pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const MemTransport = transport.MemTransport;
pub const PartialTransport = transport.PartialTransport;
pub const FailTransport = transport.FailTransport;
pub const AndroidPtyTransport = transport.AndroidPtyTransport;
pub const UnixPtyTransport = transport.UnixPtyTransport;
pub const LaneTransport = transport.LaneTransport;
pub const transport_class = transport.transport_class;
pub const initTransport = transport.initTransport;


test "facade wiring" {
    const s = @import("session.zig");
    const t = @import("transport.zig");
    comptime {
        std.debug.assert(Session == s.Session);
        std.debug.assert(SessionConfig == s.Config);
        std.debug.assert(Transport == t.Transport);
        std.debug.assert(MemTransport == t.MemTransport);
        std.debug.assert(FailTransport == t.FailTransport);
    }
}

const _api_tests = @import("testing/api_test.zig");
const _session_tests = @import("testing/session_test.zig");

test "root imports" {
    _ = _api_tests;    _ = _session_tests;
}
