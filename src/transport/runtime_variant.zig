//! Responsibility: expose the selected runtime transport implementation.
//! Ownership: compile-time transport lane binding for host consumers.
//! Reason: let hosts consume one runtime transport symbol per build lane.

const build_options = @import("build_options");
const impl = switch (build_options.transport_variant) {
    .unix_pty => @import("runtime_unix.zig"),
    .container_bridge => @import("runtime_container.zig"),
};

/// Runtime transport type selected by build option.
pub const RuntimeTransport = impl.RuntimeTransport;
/// Runtime transport class selected by build option.
pub const runtime_transport_class = impl.runtime_transport_class;
