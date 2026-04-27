//! Responsibility: bind runtime transport to Unix PTY implementation.
//! Ownership: compile-time runtime lane selection for Unix hosts.
//! Reason: keep host integrations on one stable runtime transport symbol.

const types = @import("../types.zig");
const unix_pty = @import("unix_pty.zig");
const std = @import("std");

/// Runtime transport type for Unix hosts.
pub const RuntimeTransport = unix_pty.UnixPtyTransport;
/// Runtime transport class identifier for this lane.
pub const runtime_transport_class = types.TransportClass.posix_pty;

/// Initialize runtime transport using lane-stable arguments.
pub fn initRuntimeTransport(allocator: std.mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !RuntimeTransport {
    return RuntimeTransport.init(allocator, shell_path orelse "/bin/sh", command);
}
