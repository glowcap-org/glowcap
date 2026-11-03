//! The resident set a bench reports for a live process: the `VmRSS` line of
//! `/proc/<pid>/status`, in kB. Linux only, like the benches that read it.

const std = @import("std");

/// `pid`'s resident set in kB. A process that has exited, or a status file
/// with no `VmRSS` line, is an error the caller decides to skip or to fail on.
pub fn kb(io: std.Io, pid: std.process.Child.Id) !u64 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid});
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    var text_buf: [8192]u8 = undefined;
    var len: usize = 0;
    while (len < text_buf.len) {
        const n = try reader.interface.readSliceShort(text_buf[len..]);
        if (n == 0) break;
        len += n;
    }
    const text = text_buf[0..len];
    const at = std.mem.indexOf(u8, text, "VmRSS:") orelse return error.RssUnavailable;
    var i = at + "VmRSS:".len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    return std.fmt.parseInt(u64, text[start..i], 10);
}
