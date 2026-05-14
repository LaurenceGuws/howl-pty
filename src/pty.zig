
const std = @import("std");
const builtin = @import("builtin");
const session_options = @import("session_options");
const platform = @import("pty/pty_platform.zig");
const doubles = @import("pty/pty_test.zig");
const unix = @import("pty/pty_unix.zig");
const android = @import("pty/pty_android.zig");

const PtyImpl = switch (session_options.pty_variant) {
    .unix_pty => unix.UnixPty,
    .android_pty => android.AndroidPty,
};

const selected_pty_class = switch (session_options.pty_variant) {
    .unix_pty => platform.PtyClass.posix_pty,
    .android_pty => platform.PtyClass.android_pty,
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

fn initPtyImpl(allocator: std.mem.Allocator, launch: LaunchConfig) !PtyImpl {
    return switch (session_options.pty_variant) {
        .unix_pty => PtyImpl.init(allocator, launch.shell_path orelse "/bin/sh", launch.command, launch.start_path),
        .android_pty => PtyImpl.init(allocator, launch.shell_path orelse (if (builtin.target.abi == .android) "/system/bin/sh" else "/bin/sh"), launch.command, launch.start_path),
    };
}

const SelectedPtyImpl = PtyImpl;
const SelectedPtyClass = selected_pty_class;

/// Build-selected PTY owner that keeps the concrete transport behind a boring surface.
pub const OwnedPty = struct {
    impl: SelectedPtyImpl,

    /// Construct the build-selected PTY owner.
    pub fn init(allocator: std.mem.Allocator, launch: LaunchConfig) !OwnedPty {
        return .{ .impl = try initPtyImpl(allocator, launch) };
    }

    /// Release the owned PTY transport.
    pub fn deinit(self: *OwnedPty) void {
        self.impl.deinit();
    }

    /// Expose the session-facing PTY transport interface.
    pub fn pty(self: *OwnedPty) platform.Pty {
        return self.impl.pty();
    }

    /// Report the build-selected PTY class.
    pub fn class(_: OwnedPty) platform.PtyClass {
        return SelectedPtyClass;
    }
};

/// Session-facing PTY interface.
pub const Pty = platform.Pty;
pub const PtyClass = platform.PtyClass;
pub const ControlSignal = platform.ControlSignal;

// test variants
pub const Mem = doubles.Mem;
pub const Partial = doubles.Partial;
pub const Fail = doubles.Fail;

/// Build-selected PTY class value.
pub const pty_class = SelectedPtyClass;
