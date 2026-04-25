const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const transport_api = @import("../transport.zig");
const vt_core = @import("vt_core");

pub const ControlSignal = types.ControlSignal;
pub const SessionStatus = types.SessionStatus;
pub const Transport = transport_api.Transport;

pub const Config = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pending_capacity: usize,
    transport: ?Transport = null,
};

pub const SessionSnapshot = struct {
    cols: u16,
    rows: u16,
    status: SessionStatus,
    resize_count: u32,
    last_control_signal: ?ControlSignal,
};

pub const SessionOps = struct {
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
    control_calls: u32,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    status: SessionStatus,
    pending: std.ArrayListUnmanaged(u8),
    pending_capacity: usize,
    transport: ?Transport,
    engine: vt_core.runtime.Engine,
    resize_count: u32,
    last_control_signal: ?ControlSignal,
    ops: SessionOps,

    pub fn init(config: Config) anyerror!Session {
        if (config.cols == 0 or config.rows == 0) return error.InvalidConfig;
        if (config.pending_capacity == 0) return error.InvalidConfig;
        const engine = try vt_core.runtime.Engine.initWithCells(config.allocator, config.rows, config.cols);
        return .{
            .allocator = config.allocator,
            .cols = config.cols,
            .rows = config.rows,
            .status = .idle,
            .pending = .empty,
            .pending_capacity = config.pending_capacity,
            .transport = config.transport,
            .engine = engine,
            .resize_count = 0,
            .last_control_signal = null,
            .ops = std.mem.zeroes(SessionOps),
        };
    }

    pub fn deinit(self: *Session) void {
        self.pending.deinit(self.allocator);
        self.engine.deinit();
        self.* = undefined;
    }

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

    pub fn stop(self: *Session) void {
        self.ops.stop_calls += 1;
        if (self.status == .active) {
            if (self.transport) |t| t.stop();
        }
        self.status = .stopped;
    }

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

    pub fn apply(self: *Session) usize {
        self.ops.apply_calls += 1;
        const n = self.pending.items.len;
        var drained: usize = 0;

        if (n > 0) {
            if (self.transport) |t| {
                // Outbound: flush host input to transport (e.g., PTY stdin)
                const written = t.write(self.pending.items) catch {
                    self.ops.apply_transport_write_errors += 1;
                    // Write failed: preserve pending bytes for retry (no fallback)
                    return 0;
                };
                drained = written;
                // Partial write: shift unwritten tail to front, then shrink
                if (written < n) {
                    std.mem.copyForwards(u8, self.pending.items[0..n-written], self.pending.items[written..n]);
                    self.pending.shrinkRetainingCapacity(n - written);
                } else {
                    // Full write: clear entire queue
                    self.pending.clearRetainingCapacity();
                }
            } else {
                // No transport: feed host input directly to engine (null-transport behavior)
                self.engine.feedSlice(self.pending.items);
                self.engine.apply();
                drained = n;
                self.pending.clearRetainingCapacity();
            }
        }

        self.ops.bytes_applied += drained;
        return drained;
    }

    pub fn feedProcessOutput(self: *Session, bytes: []const u8) anyerror!void {
        // Inbound: feed process output to engine (from transport, e.g., PTY stdout)
        self.engine.feedSlice(bytes);
        self.engine.apply();
    }

    pub fn reset(self: *Session) void {
        self.ops.reset_calls += 1;
        self.pending.clearRetainingCapacity();
    }

    pub fn resize(self: *Session, cols: u16, rows: u16) anyerror!void {
        if (cols == 0 or rows == 0) {
            self.ops.resize_invalid_calls += 1;
            return error.InvalidDimensions;
        }

        // RC2: Create new engine first (transactional safety)
        // If this fails, current engine remains valid and state unchanged
        const new_engine = try vt_core.runtime.Engine.initWithCells(self.allocator, rows, cols);

        // On success: swap engines (current engine becomes unreachable, new engine active)
        var old_engine = self.engine;
        self.engine = new_engine;
        old_engine.deinit();

        // Update session state (now that engine is safely in place)
        self.cols = cols;
        self.rows = rows;
        self.resize_count +%= 1;
        self.ops.resize_valid_calls += 1;

        // Notify transport if attached
        if (self.transport) |t| t.resize(cols, rows) catch |err| {
            self.ops.resize_transport_errors += 1;
            return err;
        };
    }

    pub fn control(self: *Session, signal: ControlSignal) void {
        self.ops.control_calls += 1;
        self.last_control_signal = signal;
        if (self.transport) |t| t.control(signal);
    }

    pub fn snapshot(self: *const Session) SessionSnapshot {
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .status = self.status,
            .resize_count = self.resize_count,
            .last_control_signal = self.last_control_signal,
        };
    }

    pub fn restore(self: *Session, snap: SessionSnapshot) error{InvalidSnapshot}!void {
        if (snap.cols == 0 or snap.rows == 0) return error.InvalidSnapshot;
        self.cols = snap.cols;
        self.rows = snap.rows;
        self.status = if (snap.status == .active) .stopped else snap.status;
        self.resize_count = snap.resize_count;
        self.last_control_signal = snap.last_control_signal;
        self.pending.clearRetainingCapacity();
    }
};

