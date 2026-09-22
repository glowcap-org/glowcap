//! Docker actions inherit both output streams. Queries capture only their
//! result on stdout; stderr stays live even on success or timeout.
//! No shell, timer process, or contributor toolchain participates in deployment.
const std = @import("std");
const log = @import("../../../operability/log.zig");
const Io = std.Io;
const posix = std.posix;

pub const Client = struct {
    io: Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    workspace: []const u8,

    pub fn args(self: Client, operands: []const []const u8) ![]const []const u8 {
        return std.mem.concat(self.gpa, []const u8, &.{ &.{"docker"}, operands });
    }

    const Output = struct { term: std.process.Child.Term, stdout: []const u8 };

    pub fn capture(self: Client, operands: []const []const u8) !Output {
        return self.readOutput(operands) catch |err| {
            log.err(self.io, "{s}: {f}", .{ @errorName(err), Command{ .operands = operands } });
            return err;
        };
    }

    fn readOutput(self: Client, operands: []const []const u8) !Output {
        const expires = Io.Clock.awake.now(self.io).addDuration(.fromSeconds(15));
        var child = try std.process.spawn(self.io, .{
            .argv = try self.args(operands),
            .environ_map = self.environ,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        defer retire(self.io, &child);
        var buffers: Io.File.MultiReader.Buffer(1) = undefined;
        var reader: Io.File.MultiReader = undefined;
        reader.init(self.gpa, self.io, buffers.toStreams(), &.{child.stdout.?});
        defer reader.deinit();
        // A query's partial stdout may explain its failure. Keep it out of
        // product stdout, and preserve it even when the child times out.
        errdefer log.writeMsg(self.io, reader.reader(0).buffered());
        while (reader.fill(256, .{ .deadline = expires.withClock(.awake) })) |_| {
            if (reader.reader(0).buffered().len > 1024 * 1024) return error.DockerOutputTooLarge;
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.Timeout => return error.DockerTimedOut,
            else => return err,
        }
        try reader.checkAnyError();
        const term = try wait(self.io, &child, expires);
        const output = try reader.toOwnedSlice(0);
        if (!term.success()) log.writeMsg(self.io, output);
        return .{ .term = term, .stdout = output };
    }

    pub fn query(self: Client, operands: []const []const u8) ![]const u8 {
        const result = try self.capture(operands);
        try self.checkTerm(operands, result.term);
        return std.mem.trim(u8, result.stdout, " \t\r\n");
    }

    pub fn run(self: Client, operands: []const []const u8, seconds: i64) !void {
        self.inheritOutput(operands, seconds) catch |err| {
            if (err != error.DockerCommandFailed)
                log.err(self.io, "{s}: {f}", .{ @errorName(err), Command{ .operands = operands } });
            return err;
        };
    }

    fn inheritOutput(self: Client, operands: []const []const u8, seconds: i64) !void {
        const expires = Io.Clock.awake.now(self.io).addDuration(.fromSeconds(seconds));
        var child = try std.process.spawn(self.io, .{
            .argv = try self.args(operands),
            .environ_map = self.environ,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        defer retire(self.io, &child);
        const term = try wait(self.io, &child, expires);
        try self.checkTerm(operands, term);
    }

    fn checkTerm(self: Client, operands: []const []const u8, term: std.process.Child.Term) !void {
        if (term.success()) return;
        log.err(self.io, "{f}: {f}", .{ term, Command{ .operands = operands } });
        return error.DockerCommandFailed;
    }

    pub fn composeArgs(self: Client, operands: []const []const u8) ![]const []const u8 {
        return std.mem.concat(self.gpa, []const u8, &.{ &.{
            "compose",                                                                           "--project-directory",                                               self.workspace,
            "-f",                                                                                try std.fs.path.join(self.gpa, &.{ self.workspace, "compose.yml" }), "-f",
            try std.fs.path.join(self.gpa, &.{ self.workspace, "docker-compose.override.yml" }),
        }, operands });
    }
};

const Command = struct {
    operands: []const []const u8,

    pub fn format(self: Command, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("docker");
        // Quote and escape each argument so paths with spaces and control
        // characters cannot make the diagnostic describe a different command.
        for (self.operands) |operand| try writer.print(" \"{f}\"", .{std.zig.fmtString(operand)});
    }
};

// One owner polls and reaps its POSIX child. Canceling a std child wait drops
// that handle; it is not a termination policy. Keeping the unreaped PID here
// also prevents it from being reused between the deadline and the kill.
fn wait(io: Io, child: *std.process.Child, expires: Io.Timestamp) !std.process.Child.Term {
    while (true) {
        var status: c_int = undefined;
        const result = posix.system.waitpid(child.id.?, &status, posix.W.NOHANG);
        switch (posix.errno(result)) {
            .SUCCESS => if (result != 0) {
                child.id = null;
                const value: u32 = @bitCast(status);
                if (posix.W.IFEXITED(value)) return .{ .exited = posix.W.EXITSTATUS(value) };
                if (posix.W.IFSIGNALED(value)) return .{ .signal = posix.W.TERMSIG(value) };
                return .{ .unknown = value };
            },
            .INTR => continue,
            .CHILD => {
                child.id = null;
                return error.ChildAlreadyReaped;
            },
            else => return error.ChildWaitFailed,
        }
        if (Io.Clock.awake.now(io).nanoseconds >= expires.nanoseconds) return error.DockerTimedOut;
        try Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

fn retire(io: Io, child: *std.process.Child) void {
    if (child.id) |pid| {
        // No other thread reaps this process. KILL also bounds cleanup when a
        // Docker client ignores TERM; no signal is sent to an already-reaped PID.
        posix.kill(pid, .KILL) catch |err| {
            if (err != error.ProcessNotFound) log.err(io, "could not terminate Docker process {d}: {s}", .{ pid, @errorName(err) });
        };
        var status: c_int = undefined;
        while (true) {
            const result = posix.system.waitpid(pid, &status, 0);
            if (posix.errno(result) != .INTR) break;
        }
        child.id = null;
    }
    if (child.stdin) |file| file.close(io);
    if (child.stdout) |file| file.close(io);
    if (child.stderr) |file| file.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}
