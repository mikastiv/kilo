const std = @import("std");

const syn = @import("syntax.zig");
const Syntax = syn.Syntax;
const Highlight = syn.Highlight;
const config = @import("config.zig");

const Row = @This();

chars: std.ArrayList(u8),
render: std.ArrayList(u8),
highlight: std.ArrayList(Highlight),
idx: usize,
hl_open_comment: bool,

pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
    self.chars.deinit(allocator);
    self.render.deinit(allocator);
    self.highlight.deinit(allocator);
}

pub fn cxToRx(self: *const Row, cx: usize) usize {
    var rx: usize = 0;
    for (0..cx) |idx| {
        const char = self.chars.items[idx];
        if (char == '\t')
            rx += (config.tab_stop - 1) - (rx % config.tab_stop);
        rx += 1;
    }
    return rx;
}

pub fn rxToCx(self: *const Row, rx: usize) usize {
    var cur_rx: usize = 0;
    var cx: usize = 0;
    for (self.chars.items) |char| {
        if (char == '\t')
            cur_rx += (config.tab_stop - 1) - (cur_rx % config.tab_stop);
        cur_rx += 1;

        if (cur_rx > rx) return cx;

        cx += 1;
    }

    return cx;
}
