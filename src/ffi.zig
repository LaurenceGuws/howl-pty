const std = @import("std");
const platform = @import("pty/pty_platform.zig");
const session = @import("session.zig");
const selected_transport = @import("pty/selected_transport.zig");
const test_pty = @import("pty/pty_test.zig");

pub const SessionHandle = ?*anyopaque;

pub const HowlPtyCallStatus = enum(c_int) {
    ok = 0,
    missing_handle = -1,
    invalid_argument = -2,
    failed = -3,
};

pub const FfiSnapshot = extern struct {
    status: i32 = @intFromEnum(HowlPtyCallStatus.failed),
    cols: u16 = 0,
    rows: u16 = 0,
    session_status: u8 = 0,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    resize_count: u32 = 0,
};

pub const FfiOutboundPump = extern struct {
    status: i32 = @intFromEnum(HowlPtyCallStatus.failed),
    had_pending: u8 = 0,
    has_pending: u8 = 0,
    wait_readable: u8 = 0,
    reserved0: u8 = 0,
    drained: u64 = 0,
};

pub const FfiReadResult = extern struct {
    status: i32 = @intFromEnum(HowlPtyCallStatus.failed),
    any_read: u8 = 0,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    reserved2: u32 = 0,
    bytes_read: u64 = 0,
};

pub const FfiTransportPumpLimits = extern struct {
    status: i32 = @intFromEnum(HowlPtyCallStatus.failed),
    chunk_bytes: u32 = 0,
    max_reads: u32 = 0,
    max_bytes: u32 = 0,
};

fn boolByte(value: bool) u8 {
    return if (value) 1 else 0;
}

