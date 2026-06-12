const std = @import("std");
const pty_api = @import("pty.zig");

/// Session owner internals depend on the abstract transport contract only.
const Pty = pty_api.Pty;
const ControlSignal = pty_api.ControlSignal;

pub const StartError = Pty.StartError;
pub const ReadError = Pty.ReadError;
pub const WaitReadableError = Pty.WaitReadableError;
pub const WaitReadableResult = pty_api.WaitReadableResult;

pub const TransportReadLimit = u32;
pub const TransportByteLimit = u32;
pub const TransportChunkBytes = u32;
/// Session initialization config.
pub const InitConfig = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pending_capacity: TransportByteLimit,
    pty: ?Pty = null,
    launch: ?pty_api.Launch = null,
};

/// Session lifecycle status.
pub const Status = enum(u8) {
    idle,
    active,
    stopped,
};

pub const TerminalReason = enum(u8) {
    explicit_stop = 1,
    child_exit = 2,
    transport_eof = 3,
    transport_failure = 4,
};

pub const WaitOutcome = enum(u8) {
    none = 0,
    ready = 1,
    timeout = 2,
    wake = 3,
    stopped = 4,
};
/// Serializable session snapshot.
pub const Snapshot = struct {
    cols: u16,
    rows: u16,
    status: Status,
    terminal_reason: ?TerminalReason,
    last_wait_outcome: WaitOutcome,
    resize_count: u32,
};

/// Bounds for one nonblocking transport pump pass.
pub const TransportPumpLimits = struct {
    chunk_bytes: TransportChunkBytes,
    max_reads: TransportReadLimit,
    max_bytes: TransportByteLimit,
};

/// Named transport pump budget selected by the runtime owner.
pub const TransportPumpMode = enum(u8) {
    normal = 0,
    constrained = 1,
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
    drained: TransportByteLimit = 0,
    has_pending: bool = false,
    wait_readable: bool = false,
};

// Alacritty caps one locked PTY read near 64 KiB. Keep that read chunk owned
// here so hosts can size scratch storage from the PTY contract instead of
// inventing a second local policy.
pub const transport_chunk_bytes: TransportChunkBytes = 64 * 1024;
// Alacritty stages PTY input through a 1 MiB read buffer before it forces a
// parser synchronization point. Keep the PTY owner's normal burst at the same
// byte scale so hosts can follow one explicit transport policy through the C
// ABI instead of inventing smaller local byte limits.
const normal_transport_bytes: TransportByteLimit = 1024 * 1024;
const normal_transport_reads: TransportReadLimit = 16;
// Constrained mode exists for proofs that need tighter interleaving while
// preserving the same Session-owned chunk shape: two 64 KiB reads, or 128 KiB
// total, before the owner thread must reschedule. This is a proof mode, not a
// new product throughput policy.
const constrained_transport_bytes: TransportByteLimit = 128 * 1024;
const constrained_transport_reads: TransportReadLimit = 2;

comptime {
    std.debug.assert(normal_transport_reads * transport_chunk_bytes == normal_transport_bytes);
    std.debug.assert(constrained_transport_reads * transport_chunk_bytes == constrained_transport_bytes);
}

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

