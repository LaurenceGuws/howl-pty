//! Responsibility: implement the howl-session native ABI constants surface.
//! Ownership: session status and control-signal ABI contracts.
//! Reason: keep C consumers on typed session-owned values without exposing PTY internals.

const pty = @import("pty.zig");
const session = @import("session.zig");

fn boolByte(value: bool) u8 {
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

pub fn statusIsValid(status: u8) callconv(.c) u8 {
    return boolByte(statusFromByte(status) != null);
}

pub fn statusIsActive(status: u8) callconv(.c) u8 {
    const typed = statusFromByte(status) orelse return 0;
    return boolByte(typed == .active);
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

pub fn controlSignalIsValid(signal: u8) callconv(.c) u8 {
    _ = pty.ControlSignal.fromRaw(signal) catch return 0;
    return 1;
}

test "session ffi status surface proves positive and negative space" {
    try @import("std").testing.expectEqual(@as(u8, @intFromEnum(session.Status.idle)), statusIdle());
    try @import("std").testing.expectEqual(@as(u8, @intFromEnum(session.Status.active)), statusActive());
    try @import("std").testing.expectEqual(@as(u8, @intFromEnum(session.Status.stopped)), statusStopped());
    try @import("std").testing.expectEqual(@as(u8, 1), statusIsValid(statusIdle()));
    try @import("std").testing.expectEqual(@as(u8, 1), statusIsActive(statusActive()));
    try @import("std").testing.expectEqual(@as(u8, 0), statusIsActive(statusStopped()));
    try @import("std").testing.expectEqual(@as(u8, 0), statusIsValid(255));
}

test "session ffi control-signal surface proves positive and negative space" {
    try @import("std").testing.expectEqual(pty.ControlSignal.hangup.raw(), controlSignalHangup());
    try @import("std").testing.expectEqual(pty.ControlSignal.interrupt.raw(), controlSignalInterrupt());
    try @import("std").testing.expectEqual(pty.ControlSignal.resize_notify.raw(), controlSignalResizeNotify());
    try @import("std").testing.expectEqual(pty.ControlSignal.kill.raw(), controlSignalKill());
    try @import("std").testing.expectEqual(pty.ControlSignal.terminate.raw(), controlSignalTerminate());
    try @import("std").testing.expectEqual(@as(u8, 1), controlSignalIsValid(controlSignalTerminate()));
    try @import("std").testing.expectEqual(@as(u8, 0), controlSignalIsValid(0));
}
