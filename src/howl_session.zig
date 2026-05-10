//! Public API of the howl-session Zig module.

const lib = @This();
const std = @import("std");

const ffi = @import("ffi.zig");
const session_mod = @import("session.zig");
const transport_mod = @import("pty.zig");

pub const Ffi = ffi;
pub const Session = session_mod.Session;
pub const Config = session_mod.Config;
pub const Status = session_mod.Status;
pub const Snapshot = session_mod.Snapshot;
pub const Ops = session_mod.Ops;
pub const Transport = transport_mod.Pty;
pub const TransportClass = transport_mod.PtyClass;
pub const ControlSignal = transport_mod.ControlSignal;
pub const OwnedTransport = transport_mod.OwnedPty;
pub const LaunchConfig = transport_mod.LaunchConfig;
pub const transport_class = transport_mod.pty_class;
pub const TestTransport = testing.Transport;

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

pub const runtime = struct {
    pub const Session = session_mod.Session;
    pub const Config = session_mod.Config;
    pub const Status = session_mod.Status;
    pub const Snapshot = session_mod.Snapshot;
    pub const Ops = session_mod.Ops;
};

pub const transport = struct {
    pub const Handle = transport_mod.Pty;
    pub const Class = transport_mod.PtyClass;
    pub const ControlSignal = transport_mod.ControlSignal;
    pub const Owned = transport_mod.OwnedPty;
    pub const LaunchConfig = transport_mod.LaunchConfig;
    pub const class = transport_mod.pty_class;

    pub fn init(allocator: std.mem.Allocator, launch: transport_mod.LaunchConfig) !Owned {
        return transport_mod.initPty(allocator, launch);
    }
};

pub const testing = struct {
    pub const Transport = struct {
        pub const Mem = transport_mod.Mem;
        pub const Partial = transport_mod.Partial;
        pub const Fail = transport_mod.Fail;
    };
};

pub fn initTransport(allocator: std.mem.Allocator, launch: LaunchConfig) !OwnedTransport {
    return transport.init(allocator, launch);
}

test {
    _ = @import("test/session.zig");
    _ = @import("test/pty.zig");
    std.testing.refAllDecls(lib);
}
