//! Curates the native PTY transport and session model.

const pty = @import("pty.zig");
const session = @import("session.zig");

pub const ControlSignal = pty.ControlSignal;
pub const Launch = pty.Launch;
pub const Owned = pty.Owned;
pub const Pty = pty.Pty;
pub const Session = session;

test {
    _ = pty;
    _ = session;
}