const PendingQueue = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    head: TransportByteLimit,
    count: TransportByteLimit,

    fn init(allocator: std.mem.Allocator, capacity_bytes: TransportByteLimit) !PendingQueue {
        std.debug.assert(capacity_bytes > 0);
        const buffer = try allocator.alloc(u8, capacity_bytes);
        errdefer allocator.free(buffer);
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .head = 0,
            .count = 0,
        };
    }

    fn deinit(self: *PendingQueue) void {
        self.allocator.free(self.buffer);
    }

    fn clear(self: *PendingQueue) void {
        self.head = 0;
        self.count = 0;
    }

    fn pushSlice(self: *PendingQueue, bytes: []const u8) error{NoSpaceLeft}!void {
        std.debug.assert(self.count <= self.capacity());
        if (bytes.len > self.spareCapacity()) return error.NoSpaceLeft;
        if (bytes.len == 0) return;

        const tail = self.tailIndex();
        const first_len = @min(bytes.len, self.buffer.len - tail);
        const second_len = bytes.len - first_len;

        @memcpy(self.buffer[tail .. tail + first_len], bytes[0..first_len]);
        @memcpy(self.buffer[0..second_len], bytes[first_len..]);
        self.count += @intCast(bytes.len);
        std.debug.assert(self.count <= self.capacity());
    }

    fn headSliceConst(self: *const PendingQueue) []const u8 {
        std.debug.assert(self.count <= self.capacity());
        if (self.count == 0) return self.buffer[0..0];
        const first_len = @min(self.count, self.capacity() - self.head);
        return self.buffer[self.head .. self.head + first_len];
    }

    fn discardPrefix(self: *PendingQueue, drained: TransportByteLimit) void {
        std.debug.assert(drained <= self.count);
        if (drained == self.count) {
            self.clear();
            return;
        }
        if (drained == 0) return;
        self.head = @intCast((self.head + drained) % self.capacity());
        self.count -= drained;
        std.debug.assert(self.count <= self.capacity());
    }

    fn capacity(self: *const PendingQueue) TransportByteLimit {
        std.debug.assert(self.buffer.len <= std.math.maxInt(TransportByteLimit));
        return @intCast(self.buffer.len);
    }

    fn spareCapacity(self: *const PendingQueue) usize {
        return self.buffer.len - self.count;
    }

    fn tailIndex(self: *const PendingQueue) usize {
        std.debug.assert(self.count <= self.capacity());
        return (self.head + self.count) % self.capacity();
    }
};

const Transport = union(enum) {
    none,
    external: Pty,
    owned: pty_api.Owned,

    fn deinit(self: *Transport) void {
        switch (self.*) {
            .owned => |*owned| owned.deinit(),
            else => {},
        }
    }

    fn pty(self: *Transport) ?Pty {
        return switch (self.*) {
            .none => null,
            .external => |value| value,
            .owned => |*owned| owned.pty(),
        };
    }
};

