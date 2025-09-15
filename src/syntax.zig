const ansi = @import("ansi.zig");

pub const Highlight = enum {
    normal,
    number,
    match,
    string,
    comment,

    pub fn toColor(self: Highlight) Color {
        return switch (self) {
            .normal => .default,
            .number => .red,
            .match => .blue,
            .string => .green,
            .comment => .cyan,
        };
    }
};

pub const Syntax = struct {
    const Flags = packed struct {
        numbers: bool,
        strings: bool,
    };

    filetype: []const u8,
    filematch: []const []const u8,
    single_line_comment: []const u8,
    flags: Flags,

    const c_extensions = &.{ ".c", ".h", ".cpp" };
    const zig_extensions = &.{".zig"};
};

pub const highlight_db: []const Syntax = &.{ .{
    .filetype = "c",
    .filematch = Syntax.c_extensions,
    .single_line_comment = "//",
    .flags = .{
        .numbers = true,
        .strings = true,
    },
}, .{
    .filetype = "zig",
    .filematch = Syntax.zig_extensions,
    .single_line_comment = "//",
    .flags = .{
        .numbers = true,
        .strings = true,
    },
} };

pub const Color = enum {
    default,
    red,
    blue,
    green,
    cyan,

    pub fn toAnsi(self: Color) []const u8 {
        return switch (self) {
            .default => ansi.fg_color_default,
            .red => ansi.fg_color_red,
            .blue => ansi.fg_color_blue,
            .green => ansi.fg_color_green,
            .cyan => ansi.fg_color_cyan,
        };
    }
};
