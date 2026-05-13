//! Responsibility: implement the howl-pty native ABI surface.
//! Ownership: PTY session handles, lifecycle, transport progress, and typed constants.
//! Reason: keep hosts on a C ABI seam instead of Zig owner imports.

const std = @import("std");
const pty = @import("pty.zig");
const session = @import("session.zig");

pub const SessionHandle = usize;

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

fn statusByte(status: session.Status) u8 {
    return @intFromEnum(status);
}

fn statusFromByte(status: u8) ?session.Status {
    return switch (status) {
        statusByte(.idle) => .idle,
        statusByte(.active) => .active,
        statusByte(.stopped) => .stopped,
        else => null,
    };
}

fn sessionFromHandle(handle: SessionHandle) ?*session.Session {
    if (handle == 0) return null;
    return @ptrFromInt(handle);
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

pub fn modUnused() callconv(.c) void {}

pub fn statusIdle() callconv(.c) u8 {
    return statusByte(.idle);
}

pub fn statusActive() callconv(.c) u8 {
    return statusByte(.active);
}

pub fn statusStopped() callconv(.c) u8 {
    return statusByte(.stopped);
}

pub fn statusIsValid(status: u8) callconv(.c) u8 {
    return boolByte(statusFromByte(status) != null);
}

pub fn statusIsActive(status: u8) callconv(.c) u8 {
    const typed = statusFromByte(status) orelse return 0;
    return boolByte(typed == .active);
}

pub fn controlSignalHangup() callconv(.c) u8 {
    return pty.ControlSignal.hangup.raw();
}

pub fn controlSignalInterrupt() callconv(.c) u8 {
    return pty.ControlSignal.interrupt.raw();
}

pub fn controlSignalResizeNotify() callconv(.c) u8 {
    return pty.ControlSignal.resize_notify.raw();
}

pub fn controlSignalKill() callconv(.c) u8 {
    return pty.ControlSignal.kill.raw();
}

pub fn controlSignalTerminate() callconv(.c) u8 {
    return pty.ControlSignal.terminate.raw();
}

pub fn controlSignalIsValid(signal: u8) callconv(.c) u8 {
    _ = pty.ControlSignal.fromRaw(signal) catch return 0;
    return 1;
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
    const launch = launchConfigIn(shell_ptr, shell_len, command_ptr, command_len, start_path_ptr, start_path_len) orelse return 0;
    const owned = std.heap.c_allocator.create(session.Session) catch return 0;
    owned.* = session.Session.initPty(.{
        .allocator = std.heap.c_allocator,
        .cols = cols,
        .rows = rows,
        .pending_capacity = pending_capacity,
        .launch = launch,
    }) catch {
        std.heap.c_allocator.destroy(owned);
        return 0;
    };
    return @intFromPtr(owned);
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

pub fn sessionIsActive(handle: SessionHandle) callconv(.c) u8 {
    const owned = sessionFromHandle(handle) orelse return 0;
    return boolByte(owned.isActive());
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

pub fn sessionPublishInput(handle: SessionHandle, ptr: ?[*]const u8, len: usize) callconv(.c) i32 {
    const owned = sessionFromHandle(handle) orelse return @intFromEnum(HowlPtyCallStatus.missing_handle);
    const bytes = bytesIn(ptr, len) orelse return @intFromEnum(HowlPtyCallStatus.invalid_argument);
    owned.publishHostInput(bytes) catch return @intFromEnum(HowlPtyCallStatus.failed);
    return @intFromEnum(HowlPtyCallStatus.ok);
}

pub fn sessionPublishInputAndPump(handle: SessionHandle, ptr: ?[*]const u8, len: usize) callconv(.c) FfiOutboundPump {
    const owned = sessionFromHandle(handle) orelse return .{ .status = @intFromEnum(HowlPtyCallStatus.missing_handle) };
    const bytes = bytesIn(ptr, len) orelse return .{ .status = @intFromEnum(HowlPtyCallStatus.invalid_argument) };
    const result = owned.publishHostInputAndPump(bytes) catch return .{ .status = @intFromEnum(HowlPtyCallStatus.failed) };
    return outboundPumpOut(result);
}

pub fn sessionPumpOutbound(handle: SessionHandle, woke: u8) callconv(.c) FfiOutboundPump {
    const owned = sessionFromHandle(handle) orelse return .{ .status = @intFromEnum(HowlPtyCallStatus.missing_handle) };
    return outboundPumpOut(owned.pumpOutboundInput(woke != 0));
}

pub fn sessionHasBacklog(handle: SessionHandle) callconv(.c) u8 {
    const owned = sessionFromHandle(handle) orelse return 0;
    return boolByte(owned.hasOutboundInputBacklog());
}

pub fn sessionPendingBytes(handle: SessionHandle) callconv(.c) u64 {
    const owned = sessionFromHandle(handle) orelse return 0;
    return owned.pending.items.len;
}

pub fn sessionBytesApplied(handle: SessionHandle) callconv(.c) u64 {
    const owned = sessionFromHandle(handle) orelse return 0;
    return owned.ops.bytes_applied;
}

pub fn sessionKickWait(handle: SessionHandle) callconv(.c) void {
    const owned = sessionFromHandle(handle) orelse return;
    owned.kickTransportWait();
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

test "session ffi status surface proves positive and negative space" {
    try std.testing.expectEqual(@as(u8, @intFromEnum(session.Status.idle)), statusIdle());
    try std.testing.expectEqual(@as(u8, @intFromEnum(session.Status.active)), statusActive());
    try std.testing.expectEqual(@as(u8, @intFromEnum(session.Status.stopped)), statusStopped());
    try std.testing.expectEqual(@as(u8, 1), statusIsValid(statusIdle()));
    try std.testing.expectEqual(@as(u8, 1), statusIsActive(statusActive()));
    try std.testing.expectEqual(@as(u8, 0), statusIsActive(statusStopped()));
    try std.testing.expectEqual(@as(u8, 0), statusIsValid(255));
}

test "session ffi control-signal surface proves positive and negative space" {
    try std.testing.expectEqual(pty.ControlSignal.hangup.raw(), controlSignalHangup());
    try std.testing.expectEqual(pty.ControlSignal.interrupt.raw(), controlSignalInterrupt());
    try std.testing.expectEqual(pty.ControlSignal.resize_notify.raw(), controlSignalResizeNotify());
    try std.testing.expectEqual(pty.ControlSignal.kill.raw(), controlSignalKill());
    try std.testing.expectEqual(pty.ControlSignal.terminate.raw(), controlSignalTerminate());
    try std.testing.expectEqual(@as(u8, 1), controlSignalIsValid(controlSignalTerminate()));
    try std.testing.expectEqual(@as(u8, 0), controlSignalIsValid(0));
}

test "session ffi handle path covers lifecycle and transport progress" {
    const handle = sessionInit(null, 0, null, 0, null, 0, 80, 24, 64);
    defer sessionDeinit(handle);
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i32, 0), sessionStart(handle));
    try std.testing.expectEqual(@as(u8, 1), sessionIsActive(handle));

    const pumped = sessionPublishInputAndPump(handle, "echo hi\n".ptr, "echo hi\n".len);
    try std.testing.expectEqual(@as(i32, 0), pumped.status);

    const snap = sessionSnapshot(handle);
    try std.testing.expectEqual(@as(i32, 0), snap.status);
    try std.testing.expectEqual(@as(u16, 80), snap.cols);
    try std.testing.expectEqual(@as(u16, 24), snap.rows);
}
