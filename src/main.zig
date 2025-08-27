const std = @import("std");
const posix = std.posix;

const clear_screen = "\x1b[2J";
const cursor_top = "\x1b[H";

var stdin_buffer: [1024]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
const stdin = &stdin_reader.interface;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

var original_termios: posix.termios = undefined;

pub fn main() !void {
    defer editorClearScreen() catch {};

    try enableRawMode();
    defer disableRawMode() catch {};

    var quit = false;
    while (!quit) {
        try editorRefreshScreen();
        quit = try editorProcessKeypress();
    }
}

fn editorDrawRows() !void {
    for (0..24) |_| {
        try stdout.writeAll("~\r\n");
    }
    try stdout.flush();
}

fn editorClearScreen() !void {
    try stdout.writeAll(clear_screen);
    try stdout.writeAll(cursor_top);
    try stdout.flush();
}

fn editorRefreshScreen() !void {
    try editorClearScreen();
    try editorDrawRows();
    try stdout.writeAll(cursor_top);
    try stdout.flush();
}

fn editorReadKey() !u8 {
    return stdin.takeByte() catch |err| blk: {
        break :blk switch (err) {
            error.ReadFailed => err,
            else => @as(u8, 0),
        };
    };
}

fn editorProcessKeypress() !bool {
    const char = try editorReadKey();
    return switch (char) {
        ctrlKey('q') => true,
        else => false,
    };
}

fn ctrlKey(key: u8) u8 {
    return key & 0x1f;
}

fn enableRawMode() !void {
    original_termios = try posix.tcgetattr(posix.STDIN_FILENO);

    var raw = original_termios;

    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;

    raw.oflag.OPOST = false;

    raw.cflag.CSIZE = .CS8;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 1;

    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
}

fn disableRawMode() !void {
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original_termios);
}
