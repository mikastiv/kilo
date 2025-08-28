const std = @import("std");
const posix = std.posix;
const stdio = @import("stdio.zig");
const Editor = @import("Editor.zig");

const stdin = stdio.stdin;
const stdout = stdio.stdout;

var original_termios: posix.termios = undefined;

pub fn main() !void {
    var editor: Editor = .init();

    defer editor.clearScreen() catch {};

    try enableRawMode();
    defer disableRawMode() catch {};

    var quit = false;
    while (!quit) {
        try editor.refreshScreen();
        quit = try editor.processKeypress();
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
