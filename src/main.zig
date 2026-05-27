const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const stdio = @import("stdio.zig");
const linux = @import("linux.zig");
const Editor = @import("Editor.zig");

var original_termios: posix.termios = undefined;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.deinit();
    };

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    stdio.stdin = &stdin_reader.interface;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdio.stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    stdio.stderr = &stderr_writer.interface;

    original_termios = try linux.enableRawMode();
    defer linux.disableRawMode(original_termios) catch {};

    var editor: Editor = try .init(allocator, io);
    defer editor.deinit();
    if (args.len > 1) {
        try editor.openFile(args[1]);
    }

    defer editor.clearScreen() catch {};

    try editor.setStatusMessage("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find", .{});

    var quit = false;
    while (!quit) {
        try editor.refreshScreen();
        try editor.processKeypress(&quit);
    }
}
