const std = @import("std");
const root = @import("../root.zig");

test "api exports compile" {
    _ = root.Session;
    _ = root.SessionConfig;
    _ = root.SessionStatus;
    _ = root.TransportClass;
    _ = root.Transport;
    _ = root.MemTransport;
    _ = root.PartialTransport;
    _ = root.FailTransport;
    _ = root.AndroidPtyTransport;
    _ = root.UnixPtyTransport;
    _ = root.transport_class;
    _ = root.initTransport;
    _ = root.HostLoopTick;
}

test "session method surface" {
    comptime {
        _ = root.Session.init;
        _ = root.Session.deinit;
        _ = root.Session.start;
        _ = root.Session.stop;
        _ = root.Session.feed;
        _ = root.Session.apply;
        _ = root.Session.reset;
        _ = root.Session.resize;
        _ = root.Session.snapshot;
        _ = root.Session.restore;
        std.debug.assert(@hasField(root.Session, "cols"));
        std.debug.assert(@hasField(root.Session, "rows"));
        std.debug.assert(@hasField(root.Session, "status"));
    }
}
