//! Responsibility: define the howl-pty ABI export root.
//! Ownership: export `howl_pty_*` symbols only.
//! Reason: keep the shipped boundary on the C ABI instead of a Zig root.

const ffi = @import("ffi.zig");

comptime {
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
