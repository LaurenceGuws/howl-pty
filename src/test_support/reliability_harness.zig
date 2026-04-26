//! Responsibility: define reliability test constants and expected counters.
//! Ownership: reliability evidence support.
//! Reason: keep cycle-based reliability assertions consistent.

/// Number of cycles used by reliability tests.
pub const CYCLES: u32 = 1000;
/// Number of cycles used to warm reliability tests before measurement.
pub const WARMUP_CYCLES: u32 = 10;

/// Computes the expected resize counter after a fixed number of cycles.
pub fn expectedResizeCountAfterCycles(initial: u32, cycles: u32) u32 {
    return initial +% cycles;
}
