//! Materialize the declared layer DAG for a target and optimization mode.
const std = @import("std");
const arch_check = @import("../check/arch_check.zig");

pub fn create(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    o: std.builtin.OptimizeMode,
    table: []const arch_check.LayerSpec,
    expose_root: bool,
) []*std.Build.Module {
    const mods = b.allocator.alloc(*std.Build.Module, table.len) catch @panic("OOM");
    for (table, 0..) |spec, i| {
        // Out-of-graph rows (e.g. `c_abi_net_transport_iroh`) are claimed by arch-check for file
        // coverage and edge liveness but are not DAG participants, they link a
        // non-Zig sidecar and import an injected resident, so `irohAbiModule`
        // mints them. No graph row imports such a row, so the slot stays unread.
        if (!spec.graph) continue;
        const root_source = if (std.mem.endsWith(u8, spec.prefix, ".zig"))
            b.fmt("src/{s}", .{spec.prefix})
        else
            b.fmt("src/{s}mod.zig", .{spec.prefix});
        const create_options: std.Build.Module.CreateOptions = .{
            .root_source_file = b.path(root_source),
            .target = t,
            .optimize = o,
            .pic = true,
        };
        mods[i] = if (expose_root and std.mem.eql(u8, spec.name, "glowcap"))
            b.addModule("glowcap", create_options)
        else
            b.createModule(create_options);
        for (spec.imports) |edge| {
            const j = for (table[0..i], 0..) |prior, k| {
                if (std.mem.eql(u8, prior.name, edge)) break k;
            } else @panic("layer_table edge does not name an earlier row");
            mods[i].addImport(edge, mods[j]);
        }
    }
    return mods;
}