/// Session queue/lifecycle orchestrator.
pub const Session = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    status: Status,
    pending: PendingQueue,
    pending_capacity: TransportByteLimit,
    transport: Transport,
    terminal_reason: ?TerminalReason,
    last_wait_outcome: WaitOutcome,
    resize_count: u32,
    ops: Ops,

    /// Initialize session state.
    pub fn init(config: InitConfig) !Session {
        if (config.cols == 0 or config.rows == 0) return error.InvalidConfig;
        if (config.pending_capacity == 0) return error.InvalidConfig;
        if (config.pty != null and config.launch != null) return error.InvalidConfig;
        var pending = try PendingQueue.init(config.allocator, config.pending_capacity);
        errdefer pending.deinit();
        var transport = try initTransport(config);
        errdefer transport.deinit();
        return .{
            .allocator = config.allocator,
            .cols = config.cols,
            .rows = config.rows,
            .status = .idle,
            .pending = pending,
            .pending_capacity = config.pending_capacity,
            .transport = transport,
            .terminal_reason = null,
            .last_wait_outcome = .none,
            .resize_count = 0,
            .ops = std.mem.zeroes(Ops),
        };
    }

    /// Release queue and owned transport memory.
    pub fn deinit(self: *Session) void {
        if (self.status == .active) self.stop();
        self.pending.deinit();
        self.transport.deinit();
        self.* = undefined;
    }

    /// Start the transport if configured.
    pub fn start(self: *Session) StartError!void {
        self.ops.start_attempts += 1;
        if (self.status != .idle) return error.AlreadyStarted;
        std.debug.assert(self.terminal_reason == null);
        if (self.transport.pty()) |transport| {
            // Session owns the current grid size at the lifecycle transition into
            // active transport state. Starting the transport must consume that size
            // directly instead of booting at a transport-local default.
            transport.start(self.cols, self.rows) catch |err| {
                self.ops.start_failures += 1;
                std.log.err("SES,event=startErr,error={s}", .{@errorName(err)});
                return err;
            };
        }
        self.status = .active;
        self.last_wait_outcome = .none;
        self.ops.start_successes += 1;
    }

    /// Stop the transport and mark session stopped.
    pub fn stop(self: *Session) void {
        self.ops.stop_calls += 1;
        transitionToStopped(self, .explicit_stop);
    }

    /// Report whether session transport lifecycle is active.
    pub fn isActive(self: *const Session) bool {
        return self.status == .active;
    }

    /// Publish host input bytes into the pending outbound queue.
    pub fn publishHostInput(self: *Session, bytes: []const u8) error{ OutOfMemory, QueueFull }!void {
        if (bytes.len == 0) return;
        const pending_len = pendingInputBytes(self);
        std.debug.assert(pending_len <= self.pending_capacity);
        if (bytes.len > std.math.maxInt(TransportByteLimit)) {
            self.ops.feed_rejected += 1;
            return error.QueueFull;
        }
        const projected_len = std.math.add(TransportByteLimit, pending_len, @intCast(bytes.len)) catch {
            self.ops.feed_rejected += 1;
            return error.QueueFull;
        };
        if (projected_len > self.pending_capacity) {
            self.ops.feed_rejected += 1;
            return error.QueueFull;
        }
        self.pending.pushSlice(bytes) catch unreachable;
        std.debug.assert(pendingInputBytes(self) == projected_len);
        std.debug.assert(pendingInputBytes(self) <= self.pending_capacity);
        self.ops.feed_accepted += 1;
        self.ops.bytes_fed += bytes.len;
    }

    /// Flush queued outbound input bytes to transport and return drained count.
    /// This call is non-throwing: transport write failures are reflected in `ops`.
    pub fn flushOutboundInput(self: *Session) TransportByteLimit {
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

    /// Report whether host input still waits for transport write capacity.
    pub fn hasPendingOutboundInput(self: *const Session) bool {
        return self.pending.count > 0;
    }

    /// Report whether outbound input still needs another transport pump pass.
    pub fn hasOutboundInputBacklog(self: *const Session) bool {
        return self.hasPendingOutboundInput();
    }

    pub fn kickTransportWait(self: *Session) void {
        if (self.transport.pty()) |transport| transport.kickWait();
    }

    /// Wait for transport readability.
    pub fn waitReadable(self: *Session, timeout_ms: i32) bool {
        if (self.status != .active) {
            self.last_wait_outcome = .stopped;
            return false;
        }
        const transport = self.transport.pty() orelse {
            self.last_wait_outcome = .timeout;
            return false;
        };
        const outcome = transport.waitReadable(timeout_ms) catch |err| return handleWaitError(self, err);
        return switch (outcome) {
            .ready => blk: {
                self.last_wait_outcome = .ready;
                break :blk true;
            },
            .timeout => blk: {
                self.last_wait_outcome = .timeout;
                break :blk false;
            },
            .wake => blk: {
                self.last_wait_outcome = .wake;
                break :blk false;
            },
        };
    }

    /// Block for readability only when the preceding outbound pump was idle.
    pub fn waitReadableAfterOutbound(self: *Session, outbound: OutboundInputPump, timeout_ms: i32) bool {
        if (!outbound.wait_readable) return true;
        return self.waitReadable(timeout_ms);
    }

    /// Read transport bytes into caller buffer.
    pub fn readTransport(self: *Session, buf: []u8) TransportByteLimit {
        if (buf.len == 0) return 0;
        if (self.status != .active) return 0;
        const transport = self.transport.pty() orelse return 0;
        const n = transport.read(buf) catch |err| return handleReadError(self, err);
        std.debug.assert(n <= buf.len);
        return @intCast(n);
    }

    /// Read one transport chunk and deliver it to sink.
    pub fn ingestTransport(self: *Session, scratch: []u8, sink: anytype) TransportByteLimit {
        const n = self.readTransport(scratch);
        if (n == 0) return 0;
        sink.onTransportBytes(scratch[0..@intCast(n)]);
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

    pub fn transportPumpLimits(mode: TransportPumpMode) TransportPumpLimits {
        return switch (mode) {
            .normal => .{ .chunk_bytes = transport_chunk_bytes, .max_reads = normal_transport_reads, .max_bytes = normal_transport_bytes },
            .constrained => .{ .chunk_bytes = transport_chunk_bytes, .max_reads = constrained_transport_reads, .max_bytes = constrained_transport_bytes },
        };
    }

    fn flushOutboundPhase(self: *Session) TransportByteLimit {
        const pending_len = pendingInputBytes(self);
        std.debug.assert(pending_len <= self.pending_capacity);
        if (pending_len == 0) return 0;
        if (self.status != .active) return 0;
        if (self.transport.pty()) |transport| return flushOutboundToTransport(self, transport, pending_len);
        return 0;
    }

    fn flushOutboundToTransport(self: *Session, t: Pty, pending_len: TransportByteLimit) TransportByteLimit {
        std.debug.assert(pending_len > 0);
        const pending_slice = self.pending.headSliceConst();
        std.debug.assert(pending_slice.len > 0);
        const written = t.write(pending_slice) catch |err| return handleWriteError(self, err);
        std.debug.assert(written <= pending_slice.len);
        trimPendingPrefix(self, @intCast(written), pending_len);
        return @intCast(written);
    }

    fn trimPendingPrefix(self: *Session, drained: TransportByteLimit, pending_len: TransportByteLimit) void {
        std.debug.assert(drained <= pending_len);
        self.pending.discardPrefix(drained);
        std.debug.assert(pendingInputBytes(self) == pending_len - drained);
    }

    fn handleWriteError(self: *Session, err: Pty.WriteError) TransportByteLimit {
        return switch (err) {
            error.WouldBlock, error.Interrupted => 0,
            error.NotStarted => {
                self.ops.apply_transport_write_errors += 1;
                transitionToStopped(self, .transport_failure);
                return 0;
            },
            else => {
                self.ops.apply_transport_write_errors += 1;
                transitionToStopped(self, .transport_failure);
                return 0;
            },
        };
    }

    fn handleWaitError(self: *Session, err: WaitReadableError) bool {
        return switch (err) {
            error.WouldBlock, error.Interrupted => false,
            error.NotStarted => {
                transitionToStopped(self, .child_exit);
                self.last_wait_outcome = .stopped;
                return false;
            },
            else => {
                transitionToStopped(self, .transport_failure);
                self.last_wait_outcome = .stopped;
                return false;
            },
        };
    }

    fn handleReadError(self: *Session, err: ReadError) TransportByteLimit {
        return switch (err) {
            error.WouldBlock, error.Interrupted => 0,
            error.NotStarted => {
                transitionToStopped(self, .child_exit);
                return 0;
            },
            error.EndOfStream => {
                transitionToStopped(self, .transport_eof);
                return 0;
            },
            else => {
                transitionToStopped(self, .transport_failure);
                return 0;
            },
        };
    }

    fn transitionToStopped(self: *Session, reason: TerminalReason) void {
        if (self.status == .stopped) {
            std.debug.assert(self.terminal_reason != null);
            return;
        }
        std.debug.assert(self.terminal_reason == null);
        self.terminal_reason = reason;
        stopTransport(self);
        self.status = .stopped;
        self.last_wait_outcome = .stopped;
    }

    fn stopTransport(self: *Session) void {
        if (self.status == .active) {
            if (self.transport.pty()) |transport| transport.stop();
        }
    }

    fn pendingInputBytes(self: *const Session) TransportByteLimit {
        return self.pending.count;
    }

    /// Send control signal to transport child process.
    pub fn publishControlSignal(self: *Session, signal: ControlSignal) error{TransportUnavailable}!void {
        const transport = self.transport.pty() orelse return error.TransportUnavailable;
        transport.control(signal);
    }

    /// Clear pending queue state.
    pub fn reset(self: *Session) void {
        self.ops.reset_calls += 1;
        self.pending.clear();
    }

    /// Update tracked dimensions and propagate to transport.
    pub fn resize(self: *Session, cols: u16, rows: u16) error{InvalidDimensions}!void {
        if (cols == 0 or rows == 0) {
            self.ops.resize_invalid_calls += 1;
            return error.InvalidDimensions;
        }

        self.cols = cols;
        self.rows = rows;
        self.resize_count +%= 1;
        self.ops.resize_valid_calls += 1;

        if (self.transport.pty()) |transport| transport.resize(cols, rows) catch |err| switch (err) {
            error.NotStarted, error.ResizeFailed => {
                self.ops.resize_transport_errors += 1;
            },
        };
    }

    /// Capture current session snapshot.
    pub fn snapshot(self: *const Session) Snapshot {
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .status = self.status,
            .terminal_reason = self.terminal_reason,
            .last_wait_outcome = self.last_wait_outcome,
            .resize_count = self.resize_count,
        };
    }
};

fn initTransport(config: InitConfig) !Transport {
    if (config.pty) |transport| return .{ .external = transport };
    if (config.launch) |launch| {
        const owned = try pty_api.Owned.init(
            config.allocator,
            launch.shell_path orelse "/bin/sh",
            launch.command,
            launch.start_path,
        );
        return .{ .owned = owned };
    }
    return .none;
}