fn sessionFromHandle(handle: SessionHandle) ?*session.Session {
    const raw = handle orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn bytesIn(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    // C callers provide architecture-sized byte counts; translate immediately to a Zig slice.
    if (ptr == null) {
        if (len != 0) return null;
        return &.{};
    }
    return ptr.?[0..len];
}

fn bytesOut(ptr: ?[*]u8, len: usize) ?[]u8 {
    // C callers provide architecture-sized buffer capacities; translate immediately to a Zig slice.
    if (ptr == null) {
        if (len != 0) return null;
        return &.{};
    }
    return ptr.?[0..len];
}

fn launchConfigIn(
    shell_ptr: ?[*]const u8,
    shell_len: usize,
    command_ptr: ?[*]const u8,
    command_len: usize,
    start_path_ptr: ?[*]const u8,
    start_path_len: usize,
) ?selected_transport.LaunchConfig {
    const shell = bytesIn(shell_ptr, shell_len) orelse return null;
    const command = bytesIn(command_ptr, command_len) orelse return null;
    const start_path = bytesIn(start_path_ptr, start_path_len) orelse return null;
    return .{
        .shell_path = if (shell.len == 0) null else shell,
        .command = if (command.len == 0) null else command,
        .start_path = if (start_path.len == 0) null else start_path,
    };
}

fn snapshotOut(value: session.Snapshot) FfiSnapshot {
    return .{
        .status = @intFromEnum(HowlPtyCallStatus.ok),
        .cols = value.cols,
        .rows = value.rows,
        .session_status = @intFromEnum(value.status),
        .resize_count = value.resize_count,
    };
}

fn outboundPumpOut(value: session.OutboundInputPump) FfiOutboundPump {
    return .{
        .status = @intFromEnum(HowlPtyCallStatus.ok),
        .had_pending = boolByte(value.had_pending),
        .has_pending = boolByte(value.has_pending),
        .wait_readable = boolByte(value.wait_readable),
        .drained = value.drained,
    };
}

fn transportPumpLimitsOut(value: session.TransportPumpLimits) FfiTransportPumpLimits {
    return .{
        .status = @intFromEnum(HowlPtyCallStatus.ok),
        .chunk_bytes = value.chunk_bytes,
        .max_reads = value.max_reads,
        .max_bytes = value.max_bytes,
    };
}

fn transportPumpModeIn(mode: u8) ?session.TransportPumpMode {
    return switch (mode) {
        @intFromEnum(session.TransportPumpMode.normal) => .normal,
        @intFromEnum(session.TransportPumpMode.constrained) => .constrained,
        else => null,
    };
}

pub fn sessionInit(
    shell_ptr: ?[*]const u8,
    shell_len: usize,
    command_ptr: ?[*]const u8,
    command_len: usize,
    start_path_ptr: ?[*]const u8,
    start_path_len: usize,
    cols: u16,
    rows: u16,
    pending_capacity: usize,
) callconv(.c) SessionHandle {
    const launch = launchConfigIn(shell_ptr, shell_len, command_ptr, command_len, start_path_ptr, start_path_len) orelse return null;
    // The shipped PTY ABI still exposes architecture-sized queue capacity at this seam.
    // Range-check it once, then keep Session ownership typed as TransportByteLimit.
    if (pending_capacity > std.math.maxInt(session.TransportByteLimit)) return null;
    const owned = std.heap.c_allocator.create(session.Session) catch return null;
    const transport = selected_transport.OwnedTransport.init(std.heap.c_allocator, launch) catch {
        std.heap.c_allocator.destroy(owned);
        return null;
    };
    owned.* = session.Session.initOwnedTransport(.{
        .allocator = std.heap.c_allocator,
        .cols = cols,
        .rows = rows,
        .pending_capacity = @intCast(pending_capacity),
        .transport = transport,
    }) catch {
        std.heap.c_allocator.destroy(owned);
        return null;
    };
    return @ptrCast(owned);
}

pub fn sessionDeinit(handle: SessionHandle) callconv(.c) void {
    const owned = sessionFromHandle(handle) orelse return;
    owned.deinit();
    std.heap.c_allocator.destroy(owned);
}

pub fn sessionStart(handle: SessionHandle) callconv(.c) i32 {
    const owned = sessionFromHandle(handle) orelse return @intFromEnum(HowlPtyCallStatus.missing_handle);
    owned.start() catch return @intFromEnum(HowlPtyCallStatus.failed);
    return @intFromEnum(HowlPtyCallStatus.ok);
}

pub fn sessionStop(handle: SessionHandle) callconv(.c) void {
    const owned = sessionFromHandle(handle) orelse return;
    owned.stop();
}

pub fn sessionSnapshot(handle: SessionHandle) callconv(.c) FfiSnapshot {
    const owned = sessionFromHandle(handle) orelse return .{ .status = @intFromEnum(HowlPtyCallStatus.missing_handle) };
    return snapshotOut(owned.snapshot());
}

pub fn sessionResize(handle: SessionHandle, cols: u16, rows: u16) callconv(.c) i32 {
    const owned = sessionFromHandle(handle) orelse return @intFromEnum(HowlPtyCallStatus.missing_handle);
    owned.resize(cols, rows) catch return @intFromEnum(HowlPtyCallStatus.invalid_argument);
    return @intFromEnum(HowlPtyCallStatus.ok);
}

pub fn sessionPublishSignal(handle: SessionHandle, signal: u8) callconv(.c) i32 {
    const owned = sessionFromHandle(handle) orelse return @intFromEnum(HowlPtyCallStatus.missing_handle);
    const typed = platform.ControlSignal.fromRaw(signal) catch return @intFromEnum(HowlPtyCallStatus.invalid_argument);
    owned.publishControlSignal(typed) catch return @intFromEnum(HowlPtyCallStatus.failed);
    return @intFromEnum(HowlPtyCallStatus.ok);
}

pub fn sessionPublishInput(handle: SessionHandle, ptr: ?[*]const u8, len: usize) callconv(.c) i32 {
    const owned = sessionFromHandle(handle) orelse return @intFromEnum(HowlPtyCallStatus.missing_handle);
    const bytes = bytesIn(ptr, len) orelse return @intFromEnum(HowlPtyCallStatus.invalid_argument);
    owned.publishHostInput(bytes) catch return @intFromEnum(HowlPtyCallStatus.failed);
    return @intFromEnum(HowlPtyCallStatus.ok);
}

pub fn sessionPumpOutbound(handle: SessionHandle, woke: u8) callconv(.c) FfiOutboundPump {
    const owned = sessionFromHandle(handle) orelse return .{ .status = @intFromEnum(HowlPtyCallStatus.missing_handle) };
    return outboundPumpOut(owned.pumpOutboundInput(woke != 0));
}

pub fn sessionPendingBytes(handle: SessionHandle) callconv(.c) u64 {
    const owned = sessionFromHandle(handle) orelse return 0;
    return owned.pending.count;
}

pub fn sessionKickWait(handle: SessionHandle) callconv(.c) void {
    const owned = sessionFromHandle(handle) orelse return;
    owned.kickTransportWait();
}

pub fn sessionBytesApplied(handle: SessionHandle) callconv(.c) u64 {
    const owned = sessionFromHandle(handle) orelse return 0;
    return owned.ops.bytes_applied;
}

pub fn sessionWaitReadable(handle: SessionHandle, timeout_ms: i32) callconv(.c) u8 {
    const owned = sessionFromHandle(handle) orelse return 0;
    return boolByte(owned.waitReadable(timeout_ms));
}

pub fn sessionRead(handle: SessionHandle, ptr: ?[*]u8, len: usize) callconv(.c) FfiReadResult {
    const owned = sessionFromHandle(handle) orelse return .{ .status = @intFromEnum(HowlPtyCallStatus.missing_handle) };
    const buf = bytesOut(ptr, len) orelse return .{ .status = @intFromEnum(HowlPtyCallStatus.invalid_argument) };
    const n = owned.readTransport(buf);
    return .{
        .status = @intFromEnum(HowlPtyCallStatus.ok),
        .any_read = boolByte(n != 0),
        .bytes_read = n,
    };
}

pub fn transportPumpLimits(mode: u8) callconv(.c) FfiTransportPumpLimits {
    const typed = transportPumpModeIn(mode) orelse return .{ .status = @intFromEnum(HowlPtyCallStatus.invalid_argument) };
    return transportPumpLimitsOut(session.Session.transportPumpLimits(typed));
}

test "session ffi handle path covers lifecycle and transport progress" {
    const handle = sessionInit(null, 0, null, 0, null, 0, 80, 24, 64);
    defer sessionDeinit(handle);
    try std.testing.expect(handle != null);
    try std.testing.expectEqual(@as(i32, 0), sessionStart(handle));
    try std.testing.expectEqual(@as(u8, @intFromEnum(session.Status.active)), sessionSnapshot(handle).session_status);

    try std.testing.expectEqual(@as(i32, 0), sessionPublishInput(handle, "echo hi\n".ptr, "echo hi\n".len));
    const pumped = sessionPumpOutbound(handle, 0);
    try std.testing.expectEqual(@as(i32, 0), pumped.status);

    const snap = sessionSnapshot(handle);
    try std.testing.expectEqual(@as(i32, 0), snap.status);
    try std.testing.expectEqual(@as(u16, 80), snap.cols);
    try std.testing.expectEqual(@as(u16, 24), snap.rows);
}

test "session ffi publishes typed control signals through the shipped abi" {
    const allocator = std.testing.allocator;
    var mem_pty = test_pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = mem_pty.pty(),
    });
    defer state.deinit();

    const handle: SessionHandle = @ptrCast(&state);
    try std.testing.expectEqual(
        @as(i32, 0),
        sessionPublishSignal(handle, @intFromEnum(platform.ControlSignal.interrupt)),
    );
    try std.testing.expectEqual(platform.ControlSignal.interrupt, mem_pty.last_signal.?);
    try std.testing.expectEqual(
        @as(i32, @intFromEnum(HowlPtyCallStatus.invalid_argument)),
        sessionPublishSignal(handle, 0),
    );
}

