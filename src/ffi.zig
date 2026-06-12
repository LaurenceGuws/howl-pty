const std = @import("std");
const c = @import("howl_pty_c");
const pty = @import("pty.zig");
const session = @import("session.zig");

pub const SessionHandle = c.HowlPtySessionHandle;

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

fn launchConfigIn(shell_ptr: ?[*]const u8, shell_len: usize, command_ptr: ?[*]const u8, command_len: usize, start_path_ptr: ?[*]const u8, start_path_len: usize) ?pty.Launch {
    const shell = bytesIn(shell_ptr, shell_len) orelse return null;
    const command = bytesIn(command_ptr, command_len) orelse return null;
    const start_path = bytesIn(start_path_ptr, start_path_len) orelse return null;
    return .{
        .shell_path = if (shell.len == 0) null else shell,
        .command = if (command.len == 0) null else command,
        .start_path = if (start_path.len == 0) null else start_path,
    };
}

fn snapshotOut(value: session.Snapshot) c.HowlPtySnapshot {
    return .{
        .status = c.HOWL_PTY_CALL_OK,
        .cols = value.cols,
        .rows = value.rows,
        .session_status = @intFromEnum(value.status),
        .terminal_reason = if (value.terminal_reason) |reason| @intFromEnum(reason) else 0,
        .last_wait_outcome = @intFromEnum(value.last_wait_outcome),
        .resize_count = value.resize_count,
    };
}

fn outboundPumpOut(value: session.OutboundInputPump) c.HowlPtyOutboundPump {
    return .{
        .status = c.HOWL_PTY_CALL_OK,
        .had_pending = boolByte(value.had_pending),
        .has_pending = boolByte(value.has_pending),
        .wait_readable = boolByte(value.wait_readable),
        .drained = value.drained,
    };
}

fn transportPumpLimitsOut(value: session.TransportPumpLimits) c.HowlPtyTransportPumpLimits {
    return .{
        .status = c.HOWL_PTY_CALL_OK,
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

fn startStatus(err: session.StartError) i32 {
    return switch (err) {
        error.AlreadyStarted,
        error.OpenPtyFailed,
        error.ShellUnavailable,
        error.UnsupportedPlatform,
        => c.HOWL_PTY_CALL_FAILED,
    };
}

fn resizeStatus(err: error{InvalidDimensions}) i32 {
    return switch (err) {
        error.InvalidDimensions => c.HOWL_PTY_CALL_INVALID_ARGUMENT,
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
    owned.* = session.Session.init(.{
        .allocator = std.heap.c_allocator,
        .cols = cols,
        .rows = rows,
        .pending_capacity = @intCast(pending_capacity),
        .launch = launch,
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
    const owned = sessionFromHandle(handle) orelse return c.HOWL_PTY_CALL_MISSING_HANDLE;
    owned.start() catch |err| return startStatus(err);
    return c.HOWL_PTY_CALL_OK;
}

pub fn sessionStop(handle: SessionHandle) callconv(.c) void {
    const owned = sessionFromHandle(handle) orelse return;
    owned.stop();
}

pub fn sessionSnapshot(handle: SessionHandle) callconv(.c) c.HowlPtySnapshot {
    const owned = sessionFromHandle(handle) orelse return .{ .status = c.HOWL_PTY_CALL_MISSING_HANDLE, .cols = 0, .rows = 0, .session_status = 0, .terminal_reason = 0, .last_wait_outcome = 0, .reserved0 = 0, .resize_count = 0 };
    return snapshotOut(owned.snapshot());
}

pub fn sessionResize(handle: SessionHandle, cols: u16, rows: u16) callconv(.c) i32 {
    const owned = sessionFromHandle(handle) orelse return c.HOWL_PTY_CALL_MISSING_HANDLE;
    owned.resize(cols, rows) catch |err| return resizeStatus(err);
    return c.HOWL_PTY_CALL_OK;
}

pub fn sessionPublishSignal(handle: SessionHandle, signal: u8) callconv(.c) i32 {
    const owned = sessionFromHandle(handle) orelse return c.HOWL_PTY_CALL_MISSING_HANDLE;
    const typed = pty.ControlSignal.fromRaw(signal) catch return c.HOWL_PTY_CALL_INVALID_ARGUMENT;
    owned.publishControlSignal(typed) catch return c.HOWL_PTY_CALL_FAILED;
    return c.HOWL_PTY_CALL_OK;
}

pub fn sessionPublishInput(handle: SessionHandle, ptr: ?[*]const u8, len: usize) callconv(.c) i32 {
    const owned = sessionFromHandle(handle) orelse return c.HOWL_PTY_CALL_MISSING_HANDLE;
    const bytes = bytesIn(ptr, len) orelse return c.HOWL_PTY_CALL_INVALID_ARGUMENT;
    owned.publishHostInput(bytes) catch return c.HOWL_PTY_CALL_FAILED;
    return c.HOWL_PTY_CALL_OK;
}

pub fn sessionPumpOutbound(handle: SessionHandle, woke: u8) callconv(.c) c.HowlPtyOutboundPump {
    const owned = sessionFromHandle(handle) orelse return .{ .status = c.HOWL_PTY_CALL_MISSING_HANDLE, .had_pending = 0, .has_pending = 0, .wait_readable = 0, .reserved0 = 0, .drained = 0 };
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

pub fn sessionRead(handle: SessionHandle, ptr: ?[*]u8, len: usize) callconv(.c) c.HowlPtyReadResult {
    const owned = sessionFromHandle(handle) orelse return .{ .status = c.HOWL_PTY_CALL_MISSING_HANDLE, .any_read = 0, .reserved0 = 0, .reserved1 = 0, .reserved2 = 0, .bytes_read = 0 };
    const buf = bytesOut(ptr, len) orelse return .{ .status = c.HOWL_PTY_CALL_INVALID_ARGUMENT, .any_read = 0, .reserved0 = 0, .reserved1 = 0, .reserved2 = 0, .bytes_read = 0 };
    const n = owned.readTransport(buf);
    return .{
        .status = c.HOWL_PTY_CALL_OK,
        .any_read = boolByte(n != 0),
        .bytes_read = n,
    };
}

pub fn transportPumpLimits(mode: u8) callconv(.c) c.HowlPtyTransportPumpLimits {
    const typed = transportPumpModeIn(mode) orelse return .{ .status = c.HOWL_PTY_CALL_INVALID_ARGUMENT, .chunk_bytes = 0, .max_reads = 0, .max_bytes = 0 };
    return transportPumpLimitsOut(session.Session.transportPumpLimits(typed));
}
