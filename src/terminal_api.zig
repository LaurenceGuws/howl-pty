//! Responsibility: own terminal runtime state and render-facing frame snapshot model.
//! Ownership: session lifecycle, input handling, and frame synchronization.
//! Reason: keep host integrations on one runtime surface without leaked internals.

const std = @import("std");
const session_api = @import("session.zig");
const transport_api = @import("transport.zig");
const vt_core = @import("vt_core");

pub const ControlSignal = session_api.ControlSignal;
pub const SessionStatus = session_api.SessionStatus;
pub const TerminalKey = vt_core.model.Key;
pub const TerminalModifier = vt_core.model.Modifier;
pub const Transport = transport_api.Transport;
pub const RuntimeTransport = transport_api.RuntimeTransport;
pub const runtime_transport_class = transport_api.runtime_transport_class;
pub const initRuntimeTransport = transport_api.initRuntimeTransport;

pub const mod_none: TerminalModifier = vt_core.model.VTERM_MOD_NONE;
pub const mod_shift: TerminalModifier = vt_core.model.VTERM_MOD_SHIFT;
pub const mod_alt: TerminalModifier = vt_core.model.VTERM_MOD_ALT;
pub const mod_ctrl: TerminalModifier = vt_core.model.VTERM_MOD_CTRL;

pub const key_enter: TerminalKey = vt_core.model.VTERM_KEY_ENTER;
pub const key_tab: TerminalKey = vt_core.model.VTERM_KEY_TAB;
pub const key_backspace: TerminalKey = vt_core.model.VTERM_KEY_BACKSPACE;
pub const key_escape: TerminalKey = vt_core.model.VTERM_KEY_ESCAPE;
pub const key_up: TerminalKey = vt_core.model.VTERM_KEY_UP;
pub const key_down: TerminalKey = vt_core.model.VTERM_KEY_DOWN;
pub const key_left: TerminalKey = vt_core.model.VTERM_KEY_LEFT;
pub const key_right: TerminalKey = vt_core.model.VTERM_KEY_RIGHT;
pub const key_insert: TerminalKey = vt_core.model.VTERM_KEY_INS;
pub const key_delete: TerminalKey = vt_core.model.VTERM_KEY_DEL;
pub const key_home: TerminalKey = vt_core.model.VTERM_KEY_HOME;
pub const key_end: TerminalKey = vt_core.model.VTERM_KEY_END;
pub const key_pageup: TerminalKey = vt_core.model.VTERM_KEY_PAGEUP;
pub const key_pagedown: TerminalKey = vt_core.model.VTERM_KEY_PAGEDOWN;
pub const key_f1: TerminalKey = vt_core.model.VTERM_KEY_F1;
pub const key_f2: TerminalKey = vt_core.model.VTERM_KEY_F2;
pub const key_f3: TerminalKey = vt_core.model.VTERM_KEY_F3;
pub const key_f4: TerminalKey = vt_core.model.VTERM_KEY_F4;
pub const key_f5: TerminalKey = vt_core.model.VTERM_KEY_F5;
pub const key_f6: TerminalKey = vt_core.model.VTERM_KEY_F6;
pub const key_f7: TerminalKey = vt_core.model.VTERM_KEY_F7;
pub const key_f8: TerminalKey = vt_core.model.VTERM_KEY_F8;
pub const key_f9: TerminalKey = vt_core.model.VTERM_KEY_F9;
pub const key_f10: TerminalKey = vt_core.model.VTERM_KEY_F10;
pub const key_f11: TerminalKey = vt_core.model.VTERM_KEY_F11;
pub const key_f12: TerminalKey = vt_core.model.VTERM_KEY_F12;

pub const TerminalSurfaceState = enum {
    idle,
    running,
};

pub const Color = struct {
    pub const Kind = enum {
        default,
        indexed,
        rgb,
    };

    kind: Kind = .default,
    value: u24 = 0,
};

pub const CellFlags = packed struct {
    continuation: bool = false,
    _pad: u7 = 0,
};

pub const CellAttrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    flags: CellFlags = .{},
    fg_color: Color = .{ .kind = .default, .value = 0 },
    bg_color: Color = .{ .kind = .default, .value = 0 },
    attrs: CellAttrs = .{},
};

pub const GridModel = struct {
    cells: []const Cell,
    cols: u16,
    rows: u16,
};

pub const ViewportInfo = struct {
    cols: u16,
    rows: u16,
    scroll_row: u16 = 0,
    is_alternate_screen: bool = false,
};

pub const CursorShape = enum {
    block,
    underline,
    beam,
    hollow_block,
};

pub const CursorInfo = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
    shape: CursorShape = .block,
};

pub const FrameData = struct {
    viewport: ViewportInfo,
    grid: GridModel,
    cursor: CursorInfo,
};

pub const TerminalSurfaceConfig = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pending_capacity: usize = 4096,
    transport: ?Transport = null,
};

