//! Responsibility: define reliability test constants and expected counters.
//! Ownership: reliability evidence support.
//! Reason: keep cycle-based reliability assertions consistent.

pub const CYCLES: u32 = 1000;
pub const WARMUP_CYCLES: u32 = 10;

pub fn expectedResizeCountAfterCycles(initial: u32, cycles: u32) u32 {
    return initial +% cycles;
}
