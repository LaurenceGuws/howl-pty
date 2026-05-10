//! Responsibility: implement the howl-session native ABI constants surface.
//! Ownership: session status and control-signal ABI contracts.
//! Reason: keep C consumers on typed session-owned values without exposing PTY internals.

const pty = @import("pty.zig");
const session = @import("session.zig");

fn boolInt(value: bool) c_int {
    return if (value) 1 else 0;
}

fn statusByte(status: session.Status) u8 {
    return @intFromEnum(status);
}

fn statusFromByte(status: u8) ?session.Status {
    return switch (status) {
        statusByte(.idle) => .idle,
        statusByte(.active) => .active,
        statusByte(.stopped) => .stopped,
        else => null,
    };
}

pub fn statusIdle() callconv(.c) u8 {
    return statusByte(.idle);
}

pub fn statusActive() callconv(.c) u8 {
    return statusByte(.active);
}

pub fn statusStopped() callconv(.c) u8 {
    return statusByte(.stopped);
}

pub fn statusIsValid(status: u8) callconv(.c) c_int {
    return boolInt(statusFromByte(status) != null);
}

pub fn statusIsActive(status: u8) callconv(.c) c_int {
    const typed = statusFromByte(status) orelse return 0;
    return boolInt(typed == .active);
}

pub fn controlSignalHangup() callconv(.c) u8 {
    return pty.ControlSignal.hangup.raw();
}

pub fn controlSignalInterrupt() callconv(.c) u8 {
    return pty.ControlSignal.interrupt.raw();
}

pub fn controlSignalResizeNotify() callconv(.c) u8 {
    return pty.ControlSignal.resize_notify.raw();
}

pub fn controlSignalKill() callconv(.c) u8 {
    return pty.ControlSignal.kill.raw();
}

pub fn controlSignalTerminate() callconv(.c) u8 {
    return pty.ControlSignal.terminate.raw();
}

pub fn controlSignalIsValid(signal: u8) callconv(.c) c_int {
    _ = pty.ControlSignal.fromRaw(signal) catch return 0;
    return 1;
}
