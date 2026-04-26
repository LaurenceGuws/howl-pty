//! Responsibility: implement session lifecycle state transitions.
//! Ownership: lifecycle semantics (init, deinit, start, stop).
//! Reason: isolate initialization and lifecycle control from behavior.

const core = @import("core.zig");
const Session = core.Session;

/// Start session lifecycle and transport if attached.
pub fn start(self: *Session) anyerror!void {
    self.ops.start_attempts += 1;
    if (self.status == .active) return error.AlreadyStarted;
    if (self.transport) |t| t.start() catch |err| {
        self.ops.start_failures += 1;
        return err;
    };
    self.status = .active;
    self.ops.start_successes += 1;
}

/// Stop session lifecycle.
pub fn stop(self: *Session) void {
    self.ops.stop_calls += 1;
    if (self.status == .active) {
        if (self.transport) |t| t.stop();
    }
    self.status = .stopped;
}
