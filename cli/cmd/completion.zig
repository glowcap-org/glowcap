//! Shell completion scripts derived from the command tree.
const std = @import("std");
const types = @import("types.zig");
const argv = @import("../argv.zig");

const Command = types.Command;

pub const Shell = enum { bash, zsh, fish };

pub fn parseShell(name: []const u8) ?Shell {
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "zsh")) return .zsh;
    if (std.mem.eql(u8, name, "fish")) return .fish;
    return null;
}

const Emitter = struct {
    gpa: ?std.mem.Allocator = null,
    list: ?*std.ArrayList(u8) = null,
    io: ?std.Io = null,

    fn writeAll(self: *Emitter, bytes: []const u8) !void {
        if (self.list) |list| {
            try list.appendSlice(self.gpa.?, bytes);
            return;
        }
        try argv.writeStdout(self.io.?, bytes);
    }

    fn writeFmt(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(msg);
    }
};

/// Emit a completion script for `shell` rooted at `root` to stdout.
pub fn emit(io: std.Io, root: *const Command, shell: Shell) !void {
    var em = Emitter{ .io = io };
    try emitWith(&em, root, shell);
}

/// Hermetic: emit into an owned slice (tests; avoids Zig test `--listen=-` stdout).
pub fn emitAlloc(gpa: std.mem.Allocator, root: *const Command, shell: Shell) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var em = Emitter{ .gpa = gpa, .list = &list };
    try emitWith(&em, root, shell);
    return try list.toOwnedSlice(gpa);
}

fn emitWith(em: *Emitter, root: *const Command, shell: Shell) !void {
    switch (shell) {
        .bash => try emitBash(em, root),
        .zsh => try emitZsh(em, root),
        .fish => try emitFish(em, root),
    }
}

fn emitBash(em: *Emitter, root: *const Command) !void {
    try em.writeAll(
        \\# pancake bash completion — eval "$(pancake completion bash)"
        \\_pancake() {
        \\  local cur prev
        \\  COMPREPLY=()
        \\  cur="${COMP_WORDS[COMP_CWORD]}"
        \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\
        \\  local path=()
        \\  local i
        \\  for ((i=1; i<COMP_CWORD; i++)); do
        \\    case "${COMP_WORDS[i]}" in
        \\      -*) ;;
        \\      *) path+=("${COMP_WORDS[i]}") ;;
        \\    esac
        \\  done
        \\
        \\  local cmds flags
        \\  cmds="$(_pancake_cmds "${path[@]}")"
        \\  flags="$(_pancake_flags "${path[@]}")"
        \\
        \\  if [[ "$cur" == -* ]]; then
        \\    COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        \\  else
        \\    COMPREPLY=( $(compgen -W "$cmds $flags" -- "$cur") )
        \\  fi
        \\}
        \\
    );
    try em.writeAll("_pancake_cmds() {\n  case \"$*\" in\n");
    try writeCmdCases(em, root, &.{});
    try em.writeAll("  esac\n}\n\n");
    try em.writeAll("_pancake_flags() {\n  case \"$*\" in\n");
    try writeFlagCases(em, root, &.{});
    try em.writeAll("  esac\n}\n\ncomplete -F _pancake pancake\n");
}

fn emitZsh(em: *Emitter, root: *const Command) !void {
    // Same tree-derived case tables as bash; zsh wrapper builds the path from $words.
    try em.writeAll(
        \\# pancake zsh completion — eval "$(pancake completion zsh)"
        \\#compdef pancake
        \\_pancake() {
        \\  local cur="${words[CURRENT]}"
        \\  local -a path
        \\  local i
        \\  for (( i=2; i<CURRENT; i++ )); do
        \\    case "${words[i]}" in
        \\      -*) ;;
        \\      *) path+=("${words[i]}") ;;
        \\    esac
        \\  done
        \\  local cmds_str flags_str
        \\  cmds_str="$(_pancake_cmds "${path[@]}")"
        \\  flags_str="$(_pancake_flags "${path[@]}")"
        \\  local -a cmds flags
        \\  cmds=(${=cmds_str})
        \\  flags=(${=flags_str})
        \\  if [[ "$cur" == -* ]]; then
        \\    compadd -- $flags
        \\  else
        \\    compadd -- $cmds $flags
        \\  fi
        \\}
        \\
    );
    try em.writeAll("_pancake_cmds() {\n  case \"$*\" in\n");
    try writeCmdCases(em, root, &.{});
    try em.writeAll("  esac\n}\n\n");
    try em.writeAll("_pancake_flags() {\n  case \"$*\" in\n");
    try writeFlagCases(em, root, &.{});
    try em.writeAll("  esac\n}\n\ncompdef _pancake pancake\n");
}

fn pathKey(parts: []const []const u8, buf: []u8) []const u8 {
    if (parts.len == 0) return "";
    var n: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            if (n >= buf.len) break;
            buf[n] = ' ';
            n += 1;
        }
        const take = @min(p.len, buf.len - n);
        @memcpy(buf[n .. n + take], p[0..take]);
        n += take;
    }
    return buf[0..n];
}

