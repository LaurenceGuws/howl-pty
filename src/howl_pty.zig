//! Responsibility: define the repo-local howl-pty test root.
//! Ownership: include repo-local test files only.
//! Reason: keep the shipped contract and owner imports out of this root.

test {
    _ = @import("test/session.zig");
    _ = @import("test/pty.zig");
}
