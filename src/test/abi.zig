const std = @import("std");
const ffi = @import("ffi");
pub const c = @import("howl_pty_c");

test {
    _ = @import("ffi.zig");
}

comptime {
    std.debug.assert(c.HOWL_PTY_SESSION_IDLE == 0);
    std.debug.assert(c.HOWL_PTY_SESSION_ACTIVE == 1);
    std.debug.assert(c.HOWL_PTY_SESSION_STOPPED == 2);

    std.debug.assert(c.HOWL_PTY_TERMINAL_REASON_NONE == 0);
    std.debug.assert(c.HOWL_PTY_TERMINAL_REASON_EXPLICIT_STOP == 1);
    std.debug.assert(c.HOWL_PTY_TERMINAL_REASON_CHILD_EXIT == 2);
    std.debug.assert(c.HOWL_PTY_TERMINAL_REASON_TRANSPORT_EOF == 3);
    std.debug.assert(c.HOWL_PTY_TERMINAL_REASON_TRANSPORT_FAILURE == 4);

    std.debug.assert(c.HOWL_PTY_WAIT_OUTCOME_NONE == 0);
    std.debug.assert(c.HOWL_PTY_WAIT_OUTCOME_READY == 1);
    std.debug.assert(c.HOWL_PTY_WAIT_OUTCOME_TIMEOUT == 2);
    std.debug.assert(c.HOWL_PTY_WAIT_OUTCOME_WAKE == 3);
    std.debug.assert(c.HOWL_PTY_WAIT_OUTCOME_STOPPED == 4);

    std.debug.assert(c.HOWL_PTY_CONTROL_SIGNAL_HANGUP == 1);
    std.debug.assert(c.HOWL_PTY_CONTROL_SIGNAL_INTERRUPT == 2);
    std.debug.assert(c.HOWL_PTY_CONTROL_SIGNAL_RESIZE_NOTIFY == 3);
    std.debug.assert(c.HOWL_PTY_CONTROL_SIGNAL_KILL == 9);
    std.debug.assert(c.HOWL_PTY_CONTROL_SIGNAL_TERMINATE == 15);

    std.debug.assert(c.HOWL_PTY_TRANSPORT_PUMP_NORMAL == 0);
    std.debug.assert(c.HOWL_PTY_TRANSPORT_PUMP_CONSTRAINED == 1);
    std.debug.assert(c.HOWL_PTY_TRANSPORT_CHUNK_BYTES == 64 * 1024);
}

test "pty abi null handles report missing-handle contract" {
    try std.testing.expectEqual(c.HOWL_PTY_CALL_MISSING_HANDLE, ffi.sessionStart(null));
    try std.testing.expectEqual(c.HOWL_PTY_CALL_MISSING_HANDLE, ffi.sessionResize(null, 80, 24));
    try std.testing.expectEqual(c.HOWL_PTY_CALL_MISSING_HANDLE, ffi.sessionPublishSignal(null, c.HOWL_PTY_CONTROL_SIGNAL_INTERRUPT));
    try std.testing.expectEqual(c.HOWL_PTY_CALL_MISSING_HANDLE, ffi.sessionPublishInput(null, null, 0));
    try std.testing.expectEqual(@as(u64, 0), ffi.sessionPendingBytes(null));
    try std.testing.expectEqual(@as(u64, 0), ffi.sessionBytesApplied(null));
    try std.testing.expectEqual(@as(u8, 0), ffi.sessionWaitReadable(null, 0));

    const snapshot = ffi.sessionSnapshot(null);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_MISSING_HANDLE, snapshot.status);

    const pump = ffi.sessionPumpOutbound(null, 0);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_MISSING_HANDLE, pump.status);

    const read = ffi.sessionRead(null, null, 0);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_MISSING_HANDLE, read.status);
}

test "pty abi invalid arguments report invalid-argument contract" {
    const handle = ffi.sessionInit(null, 0, null, 0, null, 0, 80, 24, 64);
    defer ffi.sessionDeinit(handle);
    try std.testing.expect(handle != null);

    try std.testing.expectEqual(c.HOWL_PTY_CALL_INVALID_ARGUMENT, ffi.sessionPublishSignal(handle, 0));

    const read = ffi.sessionRead(handle, null, 1);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_INVALID_ARGUMENT, read.status);

    const limits = ffi.transportPumpLimits(99);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_INVALID_ARGUMENT, limits.status);
}

test "pty abi exports transport burst policy through shipped contract" {
    const normal = ffi.transportPumpLimits(c.HOWL_PTY_TRANSPORT_PUMP_NORMAL);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_OK, normal.status);
    try std.testing.expectEqual(@as(u32, c.HOWL_PTY_TRANSPORT_CHUNK_BYTES), normal.chunk_bytes);
    try std.testing.expectEqual(@as(u32, 16), normal.max_reads);
    try std.testing.expectEqual(@as(u32, 1024 * 1024), normal.max_bytes);

    const constrained = ffi.transportPumpLimits(c.HOWL_PTY_TRANSPORT_PUMP_CONSTRAINED);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_OK, constrained.status);
    try std.testing.expectEqual(@as(u32, c.HOWL_PTY_TRANSPORT_CHUNK_BYTES), constrained.chunk_bytes);
    try std.testing.expectEqual(@as(u32, 2), constrained.max_reads);
    try std.testing.expectEqual(@as(u32, 128 * 1024), constrained.max_bytes);
}

test "pty abi lifecycle reports shipped snapshot contract" {
    const handle = ffi.sessionInit(null, 0, null, 0, null, 0, 132, 43, 64);
    defer ffi.sessionDeinit(handle);
    try std.testing.expect(handle != null);

    const before = ffi.sessionSnapshot(handle);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_OK, before.status);
    try std.testing.expectEqual(@as(u16, 132), before.cols);
    try std.testing.expectEqual(@as(u16, 43), before.rows);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_SESSION_IDLE), before.session_status);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_TERMINAL_REASON_NONE), before.terminal_reason);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_WAIT_OUTCOME_NONE), before.last_wait_outcome);

    try std.testing.expectEqual(c.HOWL_PTY_CALL_OK, ffi.sessionStart(handle));
    const after = ffi.sessionSnapshot(handle);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_OK, after.status);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_SESSION_ACTIVE), after.session_status);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_TERMINAL_REASON_NONE), after.terminal_reason);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_WAIT_OUTCOME_NONE), after.last_wait_outcome);
}
