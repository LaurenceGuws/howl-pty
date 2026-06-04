const ffi = @import("ffi.zig");

comptime {
    @export(&ffi.sessionInit, .{ .name = "howl_pty_session_init" });
    @export(&ffi.sessionDeinit, .{ .name = "howl_pty_session_deinit" });
    @export(&ffi.sessionStart, .{ .name = "howl_pty_session_start" });
    @export(&ffi.sessionStop, .{ .name = "howl_pty_session_stop" });
    @export(&ffi.sessionResize, .{ .name = "howl_pty_session_resize" });
    @export(&ffi.sessionPublishSignal, .{ .name = "howl_pty_session_publish_signal" });
    @export(&ffi.sessionPublishInput, .{ .name = "howl_pty_session_publish_input" });
    @export(&ffi.sessionPumpOutbound, .{ .name = "howl_pty_session_pump_outbound" });
    @export(&ffi.sessionKickWait, .{ .name = "howl_pty_session_kick_wait" });
    @export(&ffi.sessionSnapshot, .{ .name = "howl_pty_session_snapshot" });
    @export(&ffi.sessionPendingBytes, .{ .name = "howl_pty_session_pending_bytes" });
    @export(&ffi.sessionBytesApplied, .{ .name = "howl_pty_session_bytes_applied" });
    @export(&ffi.sessionWaitReadable, .{ .name = "howl_pty_session_wait_readable" });
    @export(&ffi.sessionRead, .{ .name = "howl_pty_session_read" });
    @export(&ffi.transportPumpLimits, .{ .name = "howl_pty_transport_pump_limits" });
}
