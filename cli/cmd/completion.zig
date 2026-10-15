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
        \\# glowcap bash completion: eval "$(glowcap completion bash)"
        \\_glowcap() {
        \\  local cur prev
        \\  COMPREPLY=()
        \\  cur="${COMP_WORDS[COMP_CWORD]}"
        \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\
        \\  local command_path
        \\  command_path="$(_glowcap_path "${COMP_WORDS[@]:1:$((COMP_CWORD-1))}")"
        \\
        \\  local cmds flags
        \\  cmds="$(_glowcap_cmds "$command_path")"
        \\  flags="$(_glowcap_flags "$command_path")"
        \\
        \\  if [[ "$cur" == -* ]]; then
        \\    COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        \\  else
        \\    COMPREPLY=( $(compgen -W "$cmds $flags" -- "$cur") )
        \\  fi
        \\}
        \\
    );
    try emitCaseTables(em, root, "complete -F _glowcap glowcap\n");
}

/// The `_glowcap_cmds` / `_glowcap_flags` case tables bash and zsh share. Only
/// the registration line at the tail differs per shell.
fn emitCaseTables(em: *Emitter, root: *const Command, register: []const u8) !void {
    try em.writeAll(
        \\# Follow declared children and skip option values, including values
        \\# that happen to be command names. Positional arguments keep the leaf.
        \\_glowcap_path() {
        \\  local command_path='' token child skip=0
        \\  for token in "$@"; do
        \\    if [ "$skip" = 1 ]; then skip=0; continue; fi
        \\    child="$(_glowcap_child "$command_path" "$token")"
        \\    if [ -n "$child" ]; then command_path="${command_path:+$command_path }$child"; continue; fi
        \\    case "$token" in
        \\      --) break ;;
        \\      --*=*) ;;
        \\      -*) if _glowcap_takes_value "$command_path" "$token"; then skip=1; fi ;;
        \\    esac
        \\  done
        \\  printf '%s\n' "$command_path"
        \\}
        \\_glowcap_child() {
        \\  case "$1|$2" in
        \\
    );
    try writeContextCases(em, root, &.{}, &.{root}, .child);
    try em.writeAll("  esac\n}\n_glowcap_takes_value() {\n  case \"$1|$2\" in\n");
    try writeContextCases(em, root, &.{}, &.{root}, .value);
    try em.writeAll("  esac\n  return 1\n}\n\n");
    try em.writeAll("_glowcap_cmds() {\n  case \"$*\" in\n");
    try writeCmdCases(em, root, &.{});
    try em.writeAll("  esac\n}\n\n");
    try em.writeAll("_glowcap_flags() {\n  case \"$*\" in\n");
    try writeFlagCases(em, root, &.{}, &.{root});
    try em.writeAll("  esac\n}\n\n");
    try em.writeAll(register);
}

