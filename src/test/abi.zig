const std = @import("std");
const ffi = @import("ffi");
pub const c = @cImport({
    @cInclude("howl_pty.h");
});

test {
    _ = @import("ffi.zig");
}

comptime {
    std.debug.assert(@sizeOf(ffi.FfiSnapshot) == @sizeOf(c.HowlPtySnapshot));
    std.debug.assert(@sizeOf(ffi.FfiOutboundPump) == @sizeOf(c.HowlPtyOutboundPump));
    std.debug.assert(@sizeOf(ffi.FfiReadResult) == @sizeOf(c.HowlPtyReadResult));
    std.debug.assert(@sizeOf(ffi.FfiTransportPumpLimits) == @sizeOf(c.HowlPtyTransportPumpLimits));

    std.debug.assert(@alignOf(ffi.FfiSnapshot) == @alignOf(c.HowlPtySnapshot));
    std.debug.assert(@alignOf(ffi.FfiOutboundPump) == @alignOf(c.HowlPtyOutboundPump));
    std.debug.assert(@alignOf(ffi.FfiReadResult) == @alignOf(c.HowlPtyReadResult));
    std.debug.assert(@alignOf(ffi.FfiTransportPumpLimits) == @alignOf(c.HowlPtyTransportPumpLimits));

    std.debug.assert(@offsetOf(ffi.FfiSnapshot, "status") == @offsetOf(c.HowlPtySnapshot, "status"));
    std.debug.assert(@offsetOf(ffi.FfiSnapshot, "cols") == @offsetOf(c.HowlPtySnapshot, "cols"));
    std.debug.assert(@offsetOf(ffi.FfiSnapshot, "rows") == @offsetOf(c.HowlPtySnapshot, "rows"));
    std.debug.assert(@offsetOf(ffi.FfiSnapshot, "session_status") == @offsetOf(c.HowlPtySnapshot, "session_status"));
    std.debug.assert(@offsetOf(ffi.FfiSnapshot, "terminal_reason") == @offsetOf(c.HowlPtySnapshot, "terminal_reason"));
    std.debug.assert(@offsetOf(ffi.FfiSnapshot, "last_wait_outcome") == @offsetOf(c.HowlPtySnapshot, "last_wait_outcome"));
    std.debug.assert(@offsetOf(ffi.FfiSnapshot, "reserved0") == @offsetOf(c.HowlPtySnapshot, "reserved0"));
    std.debug.assert(@offsetOf(ffi.FfiSnapshot, "resize_count") == @offsetOf(c.HowlPtySnapshot, "resize_count"));

    std.debug.assert(@offsetOf(ffi.FfiOutboundPump, "status") == @offsetOf(c.HowlPtyOutboundPump, "status"));
    std.debug.assert(@offsetOf(ffi.FfiOutboundPump, "had_pending") == @offsetOf(c.HowlPtyOutboundPump, "had_pending"));
    std.debug.assert(@offsetOf(ffi.FfiOutboundPump, "has_pending") == @offsetOf(c.HowlPtyOutboundPump, "has_pending"));
    std.debug.assert(@offsetOf(ffi.FfiOutboundPump, "wait_readable") == @offsetOf(c.HowlPtyOutboundPump, "wait_readable"));
    std.debug.assert(@offsetOf(ffi.FfiOutboundPump, "reserved0") == @offsetOf(c.HowlPtyOutboundPump, "reserved0"));
    std.debug.assert(@offsetOf(ffi.FfiOutboundPump, "drained") == @offsetOf(c.HowlPtyOutboundPump, "drained"));

    std.debug.assert(@offsetOf(ffi.FfiReadResult, "status") == @offsetOf(c.HowlPtyReadResult, "status"));
    std.debug.assert(@offsetOf(ffi.FfiReadResult, "any_read") == @offsetOf(c.HowlPtyReadResult, "any_read"));
    std.debug.assert(@offsetOf(ffi.FfiReadResult, "reserved0") == @offsetOf(c.HowlPtyReadResult, "reserved0"));
    std.debug.assert(@offsetOf(ffi.FfiReadResult, "reserved1") == @offsetOf(c.HowlPtyReadResult, "reserved1"));
    std.debug.assert(@offsetOf(ffi.FfiReadResult, "reserved2") == @offsetOf(c.HowlPtyReadResult, "reserved2"));
    std.debug.assert(@offsetOf(ffi.FfiReadResult, "bytes_read") == @offsetOf(c.HowlPtyReadResult, "bytes_read"));

    std.debug.assert(@offsetOf(ffi.FfiTransportPumpLimits, "status") == @offsetOf(c.HowlPtyTransportPumpLimits, "status"));
    std.debug.assert(@offsetOf(ffi.FfiTransportPumpLimits, "chunk_bytes") == @offsetOf(c.HowlPtyTransportPumpLimits, "chunk_bytes"));
    std.debug.assert(@offsetOf(ffi.FfiTransportPumpLimits, "max_reads") == @offsetOf(c.HowlPtyTransportPumpLimits, "max_reads"));
    std.debug.assert(@offsetOf(ffi.FfiTransportPumpLimits, "max_bytes") == @offsetOf(c.HowlPtyTransportPumpLimits, "max_bytes"));

    std.debug.assert(@intFromEnum(ffi.HowlPtyCallStatus.ok) == c.HOWL_PTY_CALL_OK);
    std.debug.assert(@intFromEnum(ffi.HowlPtyCallStatus.missing_handle) == c.HOWL_PTY_CALL_MISSING_HANDLE);
    std.debug.assert(@intFromEnum(ffi.HowlPtyCallStatus.invalid_argument) == c.HOWL_PTY_CALL_INVALID_ARGUMENT);
    std.debug.assert(@intFromEnum(ffi.HowlPtyCallStatus.failed) == c.HOWL_PTY_CALL_FAILED);

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
