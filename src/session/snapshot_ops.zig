//! Responsibility: implement session snapshot and restore operations.
//! Ownership: snapshot capture and state restoration.
//! Reason: isolate snapshot semantics from active session behavior.

const core = @import("core.zig");
const Session = core.Session;
const SessionSnapshot = core.SessionSnapshot;

/// Capture snapshot payload.
pub fn snapshot(self: *const Session) SessionSnapshot {
    return .{
        .cols = self.cols,
        .rows = self.rows,
        .status = self.status,
        .resize_count = self.resize_count,
        .last_control_signal = self.last_control_signal,
    };
}

/// Restore snapshot payload fields.
pub fn restore(self: *Session, snap: SessionSnapshot) error{InvalidSnapshot}!void {
    if (snap.cols == 0 or snap.rows == 0) return error.InvalidSnapshot;
    self.cols = snap.cols;
    self.rows = snap.rows;
    self.status = if (snap.status == .active) .stopped else snap.status;
    self.resize_count = snap.resize_count;
    self.last_control_signal = snap.last_control_signal;
    self.pending.clearRetainingCapacity();
}
