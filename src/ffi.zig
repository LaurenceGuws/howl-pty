
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

fn boolByte(value: bool) u8 {
    return if (value) 1 else 0;
}

fn sessionFromHandle(handle: SessionHandle) ?*session.Session {
    const raw = handle orelse return null;
    return @alignCast(@ptrCast(raw));
}

fn bytesIn(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (ptr == null) {
        if (len != 0) return null;
        return &.{};
    }
    return ptr.?[0..len];
}

fn bytesOut(ptr: ?[*]u8, len: usize) ?[]u8 {
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
) ?pty.LaunchConfig {
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
    const owned = std.heap.c_allocator.create(session.Session) catch return null;
    owned.* = session.Session.initPty(.{
        .allocator = std.heap.c_allocator,
        .cols = cols,
        .rows = rows,
        .pending_capacity = pending_capacity,
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
    return owned.pending.items.len;
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
    var mem_pty = pty.Mem.init(allocator);
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
        sessionPublishSignal(handle, @intFromEnum(pty.ControlSignal.interrupt)),
    );
    try std.testing.expectEqual(pty.ControlSignal.interrupt, mem_pty.last_signal.?);
    try std.testing.expectEqual(
        @as(i32, @intFromEnum(HowlPtyCallStatus.invalid_argument)),
        sessionPublishSignal(handle, 0),
    );
}
