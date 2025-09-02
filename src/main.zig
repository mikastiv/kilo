const std = @import("std");
const posix = std.posix;
const stdio = @import("stdio.zig");
const linux = @import("linux.zig");
const Editor = @import("Editor.zig");

const stdin = stdio.stdin;
const stdout = stdio.stdout;

var original_termios: posix.termios = undefined;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    original_termios = try linux.enableRawMode();
    defer linux.disableRawMode(original_termios) catch {};

    var editor: Editor = try .init(allocator);
    if (args.len > 1) {
        try editor.openFile(args[1]);
    }

    defer editor.clearScreen() catch {};

    var quit = false;
    while (!quit) {
        try editor.refreshScreen();
        try editor.processKeypress(&quit);
    }
}