const conformance_checkpoint = @import("../test_support/conformance_checkpoint.zig");
const perf = @import("../test_support/perf_harness.zig");
const reliability = @import("../test_support/reliability_harness.zig");

test "init rejects zero cols" {
    const result = Session.init(.{ .allocator = std.testing.allocator, .cols = 0, .rows = 24, .pending_capacity = 4096 });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "init rejects zero rows" {
    const result = Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 0, .pending_capacity = 4096 });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "init succeeds with valid config" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try std.testing.expectEqual(@as(u16, 80), s.cols);
    try std.testing.expectEqual(@as(u16, 24), s.rows);
}

test "feed and apply are callable" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.feed("hello");
    try std.testing.expectEqual(@as(usize, 5), s.apply());
}

test "reset is callable" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    s.reset();
}

test "resize rejects zero dimensions" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try std.testing.expectError(error.InvalidDimensions, s.resize(0, 24));
    try std.testing.expectError(error.InvalidDimensions, s.resize(80, 0));
}

test "resize updates dimensions" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.resize(132, 50);
    try std.testing.expectEqual(@as(u16, 132), s.cols);
    try std.testing.expectEqual(@as(u16, 50), s.rows);
}

test "control is callable" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    s.control(.hangup);
}

test "feed accumulates, apply drains in full" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.feed("abc");
    try s.feed("de");
    try std.testing.expectEqual(@as(usize, 5), s.apply());
    try std.testing.expectEqual(@as(usize, 0), s.apply());
}

test "apply returns 0 on empty queue" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.apply());
}

test "reset clears queue, apply returns 0" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.feed("queued");
    s.reset();
    try std.testing.expectEqual(@as(usize, 0), s.apply());
}

test "reset does not alter dimensions" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.feed("data");
    s.reset();
    try std.testing.expectEqual(@as(u16, 80), s.cols);
    try std.testing.expectEqual(@as(u16, 24), s.rows);
}

test "resize idempotent on same dimensions" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.resize(80, 24);
    try std.testing.expectEqual(@as(u16, 80), s.cols);
    try std.testing.expectEqual(@as(u16, 24), s.rows);
}

test "control accepts all signal variants" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    s.control(.hangup);
    s.control(.interrupt);
    s.control(.terminate);
    s.control(.resize_notify);
}

test "status is idle after init" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try std.testing.expectEqual(SessionStatus.idle, s.status);
}

test "init rejects zero pending_capacity" {
    const result = Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 0 });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "feed overflow returns QueueFull" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 8 });
    defer s.deinit();
    try std.testing.expectError(error.QueueFull, s.feed("123456789"));
}

test "feed overflow is atomic: no partial write" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4 });
    defer s.deinit();
    try s.feed("ab");
    try std.testing.expectError(error.QueueFull, s.feed("cde"));
    try std.testing.expectEqual(@as(usize, 2), s.apply());
}

test "apply after overflow drains only accepted bytes" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 5 });
    defer s.deinit();
    try s.feed("hello");
    try std.testing.expectError(error.QueueFull, s.feed("!"));
    try std.testing.expectEqual(@as(usize, 5), s.apply());
}

test "reset clears full queue, feed succeeds again" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4 });
    defer s.deinit();
    try s.feed("abcd");
    try std.testing.expectError(error.QueueFull, s.feed("e"));
    s.reset();
    try s.feed("xy");
    try std.testing.expectEqual(@as(usize, 2), s.apply());
}

test "feed up to exact capacity succeeds" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 6 });
    defer s.deinit();
    try s.feed("abc");
    try s.feed("def");
    try std.testing.expectEqual(@as(usize, 6), s.apply());
}

test "start with null transport is no-op and succeeds" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
}

test "stop with null transport is no-op and sets stopped" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    s.stop();
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
}

test "start with MemTransport delegates to transport" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try s.start();
    try std.testing.expect(mt.started);
    try std.testing.expectEqual(SessionStatus.active, s.status);
}

test "start/stop with UnixPtyTransport delegates lifecycle through session" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var pty = try transport_api.UnixPtyTransport.init(std.testing.allocator, "/bin/bash", "while true; do sleep 1; done");
    defer pty.deinit();

    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 4096,
        .transport = pty.transport(),
    });
    defer s.deinit();

    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
    s.stop();
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
}

test "stop with MemTransport delegates to transport" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try s.start();
    s.stop();
    try std.testing.expect(!mt.started);
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
}

test "resize with transport delegates dims and notifies" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try s.start();
    try s.resize(132, 50);
    try std.testing.expectEqual(@as(u16, 132), s.cols);
    try std.testing.expectEqual(@as(u16, 50), s.rows);
    try std.testing.expectEqual(@as(u16, 132), mt.last_cols);
    try std.testing.expectEqual(@as(u16, 50), mt.last_rows);
}

test "resize without transport still updates session dimensions" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), s.cols);
    try std.testing.expectEqual(@as(u16, 40), s.rows);
}

