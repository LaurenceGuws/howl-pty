//! Responsibility: implement session initialization, deinitialization, and lifecycle transitions.
//! Ownership: init, deinit, start, stop methods and semantics.
//! Reason: isolate resource lifecycle and state activation from other operations.

const core = @import("core.zig");
const Session = core.Session;

/// Activate session lifecycle and mount transport if present.
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

/// Release all session-owned resources and invalidate.
pub fn deinit(self: *Session) void {
    self.pending.deinit(self.allocator);
    self.engine.deinit();
    self.* = undefined;
}

/// Stop session lifecycle.
pub fn stop(self: *Session) void {
    self.ops.stop_calls += 1;
    if (self.status == .active) {
        if (self.transport) |t| t.stop();
    }
    self.status = .stopped;
}
