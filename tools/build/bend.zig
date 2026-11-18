//! Formal laws and their Zig comparisons run only under explicit proof steps.
const std = @import("std");
const execution = @import("execution.zig");

const Import = struct { name: []const u8, module: *std.Build.Module };

pub fn register(b: *std.Build, foundation: *std.Build.Module, records: *std.Build.Module, syrup: *std.Build.Module) void {
    const proofs = b.step("bend-proofs", "Check Bend laws and compare them with Zig (run through .devcontainer/bin/tools.sh exec bend --)");
    const policy = b.step("loam-policy-proof", "Prove Loam policy intersection and attenuation (run through .devcontainer/bin/tools.sh exec bend --)");
    addBook(b, policy, "test/loam/access/policy_laws/PROOF.bend");
    const native_policy = b.createModule(.{ .root_source_file = b.path("src/loam/access/core/policy.zig") });
    addComparison(b, policy, "test/loam/access/policy_laws/bounds/table.bend", "test/loam/access/policy_laws/bounds/table_test.zig", &.{.{ .name = "policy", .module = native_policy }});
    proofs.dependOn(policy);
    addBook(b, proofs, "test/loam/core/record_laws/PROOF.bend");
    addComparison(b, proofs, "test/loam/core/record_laws/table.bend", "test/loam/core/record_laws/table_test.zig", &.{
        .{ .name = "loam_records", .module = records },
        .{ .name = "syrup", .module = syrup },
    });
    addBook(b, proofs, "test/codec/capnp_laws/PROOF.bend");
    const wire = b.createModule(.{ .root_source_file = b.path("src/ocapn/codec/capnp/wire.zig") });
    wire.addImport("foundation", foundation);
    addComparison(b, proofs, "test/codec/capnp_laws/table.bend", "test/codec/capnp_laws/table_test.zig", &.{.{ .name = "wire", .module = wire }});
}

fn addBook(b: *std.Build, step: *std.Build.Step, proof: []const u8) void {
    const run = command(b, proof);
    run.addArg("--verdict");
    step.dependOn(&run.step);
}

fn addComparison(b: *std.Build, step: *std.Build.Step, table: []const u8, test_file: []const u8, imports: []const Import) void {
    const expected = command(b, table);
    const native = b.createModule(.{ .root_source_file = b.path(test_file), .target = b.graph.host });
    for (imports) |dep| native.addImport(dep.name, dep.module);
    // Always-run captures share an output directory. Give each table its own file.
    const capture_name = b.allocator.dupe(u8, table) catch @panic("OOM");
    std.mem.replaceScalar(u8, capture_name, '/', '-');
    native.addAnonymousImport("bend_table", .{ .root_source_file = expected.captureStdOut(.{ .basename = capture_name }) });
    step.dependOn(&execution.addZigTest(b, b.addTest(.{ .root_module = native }), .unit_test).step);
}

fn command(b: *std.Build, file: []const u8) *std.Build.Step.Run {
    const run = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"bend"});
    run.addFileArg(b.path(file));
    execution.showOutput(run);
    return run;
}
