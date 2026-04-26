//! Responsibility: provide deterministic test-only performance sampling helpers.
//! Ownership: performance evidence support.
//! Reason: standardize warmup/measure loops in perf tests.

const std = @import("std");

/// Number of iterations used to warm up performance measurements.
pub const WARMUP_ITERS: u32 = 10;
/// Number of iterations captured for performance measurements.
pub const MEASURE_ITERS: u32 = 100;

/// Collects bounded timing samples and computes summary statistics.
pub fn PerfSampler(comptime N: u32) type {
    return struct {
        samples: [N]u64,
        count: usize,

        const Self = @This();

        /// Creates an empty sampler with zero recorded measurements.
        pub fn init() Self {
            return .{ .samples = undefined, .count = 0 };
        }

        /// Stores one timing sample until the sampler reaches capacity.
        pub fn record(self: *Self, ns: u64) void {
            if (self.count < N) {
                self.samples[self.count] = ns;
                self.count += 1;
            }
        }

        /// Returns the smallest recorded sample, or zero when empty.
        pub fn min(self: *const Self) u64 {
            var m = std.math.maxInt(u64);
            for (self.samples[0..self.count]) |s| if (s < m) {
                m = s;
            };
            return if (self.count > 0) m else 0;
        }

        /// Returns the largest recorded sample, or zero when empty.
        pub fn max(self: *const Self) u64 {
            var m: u64 = 0;
            for (self.samples[0..self.count]) |s| if (s > m) {
                m = s;
            };
            return m;
        }

        /// Sorts recorded samples in place and returns the middle value.
        pub fn median(self: *Self) u64 {
            if (self.count == 0) return 0;
            const s = self.samples[0..self.count];
            std.mem.sort(u64, s, {}, std.sort.asc(u64));
            return s[self.count / 2];
        }
    };
}

/// Wrapper around `std.time.Timer` for measuring elapsed nanoseconds.
pub const PerfTimer = struct {
    timer: std.time.Timer,

    /// Starts a monotonic timer for later lap measurements.
    pub fn start() !PerfTimer {
        return .{ .timer = try std.time.Timer.start() };
    }

    /// Returns the elapsed nanoseconds since the previous lap or start.
    pub fn lapNs(self: *PerfTimer) u64 {
        return self.timer.lap();
    }
};
