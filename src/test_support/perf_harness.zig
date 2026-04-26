//! Responsibility: provide deterministic test-only performance sampling helpers.
//! Ownership: performance evidence support.
//! Reason: standardize warmup/measure loops in perf tests.

const std = @import("std");

pub const WARMUP_ITERS: u32 = 10;
pub const MEASURE_ITERS: u32 = 100;

pub fn PerfSampler(comptime N: u32) type {
    return struct {
        samples: [N]u64,
        count: usize,

        const Self = @This();

        pub fn init() Self {
            return .{ .samples = undefined, .count = 0 };
        }

        pub fn record(self: *Self, ns: u64) void {
            if (self.count < N) {
                self.samples[self.count] = ns;
                self.count += 1;
            }
        }

        pub fn min(self: *const Self) u64 {
            var m = std.math.maxInt(u64);
            for (self.samples[0..self.count]) |s| if (s < m) {
                m = s;
            };
            return if (self.count > 0) m else 0;
        }

        pub fn max(self: *const Self) u64 {
            var m: u64 = 0;
            for (self.samples[0..self.count]) |s| if (s > m) {
                m = s;
            };
            return m;
        }

        pub fn median(self: *Self) u64 {
            if (self.count == 0) return 0;
            const s = self.samples[0..self.count];
            std.mem.sort(u64, s, {}, std.sort.asc(u64));
            return s[self.count / 2];
        }
    };
}

pub const PerfTimer = struct {
    timer: std.time.Timer,

    pub fn start() !PerfTimer {
        return .{ .timer = try std.time.Timer.start() };
    }

    pub fn lapNs(self: *PerfTimer) u64 {
        return self.timer.lap();
    }
};
