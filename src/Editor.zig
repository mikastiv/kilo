const Editor = @This();

const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 0,
    .patch = 1,
};

const std = @import("std");
const stdio = @import("stdio.zig");
const linux = @import("linux.zig");
const posix = std.posix;

const stdin = stdio.stdin;
const stdout = stdio.stdout;

const Ansi = struct {
    const esc = "\x1b";
    const clear_screen = esc ++ "[2J";
    const clear_line = esc ++ "[K";
    const cursor_top = esc ++ "[H";
    const cursor_bottom = esc ++ "[999C";
    const cursor_right = esc ++ "[999B";
    const cursor_position = esc ++ "[6n";
    const cursor_hide = esc ++ "[?25l";
    const cursor_show = esc ++ "[?25h";
};

pub const Screen = struct {
    rows: u32,
    cols: u32,
};

allocator: std.mem.Allocator,
append_buffer: std.ArrayList(u8),
screen: Screen,

pub fn init(allocator: std.mem.Allocator) !Editor {
    const winsize: linux.WinSize = linux.getWindowSize() catch blk: {
        // fallback method
        try stdout.writeAll(Ansi.cursor_bottom ++ Ansi.cursor_right);
        try stdout.flush();

        const pos = try getCursorPosition();
        break :blk .{
            .rows = pos.rows,
            .cols = pos.cols,
        };
    };

    return .{
        .allocator = allocator,
        .append_buffer = .empty,
        .screen = .{
            .rows = winsize.rows,
            .cols = winsize.cols,
        },
    };
}

pub fn deinit(self: *Editor) void {
    self.append_buffer.deinit(self.allocator);
}

pub fn clearScreen(_: *const Editor) !void {
    try stdout.writeAll(Ansi.clear_screen ++ Ansi.cursor_top);
    try stdout.flush();
}

pub fn refreshScreen(self: *Editor) !void {
    try self.append_buffer.appendSlice(self.allocator, Ansi.cursor_hide ++ Ansi.cursor_top);
    try self.drawRows();
    try self.append_buffer.appendSlice(self.allocator, Ansi.cursor_top ++ Ansi.cursor_show);

    try stdout.writeAll(self.append_buffer.items);
    try stdout.flush();

    self.append_buffer.clearRetainingCapacity();
}

pub fn processKeypress(_: *const Editor) !bool {
    const char = try readKey();
    return switch (char) {
        ctrlKey('q') => true,
        else => false,
    };
}

fn drawRows(self: *Editor) !void {
    for (0..self.screen.rows) |y| {
        if (y == self.screen.rows / 3) {
            var buf: [64]u8 = undefined;
            const welcome = try std.fmt.bufPrint(&buf, "Kilo editor -- version {f}", .{version});

            var padding = (self.screen.cols - welcome.len) / 2;
            if (padding > 0) {
                try self.append_buffer.append(self.allocator, '~');
                padding -= 1;
            }

            try self.append_buffer.appendNTimes(self.allocator, ' ', padding);
            try self.append_buffer.appendSlice(self.allocator, welcome);
        } else {
            try self.append_buffer.append(self.allocator, '~');
        }

        try self.append_buffer.appendSlice(self.allocator, Ansi.clear_line);
        if (y < self.screen.rows - 1) {
            try self.append_buffer.appendSlice(self.allocator, "\r\n");
        }
    }
}

fn readKey() !u8 {
    while (true) {
        const char = stdin.takeByte() catch |err| blk: {
            break :blk switch (err) {
                error.ReadFailed => err,
                error.EndOfStream => continue,
            };
        };
        return char;
    }
}

fn ctrlKey(key: u8) u8 {
    return key & 0x1f;
}

fn getCursorPosition() !Screen {
    try stdout.writeAll(Ansi.cursor_position);
    try stdout.flush();

    var buffer: [32]u8 = undefined;
    var array = std.ArrayListUnmanaged(u8).initBuffer(&buffer);

    while (true) {
        var char: u8 = undefined;
        _ = std.posix.read(posix.STDIN_FILENO, @ptrCast(&char)) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (char == 'R') break;
        try array.appendBounded(char);
    }

    if (array.items[0] != Ansi.esc[0] or array.items[1] != '[') return error.InvalidCursorPosition;

    const cursor_pos_raw = array.items[2..];
    const rows_raw = std.mem.sliceTo(cursor_pos_raw, ';');
    const cols_raw = cursor_pos_raw[rows_raw.len + 1 ..];

    const rows = try std.fmt.parseInt(u32, rows_raw, 10);
    const cols = try std.fmt.parseInt(u32, cols_raw, 10);

    return .{
        .rows = rows,
        .cols = cols,
    };
}
