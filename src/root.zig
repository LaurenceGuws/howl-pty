const std = @import("std");

pub const session = @import("session.zig");
pub const Session = session.Session;
pub const SessionConfig = session.Config;
pub const ControlSignal = session.ControlSignal;
pub const SessionStatus = session.SessionStatus;
pub const TransportClass = session.TransportClass;
pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const MemTransport = transport.MemTransport;
pub const FailTransport = transport.FailTransport;
pub const UnixPtyTransport = transport.UnixPtyTransport;
pub const host_loop = @import("ops/host_loop.zig");
pub const HostLoopTick = host_loop.HostLoopTick;

test "host API: all symbols exported" {
    _ = Session;
    _ = SessionConfig;
    _ = ControlSignal;
    _ = SessionStatus;
    _ = TransportClass;
    _ = Transport;
    _ = MemTransport;
    _ = FailTransport;
    _ = UnixPtyTransport;
    _ = HostLoopTick;
    _ = host_loop.tick;
}

test "host API: SessionConfig required fields present" {
    comptime {
        std.debug.assert(@hasField(SessionConfig, "allocator"));
        std.debug.assert(@hasField(SessionConfig, "cols"));
        std.debug.assert(@hasField(SessionConfig, "rows"));
        std.debug.assert(@hasField(SessionConfig, "pending_capacity"));
        std.debug.assert(@hasField(SessionConfig, "transport"));
    }
}

test "host API: Session required methods present" {
    comptime {
        _ = Session.init;
        _ = Session.deinit;
        _ = Session.start;
        _ = Session.stop;
        _ = Session.feed;
        _ = Session.apply;
        _ = Session.reset;
        _ = Session.resize;
        _ = Session.control;
    }
}

test "host API: Session observability fields present" {
    comptime {
        std.debug.assert(@hasField(Session, "status"));
        std.debug.assert(@hasField(Session, "cols"));
        std.debug.assert(@hasField(Session, "rows"));
        std.debug.assert(@hasField(Session, "resize_count"));
        std.debug.assert(@hasField(Session, "last_control_signal"));
    }
}

test "host API: ControlSignal required variants present" {
    _ = ControlSignal.hangup;
    _ = ControlSignal.interrupt;
    _ = ControlSignal.terminate;
    _ = ControlSignal.resize_notify;
}

test "host API: SessionStatus required variants present" {
    _ = SessionStatus.idle;
    _ = SessionStatus.active;
    _ = SessionStatus.stopped;
}

test "host API: TransportClass required variants present" {
    _ = TransportClass.posix_pty;
    _ = TransportClass.container_bridge;
    _ = TransportClass.conpty;
}

test "host API: Transport vtable methods present" {
    comptime {
        _ = Transport.start;
        _ = Transport.stop;
        _ = Transport.write;
        _ = Transport.read;
        _ = Transport.resize;
        _ = Transport.control;
    }
}

test "host API: facade wiring — transport symbols match sub-module origins" {
    const t_iface = @import("transport/interface.zig");
    const t_mem = @import("transport/mem.zig");
    const t_fail = @import("transport/fail.zig");
    const t_pty = @import("transport/unix_pty.zig");
    comptime {
        std.debug.assert(Transport == t_iface.Transport);
        std.debug.assert(MemTransport == t_mem.MemTransport);
        std.debug.assert(FailTransport == t_fail.FailTransport);
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

test "host API: SessionConfig transport field present with correct default" {
    comptime {
        std.debug.assert(@hasField(SessionConfig, "transport"));
        const default_config: SessionConfig = .{
            .allocator = undefined,
            .cols = 80,
            .rows = 24,
            .pending_capacity = 4096,
        };
        std.debug.assert(default_config.transport == null);
    }
}

test "host API: method availability and accessibility" {
    comptime {
        _ = Session.init;
        _ = Session.deinit;
        _ = Session.start;
        _ = Session.stop;
        _ = Session.feed;
        _ = Session.apply;
        _ = Session.reset;
        _ = Session.resize;
        _ = Session.control;
    }
}

test "host API: observable field types (freeze)" {
    const t = std.debug.assert;
    comptime {
        var zeroed: Session = undefined;
        zeroed.status = .idle;
        zeroed.cols = 0;
        zeroed.rows = 0;
        zeroed.resize_count = 0;
        zeroed.last_control_signal = null;

        t(@TypeOf(zeroed.status) == SessionStatus);
        t(@TypeOf(zeroed.cols) == u16);
        t(@TypeOf(zeroed.rows) == u16);
        t(@TypeOf(zeroed.resize_count) == u32);
        t(@TypeOf(zeroed.last_control_signal) == ?ControlSignal);
    }
}
