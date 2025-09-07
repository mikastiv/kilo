const Editor = @This();

const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 0,
    .patch = 1,
};

const tab_stop = 8;

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
    rows: usize,
    cols: usize,
};

const Pos = struct {
    x: usize,
    y: usize,
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

const Row = struct {
    chars: std.ArrayList(u8),
    render: std.ArrayList(u8),

    fn update(self: *Row, allocator: std.mem.Allocator) !void {
        self.render.clearRetainingCapacity();

        for (self.chars.items) |char| {
            if (char == '\t') {
                const count = tab_stop - (self.render.items.len % tab_stop);
                try self.render.appendNTimes(allocator, ' ', count);
            } else {
                try self.render.append(allocator, char);
            }
        }
    }

    fn cxToRx(self: *const Row, cx: usize) usize {
        var rx: usize = 0;
        for (0..cx) |idx| {
            const char = self.chars.items[idx];
            if (char == '\t')
                rx += (tab_stop - 1) - (rx % tab_stop);
            rx += 1;
        }
        return rx;
    }
};

allocator: std.mem.Allocator,
append_buffer: std.ArrayList(u8),
screen: Screen,
cursor: Pos,
rx: usize,
rows: std.ArrayList(Row),
row_offset: usize,
col_offset: usize,

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
        .rx = 0,
        .rows = .empty,
        .row_offset = 0,
        .col_offset = 0,
    };
}

pub fn deinit(self: *Editor) void {
    self.append_buffer.deinit(self.allocator);
    for (self.rows.items) |*row| {
        row.chars.deinit(self.allocator);
        row.render.deinit(self.allocator);
    }
    self.rows.deinit(self.allocator);
}

pub fn clearScreen(_: *const Editor) !void {
    try stdout.writeAll(Ansi.clear_screen ++ Ansi.cursor_top);
    try stdout.flush();
}

pub fn refreshScreen(self: *Editor) !void {
    self.scroll();

    try self.append_buffer.appendSlice(self.allocator, Ansi.cursor_hide ++ Ansi.cursor_top);
    try self.drawRows();
    try self.append_buffer.print(self.allocator, Ansi.esc_seq ++ "{d};{d}H", .{
        (self.cursor.y - self.row_offset) + 1,
        (self.rx - self.col_offset) + 1,
    });
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
        .page_up, .page_down => {
            if (char == .page_up) {
                self.cursor.y = self.row_offset;
            } else if (char == .page_down) {
                self.cursor.y = self.row_offset + self.screen.rows - 1;
                if (self.cursor.y > self.rows.items.len)
                    self.cursor.y = self.rows.items.len;
            }

            for (0..self.screen.rows) |_| {
                self.moveCursor(if (char == .page_up) .up else .down);
            }
        },
        .home => self.cursor.x = 0,
        .end => if (self.cursor.y < self.rows.items.len) {
            self.cursor.x = self.currentRow().?.chars.items.len;
        },
        else => {},
    };
}

pub fn openFile(self: *Editor, filename: []const u8) !void {
    const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
    defer file.close();

    var file_buffer: [512]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const reader = &file_reader.interface;

    var write_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buffer);

    while (reader.streamDelimiter(&writer, '\n')) |_| {
        try self.appendRow(writer.buffered());
        _ = writer.consumeAll();
        reader.toss(1);
    } else |err| if (err != error.EndOfStream) return err;
}

fn appendRow(self: *Editor, str: []const u8) !void {
    const index = self.rows.items.len;
    try self.rows.append(self.allocator, .{ .chars = .empty, .render = .empty });

    const row = &self.rows.items[index];
    try row.chars.appendSlice(self.allocator, str);
    try row.update(self.allocator);
}

fn currentRow(self: *const Editor) ?*Row {
    return switch (self.cursor.y >= self.rows.items.len) {
        true => null,
        false => &self.rows.items[self.cursor.y],
    };
}

fn moveCursor(self: *Editor, char: Key) void {
    var current_row = self.currentRow();

    switch (char) {
        .left => if (self.cursor.x != 0) {
            self.cursor.x -= 1;
        } else if (self.cursor.y > 0) {
            self.cursor.y -= 1;
            self.cursor.x = if (self.currentRow()) |row| row.chars.items.len else 0;
        },
        .right => if (current_row) |row| {
            if (self.cursor.x < row.chars.items.len) {
                self.cursor.x += 1;
            } else if (self.cursor.x == row.chars.items.len) {
                self.cursor.y += 1;
                self.cursor.x = 0;
            }
        },
        .up => self.cursor.y -|= 1,
        .down => if (self.cursor.y < self.rows.items.len) {
            self.cursor.y += 1;
        },
        else => {},
    }

    current_row = self.currentRow();
    const row_len = if (current_row) |row| row.chars.items.len else 0;
    if (self.cursor.x > row_len) self.cursor.x = row_len;
}

fn scroll(self: *Editor) void {
    self.rx = 0;
    if (self.cursor.y < self.rows.items.len) {
        self.rx = self.currentRow().?.cxToRx(self.cursor.x);
    }

    if (self.cursor.y < self.row_offset) {
        self.row_offset = self.cursor.y;
    }

    if (self.cursor.y >= self.row_offset + self.screen.rows) {
        self.row_offset = self.cursor.y - self.screen.rows + 1;
    }

    if (self.rx < self.col_offset) {
        self.col_offset = self.rx;
    }

    if (self.rx >= self.col_offset + self.screen.cols) {
        self.col_offset = self.rx - self.screen.cols + 1;
    }
}

fn drawRows(self: *Editor) !void {
    for (0..self.screen.rows) |y| {
        const file_row = y + self.row_offset;
        if (file_row >= self.rows.items.len) {
            if (self.rows.items.len == 0 and y == self.screen.rows / 3) {
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
        } else {
            const row = &self.rows.items[file_row];
            const len = @min(row.render.items.len -| self.col_offset, self.screen.cols);
            const index = @min(self.col_offset, row.render.items.len);
            const line = row.render.items[index .. index + len];
            try self.append_buffer.appendSlice(self.allocator, line);
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

    if (!std.mem.eql(u8, array.items[0..Ansi.esc_seq.len], Ansi.esc_seq))
        return error.InvalidCursorPosition;

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
