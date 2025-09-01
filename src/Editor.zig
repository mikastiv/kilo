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
    const esc_seq = esc ++ "[";
    const clear_screen = esc_seq ++ "2J";
    const clear_line = esc_seq ++ "K";
    const cursor_top = esc_seq ++ "H";
    const cursor_bottom = esc_seq ++ "999C";
    const cursor_right = esc_seq ++ "999B";
    const cursor_position = esc_seq ++ "6n";
    const cursor_hide = esc_seq ++ "?25l";
    const cursor_show = esc_seq ++ "?25h";
};

pub const Screen = struct {
    rows: u32,
    cols: u32,
};

const Pos = struct {
    x: u32,
    y: u32,
};

const Key = enum(u8) {
    ctrl_q = 'q' & 0x1f,
    left = 128,
    right = 129,
    up = 130,
    down = 131,
    page_up = 132,
    page_down = 133,
    home = 134,
    end = 135,
    delete = 136,
    _,
};

allocator: std.mem.Allocator,
append_buffer: std.ArrayList(u8),
screen: Screen,
cursor: Pos,

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
        .cursor = .{ .x = 0, .y = 0 },
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
    try self.append_buffer.print(self.allocator, Ansi.esc_seq ++ "{d};{d}H", .{ self.cursor.y + 1, self.cursor.x + 1 });
    try self.append_buffer.appendSlice(self.allocator, Ansi.cursor_show);

    try stdout.writeAll(self.append_buffer.items);
    try stdout.flush();

    self.append_buffer.clearRetainingCapacity();
}

pub fn processKeypress(self: *Editor, quit: *bool) !void {
    const char = try readKey();
    return switch (char) {
        .ctrl_q => {
            quit.* = true;
            try stdout.writeAll(Ansi.clear_screen ++ Ansi.cursor_top);
            try stdout.flush();
        },
        .left, .right, .up, .down => self.moveCursor(char),
        .page_up, .page_down => for (0..self.screen.rows) |_| {
            self.moveCursor(if (char == .page_up) .up else .down);
        },
        .home => self.cursor.x = 0,
        .end => self.cursor.x = self.screen.cols - 1,
        else => {},
    };
}

fn moveCursor(self: *Editor, char: Key) void {
    switch (char) {
        .left => self.cursor.x -|= 1,
        .right => if (self.cursor.x < self.screen.cols - 1) {
            self.cursor.x += 1;
        },
        .up => self.cursor.y -|= 1,
        .down => if (self.cursor.y < self.screen.rows - 1) {
            self.cursor.y += 1;
        },
        else => {},
    }
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

fn readKey() !Key {
    while (true) {
        const char = stdin.takeByte() catch |err| blk: {
            break :blk switch (err) {
                error.ReadFailed => return err,
                error.EndOfStream => continue,
            };
        };

        if (char == Ansi.esc_seq[0]) {
            var seq: [3]u8 = undefined;
            seq[0] = stdin.takeByte() catch return @enumFromInt(Ansi.esc[0]);
            seq[1] = stdin.takeByte() catch return @enumFromInt(Ansi.esc[0]);

            switch (seq[0]) {
                '[' => switch (seq[1]) {
                    '0'...'9' => {
                        seq[2] = try stdin.takeByte();
                        if (seq[2] == '~') {
                            switch (seq[1]) {
                                '1', '7' => return .home,
                                '3' => return .delete,
                                '4', '8' => return .end,
                                '5' => return .page_up,
                                '6' => return .page_down,
                                else => {},
                            }
                        }
                    },
                    else => switch (seq[1]) {
                        'A' => return .up,
                        'B' => return .down,
                        'C' => return .right,
                        'D' => return .left,
                        'F' => return .end,
                        'H' => return .home,
                        else => {},
                    },
                },
                'O' => switch (seq[1]) {
                    'F' => return .end,
                    'H' => return .home,
                    else => {},
                },
                else => return @enumFromInt(Ansi.esc_seq[0]),
            }
        }

        return @enumFromInt(char);
    }
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

    if (!std.mem.eql(u8, array.items[0..Ansi.esc_seq.len], Ansi.esc_seq)) return error.InvalidCursorPosition;

    const cursor_pos_raw = array.items[Ansi.esc_seq.len..];
    const rows_raw = std.mem.sliceTo(cursor_pos_raw, ';');
    const cols_raw = cursor_pos_raw[rows_raw.len + 1 ..];

    const rows = try std.fmt.parseInt(u32, rows_raw, 10);
    const cols = try std.fmt.parseInt(u32, cols_raw, 10);

    return .{
        .rows = rows,
        .cols = cols,
    };
}
