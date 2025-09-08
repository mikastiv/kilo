const std = @import("std");
const posix = std.posix;

pub fn enableRawMode() !posix.termios {
    const original_termios = try posix.tcgetattr(posix.STDIN_FILENO);

    var raw = original_termios;

    raw.iflag.BRKINT = false; // disable break conditions cause SIGINT
    raw.iflag.ICRNL = false; // disable Ctrl-M read as \n
    raw.iflag.INPCK = false; // disable parity checking (obsolete)
    raw.iflag.ISTRIP = false; // disable stripping of 8th bit
    raw.iflag.IXON = false; // disable Ctrl-S and Ctrl-Q signals

    raw.oflag.OPOST = false; // disable output processing

    raw.cflag.CSIZE = .CS8; // set char size to 8 bits

    raw.lflag.ECHO = false; // disable echo of input characters
    raw.lflag.ICANON = false; // read byte by byte instead of line by line
    raw.lflag.ISIG = false; // disable Ctrl-C and Ctrl-Z signals
    raw.lflag.IEXTEN = false; // disable Ctrl-V

    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 1;

    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);

    return original_termios;
}

pub fn disableRawMode(original_termios: posix.termios) !void {
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original_termios);
}

pub const WinSize = struct {
    rows: usize,
    cols: usize,
};

pub fn getWindowSize() !WinSize {
    var ws: posix.winsize = undefined;

    const result = std.os.linux.ioctl(posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (result == -1) return error.IoctlFailed;
    if (ws.col == 0) return error.GetWinsizeFailed;

    return .{
        .rows = ws.row,
        .cols = ws.col,
    };
}

pub fn ftruncate(fd: std.fs.File.Handle, length: u64) !void {
    try posix.ftruncate(fd, length);
}
