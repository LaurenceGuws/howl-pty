//! Responsibility: session queue/lifecycle boundary.
//! Ownership: pending input queue, pty lifecycle, resize tracking.
//! Reason: keep session focused on I/O orchestration only.

const std = @import("std");
const pty_api = @import("pty.zig");

/// Canonical session owner surface.
pub const PtyClass = pty_api.PtyClass;
pub const Pty = pty_api.Pty;
pub const ControlSignal = pty_api.ControlSignal;
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
            std.log.err("SES,event=startErr,error={s}", .{@errorName(err)});
            return err;
        };
        self.status = .active;
        self.ops.start_successes += 1;
    }

    /// Attach or replace the session transport while inactive.
    pub fn attachPty(self: *Session, pty: Pty) error{SessionActive}!void {
        if (self.status == .active) return error.SessionActive;
        self.pty = pty;
    }

    /// Detach the current transport while inactive.
    pub fn detachPty(self: *Session) error{SessionActive}!void {
        if (self.status == .active) return error.SessionActive;
        self.pty = null;
    }

    /// Stop the transport and mark session stopped.
    pub fn stop(self: *Session) void {
        self.ops.stop_calls += 1;
        if (self.status == .active) {
            if (self.pty) |t| t.stop();
        }
        self.status = .stopped;
    }

    /// Publish host input bytes into the pending outbound queue.
    pub fn publishHostInput(self: *Session, bytes: []const u8) error{ OutOfMemory, QueueFull }!void {
        if (bytes.len == 0) return;
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

    /// Flush queued outbound input bytes to transport and return drained count.
    /// This call is non-throwing: transport write failures are reflected in `ops`.
    pub fn flushOutboundInput(self: *Session) usize {
        self.ops.apply_calls += 1;
        const n = self.pending.items.len;
        var drained: usize = 0;

        if (n > 0) {
            if (self.pty) |t| {
                const written = t.write(self.pending.items) catch |err| switch (err) {
                    error.WouldBlock, error.Interrupted => 0,
                    else => {
                        self.ops.apply_transport_write_errors += 1;
                        self.status = .stopped;
                        return 0;
                    },
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

    /// Report whether host input still waits for transport write capacity.
    pub fn hasPendingOutboundInput(self: *const Session) bool {
        return self.pending.items.len > 0;
    }

    /// Wait for transport readability.
    pub fn waitReadable(self: *Session, timeout_ms: i32) bool {
        if (self.pty) |t| {
            return t.waitReadable(timeout_ms) catch |err| switch (err) {
                error.WouldBlock, error.Interrupted => false,
                else => {
                    self.status = .stopped;
                    return false;
                },
            };
        }
        return false;
    }

    /// Read transport bytes into caller buffer.
    pub fn readTransport(self: *Session, buf: []u8) usize {
        if (self.pty) |t| {
            return t.read(buf) catch |err| switch (err) {
                error.WouldBlock, error.Interrupted => 0,
                error.NotStarted => blk: {
                    self.status = .stopped;
                    break :blk 0;
                },
                else => blk: {
                    self.status = .stopped;
                    break :blk 0;
                },
            };
        }
        return 0;
    }

    /// Read one transport chunk and deliver it to sink.
    pub fn ingestTransport(self: *Session, scratch: []u8, sink: anytype) usize {
        const n = self.readTransport(scratch);
        if (n == 0) return 0;
        sink.onTransportBytes(scratch[0..n]);
        return n;
    }

    /// Send control signal to transport child process.
    pub fn publishControlSignal(self: *Session, signal: ControlSignal) error{TransportUnavailable}!void {
        const t = self.pty orelse return error.TransportUnavailable;
        t.control(signal);
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

        if (self.pty) |t| t.resize(cols, rows) catch {
            self.ops.resize_transport_errors += 1;
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
    /// An `active` snapshot is intentionally normalized to `stopped`.
    pub fn restore(self: *Session, snap: Snapshot) error{InvalidSnapshot}!void {
        if (snap.cols == 0 or snap.rows == 0) return error.InvalidSnapshot;
        self.cols = snap.cols;
        self.rows = snap.rows;
        self.status = if (snap.status == .active) .stopped else snap.status;
        self.resize_count = snap.resize_count;
        self.pending.clearRetainingCapacity();
    }
};
