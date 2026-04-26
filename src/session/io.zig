//! Responsibility: implement session input/output and queue operations.
//! Ownership: feed, apply, feedProcessOutput, reset behavior.
//! Reason: isolate I/O and queue semantics from other behaviors.

const std = @import("std");
const core = @import("core.zig");
const Session = core.Session;

/// Queue outbound input bytes for apply.
pub fn feed(self: *Session, bytes: []const u8) error{ OutOfMemory, QueueFull }!void {
    const projected_len = std.math.add(usize, self.pending.items.len, bytes.len) catch {
        self.ops.feed_rejected += 1;
        return error.QueueFull;
    };
    if (projected_len > self.pending_capacity) {
        self.ops.feed_rejected += 1;
        return error.QueueFull;
    }
    try self.pending.appendSlice(self.allocator, bytes);
    self.ops.feed_accepted += 1;
    self.ops.bytes_fed += bytes.len;
}

/// Drain queued outbound bytes.
pub fn apply(self: *Session) usize {
    self.ops.apply_calls += 1;
    const n = self.pending.items.len;
    var drained: usize = 0;

    if (n > 0) {
        if (self.transport) |t| {
            const written = t.write(self.pending.items) catch {
                self.ops.apply_transport_write_errors += 1;
                return 0;
            };
            drained = written;
            if (written < n) {
                std.mem.copyForwards(u8, self.pending.items[0 .. n - written], self.pending.items[written..n]);
                self.pending.shrinkRetainingCapacity(n - written);
            } else {
                self.pending.clearRetainingCapacity();
            }
        } else {
            self.engine.feedSlice(self.pending.items);
            self.engine.apply();
            drained = n;
            self.pending.clearRetainingCapacity();
        }
    }

    self.ops.bytes_applied += drained;
    return drained;
}

/// Feed inbound process output bytes into VT core.
pub fn feedProcessOutput(self: *Session, bytes: []const u8) anyerror!void {
    self.engine.feedSlice(bytes);
    self.engine.apply();
}

/// Clear outbound pending queue.
pub fn reset(self: *Session) void {
    self.ops.reset_calls += 1;
    self.pending.clearRetainingCapacity();
}
