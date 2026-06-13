const std = @import("std");

test {
    std.testing.refAllDecls(@import("../src/libhowl_pty.zig"));
    _ = @import("unit/session_test.zig");
    _ = @import("unit/pty_test.zig");
    _ = @import("unit/pty/posix_test.zig");
}
