//! Responsibility: expose the selected runtime transport implementation.
//! Ownership: compile-time transport lane binding for host consumers.
//! Reason: let hosts consume one runtime transport symbol per build lane.

const build_options = @import("build_options");
const std = @import("std");
const impl = switch (build_options.transport_variant) {
    .unix_pty => @import("runtime_unix.zig"),
    .android_pty => @import("runtime_android.zig"),
};

/// Runtime transport type selected by build option.
pub const RuntimeTransport = impl.RuntimeTransport;
/// Runtime transport class selected by build option.
pub const runtime_transport_class = impl.runtime_transport_class;

/// Initialize runtime transport with lane-stable arguments.
pub fn initRuntimeTransport(allocator: std.mem.Allocator, shell_path: ?[]const u8, command: ?[]const u8) !RuntimeTransport {
    return impl.initRuntimeTransport(allocator, shell_path, command);
}
