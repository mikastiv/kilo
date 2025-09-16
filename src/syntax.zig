const ansi = @import("ansi.zig");

pub const Highlight = enum {
    normal,
    number,
    match,
    string,
    comment,
    keyword1,
    keyword2,

    pub fn toColor(self: Highlight) Color {
        return switch (self) {
            .normal => .default,
            .number => .red,
            .match => .blue,
            .string => .green,
            .comment => .cyan,
            .keyword1 => .yellow,
            .keyword2 => .magenta,
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
    keywords: []const []const u8,
    single_line_comment: []const u8,
    flags: Flags,
};

pub const highlight_db: []const Syntax = &.{ .{
    .filetype = "c",
    .filematch = &.{ ".c", ".h", ".cpp" },
    .keywords = &.{
        "switch",
        "if",
        "while",
        "for",
        "break",
        "continue",
        "goto",
        "return",
        "else",
        "struct",
        "union",
        "typedef",
        "static",
        "enum",
        "class",
        "case",
        "int|",
        "long|",
        "double|",
        "float|",
        "char|",
        "unsigned|",
        "signed|",
        "void|",
    },
    .single_line_comment = "//",
    .flags = .{
        .numbers = true,
        .strings = true,
    },
}, .{
    .filetype = "zig",
    .filematch = &.{".zig"},
    .keywords = &.{
        "const",
        "var",
        "if",
        "else",
        "try",
        "catch",
        "comptime",
        "callconv",
        "while",
        "for",
        "switch",
        "break",
        "continue",
        "return",
        "struct",
        "enum",
        "union",
        "pub",
        "fn",
        "void|",
        "bool|",
        "true|",
        "false|",
        "undefined|",
        "null|",
        "usize|",
        "isize|",
        "anyopaque|",
        "type|",
        "anytype|",
        "noreturn|",
        "comptime_int|",
        "comptime_float|",
        "u8|",
        "u16|",
        "u32|",
        "u64|",
        "i8|",
        "i16|",
        "i32|",
        "i64|",
    },
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
    yellow,
    magenta,

    pub fn toAnsi(self: Color) []const u8 {
        return switch (self) {
            .default => ansi.fg_color_default,
            .red => ansi.fg_color_red,
            .blue => ansi.fg_color_blue,
            .green => ansi.fg_color_green,
            .cyan => ansi.fg_color_cyan,
            .yellow => ansi.fg_color_yellow,
            .magenta => ansi.fg_color_magenta,
        };
    }
};
