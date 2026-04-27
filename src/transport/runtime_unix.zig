//! Responsibility: bind runtime transport to Unix PTY implementation.
//! Ownership: compile-time runtime lane selection for Unix hosts.
//! Reason: keep host integrations on one stable runtime transport symbol.

const types = @import("../types.zig");
const unix_pty = @import("unix_pty.zig");

/// Runtime transport type for Unix hosts.
pub const RuntimeTransport = unix_pty.UnixPtyTransport;
/// Runtime transport class identifier for this lane.
pub const runtime_transport_class = types.TransportClass.posix_pty;
