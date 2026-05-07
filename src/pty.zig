//! Responsibility: publish pty interface, variants, and build selection.
//! Ownership: host-to-session pty boundary and implementation binding.
//! Reason: keep pty imports stable for hosts and tests in one facade.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("pty/pty_platform.zig");
const doubles = @import("pty/pty_test.zig");
const unix = @import("pty/pty_unix.zig");
const android = @import("pty/pty_android.zig");

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

/// Build-selected PTY owner that keeps the concrete transport behind a boring surface.
const OwnedPtyType = struct {
    impl: SelectedPtyImpl,

    /// Construct the build-selected PTY owner.
    pub fn init(allocator: std.mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !OwnedPtyType {
        return .{ .impl = try initPtyImpl(allocator, shell_path, command) };
    }

    /// Release the owned PTY transport.
    pub fn deinit(self: *OwnedPtyType) void {
        self.impl.deinit();
    }

    /// Expose the session-facing PTY transport interface.
    pub fn pty(self: *OwnedPtyType) platform.Pty {
        return self.impl.pty();
    }

    /// Report the build-selected PTY class.
    pub fn class(_: OwnedPtyType) platform.PtyClass {
        return SelectedPtyClass;
    }
};

/// PTY facade surface for hosts and tests.
pub const PtyApi = struct {
    pub const Pty = platform.Pty;
    pub const PtyClass = platform.PtyClass;
    pub const ControlSignal = platform.ControlSignal;
    pub const OwnedPty = OwnedPtyType;

    // test variants
    pub const Mem = doubles.Mem;
    pub const Partial = doubles.Partial;
    pub const Fail = doubles.Fail;

    /// Build-selected PTY class value.
    pub const pty_class = SelectedPtyClass;

    /// Construct the build-selected PTY owner.
    pub fn initPty(allocator: std.mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !OwnedPtyType {
        return OwnedPtyType.init(allocator, shell_path, command);
    }
};
