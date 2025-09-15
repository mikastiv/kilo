const std = @import("std");
const posix = std.posix;

const ansi = @import("ansi.zig");
const linux = @import("linux.zig");
const Row = @import("Row.zig");
const stdio = @import("stdio.zig");
const stdin = stdio.stdin;
const stdout = stdio.stdout;
const syn = @import("syntax.zig");
const Syntax = syn.Syntax;
const Highlight = syn.Highlight;
const Color = syn.Color;

const Editor = @This();

const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 0,
    .patch = 1,
};

const presses_before_quit = 3;

pub const Screen = struct {
    rows: usize,
    cols: usize,
};

const Pos = struct {
    x: usize,
    y: usize,
};

const Key = enum(u8) {
    enter = '\r',
    escape = '\x1b',
    ctrl_f = 'f' & 0x1f,
    ctrl_h = 'h' & 0x1f,
    ctrl_l = 'l' & 0x1f,
    ctrl_q = 'q' & 0x1f,
    ctrl_s = 's' & 0x1f,
    backspace = 127,
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

    fn isControl(self: Key) bool {
        const raw: u8 = @intFromEnum(self);
        return raw >= 127 or raw < 32;
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
filename: ?[]const u8,
status_msg_buffer: [128]u8,
status_msg: []const u8,
status_msg_time: i64,
dirty: u32,
syntax: ?Syntax,

pub fn init(allocator: std.mem.Allocator) !Editor {
    const winsize: linux.WinSize = linux.getWindowSize() catch blk: {
        // fallback method
        try stdout.writeAll(ansi.cursor_bottom ++ ansi.cursor_right);
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
            .rows = winsize.rows -| 2,
            .cols = winsize.cols,
        },
        .cursor = .{ .x = 0, .y = 0 },
        .rx = 0,
        .rows = .empty,
        .row_offset = 0,
        .col_offset = 0,
        .filename = null,
        .status_msg_buffer = undefined,
        .status_msg = "",
        .status_msg_time = 0,
        .dirty = 0,
        .syntax = null,
    };
}

pub fn deinit(self: *Editor) void {
    self.append_buffer.deinit(self.allocator);
    for (self.rows.items) |*row| {
        row.chars.deinit(self.allocator);
        row.render.deinit(self.allocator);
        row.highlight.deinit(self.allocator);
    }
    self.rows.deinit(self.allocator);
    if (self.filename) |filename| {
        self.allocator.free(filename);
    }
}

pub fn clearScreen(_: *const Editor) !void {
    try stdout.writeAll(ansi.clear_screen ++ ansi.cursor_top);
    try stdout.flush();
}

pub fn refreshScreen(self: *Editor) !void {
    self.scroll();

    try self.append_buffer.appendSlice(self.allocator, ansi.cursor_hide ++ ansi.cursor_top);

    try self.drawRows();
    try self.drawStatusBar();
    try self.drawMessageBar();

    try self.append_buffer.print(self.allocator, ansi.esc_seq ++ "{d};{d}H", .{
        (self.cursor.y - self.row_offset) + 1,
        (self.rx - self.col_offset) + 1,
    });

    try self.append_buffer.appendSlice(self.allocator, ansi.cursor_show);

    try stdout.writeAll(self.append_buffer.items);
    try stdout.flush();

    self.append_buffer.clearRetainingCapacity();
}

pub fn processKeypress(self: *Editor, quit: *bool) !void {
    const S = struct {
        var quit_times: u32 = presses_before_quit;
    };

    const char = try readKey();
    switch (char) {
        .enter => {
            try self.insertNewline();
        },
        .ctrl_q => {
            if (self.dirty != 0 and S.quit_times > 0) {
                try self.setStatusMessage(
                    "WARNING! File has unsaved changes. Press Ctrl-Q {d} more times to quit.",
                    .{S.quit_times},
                );
                S.quit_times -= 1;
                return;
            }

            quit.* = true;
            try stdout.writeAll(ansi.clear_screen ++ ansi.cursor_top);
            try stdout.flush();
        },
        .ctrl_s => try self.save(),
        .ctrl_f => try self.find(),
        .backspace, .delete, .ctrl_h => {
            if (char == .delete) self.moveCursor(.right);
            try self.deleteChar();
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
        .escape, .ctrl_l => {},
        else => try self.insertChar(@intFromEnum(char)),
    }

    S.quit_times = presses_before_quit;
}

pub fn openFile(self: *Editor, filename: []const u8) !void {
    if (self.filename) |name| self.allocator.free(name);

    self.filename = try self.allocator.dupe(u8, filename);

    try self.selectSyntaxHighlight();

    const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
    defer file.close();

    var file_buffer: [512]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const reader = &file_reader.interface;

    var write_buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&write_buffer);

    while (reader.streamDelimiter(&writer, '\n')) |_| {
        try self.insertRow(self.rows.items.len, writer.buffered());
        _ = writer.consumeAll();
        reader.toss(1);
    } else |err| if (err != error.EndOfStream) return err;

    self.dirty = 0;
}

pub fn setStatusMessage(self: *Editor, comptime fmt: []const u8, args: anytype) !void {
    self.status_msg = try std.fmt.bufPrint(&self.status_msg_buffer, fmt, args);
    self.status_msg_time = std.time.timestamp();
}

fn selectSyntaxHighlight(self: *Editor) !void {
    self.syntax = null;
    const filename = self.filename orelse return;

    const ext = std.fs.path.extension(filename);
    for (syn.highlight_db) |entry| {
        for (entry.filematch) |filematch| {
            const is_ext = filematch[0] == '.';
            if (is_ext and std.mem.eql(u8, ext, filematch)) {
                self.syntax = entry;
                for (self.rows.items) |*row| {
                    try row.updateSyntax(self.allocator, self.syntax);
                }
                return;
            }
        }
    }
}

fn save(self: *Editor) !void {
    errdefer |err| self.setStatusMessage("Can't save! I/O error: {t}", .{err}) catch {};

    const filename = self.filename orelse blk: {
        self.filename = try self.prompt("Save as: {s}", null);
        if (self.filename) |name| {
            try self.selectSyntaxHighlight();
            break :blk name;
        } else {
            try self.setStatusMessage("Save aborted", .{});
            return;
        }
    };

    const buffer = try self.rowsToString();
    defer self.allocator.free(buffer);

    const file = try std.fs.cwd().createFile(filename, .{ .truncate = false });
    defer file.close();

    try linux.ftruncate(file.handle, buffer.len);
    try file.writeAll(buffer);
    self.dirty = 0;

    try self.setStatusMessage("{d} bytes written to disk", .{buffer.len});
}

fn prompt(
    self: *Editor,
    comptime prompt_text: []const u8,
    callback: ?*const fn (*Editor, []const u8, Key) error{OutOfMemory}!void,
) !?[]u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer alloc_writer.deinit();

    const writer = &alloc_writer.writer;

    while (true) {
        try self.setStatusMessage(prompt_text, .{alloc_writer.written()});
        try self.refreshScreen();

        const key = try readKey();
        if (key == .backspace or key == .delete or key == .ctrl_h) {
            if (writer.end > 0) {
                writer.undo(1);
            }
        } else if (key == .escape) {
            try self.setStatusMessage("", .{});
            if (callback) |cb| try cb(self, alloc_writer.written(), key);
            alloc_writer.deinit();
            return null;
        } else if (key == .enter) {
            if (alloc_writer.written().len != 0) {
                try self.setStatusMessage("", .{});
                if (callback) |cb| try cb(self, alloc_writer.written(), key);
                return try alloc_writer.toOwnedSlice();
            }
        } else if (!key.isControl()) {
            try writer.writeByte(@intFromEnum(key));
        }

        if (callback) |cb| try cb(self, alloc_writer.written(), key);
    }
}

