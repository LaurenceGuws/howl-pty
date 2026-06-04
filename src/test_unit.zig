const std = @import("std");

test {
    std.testing.refAllDecls(@import("libhowl_pty.zig"));
    _ = @import("session_test.zig");
    _ = @import("pty_test.zig");
    _ = @import("pty/posix_test.zig");
}