test "control with transport routes signal" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    s.control(.terminate);
    try std.testing.expectEqual(ControlSignal.terminate, mt.last_signal.?);
}

test "control without transport is no-op" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    s.control(.hangup);
}

test "feed/apply/reset unaffected by transport attachment" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try s.start();
    try s.feed("abc");
    try s.feed("de");
    try std.testing.expectEqual(@as(usize, 5), s.apply());
    try s.feed("xyz");
    s.reset();
    try std.testing.expectEqual(@as(usize, 0), s.apply());
    try std.testing.expectError(error.QueueFull, s.feed("123456789"));
}

test "start from idle transitions to active" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try std.testing.expectEqual(SessionStatus.idle, s.status);
    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
}

test "start from active returns AlreadyStarted, no status change" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.start();
    try std.testing.expectError(error.AlreadyStarted, s.start());
    try std.testing.expectEqual(SessionStatus.active, s.status);
}

test "start from active does not double-start transport" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try s.start();
    try std.testing.expectError(error.AlreadyStarted, s.start());
    try std.testing.expect(mt.started);
}

test "stop from active transitions to stopped and calls transport" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try s.start();
    s.stop();
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
    try std.testing.expect(!mt.started);
}

test "stop from idle transitions to stopped without calling transport" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    s.stop();
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
    try std.testing.expect(!mt.started);
}

test "stop from stopped is idempotent, transport not called again" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try s.start();
    s.stop();
    s.stop();
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
    try std.testing.expect(!mt.started);
}

test "start from stopped restarts transport" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try s.start();
    s.stop();
    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
    try std.testing.expect(mt.started);
}

test "start from stopped without transport transitions to active" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    s.stop();
    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
}

test "full lifecycle cycle: idle-active-stopped-active" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try std.testing.expectEqual(SessionStatus.idle, s.status);
    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
    try std.testing.expect(mt.started);
    s.stop();
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
    try std.testing.expect(!mt.started);
    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
    try std.testing.expect(mt.started);
}

test "start failure from idle leaves status idle" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = ft.transport(),
    });
    defer s.deinit();
    try std.testing.expectError(error.TransportFailed, s.start());
    try std.testing.expectEqual(SessionStatus.idle, s.status);
}

test "start failure from stopped leaves status stopped" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    try s.start();
    s.stop();
    s.transport = ft.transport();
    try std.testing.expectError(error.TransportFailed, s.start());
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
}

test "start failure is repeatable and deterministic" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = ft.transport(),
    });
    defer s.deinit();
    try std.testing.expectError(error.TransportFailed, s.start());
    try std.testing.expectError(error.TransportFailed, s.start());
    try std.testing.expectEqual(SessionStatus.idle, s.status);
}

test "resize failure retains updated dims" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = ft.transport(),
    });
    defer s.deinit();
    try std.testing.expectError(error.TransportFailed, s.resize(132, 50));
    try std.testing.expectEqual(@as(u16, 132), s.cols);
    try std.testing.expectEqual(@as(u16, 50), s.rows);
}

test "resize failure is repeatable and deterministic" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = ft.transport(),
    });
    defer s.deinit();
    try std.testing.expectError(error.TransportFailed, s.resize(100, 40));
    try std.testing.expectError(error.TransportFailed, s.resize(120, 48));
    try std.testing.expectEqual(@as(u16, 120), s.cols);
    try std.testing.expectEqual(@as(u16, 48), s.rows);
}

test "feed/apply/reset unaffected after start failure" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = ft.transport(),
    });
    defer s.deinit();
    try std.testing.expectError(error.TransportFailed, s.start());
    try s.feed("hello");
    // Transport write fails: apply returns 0, pending preserved
    try std.testing.expectEqual(@as(usize, 0), s.apply());
    try std.testing.expectEqual(@as(usize, 5), s.pending.items.len);
    // Reset clears pending
    s.reset();
    try std.testing.expectEqual(@as(usize, 0), s.apply());
}

test "resize_count zero at init" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try std.testing.expectEqual(@as(u32, 0), s.resize_count);
}

test "resize increments counter on each valid call" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.resize(100, 40);
    try std.testing.expectEqual(@as(u32, 1), s.resize_count);
    try s.resize(132, 50);
    try std.testing.expectEqual(@as(u32, 2), s.resize_count);
    try s.resize(80, 24);
    try std.testing.expectEqual(@as(u32, 3), s.resize_count);
}

test "resize to same dims still increments counter" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try s.resize(80, 24);
    try s.resize(80, 24);
    try std.testing.expectEqual(@as(u32, 2), s.resize_count);
}

test "failed resize still increments counter and retains dims" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = ft.transport(),
    });
    defer s.deinit();
    try std.testing.expectError(error.TransportFailed, s.resize(132, 50));
    try std.testing.expectEqual(@as(u32, 1), s.resize_count);
    try std.testing.expectEqual(@as(u16, 132), s.cols);
    try std.testing.expectEqual(@as(u16, 50), s.rows);
}

test "invalid resize does not increment counter" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try std.testing.expectError(error.InvalidDimensions, s.resize(0, 24));
    try std.testing.expectError(error.InvalidDimensions, s.resize(80, 0));
    try std.testing.expectEqual(@as(u32, 0), s.resize_count);
}