fn emitZsh(em: *Emitter, root: *const Command) !void {
    // Both wrappers feed shell tokens to the same tree-derived context scanner.
    try em.writeAll(
        \\# glowcap zsh completion: eval "$(glowcap completion zsh)"
        \\#compdef glowcap
        \\_glowcap() {
        \\  local cur="${words[CURRENT]}"
        \\  local command_path
        \\  command_path="$(_glowcap_path "${words[@]:1:$((CURRENT-2))}")"
        \\  local cmds_str flags_str
        \\  cmds_str="$(_glowcap_cmds "$command_path")"
        \\  flags_str="$(_glowcap_flags "$command_path")"
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
    try emitCaseTables(em, root, "compdef _glowcap glowcap\n");
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

fn writeValueCase(em: *Emitter, key: []const u8, flag: types.Flag) !void {
    if (flag.kind != .string_flag) return;
    try em.writeFmt("    \"{s}|--{s}\") return 0 ;;\n", .{ key, flag.long });
    if (flag.short) |short| try em.writeFmt("    \"{s}|-{c}\") return 0 ;;\n", .{ key, short });
}

fn writeContextCases(em: *Emitter, cmd: *const Command, path: []const []const u8, nodes: []const *const Command, kind: enum { child, value }) !void {
    var key_buf: [256]u8 = undefined;
    const key = pathKey(path, &key_buf);
    switch (kind) {
        .child => for (cmd.children) |child| {
            if (child.hidden_from_help) continue;
            try em.writeFmt("    \"{s}|{s}\") echo \"{s}\" ;;\n", .{ key, child.name, child.name });
            for (child.aliases) |alias| try em.writeFmt("    \"{s}|{s}\") echo \"{s}\" ;;\n", .{ key, alias, child.name });
        },
        .value => {
            for (cmd.flags) |flag| try writeValueCase(em, key, flag);
            var flags: [48]types.Flag = undefined;
            var count: usize = 0;
            types.collectPersistent(nodes, &flags, &count);
            for (flags[0..count]) |flag| {
                if (!hasFlag(cmd.flags, flag.long)) try writeValueCase(em, key, flag);
            }
        },
    }
    var child_path: [12][]const u8 = undefined;
    var child_nodes: [12]*const Command = undefined;
    for (cmd.children) |*child| {
        if (child.hidden_from_help or path.len >= child_path.len or nodes.len >= child_nodes.len) continue;
        @memcpy(child_path[0..path.len], path);
        child_path[path.len] = child.name;
        @memcpy(child_nodes[0..nodes.len], nodes);
        child_nodes[nodes.len] = child;
        try writeContextCases(em, child, child_path[0 .. path.len + 1], child_nodes[0 .. nodes.len + 1], kind);
    }
}

fn writeFlagCases(em: *Emitter, cmd: *const Command, path: []const []const u8, nodes: []const *const Command) !void {
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
    var flags: [48]types.Flag = undefined;
    var count: usize = 0;
    types.collectPersistent(nodes, &flags, &count);
    for (flags[0..count]) |f| {
        if (hasFlag(cmd.flags, f.long)) continue;
        if (!first) try em.writeAll(" ");
        first = false;
        try em.writeFmt("--{s}", .{f.long});
    }
    if (!first) try em.writeAll(" ");
    try em.writeAll("--help");
    try em.writeAll("\" ;;\n");

    var child_path_buf: [12][]const u8 = undefined;
    var child_nodes: [12]*const Command = undefined;
    for (cmd.children) |*c| {
        if (c.hidden_from_help) continue;
        const n = path.len;
        if (n >= child_path_buf.len or nodes.len >= child_nodes.len) continue;
        @memcpy(child_path_buf[0..n], path);
        child_path_buf[n] = c.name;
        @memcpy(child_nodes[0..nodes.len], nodes);
        child_nodes[nodes.len] = c;
        try writeFlagCases(em, c, child_path_buf[0 .. n + 1], child_nodes[0 .. nodes.len + 1]);
    }
}

fn emitFish(em: *Emitter, root: *const Command) !void {
    try em.writeAll("# glowcap fish completion: glowcap completion fish | source\n");
    try em.writeAll("complete -c glowcap -f\n");
    try em.writeAll("complete -c glowcap -l help -s h -d 'Help'\n");
    try writeFishNode(em, root, &.{}, &.{root});
    try em.writeAll("\n");
}

/// One fish flag spec (` -l NAME -d 'HELP'`, plus ` -r` when it takes a value),
/// shared by local and inherited flags in each node's scope.
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

fn writeFishCondition(em: *Emitter, cmd: *const Command, path: []const []const u8) !void {
    try em.writeAll("complete -c glowcap -n '");
    if (path.len == 0) {
        try em.writeAll("__fish_use_subcommand");
    } else {
        for (path, 0..) |p, i| {
            if (i > 0) try em.writeAll("; and ");
            try em.writeFmt("__fish_seen_subcommand_from {s}", .{p});
        }
        // Parent options must stop matching once a child owns the scope.
        if (cmd.children.len > 0) {
            try em.writeAll("; and not __fish_seen_subcommand_from");
            for (cmd.children) |c| try em.writeFmt(" {s}", .{c.name});
        }
    }
    try em.writeAll("'");
}

fn writeFishNode(em: *Emitter, cmd: *const Command, path: []const []const u8, nodes: []const *const Command) !void {
    var help_buf: [256]u8 = undefined;
    for (cmd.children) |c| {
        if (c.hidden_from_help) continue;
        try writeFishCondition(em, cmd, path);
        try em.writeFmt(" -a '{s}' -d '{s}'\n", .{ c.name, fishEscape(c.short_help, &help_buf) });
    }
    for (cmd.flags) |f| {
        try writeFishCondition(em, cmd, path);
        try writeFishFlagSpec(em, f, &help_buf);
        try em.writeAll("\n");
    }
    var flags: [48]types.Flag = undefined;
    var count: usize = 0;
    types.collectPersistent(nodes, &flags, &count);
    for (flags[0..count]) |f| {
        if (hasFlag(cmd.flags, f.long)) continue;
        try writeFishCondition(em, cmd, path);
        try writeFishFlagSpec(em, f, &help_buf);
        try em.writeAll("\n");
    }

    var child_path_buf: [12][]const u8 = undefined;
    var child_nodes: [12]*const Command = undefined;
    for (cmd.children) |*c| {
        if (c.hidden_from_help) continue;
        const n = path.len;
        if (n >= child_path_buf.len or nodes.len >= child_nodes.len) continue;
        @memcpy(child_path_buf[0..n], path);
        child_path_buf[n] = c.name;
        @memcpy(child_nodes[0..nodes.len], nodes);
        child_nodes[nodes.len] = c;
        try writeFishNode(em, c, child_path_buf[0 .. n + 1], child_nodes[0 .. nodes.len + 1]);
    }
}