fn find(self: *Editor) !void {
    const saved_cursor = self.cursor;
    const saved_row_offset = self.row_offset;
    const saved_col_offset = self.col_offset;

    if (try self.prompt("Search: {s} (Use ESC/Arrows/Enter)", findCallback)) |query| {
        defer self.allocator.free(query);
    } else {
        self.cursor = saved_cursor;
        self.row_offset = saved_row_offset;
        self.col_offset = saved_col_offset;
    }
}

fn findCallback(self: *Editor, query: []const u8, key: Key) !void {
    const S = struct {
        const Dir = enum(i8) {
            backward = -1,
            forward = 1,
        };

        var last_match: ?usize = null;
        var direction: Dir = .forward;
        var saved_hl_line: usize = 0;
        var saved_hl: ?[]const Highlight = null;
    };

    if (S.saved_hl) |hl| {
        @memcpy(self.rows.items[S.saved_hl_line].highlight.items, hl);
        self.allocator.free(hl);
        S.saved_hl = null;
    }

    switch (key) {
        .enter, .escape => {
            S.last_match = null;
            S.direction = .forward;
            return;
        },
        .right, .down => S.direction = .forward,
        .left, .up => S.direction = .backward,
        else => {
            S.last_match = null;
            S.direction = .forward;
        },
    }

    if (S.last_match == null) S.direction = .forward;
    var current = S.last_match orelse std.math.maxInt(usize);
    for (self.rows.items) |_| {
        current +%= @bitCast(@as(isize, @intFromEnum(S.direction)));

        const row_count = self.rows.items.len;
        if (current == row_count)
            current = 0
        else if (current > row_count)
            current = row_count -| 1;

        const row = &self.rows.items[current];
        if (std.mem.indexOf(u8, row.render.items, query)) |match| {
            S.last_match = current;
            self.cursor.y = current;
            self.cursor.x = row.rxToCx(match);
            self.row_offset = self.rows.items.len;

            S.saved_hl = try self.allocator.dupe(Highlight, row.highlight.items);
            S.saved_hl_line = current;
            @memset(row.highlight.items[match .. match + query.len], .match);
            break;
        }
    }
}