test "last_control_signal null at init" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    try std.testing.expectEqual(@as(?ControlSignal, null), s.last_control_signal);
}

test "control records last signal without transport" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    s.control(.hangup);
    try std.testing.expectEqual(ControlSignal.hangup, s.last_control_signal.?);
    s.control(.terminate);
    try std.testing.expectEqual(ControlSignal.terminate, s.last_control_signal.?);
}

test "control records last signal with transport" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();
    s.control(.interrupt);
    try std.testing.expectEqual(ControlSignal.interrupt, s.last_control_signal.?);
    try std.testing.expectEqual(ControlSignal.interrupt, mt.last_signal.?);
}

test "control with FailTransport still records signal on session" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = ft.transport(),
    });
    defer s.deinit();
    s.control(.resize_notify);
    try std.testing.expectEqual(ControlSignal.resize_notify, s.last_control_signal.?);
}

test "resize and control do not affect queue semantics" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 64 });
    defer s.deinit();
    try s.feed("before");
    try s.resize(100, 40);
    s.control(.hangup);
    try s.feed("after");
    try std.testing.expectEqual(@as(usize, 11), s.apply());
    try std.testing.expectEqual(@as(u32, 1), s.resize_count);
    try std.testing.expectEqual(ControlSignal.hangup, s.last_control_signal.?);
}

// FC-1: Lifecycle transitions
test "conformance FC-1: lifecycle transition checkpoint sequence" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s.deinit();

    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try s.start();
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .active, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try std.testing.expectError(error.AlreadyStarted, s.start());
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .active, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    s.stop();
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .stopped, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try s.start();
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .active, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );
}

// FC-2: Queue capacity and overflow
test "conformance FC-2: queue capacity checkpoint sequence" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 8,
    });
    defer s.deinit();

    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try s.feed("abc");
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 3 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try s.feed("de");
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 5 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try std.testing.expectError(error.QueueFull, s.feed("overflow!"));
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 5 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try s.feed("fgh");
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 8 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    _ = s.apply();
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try s.feed("xyz");
    s.reset();
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );
}

// FC-3: Resize and control sequencing
test "conformance FC-3: resize and control sequencing checkpoint sequence" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
    });
    defer s.deinit();

    try s.resize(100, 40);
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 100, .rows = 40, .resize_count = 1, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try s.resize(100, 40);
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 100, .rows = 40, .resize_count = 2, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try std.testing.expectError(error.InvalidDimensions, s.resize(0, 40));
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 100, .rows = 40, .resize_count = 2, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    s.control(.hangup);
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 100, .rows = 40, .resize_count = 2, .last_control_signal = ControlSignal.hangup, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    s.control(.terminate);
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 100, .rows = 40, .resize_count = 2, .last_control_signal = ControlSignal.terminate, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );
}

// FC-4: Failure-boundary behavior
test "conformance FC-4: failure-boundary checkpoint sequence" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = ft.transport(),
    });
    defer s.deinit();

    try std.testing.expectError(error.TransportFailed, s.start());
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try std.testing.expectError(error.TransportFailed, s.start());
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 80, .rows = 24, .resize_count = 0, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try std.testing.expectError(error.TransportFailed, s.resize(132, 50));
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 132, .rows = 50, .resize_count = 1, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );

    try std.testing.expectError(error.TransportFailed, s.resize(100, 40));
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        .{ .status = .idle, .cols = 100, .rows = 40, .resize_count = 2, .last_control_signal = null, .pending_len = 0 },
        conformance_checkpoint.ConformanceCheckpoint.capture(&s),
    );
}

// FC-5: Null vs attached transport equivalence
test "conformance FC-5: null vs attached transport session-state equivalence" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();

    var s_null = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
    });
    defer s_null.deinit();

    var s_attached = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = mt.transport(),
    });
    defer s_attached.deinit();

    try s_null.start();
    try s_attached.start();
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_null),
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_attached),
    );

    try s_null.resize(132, 50);
    try s_attached.resize(132, 50);
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_null),
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_attached),
    );

    s_null.control(.interrupt);
    s_attached.control(.interrupt);
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_null),
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_attached),
    );

    try s_null.feed("hello");
    try s_attached.feed("hello");
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_null),
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_attached),
    );

    s_null.stop();
    s_attached.stop();
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_null),
        conformance_checkpoint.ConformanceCheckpoint.capture(&s_attached),
    );
}

// Performance evidence: Class B steady-state operations
test "perf: apply steady-state (Class B)" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    for (0..perf.WARMUP_ITERS) |_| {
        try s.feed("warmup-bytes");
        _ = s.apply();
    }
    var sampler = perf.PerfSampler(perf.MEASURE_ITERS).init();
    var timer = try perf.PerfTimer.start();
    for (0..perf.MEASURE_ITERS) |_| {
        try s.feed("measure-bytes");
        timer.timer.reset();
        _ = s.apply();
        sampler.record(timer.lapNs());
    }
    const med = sampler.median();
    try std.testing.expect(med > 0);
    try std.testing.expect(med < 1_000_000);
}

