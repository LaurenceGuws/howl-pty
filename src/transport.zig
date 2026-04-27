//! Responsibility: publish transport interface and concrete implementations.
//! Ownership: transport facade exports.
//! Reason: keep transport imports stable for hosts and tests.

const std = @import("std");
const builtin = @import("builtin");
const _interface = @import("transport/interface.zig");
const _mem = @import("transport/mem.zig");
const _fail = @import("transport/fail.zig");
const _android_pty = @import("transport/android_pty.zig");
const _runtime = @import("transport/runtime_variant.zig");

const _unix_pty = if (builtin.os.tag == .linux or builtin.os.tag == .macos)
    @import("transport/unix_pty.zig")
else
    struct {
        /// Placeholder PTY transport type for unsupported target platforms.
        pub const UnixPtyTransport = struct {
            allocator: std.mem.Allocator,

            /// Creates a placeholder PTY transport on unsupported platforms.
            pub fn init(allocator: std.mem.Allocator, shell_path: []const u8, command: ?[]const u8) !@This() {
                _ = shell_path;
                _ = command;
                return .{ .allocator = allocator };
            }

            /// Placeholder deinitializer for unsupported platforms.
            pub fn deinit(self: *@This()) void {
                _ = self;
            }

            /// Placeholder transport accessor for unsupported platforms.
            pub fn transport(self: *@This()) Transport {
                return .{
                    .ptr = self,
                    .vtable = &.{
                        .start = startImpl,
                        .stop = stopImpl,
                        .write = writeImpl,
                        .read = readImpl,
                        .resize = resizeImpl,
                        .control = controlImpl,
                    },
                };
            }

            fn startImpl(ptr: *anyopaque) anyerror!void {
                _ = ptr;
                return error.UnsupportedPlatform;
            }
            fn stopImpl(ptr: *anyopaque) void {
                _ = ptr;
            }
            fn writeImpl(ptr: *anyopaque, bytes: []const u8) anyerror!usize {
                _ = ptr;
                _ = bytes;
                return error.UnsupportedPlatform;
            }
            fn readImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
                _ = ptr;
                _ = buf;
                return error.UnsupportedPlatform;
            }
            fn resizeImpl(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
                _ = ptr;
                _ = cols;
                _ = rows;
                return error.UnsupportedPlatform;
            }
            fn controlImpl(ptr: *anyopaque, signal: _interface.ControlSignal) void {
                _ = ptr;
                _ = signal;
            }
        };
    };

/// Transport contract wrapper.
pub const Transport = _interface.Transport;
/// In-memory deterministic transport implementation.
pub const MemTransport = _mem.MemTransport;
/// Partial-write deterministic transport implementation.
pub const PartialTransport = _mem.PartialTransport;
/// Always-failing deterministic transport implementation.
pub const FailTransport = _fail.FailTransport;
/// Android PTY transport implementation.
pub const AndroidPtyTransport = _android_pty.AndroidPtyTransport;
/// POSIX PTY transport implementation.
pub const UnixPtyTransport = _unix_pty.UnixPtyTransport;
/// Runtime transport selected by compile-time session lane.
pub const RuntimeTransport = _runtime.RuntimeTransport;
/// Runtime transport class selected by compile-time session lane.
pub const runtime_transport_class = _runtime.runtime_transport_class;
/// Runtime transport constructor selected by compile-time session lane.
pub const initRuntimeTransport = _runtime.initRuntimeTransport;

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
