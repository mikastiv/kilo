const std = @import("std");
const posix = std.posix;
const stdio = @import("stdio.zig");
const linux = @import("linux.zig");
const Editor = @import("Editor.zig");

const stdin = stdio.stdin;
const stdout = stdio.stdout;

var original_termios: posix.termios = undefined;

pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    original_termios = try linux.enableRawMode();
    defer linux.disableRawMode(original_termios) catch {};

    var editor: Editor = try .init(alloc);

    defer editor.clearScreen() catch {};

    var quit = false;
    while (!quit) {
        try editor.refreshScreen();
        try editor.processKeypress(&quit);
    }
}
