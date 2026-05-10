//! Public API of the howl-session Zig module.

const lib = @This();
const std = @import("std");

const session = @import("session_namespace.zig");
const ffi = session.c_api;

pub const Ffi = ffi;
pub const Session = session.Session;
pub const Config = session.Config;
pub const Status = session.Status;
pub const Snapshot = session.Snapshot;
pub const Ops = session.Ops;
pub const Transport = session.Transport;
pub const TransportClass = session.TransportClass;
pub const ControlSignal = session.ControlSignal;
pub const OwnedTransport = session.OwnedTransport;
pub const LaunchConfig = session.LaunchConfig;
pub const transport_class = session.transport_class;
pub const TestTransport = session.TestTransport;

comptime {
    if (@import("root") == lib) {
        @export(&ffi.statusIdle, .{ .name = "howl_session_status_idle" });
        @export(&ffi.statusActive, .{ .name = "howl_session_status_active" });
        @export(&ffi.statusStopped, .{ .name = "howl_session_status_stopped" });
        @export(&ffi.statusIsValid, .{ .name = "howl_session_status_is_valid" });
        @export(&ffi.statusIsActive, .{ .name = "howl_session_status_is_active" });
        @export(&ffi.controlSignalHangup, .{ .name = "howl_session_control_signal_hangup" });
        @export(&ffi.controlSignalInterrupt, .{ .name = "howl_session_control_signal_interrupt" });
        @export(&ffi.controlSignalResizeNotify, .{ .name = "howl_session_control_signal_resize_notify" });
        @export(&ffi.controlSignalKill, .{ .name = "howl_session_control_signal_kill" });
        @export(&ffi.controlSignalTerminate, .{ .name = "howl_session_control_signal_terminate" });
        @export(&ffi.controlSignalIsValid, .{ .name = "howl_session_control_signal_is_valid" });
    }
}

pub const runtime = session.runtime;
pub const transport = session.transport;
pub const testing = session.testing;

pub fn initTransport(allocator: std.mem.Allocator, launch: LaunchConfig) !OwnedTransport {
    return session.initTransport(allocator, launch);
}

test {
    _ = @import("test/session.zig");
    _ = @import("test/pty.zig");
    std.testing.refAllDecls(lib);
}
