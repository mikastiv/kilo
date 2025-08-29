const Editor = @This();

const std = @import("std");
const stdio = @import("stdio.zig");
const linux = @import("linux.zig");
const posix = std.posix;

const stdin = stdio.stdin;
const stdout = stdio.stdout;

const clear_screen = "\x1b[2J";
const cursor_top = "\x1b[H";
const cursor_bottom = "\x1b[999C";
const cursor_right = "\x1b[999B";
const cursor_position = "\x1b[6n";

pub const Screen = struct {
    rows: u32,
    cols: u32,
};

screen: Screen,

pub fn init() !Editor {
    const winsize: linux.WinSize = linux.getWindowSize() catch blk: {
        // fallback method
        try stdout.writeAll(cursor_bottom ++ cursor_right);
        try stdout.flush();

        const pos = try getCursorPosition();
        break :blk .{
            .rows = pos.rows,
            .cols = pos.cols,
        };
    };

    return .{
        .screen = .{
            .rows = winsize.rows,
            .cols = winsize.cols,
        },
    };
}

pub fn clearScreen(_: *const Editor) !void {
    try stdout.writeAll(clear_screen);
    try stdout.flush();
    try stdout.writeAll(cursor_top);
    try stdout.flush();
}

pub fn refreshScreen(self: *const Editor) !void {
    try self.clearScreen();
    try self.drawRows();
    try stdout.writeAll(cursor_top);
    try stdout.flush();
}

pub fn processKeypress(_: *const Editor) !bool {
    const char = try readKey();
    return switch (char) {
        ctrlKey('q') => true,
        else => false,
    };
}

fn drawRows(self: *const Editor) !void {
    for (0..self.screen.rows) |_| {
        try stdout.writeAll("~\r\n");
    }
    try stdout.flush();
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
    try stdout.writeAll(cursor_position);
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

    if (array.items[0] != '\x1b' or array.items[1] != '[') return error.InvalidCursorPosition;

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
