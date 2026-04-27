//! Responsibility: bind runtime transport to container implementation.
//! Ownership: compile-time runtime lane selection for Android/container hosts.
//! Reason: keep host integrations on one stable runtime transport symbol.

const types = @import("../types.zig");
const container = @import("container_transport.zig");

/// Runtime transport type for container-managed hosts.
pub const RuntimeTransport = container.ContainerTransport;
/// Runtime transport class identifier for this lane.
pub const runtime_transport_class = types.TransportClass.container_bridge;
