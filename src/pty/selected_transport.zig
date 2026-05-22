const std = @import("std");
const builtin = @import("builtin");
const session_options = @import("session_options");
const platform = @import("pty_platform.zig");
const unix = @import("pty_unix.zig");
const android = @import("pty_android.zig");

const SelectedTransport = switch (session_options.pty_variant) {
    .unix_pty => unix.UnixPty,
    .android_pty => android.AndroidPty,
};

/// Child process launch inputs for the build-selected PTY owner.
pub const LaunchConfig = struct {
    /// Executable path to launch. Defaults to the platform shell when omitted.
    shell_path: ?[]const u8 = null,
    /// Optional command passed to the shell as its command string.
    command: ?[]const u8 = null,
    /// Optional child process working directory applied before exec.
    start_path: ?[]const u8 = null,
};

fn createSelectedTransport(allocator: std.mem.Allocator, launch: LaunchConfig) !SelectedTransport {
    return switch (session_options.pty_variant) {
        .unix_pty => SelectedTransport.init(allocator, launch.shell_path orelse "/bin/sh", launch.command, launch.start_path),
        .android_pty => SelectedTransport.init(allocator, launch.shell_path orelse (if (builtin.target.abi == .android) "/system/bin/sh" else "/bin/sh"), launch.command, launch.start_path),
    };
}

/// Build-selected PTY owner kept behind Session.
pub const OwnedTransport = struct {
    transport: SelectedTransport,

    pub fn init(allocator: std.mem.Allocator, launch: LaunchConfig) !OwnedTransport {
        return .{ .transport = try createSelectedTransport(allocator, launch) };
    }

    pub fn deinit(self: *OwnedTransport) void {
        self.transport.deinit();
    }

    pub fn pty(self: *OwnedTransport) platform.Pty {
        return self.transport.pty();
    }
};
