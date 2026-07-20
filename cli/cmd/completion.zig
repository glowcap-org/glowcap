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

const Emitter = union(enum) {
    stdout: std.Io,
    list: struct { gpa: std.mem.Allocator, out: *std.ArrayList(u8) },

    fn writeAll(self: *Emitter, bytes: []const u8) !void {
        switch (self.*) {
            .stdout => |io| try argv.writeStdout(io, bytes),
            .list => |sink| try sink.out.appendSlice(sink.gpa, bytes),
        }
    }

    fn writeFmt(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(msg);
    }
};

/// Emit a completion script for `shell` rooted at `root` to stdout.
pub fn emit(io: std.Io, root: *const Command, shell: Shell) !void {
    var em = Emitter{ .stdout = io };
    try emitWith(&em, root, shell);
}

/// Hermetic: emit into an owned slice (tests; avoids Zig test `--listen=-` stdout).
pub fn emitAlloc(gpa: std.mem.Allocator, root: *const Command, shell: Shell) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var em = Emitter{ .list = .{ .gpa = gpa, .out = &list } };
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
    try emitCaseTables(em, root, "complete -F _pancake pancake\n");
}

/// The `_pancake_cmds` / `_pancake_flags` case tables bash and zsh share; only
/// the registration line at the tail differs per shell.
fn emitCaseTables(em: *Emitter, root: *const Command, register: []const u8) !void {
    try em.writeAll("_pancake_cmds() {\n  case \"$*\" in\n");
    try writeCmdCases(em, root, &.{});
    try em.writeAll("  esac\n}\n\n");
    try em.writeAll("_pancake_flags() {\n  case \"$*\" in\n");
    try writeFlagCases(em, root, &.{}, root.flags);
    try em.writeAll("  esac\n}\n\n");
    try em.writeAll(register);
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
    try emitCaseTables(em, root, "compdef _pancake pancake\n");
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

fn hasFlag(flags: []const types.Flag, long: []const u8) bool {
    for (flags) |f| {
        if (std.mem.eql(u8, f.long, long)) return true;
    }
    return false;
}

fn writeFlagCases(em: *Emitter, cmd: *const Command, path: []const []const u8, root_flags: []const types.Flag) !void {
    var key_buf: [256]u8 = undefined;
    const key = pathKey(path, &key_buf);

    try em.writeAll("    \"");
    try em.writeAll(key);
    try em.writeAll("\") echo \"");
    var first = true;
    for (cmd.flags) |f| {
        if (!first) try em.writeAll(" ");
        first = false;
        try em.writeFmt("--{s}", .{f.long});
    }
    // Persistent root flags apply at every node; derived, so a new one lands
    // in completion the same day it lands in `root_flags`.
    for (root_flags) |f| {
        if (!f.persistent) continue;
        if (hasFlag(cmd.flags, f.long)) continue;
        if (!first) try em.writeAll(" ");
        first = false;
        try em.writeFmt("--{s}", .{f.long});
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
        try writeFlagCases(em, c, child_path_buf[0 .. n + 1], root_flags);
    }
}

fn emitFish(em: *Emitter, root: *const Command) !void {
    var help_buf: [256]u8 = undefined;
    try em.writeAll("# pancake fish completion — pancake completion fish | source\n");
    try em.writeAll("complete -c pancake -f\n");
    // Persistent root flags are emitted once, unguarded, so fish offers them in
    // every context; per-node lines below carry only the node's own flags.
    // Derived, so a new persistent flag lands here the day it lands in the tree.
    for (root.flags) |f| {
        if (!f.persistent) continue;
        try em.writeAll("complete -c pancake");
        try writeFishFlagSpec(em, f, &help_buf);
        try em.writeAll("\n");
    }
    try em.writeAll("complete -c pancake -l help -s h -d 'Help'\n");
    try writeFishNode(em, root, &.{});
    try em.writeAll("\n");
}

/// One fish flag spec (` -l NAME -d 'HELP'`, plus ` -r` when it takes a value),
/// shared by the global persistent lines and the per-node lines.
fn writeFishFlagSpec(em: *Emitter, f: types.Flag, help_buf: []u8) !void {
    const d = fishEscape(f.help, help_buf);
    if (f.kind == .string_flag) {
        try em.writeFmt(" -l {s} -d '{s}' -r", .{ f.long, d });
    } else {
        try em.writeFmt(" -l {s} -d '{s}'", .{ f.long, d });
    }
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
            try writeFishFlagSpec(em, f, &help_buf);
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