fn writeCmdCases(em: *Emitter, cmd: *const Command, path: []const []const u8) !void {
    var key_buf: [256]u8 = undefined;
    const key = pathKey(path, &key_buf);
    try em.writeAll("    \"");
    try em.writeAll(key);
    try em.writeAll("\") echo \"");
    var first = true;
    for (cmd.children) |c| {
        if (c.hidden_from_help) continue;
        if (!first) try em.writeAll(" ");
        first = false;
        try em.writeAll(c.name);
    }
    try em.writeAll("\" ;;\n");

    var child_path_buf: [12][]const u8 = undefined;
    for (cmd.children) |*c| {
        if (c.hidden_from_help) continue;
        if (c.isLeaf()) continue;
        const n = path.len;
        if (n >= child_path_buf.len) continue;
        @memcpy(child_path_buf[0..n], path);
        child_path_buf[n] = c.name;
        try writeCmdCases(em, c, child_path_buf[0 .. n + 1]);
    }
}

fn writeFlagCases(em: *Emitter, cmd: *const Command, path: []const []const u8) !void {
    var key_buf: [256]u8 = undefined;
    const key = pathKey(path, &key_buf);

    try em.writeAll("    \"");
    try em.writeAll(key);
    try em.writeAll("\") echo \"");
    var first = true;
    var saw_json = false;
    var saw_plain = false;
    var saw_identity = false;
    for (cmd.flags) |f| {
        if (!first) try em.writeAll(" ");
        first = false;
        try em.writeFmt("--{s}", .{f.long});
        if (std.mem.eql(u8, f.long, "json")) saw_json = true;
        if (std.mem.eql(u8, f.long, "plain")) saw_plain = true;
        if (std.mem.eql(u8, f.long, "identity")) saw_identity = true;
    }
    if (!saw_json) {
        if (!first) try em.writeAll(" ");
        try em.writeAll("--json");
        first = false;
    }
    if (!saw_plain) {
        if (!first) try em.writeAll(" ");
        try em.writeAll("--plain");
        first = false;
    }
    if (!saw_identity) {
        if (!first) try em.writeAll(" ");
        try em.writeAll("--identity");
        first = false;
    }
    if (!first) try em.writeAll(" ");
    try em.writeAll("--help");
    try em.writeAll("\" ;;\n");

    var child_path_buf: [12][]const u8 = undefined;
    for (cmd.children) |*c| {
        if (c.hidden_from_help) continue;
        const n = path.len;
        if (n >= child_path_buf.len) continue;
        @memcpy(child_path_buf[0..n], path);
        child_path_buf[n] = c.name;
        try writeFlagCases(em, c, child_path_buf[0 .. n + 1]);
    }
}

fn emitFish(em: *Emitter, root: *const Command) !void {
    try em.writeAll("# pancake fish completion — pancake completion fish | source\n");
    try em.writeAll("complete -c pancake -f\n");
    try em.writeAll("complete -c pancake -l json -d 'JSON output'\n");
    try em.writeAll("complete -c pancake -l plain -d 'Human output'\n");
    try em.writeAll("complete -c pancake -l identity -d 'Identity seed path' -r\n");
    try em.writeAll("complete -c pancake -l help -s h -d 'Help'\n");
    try writeFishNode(em, root, &.{});
    try em.writeAll("\n");
}

fn fishEscape(s: []const u8, buf: []u8) []const u8 {
    // Fish -d '...' : strip single quotes from help text.
    var n: usize = 0;
    for (s) |c| {
        if (c == '\'') continue;
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn writeFishNode(em: *Emitter, cmd: *const Command, path: []const []const u8) !void {
    var help_buf: [256]u8 = undefined;
    if (path.len == 0) {
        for (cmd.children) |c| {
            if (c.hidden_from_help) continue;
            const d = fishEscape(c.short_help, &help_buf);
            try em.writeFmt("complete -c pancake -n '__fish_use_subcommand' -a '{s}' -d '{s}'\n", .{ c.name, d });
        }
    } else if (cmd.children.len > 0 or cmd.flags.len > 0) {
        try em.writeAll("complete -c pancake -n '");
        for (path, 0..) |p, i| {
            if (i > 0) try em.writeAll("; and ");
            try em.writeFmt("__fish_seen_subcommand_from {s}", .{p});
        }
        try em.writeAll("'");
        for (cmd.children) |c| {
            if (c.hidden_from_help) continue;
            const d = fishEscape(c.short_help, &help_buf);
            try em.writeFmt(" -a '{s}' -d '{s}'", .{ c.name, d });
        }
        for (cmd.flags) |f| {
            const d = fishEscape(f.help, &help_buf);
            if (f.kind == .string_flag) {
                try em.writeFmt(" -l {s} -d '{s}' -r", .{ f.long, d });
            } else {
                try em.writeFmt(" -l {s} -d '{s}'", .{ f.long, d });
            }
        }
        try em.writeAll("\n");
    }

    var child_path_buf: [12][]const u8 = undefined;
    for (cmd.children) |*c| {
        if (c.hidden_from_help) continue;
        const n = path.len;
        if (n >= child_path_buf.len) continue;
        @memcpy(child_path_buf[0..n], path);
        child_path_buf[n] = c.name;
        try writeFishNode(em, c, child_path_buf[0 .. n + 1]);
    }
}