test "perf: reset steady-state (Class B)" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    for (0..perf.WARMUP_ITERS) |_| {
        try s.feed("warmup");
        s.reset();
    }
    var sampler = perf.PerfSampler(perf.MEASURE_ITERS).init();
    var timer = try perf.PerfTimer.start();
    for (0..perf.MEASURE_ITERS) |_| {
        try s.feed("measure");
        timer.timer.reset();
        s.reset();
        sampler.record(timer.lapNs());
    }
    const med = sampler.median();
    try std.testing.expect(med > 0);
    try std.testing.expect(med < 1_000_000);
}

test "perf: resize steady-state (Class B)" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    for (0..perf.WARMUP_ITERS) |_| try s.resize(80, 24);
    var sampler = perf.PerfSampler(perf.MEASURE_ITERS).init();
    var timer = try perf.PerfTimer.start();
    for (0..perf.MEASURE_ITERS) |_| {
        timer.timer.reset();
        try s.resize(80, 24);
        sampler.record(timer.lapNs());
    }
    const med = sampler.median();
    try std.testing.expect(med > 0);
    try std.testing.expect(med < 1_000_000);
}

test "perf: control steady-state (Class B)" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    for (0..perf.WARMUP_ITERS) |_| s.control(.hangup);
    var sampler = perf.PerfSampler(perf.MEASURE_ITERS).init();
    var timer = try perf.PerfTimer.start();
    for (0..perf.MEASURE_ITERS) |_| {
        timer.timer.reset();
        s.control(.hangup);
        sampler.record(timer.lapNs());
    }
    const med = sampler.median();
    try std.testing.expect(med > 0);
    try std.testing.expect(med < 1_000_000);
}

test "perf: start/stop cycle steady-state (Class B, null transport)" {
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    for (0..perf.WARMUP_ITERS) |_| {
        try s.start();
        s.stop();
    }
    var sampler = perf.PerfSampler(perf.MEASURE_ITERS).init();
    var timer = try perf.PerfTimer.start();
    for (0..perf.MEASURE_ITERS) |_| {
        timer.timer.reset();
        try s.start();
        s.stop();
        sampler.record(timer.lapNs());
    }
    const med = sampler.median();
    try std.testing.expect(med > 0);
    try std.testing.expect(med < 1_000_000);
}

test "perf: feed 64-byte payload steady-state (Class A, warm capacity)" {
    const payload = "x" ** 64;
    var s = try Session.init(.{ .allocator = std.testing.allocator, .cols = 80, .rows = 24, .pending_capacity = 4096 });
    defer s.deinit();
    for (0..perf.WARMUP_ITERS) |_| {
        try s.feed(payload);
        _ = s.apply();
    }
    var sampler = perf.PerfSampler(perf.MEASURE_ITERS).init();
    var timer = try perf.PerfTimer.start();
    for (0..perf.MEASURE_ITERS) |_| {
        timer.timer.reset();
        try s.feed(payload);
        sampler.record(timer.lapNs());
        _ = s.apply();
    }
    const med = sampler.median();
    try std.testing.expect(med > 0);
    try std.testing.expect(med < 1_000_000);
}

// Reliability evidence
test "reliability R-1: start/stop cycle stability" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = mt.transport(),
    });
    defer s.deinit();

    for (0..reliability.WARMUP_CYCLES) |_| {
        try s.start();
        s.stop();
    }

    const baseline = conformance_checkpoint.ConformanceCheckpoint.capture(&s);

    for (0..reliability.CYCLES) |_| {
        try s.start();
        s.stop();
        try std.testing.expect(!mt.started);
        const cp = conformance_checkpoint.ConformanceCheckpoint.capture(&s);
        try conformance_checkpoint.ConformanceCheckpoint.expectEqual(baseline, cp);
    }
}

test "reliability R-2: error-path retry stability" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = ft.transport(),
    });
    defer s.deinit();

    for (0..reliability.WARMUP_CYCLES) |_| {
        try std.testing.expectError(error.TransportFailed, s.start());
    }

    const baseline = conformance_checkpoint.ConformanceCheckpoint.capture(&s);

    for (0..reliability.CYCLES) |_| {
        try std.testing.expectError(error.TransportFailed, s.start());
        const cp = conformance_checkpoint.ConformanceCheckpoint.capture(&s);
        try conformance_checkpoint.ConformanceCheckpoint.expectEqual(baseline, cp);
    }
}

test "reliability R-3: queue pressure at capacity" {
    const capacity: usize = 64;
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = capacity,
    });
    defer s.deinit();

    const payload = [_]u8{'x'} ** 64;

    for (0..reliability.WARMUP_CYCLES) |_| {
        try s.feed(&payload);
        _ = s.apply();
    }

    const baseline = conformance_checkpoint.ConformanceCheckpoint.capture(&s);
    try std.testing.expectEqual(@as(usize, 0), baseline.pending_len);

    for (0..reliability.CYCLES) |_| {
        try s.feed(&payload);
        _ = s.apply();
        const cp = conformance_checkpoint.ConformanceCheckpoint.capture(&s);
        try std.testing.expectEqual(@as(usize, 0), cp.pending_len);
        try std.testing.expectEqual(baseline.resize_count, cp.resize_count);
        try std.testing.expectEqual(baseline.last_control_signal, cp.last_control_signal);
        try std.testing.expectEqual(baseline.status, cp.status);
        try std.testing.expectEqual(baseline.cols, cp.cols);
        try std.testing.expectEqual(baseline.rows, cp.rows);
    }

    try std.testing.expectEqual(capacity, s.pending_capacity);
}

