const std = @import("std");
const pty = @import("pty.zig");
const session = @import("session.zig");

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
    terminal_reason: u8 = 0,
    last_wait_outcome: u8 = 0,
    reserved0: u8 = 0,
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

fn snapshotOut(value: session.Snapshot) FfiSnapshot {
    return .{
        .status = @intFromEnum(HowlPtyCallStatus.ok),
        .cols = value.cols,
        .rows = value.rows,
        .session_status = @intFromEnum(value.status),
        .terminal_reason = if (value.terminal_reason) |reason| @intFromEnum(reason) else 0,
        .last_wait_outcome = @intFromEnum(value.last_wait_outcome),
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

fn startStatus(err: session.StartError) i32 {
    return switch (err) {
        error.AlreadyStarted,
        error.OpenPtyFailed,
        error.ShellUnavailable,
        error.UnsupportedPlatform,
        => @intFromEnum(HowlPtyCallStatus.failed),
    };
}

fn resizeStatus(err: error{InvalidDimensions}) i32 {
    return switch (err) {
        error.InvalidDimensions => @intFromEnum(HowlPtyCallStatus.invalid_argument),
    };
}

pub fn sessionInit(shell_ptr: ?[*]const u8, shell_len: usize, command_ptr: ?[*]const u8, command_len: usize, start_path_ptr: ?[*]const u8, start_path_len: usize, cols: u16, rows: u16, pending_capacity: usize) callconv(.c) SessionHandle {
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
    const owned = sessionFromHandle(handle) orelse return @intFromEnum(HowlPtyCallStatus.missing_handle);
    owned.start() catch |err| return startStatus(err);
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
    owned.resize(cols, rows) catch |err| return resizeStatus(err);
    return @intFromEnum(HowlPtyCallStatus.ok);
}

pub fn sessionPublishSignal(handle: SessionHandle, signal: u8) callconv(.c) i32 {
    const owned = sessionFromHandle(handle) orelse return @intFromEnum(HowlPtyCallStatus.missing_handle);
    const typed = pty.ControlSignal.fromRaw(signal) catch return @intFromEnum(HowlPtyCallStatus.invalid_argument);
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
