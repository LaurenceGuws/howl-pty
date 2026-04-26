//! Responsibility: implement session resize and control operations.
//! Ownership: resize and control signal behavior.
//! Reason: isolate dimension/signal management from other behaviors.

const vt_core = @import("vt_core");
const core = @import("core.zig");
const Session = core.Session;
const ControlSignal = core.ControlSignal;

/// Resize session dimensions and recreate backing engine.
pub fn resize(self: *Session, cols: u16, rows: u16) anyerror!void {
    if (cols == 0 or rows == 0) {
        self.ops.resize_invalid_calls += 1;
        return error.InvalidDimensions;
    }

    const new_engine = try vt_core.runtime.Engine.initWithCells(self.allocator, rows, cols);

    var old_engine = self.engine;
    self.engine = new_engine;
    old_engine.deinit();

    self.cols = cols;
    self.rows = rows;
    self.resize_count +%= 1;
    self.ops.resize_valid_calls += 1;

    if (self.transport) |t| t.resize(cols, rows) catch |err| {
        self.ops.resize_transport_errors += 1;
        return err;
    };
}

/// Send control signal and record last sent value.
pub fn control(self: *Session, signal: ControlSignal) void {
    self.ops.control_calls += 1;
    self.last_control_signal = signal;
    if (self.transport) |t| t.control(signal);
}
