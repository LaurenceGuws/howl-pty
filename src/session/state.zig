//! Responsibility: define session operations counter type.
//! Ownership: SessionOps counter structure for observability.
//! Reason: centralize counter definitions to avoid duplication.

const std = @import("std");

/// Session operations counters.
pub const SessionOps = struct {
    start_attempts: u32,
    start_successes: u32,
    start_failures: u32,
    stop_calls: u32,
    feed_accepted: u32,
    feed_rejected: u32,
    bytes_fed: u64,
    bytes_applied: u64,
    apply_calls: u32,
    apply_transport_write_errors: u32,
    reset_calls: u32,
    resize_valid_calls: u32,
    resize_invalid_calls: u32,
    resize_transport_errors: u32,
    control_calls: u32,
};
