//! Responsibility: define the howl-pty root used for the C ABI and internal build wiring.
//! Ownership: C ABI export root and internal root-module assembly.
//! Reason: keep the public contract C-first while Zig internals remain free to change.

const lib = @This();
const std = @import("std");

const session = @import("session_namespace.zig");
const ffi = session.c_api;

pub const Ffi = ffi;
pub const C = ffi;
pub const Session = session.Session;
pub const Config = session.Config;
pub const Status = session.Status;
pub const Snapshot = session.Snapshot;
pub const TransportPumpMode = session.TransportPumpMode;
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
        @export(&ffi.statusIdle, .{ .name = "howl_pty_status_idle" });
        @export(&ffi.statusActive, .{ .name = "howl_pty_status_active" });
        @export(&ffi.statusStopped, .{ .name = "howl_pty_status_stopped" });
        @export(&ffi.statusIsValid, .{ .name = "howl_pty_status_is_valid" });
        @export(&ffi.statusIsActive, .{ .name = "howl_pty_status_is_active" });
        @export(&ffi.controlSignalHangup, .{ .name = "howl_pty_control_signal_hangup" });
        @export(&ffi.controlSignalInterrupt, .{ .name = "howl_pty_control_signal_interrupt" });
        @export(&ffi.controlSignalResizeNotify, .{ .name = "howl_pty_control_signal_resize_notify" });
        @export(&ffi.controlSignalKill, .{ .name = "howl_pty_control_signal_kill" });
        @export(&ffi.controlSignalTerminate, .{ .name = "howl_pty_control_signal_terminate" });
        @export(&ffi.controlSignalIsValid, .{ .name = "howl_pty_control_signal_is_valid" });
        @export(&ffi.sessionInit, .{ .name = "howl_pty_session_init" });
        @export(&ffi.sessionDeinit, .{ .name = "howl_pty_session_deinit" });
        @export(&ffi.sessionStart, .{ .name = "howl_pty_session_start" });
        @export(&ffi.sessionStop, .{ .name = "howl_pty_session_stop" });
        @export(&ffi.sessionIsActive, .{ .name = "howl_pty_session_is_active" });
        @export(&ffi.sessionSnapshot, .{ .name = "howl_pty_session_snapshot" });
        @export(&ffi.sessionResize, .{ .name = "howl_pty_session_resize" });
        @export(&ffi.sessionPublishInput, .{ .name = "howl_pty_session_publish_input" });
        @export(&ffi.sessionPublishInputAndPump, .{ .name = "howl_pty_session_publish_input_and_pump" });
        @export(&ffi.sessionPumpOutbound, .{ .name = "howl_pty_session_pump_outbound" });
        @export(&ffi.sessionHasBacklog, .{ .name = "howl_pty_session_has_backlog" });
        @export(&ffi.sessionPendingBytes, .{ .name = "howl_pty_session_pending_bytes" });
        @export(&ffi.sessionBytesApplied, .{ .name = "howl_pty_session_bytes_applied" });
        @export(&ffi.sessionKickWait, .{ .name = "howl_pty_session_kick_wait" });
        @export(&ffi.sessionWaitReadable, .{ .name = "howl_pty_session_wait_readable" });
        @export(&ffi.sessionRead, .{ .name = "howl_pty_session_read" });
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
