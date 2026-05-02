//! Responsibility: publish pty interface, variants, and build selection.
//! Ownership: host-to-session pty boundary and implementation binding.
//! Reason: keep pty imports stable for hosts and tests in one facade.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("pty/PtyPlatform.zig");
const doubles = @import("pty/PtyTest.zig");
const unix = @import("pty/PtyUnix.zig");
const android = @import("pty/PtyAndroid.zig");

const PtyImpl = switch (build_options.pty_variant) {
    .unix_pty => unix.UnixPty,
    .android_pty => android.AndroidPty,
};

const pty_class = switch (build_options.pty_variant) {
    .unix_pty => platform.PtyClass.posix_pty,
    .android_pty => platform.PtyClass.android_pty,
};

fn initPtyImpl(allocator: std.mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !PtyImpl {
    return switch (build_options.pty_variant) {
        .unix_pty => PtyImpl.init(allocator, shell_path orelse "/bin/sh", command),
        .android_pty => PtyImpl.init(allocator, shell_path orelse (if (builtin.target.abi == .android) "/system/bin/sh" else "/bin/sh"), command),
    };
}

const SelectedPtyImpl = PtyImpl;
const SelectedPtyClass = pty_class;

pub const PtyApi = struct {
    pub const Pty = platform.Pty;
    pub const PtyClass = platform.PtyClass;

    // test variants
    pub const Mem = doubles.Mem;
    pub const Partial = doubles.Partial;
    pub const Fail = doubles.Fail;

    // platform variants
    pub const UnixPty = unix.UnixPty;
    pub const AndroidPty = android.AndroidPty;

    // build-selected transport
    pub const PtyImpl = SelectedPtyImpl;
    pub const pty_class = SelectedPtyClass;

    pub fn initPty(allocator: std.mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !SelectedPtyImpl {
        return initPtyImpl(allocator, shell_path, command);
    }
};