pub const TerminalSurface = struct {
    session: session_api.Session,
    cells: std.ArrayListUnmanaged(Cell),
    cols: u16,
    rows: u16,
    cursor: CursorInfo,
    state: TerminalSurfaceState,
    dirty: bool,

    pub fn init(config: TerminalSurfaceConfig) anyerror!TerminalSurface {
        if (config.cols == 0 or config.rows == 0) return error.InvalidDimensions;

        var session = try session_api.Session.init(.{
            .allocator = config.allocator,
            .cols = config.cols,
            .rows = config.rows,
            .pending_capacity = config.pending_capacity,
            .transport = config.transport,
        });
        errdefer session.deinit();

        var cells = std.ArrayListUnmanaged(Cell){};
        errdefer cells.deinit(config.allocator);
        try cells.resize(config.allocator, @as(usize, config.cols) * @as(usize, config.rows));
        @memset(cells.items, Cell{});

        return .{
            .session = session,
            .cells = cells,
            .cols = config.cols,
            .rows = config.rows,
            .cursor = .{},
            .state = .idle,
            .dirty = true,
        };
    }

    pub fn deinit(self: *TerminalSurface) void {
        if (self.state == .running) self.session.stop();
        const allocator = self.session.allocator;
        self.session.deinit();
        self.cells.deinit(allocator);
        self.state = .idle;
        self.dirty = false;
    }

    pub fn start(self: *TerminalSurface) anyerror!void {
        try self.session.start();
        self.state = .running;
        self.dirty = true;
    }

    pub fn stop(self: *TerminalSurface) void {
        self.session.stop();
        self.state = .idle;
    }

    pub fn setTransport(self: *TerminalSurface, transport: Transport) void {
        self.session.transport = transport;
    }

    pub fn feedBytes(self: *TerminalSurface, bytes: []const u8) anyerror!void {
        try self.session.feed(bytes);
    }

    pub fn feedKey(self: *TerminalSurface, key: TerminalKey, mod: TerminalModifier) anyerror!void {
        const encoded = self.session.engine.encodeKey(key, mod);
        if (encoded.len == 0) return;
        try self.session.feed(encoded);
    }

    pub fn tick(self: *TerminalSurface) usize {
        const drained = self.session.apply();
        _ = self.feedInboundFromTransport();
        self.syncFrameFromSession();
        return drained;
    }

    pub fn resize(self: *TerminalSurface, cols: u16, rows: u16) anyerror!void {
        if (cols == 0 or rows == 0) return error.InvalidDimensions;
        const allocator = self.session.allocator;
        try self.cells.resize(allocator, @as(usize, cols) * @as(usize, rows));
        @memset(self.cells.items, Cell{});
        try self.session.resize(cols, rows);
        self.cols = cols;
        self.rows = rows;
        self.cursor = .{};
        self.dirty = true;
    }

    pub fn control(self: *TerminalSurface, signal: ControlSignal) void {
        self.session.control(signal);
    }

    pub fn frameData(self: *TerminalSurface) FrameData {
        self.dirty = false;
        return .{
            .viewport = .{ .cols = self.cols, .rows = self.rows },
            .grid = .{ .cells = self.cells.items, .cols = self.cols, .rows = self.rows },
            .cursor = self.cursor,
        };
    }

    pub fn isDirty(self: *const TerminalSurface) bool {
        return self.dirty;
    }

    fn syncFrameFromSession(self: *TerminalSurface) void {
        const screen = self.session.engine.screen();
        var changed = false;

        if (screen.cells) |cells| {
            const count = @min(self.cells.items.len, cells.len);
            for (0..count) |idx| {
                const codepoint: u21 = cells[idx];
                if (self.cells.items[idx].codepoint != codepoint) {
                    self.cells.items[idx].codepoint = codepoint;
                    self.cells.items[idx].fg_color = .{ .kind = .default, .value = 0 };
                    self.cells.items[idx].bg_color = .{ .kind = .default, .value = 0 };
                    self.cells.items[idx].flags = .{};
                    self.cells.items[idx].attrs = .{};
                    changed = true;
                }
            }
        }

        const max_row = self.rows -| 1;
        const max_col = self.cols -| 1;
        const cursor_row = @min(screen.cursor_row, max_row);
        const cursor_col = @min(screen.cursor_col, max_col);
        if (self.cursor.row != cursor_row or self.cursor.col != cursor_col or self.cursor.visible != screen.cursor_visible) {
            self.cursor.row = cursor_row;
            self.cursor.col = cursor_col;
            self.cursor.visible = screen.cursor_visible;
            self.cursor.shape = .block;
            changed = true;
        }

        if (changed) self.dirty = true;
    }

    fn feedInboundFromTransport(self: *TerminalSurface) usize {
        const transport = self.session.transport orelse {
            if (self.state == .running) @panic("terminal runtime missing transport while running");
            return 0;
        };
        var scratch: [4096]u8 = undefined;
        const read_len = transport.read(scratch[0..]) catch |err| switch (err) {
            error.NotStarted => return 0,
            else => {
                std.log.err("transport read failed: {s}", .{@errorName(err)});
                return 0;
            },
        };
        if (read_len == 0) return 0;
        self.session.feedProcessOutput(scratch[0..read_len]) catch |err| {
            std.log.err("session feedProcessOutput failed: {s}", .{@errorName(err)});
            return 0;
        };
        return read_len;
    }
};
