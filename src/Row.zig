const std = @import("std");

const syn = @import("syntax.zig");
const Syntax = syn.Syntax;
const Highlight = syn.Highlight;

const Row = @This();

const tab_stop = 8;

chars: std.ArrayList(u8),
render: std.ArrayList(u8),
highlight: std.ArrayList(Highlight),

pub fn update(self: *Row, allocator: std.mem.Allocator, maybe_syntax: ?Syntax) !void {
    self.render.clearRetainingCapacity();

    for (self.chars.items) |char| {
        if (char == '\t') {
            const count = tab_stop - (self.render.items.len % tab_stop);
            try self.render.appendNTimes(allocator, ' ', count);
        } else {
            try self.render.append(allocator, char);
        }
    }

    try self.updateSyntax(allocator, maybe_syntax);
}

pub fn updateSyntax(self: *Row, allocator: std.mem.Allocator, maybe_syntax: ?Syntax) !void {
    self.highlight.clearRetainingCapacity();
    try self.highlight.appendNTimes(allocator, .normal, self.render.items.len);

    const syntax = maybe_syntax orelse return;
    const keywords = syntax.keywords;

    var prev_separator = true;
    var in_string: ?u8 = null;

    var i: usize = 0;
    loop: while (i < self.render.items.len) {
        const char = self.render.items[i];
        const prev_hl = if (i > 0) self.highlight.items[i - 1] else .normal;
        const prev_char = if (i > 0) self.render.items[i - 1] else 0;
        const next_char = if (i + 1 < self.render.items.len) self.render.items[i + 1] else 0;

        if (in_string == null and syntax.single_line_comment.len > 0) {
            if (std.mem.startsWith(u8, self.render.items[i..], syntax.single_line_comment)) {
                @memset(self.highlight.items[i..], .comment);
                break;
            }
        }

        if (syntax.flags.strings) {
            if (in_string) |delim| {
                self.highlight.items[i] = .string;
                if (char == '\\' and i + 1 < self.render.items.len) {
                    self.highlight.items[i + 1] = .string;
                    i += 2;
                    continue;
                }
                if (char == delim) in_string = null;
                i += 1;
                prev_separator = true;
                continue;
            } else if (char == '"' or char == '\'') {
                in_string = char;
                self.highlight.items[i] = .string;
                i += 1;
                continue;
            }
        }

        if (syntax.flags.numbers) {
            const condition1 =
                std.ascii.isDigit(char) and
                (prev_separator or prev_hl == .number) or
                (char == '.' and prev_hl == .number and std.ascii.isDigit(next_char)) or
                ((prev_char == 'x' or prev_char == 'X') and prev_hl == .number);

            const condition2 = (char == 'x' or char == 'X') and prev_char == '0';

            const condition3 =
                prev_hl == .number and
                std.mem.indexOfScalar(
                    u8,
                    std.ascii.HexEscape.lower_charset,
                    std.ascii.toLower(char),
                ) != null;

            if (condition1 or condition2 or condition3) {
                self.highlight.items[i] = .number;
                i += 1;
                prev_separator = false;
                continue;
            }
        }

        if (prev_separator) {
            for (keywords) |kw| {
                const secondary = kw[kw.len - 1] == '|';
                const keyword = if (secondary) kw[0 .. kw.len - 1] else kw;
                const slice = self.render.items[i..];
                if (std.mem.startsWith(u8, slice, keyword)) {
                    const end_char = if (slice.len > keyword.len) slice[keyword.len] else 0;
                    if (isSeparator(end_char)) {
                        @memset(
                            self.highlight.items[i .. i + keyword.len],
                            if (secondary) .keyword2 else .keyword1,
                        );
                        i += keyword.len;
                        prev_separator = false;
                        continue :loop;
                    }
                }
            }
        }

        prev_separator = isSeparator(char);
        i += 1;
    }
}

pub fn insertChar(
    self: *Row,
    allocator: std.mem.Allocator,
    maybe_syntax: ?Syntax,
    at: usize,
    char: u8,
) !void {
    const index = @min(at, self.chars.items.len);
    try self.chars.insert(allocator, index, char);
    try self.update(allocator, maybe_syntax);
}

pub fn deleteChar(self: *Row, allocator: std.mem.Allocator, maybe_syntax: ?Syntax, at: usize) !void {
    const index = @min(at, self.chars.items.len -| 1);
    _ = self.chars.orderedRemove(index);
    try self.update(allocator, maybe_syntax);
}

pub fn appendString(self: *Row, allocator: std.mem.Allocator, maybe_syntax: ?Syntax, str: []const u8) !void {
    try self.chars.appendSlice(allocator, str);
    try self.update(allocator, maybe_syntax);
}

pub fn cxToRx(self: *const Row, cx: usize) usize {
    var rx: usize = 0;
    for (0..cx) |idx| {
        const char = self.chars.items[idx];
        if (char == '\t')
            rx += (tab_stop - 1) - (rx % tab_stop);
        rx += 1;
    }
    return rx;
}

pub fn rxToCx(self: *const Row, rx: usize) usize {
    var cur_rx: usize = 0;
    var cx: usize = 0;
    for (self.chars.items) |char| {
        if (char == '\t')
            cur_rx += (tab_stop - 1) - (cur_rx % tab_stop);
        cur_rx += 1;

        if (cur_rx > rx) return cx;

        cx += 1;
    }

    return cx;
}

fn isSeparator(char: u8) bool {
    return std.ascii.isWhitespace(char) or
        std.mem.indexOfScalar(u8, ",.()+-/*=~%<>[];!?", char) != null;
}
