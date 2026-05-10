//! Session namespace wrapper for the howl-session module.

const options = @import("session_options");

pub const c_api = if (options.c_abi) @import("ffi.zig") else void;

const runtime_mod = @import("session.zig");
const transport_mod = @import("pty.zig");

pub const Session = runtime_mod.Session;
pub const Config = runtime_mod.Config;
pub const Status = runtime_mod.Status;
pub const Snapshot = runtime_mod.Snapshot;
pub const Ops = runtime_mod.Ops;

pub const Transport = transport_mod.Pty;
pub const TransportClass = transport_mod.PtyClass;
pub const ControlSignal = transport_mod.ControlSignal;
pub const OwnedTransport = transport_mod.OwnedPty;
pub const LaunchConfig = transport_mod.LaunchConfig;
pub const transport_class = transport_mod.pty_class;

pub const runtime = struct {
    pub const Session = runtime_mod.Session;
    pub const Config = runtime_mod.Config;
    pub const Status = runtime_mod.Status;
    pub const Snapshot = runtime_mod.Snapshot;
    pub const Ops = runtime_mod.Ops;
};

pub const transport = struct {
    pub const Handle = transport_mod.Pty;
    pub const Class = transport_mod.PtyClass;
    pub const ControlSignal = transport_mod.ControlSignal;
    pub const Owned = transport_mod.OwnedPty;
    pub const LaunchConfig = transport_mod.LaunchConfig;
    pub const class = transport_mod.pty_class;
    pub const init = transport_mod.initPty;
};

pub const testing = struct {
    pub const Transport = struct {
        pub const Mem = transport_mod.Mem;
        pub const Partial = transport_mod.Partial;
        pub const Fail = transport_mod.Fail;
    };
};

pub const TestTransport = testing.Transport;

pub const initTransport = transport_mod.initPty;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