fn rowsToString(self: *const Editor) ![]u8 {
    var total_size: usize = 0;
    for (self.rows.items) |row| {
        total_size += row.chars.items.len + 1;
    }

    var buffer = try std.ArrayList(u8).initCapacity(self.allocator, total_size);
    errdefer buffer.deinit(self.allocator);

    for (self.rows.items) |row| {
        buffer.appendSliceAssumeCapacity(row.chars.items);
        buffer.appendAssumeCapacity('\n');
    }

    return try buffer.toOwnedSlice(self.allocator);
}

fn insertChar(self: *Editor, char: u8) !void {
    if (self.cursor.y == self.rows.items.len) {
        try self.insertRow(self.rows.items.len, "");
    }

    const row = self.currentRow().?;
    try row.insertChar(self.allocator, self.syntax, self.cursor.x, char);
    self.cursor.x += 1;
    self.dirty += 1;
}

fn deleteChar(self: *Editor) !void {
    if (self.cursor.y == self.rows.items.len) return;
    if (self.cursor.y == 0 and self.cursor.x == 0) return;

    const row = self.currentRow().?;
    if (self.cursor.x > 0) {
        try row.deleteChar(self.allocator, self.syntax, self.cursor.x - 1);
        self.cursor.x -= 1;
    } else {
        const prev_row = &self.rows.items[self.cursor.y - 1];
        self.cursor.x = prev_row.chars.items.len;
        try prev_row.appendString(self.allocator, self.syntax, row.chars.items);
        self.deleteRow(self.cursor.y);
        self.cursor.y -= 1;
    }

    self.dirty += 1;
}

fn insertNewline(self: *Editor) !void {
    if (self.cursor.x == 0) {
        try self.insertRow(self.cursor.y, "");
    } else {
        var row = self.currentRow().?;
        try self.insertRow(self.cursor.y + 1, row.chars.items[self.cursor.x..]);
        row = self.currentRow().?;
        row.chars.shrinkRetainingCapacity(self.cursor.x);
        try row.update(self.allocator, self.syntax);
    }

    self.cursor.y += 1;
    self.cursor.x = 0;
}

fn insertRow(self: *Editor, at: usize, str: []const u8) !void {
    if (at > self.rows.items.len) return;

    try self.rows.insert(self.allocator, at, .{ .chars = .empty, .render = .empty, .highlight = .empty });

    const row = &self.rows.items[at];
    try row.chars.appendSlice(self.allocator, str);
    try row.update(self.allocator, self.syntax);

    self.dirty += 1;
}

