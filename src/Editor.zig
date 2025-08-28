const Editor = @This();

const std = @import("std");
const stdio = @import("stdio.zig");

const stdin = stdio.stdin;
const stdout = stdio.stdout;

const clear_screen = "\x1b[2J";
const cursor_top = "\x1b[H";

pub fn init() Editor {
    return .{};
}

pub fn clearScreen(_: *Editor) !void {
    try stdout.writeAll(clear_screen);
    try stdout.writeAll(cursor_top);
    try stdout.flush();
}

pub fn refreshScreen(self: *Editor) !void {
    try self.clearScreen();
    try drawRows();
    try stdout.writeAll(cursor_top);
    try stdout.flush();
}

pub fn processKeypress(_: *Editor) !bool {
    const char = try readKey();
    return switch (char) {
        ctrlKey('q') => true,
        else => false,
    };
}

fn drawRows() !void {
    for (0..24) |_| {
        try stdout.writeAll("~\r\n");
    }
    try stdout.flush();
}

fn readKey() !u8 {
    return stdin.takeByte() catch |err| blk: {
        break :blk switch (err) {
            error.ReadFailed => err,
            else => @as(u8, 0),
        };
    };
}

fn ctrlKey(key: u8) u8 {
    return key & 0x1f;
}
