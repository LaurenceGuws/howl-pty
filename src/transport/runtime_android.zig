//! Responsibility: bind runtime transport to Android PTY implementation.
//! Ownership: compile-time runtime lane selection for Android hosts.
//! Reason: keep host integrations on one stable runtime transport symbol.

const types = @import("../types.zig");
const android_pty = @import("android_pty.zig");
const std = @import("std");
const builtin = @import("builtin");

/// Runtime transport type for Android hosts.
pub const RuntimeTransport = android_pty.AndroidPtyTransport;
/// Runtime transport class identifier for this lane.
pub const runtime_transport_class = types.TransportClass.android_pty;

/// Initialize runtime transport using lane-stable arguments.
pub fn initRuntimeTransport(allocator: std.mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !RuntimeTransport {
    const default_shell = if (builtin.target.abi == .android) "/system/bin/sh" else "/bin/sh";
    return RuntimeTransport.init(allocator, shell_path orelse default_shell, command);
}
