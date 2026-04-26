//! Responsibility: verify the stable howl-session package API shape and contracts.
//! Ownership: API shape assertions and conformance tests.
//! Reason: isolate API contract verification from root module wiring.

const std = @import("std");
const root = @import("../root.zig");

test "host API: all symbols exported" {
    _ = root.Session;
    _ = root.SessionConfig;
    _ = root.ControlSignal;
    _ = root.SessionStatus;
    _ = root.TransportClass;
    _ = root.Transport;
    _ = root.MemTransport;
    _ = root.FailTransport;
    _ = root.UnixPtyTransport;
    _ = root.HostLoopTick;
    _ = root.host_loop.tick;
}

test "host API: SessionConfig required fields present" {
    comptime {
        std.debug.assert(@hasField(root.SessionConfig, "allocator"));
        std.debug.assert(@hasField(root.SessionConfig, "cols"));
        std.debug.assert(@hasField(root.SessionConfig, "rows"));
        std.debug.assert(@hasField(root.SessionConfig, "pending_capacity"));
        std.debug.assert(@hasField(root.SessionConfig, "transport"));
    }
}

test "host API: Session required methods present" {
    comptime {
        _ = root.Session.init;
        _ = root.Session.deinit;
        _ = root.Session.start;
        _ = root.Session.stop;
        _ = root.Session.feed;
        _ = root.Session.apply;
        _ = root.Session.reset;
        _ = root.Session.resize;
        _ = root.Session.control;
    }
}

test "host API: Session observability fields present" {
    comptime {
        std.debug.assert(@hasField(root.Session, "status"));
        std.debug.assert(@hasField(root.Session, "cols"));
        std.debug.assert(@hasField(root.Session, "rows"));
        std.debug.assert(@hasField(root.Session, "resize_count"));
        std.debug.assert(@hasField(root.Session, "last_control_signal"));
    }
}

test "host API: ControlSignal required variants present" {
    _ = root.ControlSignal.hangup;
    _ = root.ControlSignal.interrupt;
    _ = root.ControlSignal.terminate;
    _ = root.ControlSignal.resize_notify;
}

test "host API: SessionStatus required variants present" {
    _ = root.SessionStatus.idle;
    _ = root.SessionStatus.active;
    _ = root.SessionStatus.stopped;
}

test "host API: TransportClass required variants present" {
    _ = root.TransportClass.posix_pty;
    _ = root.TransportClass.container_bridge;
    _ = root.TransportClass.conpty;
}

test "host API: Transport vtable methods present" {
    comptime {
        _ = root.Transport.start;
        _ = root.Transport.stop;
        _ = root.Transport.write;
        _ = root.Transport.read;
        _ = root.Transport.resize;
        _ = root.Transport.control;
    }
}

test "host API: SessionConfig transport field present with correct default" {
    comptime {
        std.debug.assert(@hasField(root.SessionConfig, "transport"));
        const default_config: root.SessionConfig = .{
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
        _ = root.Session.init;
        _ = root.Session.deinit;
        _ = root.Session.start;
        _ = root.Session.stop;
        _ = root.Session.feed;
        _ = root.Session.apply;
        _ = root.Session.reset;
        _ = root.Session.resize;
        _ = root.Session.control;
    }
}

test "host API: observable field types (freeze)" {
    const t = std.debug.assert;
    comptime {
        var zeroed: root.Session = undefined;
        zeroed.status = .idle;
        zeroed.cols = 0;
        zeroed.rows = 0;
        zeroed.resize_count = 0;
        zeroed.last_control_signal = null;

        t(@TypeOf(zeroed.status) == root.SessionStatus);
        t(@TypeOf(zeroed.cols) == u16);
        t(@TypeOf(zeroed.rows) == u16);
        t(@TypeOf(zeroed.resize_count) == u32);
        t(@TypeOf(zeroed.last_control_signal) == ?root.ControlSignal);
    }
}
