//! Responsibility: expose the session facade and stable aliases.
//! Ownership: facade layer over session core and shared types.
//! Reason: preserve a small host-facing import surface.

const _core = @import("session/core.zig");
const _snapshot_restore = @import("session/snapshot_restore.zig");
const _ops_counters = @import("session/ops_counters.zig");
const types = @import("types.zig");

/// Control signal enum used by session and transport boundaries.
pub const ControlSignal = _core.ControlSignal;
/// Session lifecycle status enum.
pub const SessionStatus = _core.SessionStatus;
/// Transport portability class enum.
pub const TransportClass = types.TransportClass;
/// Transport api wrapper type.
pub const Transport = _core.Transport;
/// Session configuration type.
pub const Config = _core.Config;
/// Snapshot payload type.
pub const SessionSnapshot = _core.SessionSnapshot;
/// Operations counter payload type.
pub const SessionOps = _core.SessionOps;
/// Session runtime type.
pub const Session = _core.Session;
