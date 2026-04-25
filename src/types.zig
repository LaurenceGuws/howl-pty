pub const ControlSignal = enum {
    hangup,
    interrupt,
    terminate,
    resize_notify,
};

pub const SessionStatus = enum {
    idle,
    active,
    stopped,
};

pub const TransportClass = enum {
    /// POSIX PTY transport for Linux and macOS hosts.
    /// Uses fork(), openpty(), and POSIX process control (signals, ioctl).
    posix_pty,
    /// Container bridge transport for Android, iOS, and platform-managed containers.
    /// Routes I/O through platform container/process bridge services.
    container_bridge,
    /// ConPTY transport for Windows hosts (future).
    /// Uses Windows ConPTY API and Windows process management.
    conpty,
};
