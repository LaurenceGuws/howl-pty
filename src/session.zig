//! Responsibility: session queue/lifecycle boundary.
//! Ownership: pending input queue, owned pty lifecycle, outbound pump policy, resize tracking.
//! Reason: keep session focused on I/O orchestration only.

const std = @import("std");
const pty_api = @import("pty.zig");

/// Canonical session owner surface.
pub const PtyClass = pty_api.PtyClass;
pub const Pty = pty_api.Pty;
pub const OwnedTransport = pty_api.OwnedPty;
pub const LaunchConfig = pty_api.LaunchConfig;
pub const ControlSignal = pty_api.ControlSignal;

const TransportReadLimit = u32;
const TransportByteLimit = u32;
/// Session initialization config.
pub const Config = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pending_capacity: usize,
    pty: ?Pty = null,
};

/// Session config for an already-created owned transport.
pub const OwnedTransportConfig = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pending_capacity: usize,
    transport: OwnedTransport,
};

/// Session config for a build-selected PTY launch.
pub const PtyConfig = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pending_capacity: usize,
    launch: LaunchConfig = .{},
};
/// Session lifecycle status.
pub const Status = enum(u8) {
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

/// Bounds for one nonblocking transport pump pass.
pub const TransportPumpLimits = struct {
    max_reads: TransportReadLimit,
    max_bytes: TransportByteLimit,
};

/// Named transport pump budget selected by the runtime owner.
pub const TransportPumpMode = enum {
    normal,
    constrained,
};

/// Result of one transport pump pass.
pub const TransportPumpResult = struct {
    any_read: bool = false,
    reads: TransportReadLimit = 0,
    bytes_read: TransportByteLimit = 0,
};

/// Result of one outbound input pump pass.
pub const OutboundInputPump = struct {
    had_pending: bool = false,
    drained: usize = 0,
    has_pending: bool = false,
    wait_readable: bool = false,
};

const normal_transport_reads: TransportReadLimit = 16;
const normal_transport_bytes: TransportByteLimit = 1024 * 1024;
const constrained_transport_reads: TransportReadLimit = 2;
const constrained_transport_bytes: TransportByteLimit = 128 * 1024;

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
    owned_transport: ?OwnedTransport,
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
            .owned_transport = null,
            .resize_count = 0,
            .ops = std.mem.zeroes(Ops),
        };
    }

    /// Initialize a session that owns the supplied transport.
    pub fn initOwnedTransport(config: OwnedTransportConfig) !Session {
        var transport = config.transport;
        errdefer transport.deinit();
        var session = try Session.init(.{
            .allocator = config.allocator,
            .cols = config.cols,
            .rows = config.rows,
            .pending_capacity = config.pending_capacity,
        });
        session.owned_transport = transport;
        return session;
    }

    /// Initialize a session that owns a build-selected PTY transport.
    pub fn initPty(config: PtyConfig) !Session {
        const transport = try pty_api.initPty(config.allocator, config.launch);
        return try Session.initOwnedTransport(.{
            .allocator = config.allocator,
            .cols = config.cols,
            .rows = config.rows,
            .pending_capacity = config.pending_capacity,
            .transport = transport,
        });
    }

    /// Release queue and owned transport memory.
    pub fn deinit(self: *Session) void {
        if (self.status == .active) self.stop();
        self.pending.deinit(self.allocator);
        if (self.owned_transport) |*transport| transport.deinit();
        self.* = undefined;
    }

    /// Start the transport if configured.
    pub fn start(self: *Session) !void {
        self.ops.start_attempts += 1;
        if (self.status == .active) return error.AlreadyStarted;
        self.bindOwnedTransport();
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
        if (self.owned_transport) |*transport| transport.deinit();
        self.owned_transport = null;
        self.pty = pty;
    }

    /// Detach the current transport while inactive.
    pub fn detachPty(self: *Session) error{SessionActive}!void {
        if (self.status == .active) return error.SessionActive;
        if (self.owned_transport) |*transport| transport.deinit();
        self.owned_transport = null;
        self.pty = null;
    }

    /// Stop the transport and mark session stopped.
    pub fn stop(self: *Session) void {
        self.ops.stop_calls += 1;
        if (self.status == .active) {
            if (self.pty) |t| t.stop();
        }
        if (self.owned_transport != null) self.pty = null;
        self.status = .stopped;
    }

    /// Report whether session transport lifecycle is active.
    pub fn isActive(self: *const Session) bool {
        return self.status == .active;
    }

    fn bindOwnedTransport(self: *Session) void {
        if (self.pty != null) return;
        if (self.owned_transport) |*transport| self.pty = transport.pty();
    }

    /// Publish host input bytes into the pending outbound queue.
    pub fn publishHostInput(self: *Session, bytes: []const u8) error{ OutOfMemory, QueueFull }!void {
        if (bytes.len == 0) return;
        std.debug.assert(self.pending.items.len <= self.pending_capacity);
        const projected_len = std.math.add(usize, self.pending.items.len, bytes.len) catch {
            self.ops.feed_rejected += 1;
            return error.QueueFull;
        };
        if (projected_len > self.pending_capacity) {
            self.ops.feed_rejected += 1;
            return error.QueueFull;
        }
        try self.pending.appendSlice(self.allocator, bytes);
        std.debug.assert(self.pending.items.len == projected_len);
        std.debug.assert(self.pending.items.len <= self.pending_capacity);
        self.ops.feed_accepted += 1;
        self.ops.bytes_fed += bytes.len;
    }

    /// Flush queued outbound input bytes to transport and return drained count.
    /// This call is non-throwing: transport write failures are reflected in `ops`.
    pub fn flushOutboundInput(self: *Session) usize {
        self.ops.apply_calls += 1;
        const drained = flushOutboundPhase(self);
        self.ops.bytes_applied += drained;
        return drained;
    }

    /// Flush queued outbound input and report runtime wait/backlog policy.
    pub fn pumpOutboundInput(self: *Session, woke: bool) OutboundInputPump {
        const had_pending = self.hasPendingOutboundInput();
        const drained = self.flushOutboundInput();
        const has_pending = self.hasPendingOutboundInput();
        return .{
            .had_pending = had_pending,
            .drained = drained,
            .has_pending = has_pending,
            .wait_readable = !woke and !had_pending and !has_pending,
        };
    }

    /// Queue host input, immediately pump it toward the transport, and report backlog.
    pub fn publishHostInputAndPump(self: *Session, bytes: []const u8) error{ OutOfMemory, QueueFull }!OutboundInputPump {
        try self.publishHostInput(bytes);
        const outbound = self.pumpOutboundInput(true);
        if (outbound.has_pending) self.kickTransportWait();
        return outbound;
    }

    /// Report whether host input still waits for transport write capacity.
    pub fn hasPendingOutboundInput(self: *const Session) bool {
        return self.pending.items.len > 0;
    }

    /// Report whether outbound input still needs another transport pump pass.
    pub fn hasOutboundInputBacklog(self: *const Session) bool {
        return self.hasPendingOutboundInput();
    }

    pub fn kickTransportWait(self: *Session) void {
        if (self.pty) |t| t.kickWait();
    }

    /// Wait for transport readability.
    pub fn waitReadable(self: *Session, timeout_ms: i32) bool {
        const t = self.pty orelse return false;
        return t.waitReadable(timeout_ms) catch |err| handleWaitError(self, err);
    }

    /// Block for readability only when the preceding outbound pump was idle.
    pub fn waitReadableAfterOutbound(self: *Session, outbound: OutboundInputPump, timeout_ms: i32) bool {
        if (!outbound.wait_readable) return true;
        return self.waitReadable(timeout_ms);
    }

    /// Read transport bytes into caller buffer.
    pub fn readTransport(self: *Session, buf: []u8) usize {
        if (buf.len == 0) return 0;
        const t = self.pty orelse return 0;
        const n = t.read(buf) catch |err| return handleReadError(self, err);
        std.debug.assert(n <= buf.len);
        return n;
    }

    /// Read one transport chunk and deliver it to sink.
    pub fn ingestTransport(self: *Session, scratch: []u8, sink: anytype) usize {
        const n = self.readTransport(scratch);
        if (n == 0) return 0;
        sink.onTransportBytes(scratch[0..n]);
        return n;
    }

    /// Pump bounded transport reads into the caller-owned sink.
    pub fn pumpTransport(self: *Session, scratch: []u8, sink: anytype, limits: TransportPumpLimits) TransportPumpResult {
        var result = TransportPumpResult{};
        if (scratch.len == 0 or limits.max_reads == 0 or limits.max_bytes == 0) return result;
        while (result.reads < limits.max_reads and result.bytes_read < limits.max_bytes) {
            const remaining = limits.max_bytes - result.bytes_read;
            const read_buf = scratch[0..@min(scratch.len, remaining)];
            const n = self.ingestTransport(read_buf, sink);
            if (n == 0) break;
            std.debug.assert(n <= remaining);
            result.any_read = true;
            result.reads += 1;
            result.bytes_read += @intCast(n);
        }
        std.debug.assert(result.reads <= limits.max_reads);
        std.debug.assert(result.bytes_read <= limits.max_bytes);
        return result;
    }

    /// Pump transport reads using the session-owned runtime budget policy.
    pub fn pumpTransportMode(self: *Session, scratch: []u8, sink: anytype, mode: TransportPumpMode) TransportPumpResult {
        return self.pumpTransport(scratch, sink, transportPumpLimits(mode));
    }

    fn transportPumpLimits(mode: TransportPumpMode) TransportPumpLimits {
        return switch (mode) {
            .normal => .{ .max_reads = normal_transport_reads, .max_bytes = normal_transport_bytes },
            .constrained => .{ .max_reads = constrained_transport_reads, .max_bytes = constrained_transport_bytes },
        };
    }

    fn flushOutboundPhase(self: *Session) usize {
        std.debug.assert(self.pending.items.len <= self.pending_capacity);
        const pending_len = self.pending.items.len;
        if (pending_len == 0) return 0;
        if (self.pty) |t| return flushOutboundToTransport(self, t, pending_len);
        self.pending.clearRetainingCapacity();
        return pending_len;
    }

    fn flushOutboundToTransport(self: *Session, t: Pty, pending_len: usize) usize {
        std.debug.assert(pending_len > 0);
        const written = t.write(self.pending.items) catch |err| return handleWriteError(self, err);
        std.debug.assert(written <= pending_len);
        trimPendingPrefix(self, written, pending_len);
        return written;
    }

    fn trimPendingPrefix(self: *Session, drained: usize, pending_len: usize) void {
        std.debug.assert(drained <= pending_len);
        if (drained == pending_len) {
            self.pending.clearRetainingCapacity();
            return;
        }
        if (drained == 0) return;
        std.mem.copyForwards(u8, self.pending.items[0 .. pending_len - drained], self.pending.items[drained..pending_len]);
        self.pending.shrinkRetainingCapacity(pending_len - drained);
        std.debug.assert(self.pending.items.len == pending_len - drained);
    }

    fn handleWriteError(self: *Session, err: anyerror) usize {
        return switch (err) {
            error.WouldBlock, error.Interrupted => 0,
            else => {
                self.ops.apply_transport_write_errors += 1;
                self.status = .stopped;
                return 0;
            },
        };
    }

    fn handleWaitError(self: *Session, err: anyerror) bool {
        return switch (err) {
            error.WouldBlock, error.Interrupted => false,
            else => {
                self.status = .stopped;
                return false;
            },
        };
    }

    fn handleReadError(self: *Session, err: anyerror) usize {
        return switch (err) {
            error.WouldBlock, error.Interrupted => 0,
            error.NotStarted => {
                self.status = .stopped;
                return 0;
            },
            else => {
                self.status = .stopped;
                return 0;
            },
        };
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
