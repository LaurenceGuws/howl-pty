//! Defines exact native PTY failures, outcomes, signals, and the owned Unix implementation.

const std = @import("std");

/// Reports lifecycle or platform failure while starting a child.
pub const StartError = error{
    AlreadyStarted,
    OpenPtyFailed,
    ShellUnavailable,
    UnsupportedPlatform,
};

/// Reports a nonblocking transport write outcome.
pub const WriteError = error{
    Interrupted,
    NotStarted,
    WouldBlock,
    WriteFailed,
};

/// Reports a nonblocking transport read outcome.
pub const ReadError = error{
    EndOfStream,
    Interrupted,
    NotStarted,
    ReadFailed,
    WouldBlock,
};

/// Reports a transport wait outcome that could not be represented as a result.
pub const WaitReadableError = error{
    Interrupted,
    NotStarted,
    WaitFailed,
    WouldBlock,
};

/// Distinguishes readable transport, elapsed timeout, and explicit wake.
pub const WaitReadableResult = enum(u8) {
    ready,
    timeout,
    wake,
};

/// Reports resize before start or platform resize failure.
pub const ResizeError = error{
    NotStarted,
    ResizeFailed,
};

/// Names signals supported by native PTY child control.
pub const ControlSignal = enum(u8) {
    hangup = 1,
    interrupt = 2,
    resize_notify = 3,
    kill = 9,
    terminate = 15,

    /// Maps the control identity to its POSIX signal.
    pub fn posixSignal(self: ControlSignal) std.posix.SIG {
        return switch (self) {
            .hangup => .HUP,
            .interrupt => .INT,
            .resize_notify => .WINCH,
            .kill => .KILL,
            .terminate => .TERM,
        };
    }
};

/// Owns one platform PTY, child process group, descriptors, and copied launch strings.
pub const Owned = @import("unix.zig").Pty;

test "control signals map to exact POSIX signals" {
    try std.testing.expectEqual(std.posix.SIG.HUP, ControlSignal.hangup.posixSignal());
    try std.testing.expectEqual(std.posix.SIG.INT, ControlSignal.interrupt.posixSignal());
    try std.testing.expectEqual(std.posix.SIG.WINCH, ControlSignal.resize_notify.posixSignal());
    try std.testing.expectEqual(std.posix.SIG.KILL, ControlSignal.kill.posixSignal());
    try std.testing.expectEqual(std.posix.SIG.TERM, ControlSignal.terminate.posixSignal());
}
