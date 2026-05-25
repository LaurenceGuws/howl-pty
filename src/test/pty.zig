const builtin = @import("builtin");
const std = @import("std");
const pty_api = @import("../pty.zig");
const pty = @import("../pty/pty_test.zig");
const posix_pty = @import("../pty/posix.zig");

const real_pty_timeout_ms: i32 = 100;
const real_pty_max_turns: u32 = 50;

fn requireOwnedUnixPty() !void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
        return error.SkipZigTest;
    }
}

fn trimTransportLine(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, "\r\n \t");
}

fn readOwnedTransportLine(transport: pty_api.Pty, line_buf: []u8) ![]const u8 {
    var filled: usize = 0;
    var turns: u32 = 0;
    while (turns < real_pty_max_turns) : (turns += 1) {
        if (filled == line_buf.len) return error.TestBufferFull;
        const outcome = try transport.waitReadable(real_pty_timeout_ms);
        switch (outcome) {
            .timeout => continue,
            .wake => return error.UnexpectedWake,
            .ready => {
                const read_count = try transport.read(line_buf[filled..]);
                try std.testing.expect(read_count > 0);
                filled += read_count;
                if (std.mem.indexOfScalar(u8, line_buf[0..filled], '\n') != null) break;
            },
        }
    }

    const line_end = std.mem.indexOfScalar(u8, line_buf[0..filled], '\n') orelse return error.TestTimeout;
    return trimTransportLine(line_buf[0..line_end]);
}

fn waitForOwnedTransportNotStarted(transport: pty_api.Pty) !void {
    var turns: u32 = 0;
    while (turns < real_pty_max_turns) : (turns += 1) {
        const outcome = transport.waitReadable(real_pty_timeout_ms) catch |err| switch (err) {
            error.NotStarted => return,
            else => return err,
        };
        switch (outcome) {
            .ready => {
                var scratch: [128]u8 = undefined;
                _ = transport.read(scratch[0..]) catch |err| switch (err) {
                    error.NotStarted => return,
                    error.EndOfStream => {},
                    else => return err,
                };
            },
            .timeout, .wake => {},
        }
    }
    return error.TestTimeout;
}

test "pty control signals stay typed across the interface" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();

    try mem_pty.pty().start(80, 24);
    defer mem_pty.pty().stop();

    mem_pty.pty().control(.terminate);
    try std.testing.expectEqual(pty_api.ControlSignal.terminate, mem_pty.last_signal.?);
}

test "pty doubles share resize and write semantics through the interface" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();
    try mem_pty.pty().start(80, 24);
    defer mem_pty.pty().stop();

    try mem_pty.pty().resize(132, 43);
    try std.testing.expectEqual(@as(u16, 132), mem_pty.last_cols);
    try std.testing.expectEqual(@as(u16, 43), mem_pty.last_rows);

    const bytes = "hello";
    try std.testing.expectEqual(bytes.len, try mem_pty.pty().write(bytes));
    try std.testing.expectEqualStrings(bytes, mem_pty.tx.items);
}

test "partial pty preserves partial-write semantics through the interface" {
    const allocator = std.testing.allocator;

    var partial = pty.Partial.init(allocator, 2);
    defer partial.deinit();
    try partial.pty().start(80, 24);
    defer partial.pty().stop();

    try std.testing.expectEqual(@as(usize, 2), try partial.pty().write("abcd"));
    try std.testing.expectEqualStrings("ab", partial.tx.items);
}

test "fail pty surfaces transport errors instead of swallowing them" {
    var fail_pty = pty.Fail.init();
    defer fail_pty.deinit();
    var buf = [_]u8{0};

    try std.testing.expectError(error.OpenPtyFailed, fail_pty.pty().start(80, 24));
    try std.testing.expectError(error.WriteFailed, fail_pty.pty().write("x"));
    try std.testing.expectError(error.ReadFailed, fail_pty.pty().read(buf[0..]));
    try std.testing.expectError(error.WaitFailed, fail_pty.pty().waitReadable(1));
    try std.testing.expectError(error.ResizeFailed, fail_pty.pty().resize(1, 1));
}

test "mem pty distinguishes timeout from readable through the interface" {
    const allocator = std.testing.allocator;

    var mem_pty = pty.Mem.init(allocator);
    defer mem_pty.deinit();
    try mem_pty.pty().start(80, 24);
    defer mem_pty.pty().stop();

    try std.testing.expectEqual(pty_api.Pty.WaitReadableResult.timeout, try mem_pty.pty().waitReadable(1));
    try mem_pty.rx.appendSlice(allocator, "x");
    try std.testing.expectEqual(pty_api.Pty.WaitReadableResult.ready, try mem_pty.pty().waitReadable(1));
}

test "owned unix pty stop reaps the child group and remains idempotent" {
    try requireOwnedUnixPty();

    var owned = try pty_api.Owned.init(
        std.testing.allocator,
        "/bin/sh",
        "sleep 30 & printf '%s\\n' \"$!\"; wait",
        null,
    );
    defer owned.deinit();

    const transport = owned.pty();
    try transport.start(80, 24);

    var buf: [128]u8 = undefined;
    var filled: usize = 0;
    while (std.mem.indexOfScalar(u8, buf[0..filled], '\n') == null) {
        try std.testing.expectEqual(pty_api.Pty.WaitReadableResult.ready, try transport.waitReadable(1_000));
        filled += try transport.read(buf[filled..]);
        try std.testing.expect(filled < buf.len);
    }

    const line_end = std.mem.indexOfScalar(u8, buf[0..filled], '\n').?;
    const line = std.mem.trim(u8, buf[0..line_end], "\r \t");
    const background_pid = try std.fmt.parseInt(i32, line, 10);

    transport.stop();
    transport.stop();

    const kill_result = posix_pty.c.kill(background_pid, 0);
    try std.testing.expectEqual(@as(@TypeOf(kill_result), -1), kill_result);
    try std.testing.expectEqual(std.posix.E.SRCH, std.posix.errno(kill_result));
}

test "owned unix pty natural exit becomes not started" {
    try requireOwnedUnixPty();

    var owned = try pty_api.Owned.init(
        std.testing.allocator,
        "/bin/sh",
        "sleep 0.05",
        null,
    );
    defer owned.deinit();

    const transport = owned.pty();
    try transport.start(80, 24);
    try waitForOwnedTransportNotStarted(transport);

    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.NotStarted, transport.read(buf[0..]));
    try std.testing.expectError(error.NotStarted, transport.resize(100, 40));
    transport.stop();
    transport.stop();
}

test "owned unix pty routes interrupt to the child and then exits naturally" {
    try requireOwnedUnixPty();

    var owned = try pty_api.Owned.init(
        std.testing.allocator,
        "/bin/sh",
        "trap \"printf 'caught\\n'; sleep 0.2; exit 0\" INT; printf 'ready\\n'; while :; do sleep 1; done",
        null,
    );
    defer owned.deinit();

    const transport = owned.pty();
    try transport.start(80, 24);

    var line_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("ready", try readOwnedTransportLine(transport, line_buf[0..]));

    transport.control(.interrupt);
    try std.testing.expectEqualStrings("caught", try readOwnedTransportLine(transport, line_buf[0..]));

    try waitForOwnedTransportNotStarted(transport);
    transport.stop();
}
