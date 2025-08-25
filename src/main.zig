const std = @import("std");
const posix = std.posix;

var stdin_buffer: [1024]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
const stdin = &stdin_reader.interface;

var original_termios: posix.termios = undefined;

pub fn main() !void {
    try enableRawMode();
    defer disableRawMode() catch {};

    while (true) {
        const char = stdin.takeByte() catch 0;
        switch (char) {
            'q' => break,
            else => if (std.ascii.isPrint(char))
                std.debug.print("{d} ('{c}')\r\n", .{ char, char })
            else
                std.debug.print("{d}\r\n", .{char}),
        }
    }
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