test "reliability R-4: resize/control churn stability" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    for (0..reliability.WARMUP_CYCLES) |_| {
        try s.resize(100, 40);
        s.control(.interrupt);
    }

    const initial_resize_count = s.resize_count;

    for (0..reliability.CYCLES) |i| {
        try s.resize(100, 40);
        s.control(.interrupt);
        try std.testing.expectEqual(SessionStatus.idle, s.status);
        try std.testing.expectEqual(@as(u16, 100), s.cols);
        try std.testing.expectEqual(@as(u16, 40), s.rows);
        try std.testing.expectEqual(
            reliability.expectedResizeCountAfterCycles(initial_resize_count, @as(u32, @intCast(i + 1))),
            s.resize_count,
        );
        try std.testing.expectEqual(ControlSignal.interrupt, s.last_control_signal.?);
        try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
    }
}

test "lifecycle error-path stability: transport failure leaves session recoverable" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = ft.transport(),
    });
    defer s.deinit();

    const baseline = conformance_checkpoint.ConformanceCheckpoint.capture(&s);

    try std.testing.expectError(error.TransportFailed, s.start());
    const after_fail = conformance_checkpoint.ConformanceCheckpoint.capture(&s);
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(baseline, after_fail);

    try s.feed("data");
    // Transport write fails: apply returns 0, pending preserved
    try std.testing.expectEqual(@as(usize, 0), s.apply());
    try std.testing.expectEqual(@as(usize, 4), s.pending.items.len);

    try std.testing.expectEqual(SessionStatus.idle, s.status);
}

test "lifecycle contract guarantee: stop idempotence after transport success" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = mt.transport(),
    });
    defer s.deinit();

    try s.start();
    s.stop();
    const after_first_stop = conformance_checkpoint.ConformanceCheckpoint.capture(&s);
    try std.testing.expectEqual(SessionStatus.stopped, after_first_stop.status);

    s.stop();
    const after_second_stop = conformance_checkpoint.ConformanceCheckpoint.capture(&s);
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(after_first_stop, after_second_stop);
}

test "lifecycle contract guarantee: restart from stopped transitions to active" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = mt.transport(),
    });
    defer s.deinit();

    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
    s.stop();
    try std.testing.expectEqual(SessionStatus.stopped, s.status);

    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);
    try std.testing.expect(mt.started);
}

test "lifecycle contract guarantee: double-start returns AlreadyStarted without transport call" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = mt.transport(),
    });
    defer s.deinit();

    try s.start();
    const after_first = conformance_checkpoint.ConformanceCheckpoint.capture(&s);

    try std.testing.expectError(error.AlreadyStarted, s.start());

    const after_double = conformance_checkpoint.ConformanceCheckpoint.capture(&s);
    try conformance_checkpoint.ConformanceCheckpoint.expectEqual(after_first, after_double);
}

test "lifecycle contract guarantee: resize commits dims before transport error" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = ft.transport(),
    });
    defer s.deinit();

    try std.testing.expectError(error.TransportFailed, s.resize(132, 50));

    try std.testing.expectEqual(@as(u16, 132), s.cols);
    try std.testing.expectEqual(@as(u16, 50), s.rows);

    try std.testing.expectEqual(@as(u32, 1), s.resize_count);
}

test "lifecycle contract guarantee: control always records signal before transport" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = ft.transport(),
    });
    defer s.deinit();

    s.control(.interrupt);
    try std.testing.expectEqual(ControlSignal.interrupt, s.last_control_signal.?);

    var s_no_t = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s_no_t.deinit();
    s_no_t.control(.terminate);
    try std.testing.expectEqual(ControlSignal.terminate, s_no_t.last_control_signal.?);
}

test "resize contract: valid resize increments counter and records dims" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    try s.resize(132, 50);
    try std.testing.expectEqual(@as(u16, 132), s.cols);
    try std.testing.expectEqual(@as(u16, 50), s.rows);
    try std.testing.expectEqual(@as(u32, 1), s.resize_count);
}

test "resize contract: same-dims resize still increments counter" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    try s.resize(80, 24);
    try std.testing.expectEqual(@as(u32, 1), s.resize_count);

    try s.resize(80, 24);
    try std.testing.expectEqual(@as(u32, 2), s.resize_count);
}

test "resize contract: repeated different resizes increment counter independently" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    try s.resize(100, 40);
    try s.resize(120, 50);
    try s.resize(80, 24);

    try std.testing.expectEqual(@as(u32, 3), s.resize_count);
    try std.testing.expectEqual(@as(u16, 80), s.cols);
    try std.testing.expectEqual(@as(u16, 24), s.rows);
}