fn deleteRow(self: *Editor, at: usize) void {
    const index = @min(at, self.rows.items.len -| 1);
    var row = self.rows.orderedRemove(index);
    row.chars.deinit(self.allocator);
    row.render.deinit(self.allocator);
    self.dirty += 1;
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
            const highlight = row.highlight.items[index .. index + len];
            var current_color: Color = .default;
            for (line, highlight) |char, hl| {
                switch (hl) {
                    .normal => {
                        if (current_color != .default) {
                            try self.append_buffer.appendSlice(self.allocator, ansi.fg_color_default);
                            current_color = .default;
                        }
                        try self.append_buffer.append(self.allocator, char);
                    },
                    .number, .match, .string, .comment => {
                        const color = hl.toColor();
                        if (color != current_color) {
                            try self.append_buffer.appendSlice(self.allocator, color.toAnsi());
                            current_color = color;
                        }
                        try self.append_buffer.append(self.allocator, char);
                    },
                }
            }
            try self.append_buffer.appendSlice(self.allocator, ansi.fg_color_default);
        }

        try self.append_buffer.appendSlice(self.allocator, ansi.clear_line);
        try self.append_buffer.appendSlice(self.allocator, "\r\n");
    }
}

fn drawStatusBar(self: *Editor) !void {
    try self.append_buffer.appendSlice(self.allocator, ansi.invert_colors);

    var left_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const left_str = try std.fmt.bufPrint(
        &left_buffer,
        " {s} - {d} lines {s}",
        .{
            self.filename orelse "[No Name]",
            self.rows.items.len,
            if (self.dirty != 0) "(modified)" else "",
        },
    );
    const left_status = left_str[0..@min(left_str.len, self.screen.cols)];

    var right_buffer: [64]u8 = undefined;
    const right_status = try std.fmt.bufPrint(
        &right_buffer,
        " {s} | {d}/{d} ",
        .{
            if (self.syntax) |syntax| syntax.filetype else "no ft",
            self.cursor.y + 1,
            self.rows.items.len,
        },
    );

    try self.append_buffer.appendSlice(self.allocator, left_status);
    if (self.screen.cols >= left_status.len + right_status.len) {
        try self.append_buffer.appendNTimes(
            self.allocator,
            ' ',
            self.screen.cols -| left_status.len -| right_status.len,
        );
        try self.append_buffer.appendSlice(self.allocator, right_status);
    } else {
        try self.append_buffer.appendNTimes(self.allocator, ' ', self.screen.cols -| left_status.len);
    }

    try self.append_buffer.appendSlice(self.allocator, ansi.normal_colors);
    try self.append_buffer.appendSlice(self.allocator, "\r\n");
}

fn drawMessageBar(self: *Editor) !void {
    try self.append_buffer.appendSlice(self.allocator, ansi.clear_line);
    const len = @min(self.status_msg.len, self.screen.cols);
    if (std.time.timestamp() - self.status_msg_time < 5) {
        try self.append_buffer.appendSlice(self.allocator, self.status_msg[0..len]);
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

        if (char == ansi.esc_seq[0]) {
            var seq: [3]u8 = undefined;
            seq[0] = stdin.takeByte() catch return @enumFromInt(ansi.esc[0]);
            seq[1] = stdin.takeByte() catch return @enumFromInt(ansi.esc[0]);

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
                else => return @enumFromInt(ansi.esc_seq[0]),
            }
        }

        return @enumFromInt(char);
    }
}

fn getCursorPosition() !Screen {
    try stdout.writeAll(ansi.cursor_position);
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

    if (!std.mem.eql(u8, array.items[0..ansi.esc_seq.len], ansi.esc_seq))
        return error.InvalidCursorPosition;

    const cursor_pos_raw = array.items[ansi.esc_seq.len..];
    const rows_raw = std.mem.sliceTo(cursor_pos_raw, ';');
    const cols_raw = cursor_pos_raw[rows_raw.len + 1 ..];

    const rows = try std.fmt.parseInt(u32, rows_raw, 10);
    const cols = try std.fmt.parseInt(u32, cols_raw, 10);

    return .{
        .rows = rows,
        .cols = cols,
    };
}
