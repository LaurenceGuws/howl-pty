const std = @import("std");
const ffi = @import("ffi");
const c = @import("howl_pty_c");

test "session ffi rejects invalid init arguments through null handle" {
    try std.testing.expectEqual(@as(ffi.SessionHandle, null), ffi.sessionInit(null, 1, null, 0, null, 0, 80, 24, 64));
    try std.testing.expectEqual(@as(ffi.SessionHandle, null), ffi.sessionInit(null, 0, null, 1, null, 0, 80, 24, 64));
    try std.testing.expectEqual(@as(ffi.SessionHandle, null), ffi.sessionInit(null, 0, null, 0, null, 1, 80, 24, 64));
    try std.testing.expectEqual(@as(ffi.SessionHandle, null), ffi.sessionInit(null, 0, null, 0, null, 0, 0, 24, 64));
    try std.testing.expectEqual(@as(ffi.SessionHandle, null), ffi.sessionInit(null, 0, null, 0, null, 0, 80, 0, 64));
    try std.testing.expectEqual(@as(ffi.SessionHandle, null), ffi.sessionInit(null, 0, null, 0, null, 0, 80, 24, 0));

    if (@bitSizeOf(usize) > @bitSizeOf(u32)) {
        try std.testing.expectEqual(@as(ffi.SessionHandle, null), ffi.sessionInit(null, 0, null, 0, null, 0, 80, 24, @as(usize, std.math.maxInt(u32)) + 1));
    }
}

test "session ffi handle path covers lifecycle and transport progress" {
    const handle = ffi.sessionInit(null, 0, null, 0, null, 0, 80, 24, 64);
    defer ffi.sessionDeinit(handle);
    try std.testing.expect(handle != null);
    try std.testing.expectEqual(@as(i32, 0), ffi.sessionStart(handle));
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_SESSION_ACTIVE), ffi.sessionSnapshot(handle).session_status);

    try std.testing.expectEqual(@as(i32, 0), ffi.sessionPublishInput(handle, "echo hi\n".ptr, "echo hi\n".len));
    const pumped = ffi.sessionPumpOutbound(handle, 0);
    try std.testing.expectEqual(@as(i32, 0), pumped.status);

    const snap = ffi.sessionSnapshot(handle);
    try std.testing.expectEqual(@as(i32, 0), snap.status);
    try std.testing.expectEqual(@as(u16, 80), snap.cols);
    try std.testing.expectEqual(@as(u16, 24), snap.rows);
    try std.testing.expectEqual(@as(u8, 0), snap.terminal_reason);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_WAIT_OUTCOME_NONE), snap.last_wait_outcome);
}

test "session ffi rejects invalid control signals through the shipped abi" {
    const handle = ffi.sessionInit(null, 0, null, 0, null, 0, 80, 24, 64);
    defer ffi.sessionDeinit(handle);
    try std.testing.expect(handle != null);

    try std.testing.expectEqual(@as(i32, 0), ffi.sessionPublishSignal(handle, c.HOWL_PTY_CONTROL_SIGNAL_INTERRUPT));
    try std.testing.expectEqual(
        c.HOWL_PTY_CALL_INVALID_ARGUMENT,
        ffi.sessionPublishSignal(handle, 0),
    );
}

test "transport pump limits ffi exposes shipped PTY burst policy" {
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

    const invalid = ffi.transportPumpLimits(99);
    try std.testing.expectEqual(c.HOWL_PTY_CALL_INVALID_ARGUMENT, invalid.status);
}

test "session ffi exports the shipped PTY wait wake seam" {
    const handle = ffi.sessionInit(null, 0, null, 0, null, 0, 80, 24, 64);
    defer ffi.sessionDeinit(handle);
    try std.testing.expect(handle != null);

    ffi.sessionKickWait(handle);
    try std.testing.expectEqual(@as(u8, 0), ffi.sessionWaitReadable(handle, 0));
}

test "session ffi snapshot exports terminal reason and wait outcome truth" {
    const handle = ffi.sessionInit(null, 0, null, 0, null, 0, 80, 24, 64);
    defer ffi.sessionDeinit(handle);
    try std.testing.expect(handle != null);
    try std.testing.expectEqual(@as(i32, 0), ffi.sessionStart(handle));
    ffi.sessionStop(handle);
    try std.testing.expectEqual(@as(u8, 0), ffi.sessionWaitReadable(handle, 0));

    const snap = ffi.sessionSnapshot(handle);
    try std.testing.expectEqual(@as(i32, 0), snap.status);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_SESSION_STOPPED), snap.session_status);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_TERMINAL_REASON_EXPLICIT_STOP), snap.terminal_reason);
    try std.testing.expectEqual(@as(u8, c.HOWL_PTY_WAIT_OUTCOME_STOPPED), snap.last_wait_outcome);
}