test "resize contract: invalid zero-dim returns error without state change" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    try std.testing.expectError(error.InvalidDimensions, s.resize(0, 24));
    try std.testing.expectEqual(@as(u16, 80), s.cols);
    try std.testing.expectEqual(@as(u32, 0), s.resize_count);

    // Next valid resize works fresh
    try s.resize(100, 40);
    try std.testing.expectEqual(@as(u32, 1), s.resize_count);
}

test "resize contract: transport failure leaves dims committed" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = ft.transport(),
    });
    defer s.deinit();

    try std.testing.expectError(error.TransportFailed, s.resize(132, 50));
    try std.testing.expectEqual(@as(u16, 132), s.cols);
    try std.testing.expectEqual(@as(u16, 50), s.rows);
    try std.testing.expectEqual(@as(u32, 1), s.resize_count);
}

test "control contract: signal always recorded regardless of transport" {
    var ft = transport_api.FailTransport.init();
    defer ft.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = ft.transport(),
    });
    defer s.deinit();

    s.control(.interrupt);
    try std.testing.expectEqual(ControlSignal.interrupt, s.last_control_signal.?);

    s.control(.terminate);
    try std.testing.expectEqual(ControlSignal.terminate, s.last_control_signal.?);
}

test "control contract: repeated signals overwrite, no deduplication" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    s.control(.interrupt);
    s.control(.interrupt);
    s.control(.interrupt);

    try std.testing.expectEqual(ControlSignal.interrupt, s.last_control_signal.?);
}

test "control contract: control before start is safe" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    s.control(.hangup);
    try std.testing.expectEqual(ControlSignal.hangup, s.last_control_signal.?);
    try std.testing.expectEqual(SessionStatus.idle, s.status);
}

test "control contract: control after stop is safe" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = mt.transport(),
    });
    defer s.deinit();

    try s.start();
    s.stop();

    s.control(.hangup);
    try std.testing.expectEqual(ControlSignal.hangup, s.last_control_signal.?);
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
}

// VT Core Integration Tests

test "vt_core integration: apply feeds engine when no transport" {
    // No transport: apply() should feed input directly to engine
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    try s.feed("hello");
    const n = s.apply();
    try std.testing.expectEqual(@as(usize, 5), n);

    // Engine should have processed the text (null-transport mode)
    const screen = s.engine.screen();
    try std.testing.expectEqual(@as(u16, 80), screen.cols);
}

test "vt_core integration: empty apply is safe" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    const n = s.apply();
    try std.testing.expectEqual(@as(usize, 0), n);

    const screen = s.engine.screen();
    try std.testing.expectEqual(@as(u16, 80), screen.cols);
}

test "vt_core integration: feedProcessOutput processes engine bytes" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    // Process output (from PTY) goes through feedProcessOutput
    try s.feedProcessOutput("output");

    // Engine should have processed the output
    const screen = s.engine.screen();
    try std.testing.expectEqual(@as(u16, 80), screen.cols);
}

test "vt_core integration: deterministic behavior across cycles (null transport)" {
    // Cycle 1
    var s1 = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s1.deinit();

    try s1.feed("ABC");
    _ = s1.apply();
    const seq1_after_abc = s1.engine.queuedEventCount();

    // Cycle 2 (same session)
    try s1.feed("DEF");
    _ = s1.apply();
    _ = s1.engine.queuedEventCount();

    // Create second session with same initial config
    var s2 = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s2.deinit();

    try s2.feed("ABC");
    _ = s2.apply();
    const seq2_after_abc = s2.engine.queuedEventCount();

    // After same feed/apply in both sessions (null transport), behavior should match
    try std.testing.expectEqual(seq1_after_abc, seq2_after_abc);
}

test "vt_core integration: resize keeps session and engine dims consistent" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    const screen_before = s.engine.screen();
    try std.testing.expectEqual(@as(u16, 80), screen_before.cols);
    try std.testing.expectEqual(@as(u16, 24), screen_before.rows);

    // Resize session dimensions
    try s.resize(132, 50);
    try std.testing.expectEqual(@as(u16, 132), s.cols);
    try std.testing.expectEqual(@as(u16, 50), s.rows);

    // Engine dimensions now match session (engine was recreated with new dims)
    const screen_after = s.engine.screen();
    try std.testing.expectEqual(@as(u16, 132), screen_after.cols);
    try std.testing.expectEqual(@as(u16, 50), screen_after.rows);
}

test "vt_core integration: reset clears pending but preserves engine" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    try s.feed("hello");
    s.reset();

    // Pending should be cleared
    try std.testing.expectEqual(@as(usize, 0), s.apply());

    // Engine should still be functional
    const screen = s.engine.screen();
    try std.testing.expectEqual(@as(u16, 80), screen.cols);
}

test "vt_core integration: apply flushes to transport or engine (null)" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    try s.feed("A");
    try std.testing.expectEqual(@as(usize, 1), s.apply());

    try s.feed("B");
    try std.testing.expectEqual(@as(usize, 1), s.apply());

    try s.feed("CD");
    try std.testing.expectEqual(@as(usize, 2), s.apply());

    // In null-transport mode, pending is fed to engine; no transport writes
    const screen = s.engine.screen();
    try std.testing.expectEqual(@as(u16, 80), screen.cols);
}

