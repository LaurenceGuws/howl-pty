//! Responsibility: define shared session domain enums.
//! Ownership: common types used by session and transport APIs.
//! Reason: avoid type duplication across module boundaries.

/// Session lifecycle status.
pub const SessionStatus = enum {
    idle,
    active,
    stopped,
};

/// Transport portability class used for host-level selection.
pub const TransportClass = enum {
    /// POSIX PTY transport for Linux and macOS hosts.
    /// Uses fork(), openpty(), and POSIX process control (signals, ioctl).
    posix_pty,
    /// Android PTY transport for Android hosts.
    /// Routes I/O through Android shell PTY
    android_pty,
    /// ConPTY transport for Windows hosts (future).
    /// Uses Windows ConPTY API and Windows process management.
    conpty,
};
