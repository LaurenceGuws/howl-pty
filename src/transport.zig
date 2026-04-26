//! Responsibility: publish transport interface and concrete implementations.
//! Ownership: transport facade exports.
//! Reason: keep transport imports stable for hosts and tests.

const std = @import("std");
const _interface = @import("transport/interface.zig");
const _mem = @import("transport/mem.zig");
const _fail = @import("transport/fail.zig");
const _unix_pty = @import("transport/unix_pty.zig");

/// Transport contract wrapper.
pub const Transport = _interface.Transport;
/// In-memory deterministic transport implementation.
pub const MemTransport = _mem.MemTransport;
/// Partial-write deterministic transport implementation.
pub const PartialTransport = _mem.PartialTransport;
/// Always-failing deterministic transport implementation.
pub const FailTransport = _fail.FailTransport;
/// POSIX PTY transport implementation.
pub const UnixPtyTransport = _unix_pty.UnixPtyTransport;

test "session holds transport reference" {
    const session_api = @import("session.zig");
    var mt = MemTransport.init(std.testing.allocator);
    defer mt.deinit();
    const t = mt.transport();
    var s = try session_api.Session.init(.{
        .allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .pending_capacity = 4096,
        .transport = t,
    });
    defer s.deinit();
    try std.testing.expect(s.transport != null);
}