test "transport pump limits ffi exposes shipped PTY burst policy" {
    const normal = transportPumpLimits(@intFromEnum(session.TransportPumpMode.normal));
    try std.testing.expectEqual(@as(i32, @intFromEnum(HowlPtyCallStatus.ok)), normal.status);
    try std.testing.expectEqual(@as(u32, session.transport_chunk_bytes), normal.chunk_bytes);
    try std.testing.expectEqual(@as(u32, 16), normal.max_reads);
    try std.testing.expectEqual(@as(u32, 1024 * 1024), normal.max_bytes);

    const constrained = transportPumpLimits(@intFromEnum(session.TransportPumpMode.constrained));
    try std.testing.expectEqual(@as(i32, @intFromEnum(HowlPtyCallStatus.ok)), constrained.status);
    try std.testing.expectEqual(@as(u32, session.transport_chunk_bytes), constrained.chunk_bytes);
    try std.testing.expectEqual(@as(u32, 2), constrained.max_reads);
    try std.testing.expectEqual(@as(u32, 128 * 1024), constrained.max_bytes);

    const invalid = transportPumpLimits(99);
    try std.testing.expectEqual(@as(i32, @intFromEnum(HowlPtyCallStatus.invalid_argument)), invalid.status);
}

test "session ffi exports the shipped PTY wait wake seam" {
    const allocator = std.testing.allocator;
    var mem_pty = test_pty.Mem.init(allocator);
    defer mem_pty.deinit();

    var state = try session.Session.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 8,
        .pty = mem_pty.pty(),
    });
    defer state.deinit();

    const handle: SessionHandle = @ptrCast(&state);
    sessionKickWait(handle);
    try std.testing.expectEqual(@as(u32, 1), mem_pty.kick_wait_calls);
}
