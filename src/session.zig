//! Responsibility: session queue/lifecycle boundary.
//! Ownership: pending input queue, pty lifecycle, resize tracking.
//! Reason: keep session focused on I/O orchestration only.

const std = @import("std");
const pty_api = @import("pty.zig");

pub const PtyClass = pty_api.PtyClass;
pub const Pty = pty_api.Pty;

/// Session initialization config.
pub const Config = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pending_capacity: usize,
    pty: ?Pty = null,
};
/// Session lifecycle status.
pub const Status = enum {
    idle,
    active,
    stopped,
};
/// Serializable session snapshot.
pub const Snapshot = struct {
    cols: u16,
    rows: u16,
    status: Status,
    resize_count: u32,
};

/// Operation counters for conformance/testing.
pub const Ops = struct {
    start_attempts: u32,
    start_successes: u32,
    start_failures: u32,
    stop_calls: u32,
    feed_accepted: u32,
    feed_rejected: u32,
    bytes_fed: u64,
    bytes_applied: u64,
    apply_calls: u32,
    apply_transport_write_errors: u32,
    reset_calls: u32,
    resize_valid_calls: u32,
    resize_invalid_calls: u32,
    resize_transport_errors: u32,
};

/// Session queue/lifecycle orchestrator.
pub const Session = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    status: Status,
    pending: std.ArrayListUnmanaged(u8),
    pending_capacity: usize,
    pty: ?Pty,
    resize_count: u32,
    ops: Ops,

    /// Initialize session state.
    pub fn init(config: Config) !Session {
        if (config.cols == 0 or config.rows == 0) return error.InvalidConfig;
        if (config.pending_capacity == 0) return error.InvalidConfig;
        return .{
            .allocator = config.allocator,
            .cols = config.cols,
            .rows = config.rows,
            .status = .idle,
            .pending = .empty,
            .pending_capacity = config.pending_capacity,
            .pty = config.pty,
            .resize_count = 0,
            .ops = std.mem.zeroes(Ops),
        };
    }

    /// Release queue memory.
    pub fn deinit(self: *Session) void {
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    /// Start the transport if configured.
    pub fn start(self: *Session) !void {
        self.ops.start_attempts += 1;
        if (self.status == .active) return error.AlreadyStarted;
        if (self.pty) |t| t.start() catch |err| {
            self.ops.start_failures += 1;
            return err;
        };
        self.status = .active;
        self.ops.start_successes += 1;
    }

    /// Stop the transport and mark session stopped.
    pub fn stop(self: *Session) void {
        self.ops.stop_calls += 1;
        if (self.status == .active) {
            if (self.pty) |t| t.stop();
        }
        self.status = .stopped;
    }

    /// Queue bytes for later apply/write.
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

    /// Apply queued bytes to transport and return bytes drained.
    pub fn apply(self: *Session) usize {
        self.ops.apply_calls += 1;
        const n = self.pending.items.len;
        var drained: usize = 0;

        if (n > 0) {
            if (self.pty) |t| {
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
                drained = n;
                self.pending.clearRetainingCapacity();
            }
        }

        self.ops.bytes_applied += drained;
        return drained;
    }

    /// Clear pending queue state.
    pub fn reset(self: *Session) void {
        self.ops.reset_calls += 1;
        self.pending.clearRetainingCapacity();
    }

    /// Update tracked dimensions and propagate to transport.
    pub fn resize(self: *Session, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) {
            self.ops.resize_invalid_calls += 1;
            return error.InvalidDimensions;
        }

        self.cols = cols;
        self.rows = rows;
        self.resize_count +%= 1;
        self.ops.resize_valid_calls += 1;

        if (self.pty) |t| t.resize(cols, rows) catch |err| {
            self.ops.resize_transport_errors += 1;
            return err;
        };
    }

    /// Capture current session snapshot.
    pub fn snapshot(self: *const Session) Snapshot {
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .status = self.status,
            .resize_count = self.resize_count,
        };
    }

    /// Restore session from validated snapshot.
    pub fn restore(self: *Session, snap: Snapshot) error{InvalidSnapshot}!void {
        if (snap.cols == 0 or snap.rows == 0) return error.InvalidSnapshot;
        self.cols = snap.cols;
        self.rows = snap.rows;
        self.status = if (snap.status == .active) .stopped else snap.status;
        self.resize_count = snap.resize_count;
        self.pending.clearRetainingCapacity();
    }
};
