const std = @import("std");

pub var stdout: *std.Io.Writer = undefined;
pub var stderr: *std.Io.Writer = undefined;
pub var stdin: *std.Io.Reader = undefined;