// Platform-specific smoke test
test "unix_pty transport: session lifecycle with shell (Linux only)" {
    if (builtin.os.tag != .linux) {
        return;
    }

    var pty = transport_api.UnixPtyTransport.init(
        std.testing.allocator,
        "/bin/sh",
        null
    ) catch {
        // Skip if PTY unavailable (e.g., in container without PTY support)
        return;
    };
    defer pty.deinit();

    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 4096,
        .transport = pty.transport(),
    });
    defer s.deinit();

    // Start PTY transport
    try s.start();
    try std.testing.expectEqual(SessionStatus.active, s.status);

    // Send a simple command
    try s.feed("echo test\n");
    _ = s.apply();

    // Stop cleanly
    s.stop();
    try std.testing.expectEqual(SessionStatus.stopped, s.status);
}

// ============================================================================
// LMVP-R: Regression tests for fixed defects
// ============================================================================

test "regression: R1 I/O direction — apply writes to transport, not engine" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = mt.transport(),
    });
    defer s.deinit();

    try s.start();
    try s.feed("hello");
    const n = s.apply();

    // Bytes flushed to transport, not engine
    try std.testing.expectEqual(@as(usize, 5), n);
    // MemTransport records written bytes in tx
    try std.testing.expectEqual(@as(usize, 5), mt.tx.items.len);
}

test "regression: R1 I/O direction — feedProcessOutput feeds engine" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    try s.feedProcessOutput("output");
    const screen = s.engine.screen();
    try std.testing.expectEqual(@as(u16, 80), screen.cols);
}

test "regression: R2 resize consistency — engine dims match session" {
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
    });
    defer s.deinit();

    try s.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), s.cols);
    try std.testing.expectEqual(@as(u16, 40), s.rows);
    
    const screen = s.engine.screen();
    try std.testing.expectEqual(@as(u16, 120), screen.cols);
    try std.testing.expectEqual(@as(u16, 40), screen.rows);
}


// ============================================================================
// LMVP-RC1: Partial-write correctness tests
// ============================================================================

test "RC1: apply full write drains all pending" {
    var mt = transport_api.MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = mt.transport(),
    });
    defer s.deinit();

    try s.start();
    try s.feed("hello");
    try std.testing.expectEqual(@as(usize, 5), s.pending.items.len);

    const drained = s.apply();
    try std.testing.expectEqual(@as(usize, 5), drained);
    try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "RC1: apply partial write keeps unwritten tail" {
    // Partial write transport (writes only first 3 bytes of 5)
    var pt = transport_api.PartialTransport.init(std.testing.allocator, 3);
    defer pt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = pt.transport(),
    });
    defer s.deinit();

    try s.start();
    try s.feed("hello");
    try std.testing.expectEqual(@as(usize, 5), s.pending.items.len);

    const drained = s.apply();
    try std.testing.expectEqual(@as(usize, 3), drained);
    try std.testing.expectEqual(@as(usize, 2), s.pending.items.len);
    // Verify tail is "lo" (last 2 bytes of "hello")
    try std.testing.expectEqualSlices(u8, "lo", s.pending.items);
}

test "RC1: repeated apply drains retained tail" {
    var pt = transport_api.PartialTransport.init(std.testing.allocator, 2);
    defer pt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = pt.transport(),
    });
    defer s.deinit();

    try s.start();
    try s.feed("hello");

    // First apply: 2 bytes written ("he"), 3 retained ("llo")
    var drained = s.apply();
    try std.testing.expectEqual(@as(usize, 2), drained);
    try std.testing.expectEqual(@as(usize, 3), s.pending.items.len);

    // Second apply: 2 more bytes written ("ll"), 1 retained ("o")
    drained = s.apply();
    try std.testing.expectEqual(@as(usize, 2), drained);
    try std.testing.expectEqual(@as(usize, 1), s.pending.items.len);

    // Third apply: final 1 byte written ("o"), queue empty
    drained = s.apply();
    try std.testing.expectEqual(@as(usize, 1), drained);
    try std.testing.expectEqual(@as(usize, 0), s.pending.items.len);
}

test "RC1: zero-byte write preserves pending for retry" {
    // PartialTransport with max_bytes=0 simulates a "not ready" state
    var pt = transport_api.PartialTransport.init(std.testing.allocator, 0);
    defer pt.deinit();
    var s = try Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80, .rows = 24, .pending_capacity = 256,
        .transport = pt.transport(),
    });
    defer s.deinit();

    try s.start();
    try s.feed("hello");
    try std.testing.expectEqual(@as(usize, 5), s.pending.items.len);

    const drained = s.apply();
    try std.testing.expectEqual(@as(usize, 0), drained);
    // Pending should be preserved (5 bytes retained for retry)
    try std.testing.expectEqual(@as(usize, 5), s.pending.items.len);
    try std.testing.expectEqualSlices(u8, "hello", s.pending.items);
}
