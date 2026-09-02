//! External conformance pressure: the upstream OCapN suite against a
//! glowcap peer (TCP and onion), the pinned-source findings, Syrup corpus
//! parity through the upstream encoder, the `check-external` baseline that
//! bundles them with the live Goblins steps, and the hermetic C-ABI extract
//! matrix that stays inside `check`.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");
const goblins_build = @import("goblins.zig");

const glowcapExecutable = common.glowcapExecutable;

pub fn register(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    check_step: *std.Build.Step,
    pin_port: ?u16,
    goblins_reg: goblins_build.Registered,
) void {
    // ── External conformance pressure (siblings of `check`) ──────────────────
    // A glowcap peer the upstream OCapN test suite can dial: it serves the
    // canonical conformance swiss-nums over `tcp-testing-only`. The orchestrator
    // `run-against-glowcap.sh` starts it and runs the suite against it, pointing
    // the external authority back at glowcap. Not part of `check`; needs uv +
    // the suite submodule. The peer installs only for this step, not on every
    // default build.
    const ocapn_peer_exe = glowcapExecutable(b, lib_mod, target, optimize, "glowcap-ocapn-peer", "conformance/ocapn-conformance/glowcap_peer.zig");
    const ocapn_tcp_peer_options = b.addOptions();
    ocapn_tcp_peer_options.addOption(bool, "use_onion", false);
    ocapn_peer_exe.root_module.addOptions("ocapn_peer_options", ocapn_tcp_peer_options);
    // The peer is pure Zig over the glowcap API; running the suite needs uv, but
    // compiling the peer does not, so it rides `check`. A core-API change that
    // breaks this consumer then fails fast on `zig build check` rather than only
    // under the uv-driven ocapn-conformance sibling.
    check_step.dependOn(&ocapn_peer_exe.step);
    const ocapn_conformance = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "conformance/ocapn-conformance/run-against-glowcap.sh", "--peer" });
    ocapn_conformance.addArtifactArg(ocapn_peer_exe);
    ocapn_conformance.setCwd(b.path("."));
    ocapn_conformance.has_side_effects = true;
    // The run above takes the peer's path directly, so it needs no install.
    // The install still happens, as a dependency of this step rather than of
    // `install`, because the wrapper is also run by hand for one module at a
    // time (conformance/ocapn-conformance/README.md) and that path finds the
    // peer at its installed default.
    const ocapn_peer_install = b.addInstallArtifact(ocapn_peer_exe, .{});
    ocapn_conformance.step.dependOn(&ocapn_peer_install.step);
    if (pin_port) |p| ocapn_conformance.addArg(b.fmt("--port={d}", .{p}));
    const ocapn_conformance_step = b.step("ocapn-conformance", "Run portable upstream OCapN modules plus the strict abort probe against glowcap (needs uv + the ocapn-conformance submodule)");
    ocapn_conformance_step.dependOn(&ocapn_conformance.step);

    // Dedicated upstream pressure over the standardized onion netlayer.
    // Glowcap uses the operator-configured Tor; the pinned suite owns its own
    // Tor through its upstream OnionNetlayer. The harness starts the glowcap
    // peer but never replaces the foreign implementation. This remains opt-in
    // because it needs Tor and live network access.
    const ocapn_onion_peer_exe = glowcapExecutable(b, lib_mod, target, optimize, "glowcap-ocapn-onion-peer", "conformance/ocapn-conformance/glowcap_peer.zig");
    const ocapn_onion_peer_options = b.addOptions();
    ocapn_onion_peer_options.addOption(bool, "use_onion", true);
    ocapn_onion_peer_exe.root_module.addOptions("ocapn_peer_options", ocapn_onion_peer_options);
    const ocapn_conformance_onion = execution.addSystemCommand(b, .real_internet, &.{ "bash", "conformance/ocapn-conformance/run-against-glowcap-onion.sh", "--peer" });
    ocapn_conformance_onion.addArtifactArg(ocapn_onion_peer_exe);
    ocapn_conformance_onion.setCwd(b.path("."));
    ocapn_conformance_onion.has_side_effects = true;
    const ocapn_conformance_onion_step = b.step("ocapn-conformance-onion", "Run the upstream OCapN suite against glowcap over an operator-supplied Tor (needs uv + external Tor + network)");
    ocapn_conformance_onion_step.dependOn(&ocapn_conformance_onion.step);

    // Reproduce neutral discrepancies across the exact OCapN spec, suite, and
    // Goblins revisions pinned here. Unlike a prose watch item, the comparison
    // fails on a pin bump until the observation is re-evaluated.
    const ocapn_findings = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "sh", "conformance/ocapn-findings/check.sh" });
    ocapn_findings.setCwd(b.path("."));
    const ocapn_findings_step = b.step("ocapn-findings-check", "Reproduce neutral protocol discrepancies across the pinned OCapN spec, suite, and Goblins sources");
    ocapn_findings_step.dependOn(&ocapn_findings.step);

    // Regenerate the Syrup fixture corpus through the upstream Racket Syrup
    // encoder and byte-compare it against the committed corpus, so
    // generator/corpus drift fails loud instead of rotting silently. A sibling
    // step (needs racket + the syrup collection), not part of the hermetic
    // check; a deliberate corpus change regenerates with
    // `racket test/oracle/generate.rkt test/oracle/corpus`.
    const fixture_gen = execution.addSystemCommand(b, .build_tool, &.{"racket"});
    fixture_gen.addFileArg(b.path("test/oracle/generate.rkt"));
    const fixture_gen_out = fixture_gen.addOutputDirectoryArg("generated-fixtures");
    const fixture_diff = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "diff", "-r" });
    fixture_diff.addDirectoryArg(b.path("test/oracle/corpus"));
    fixture_diff.addDirectoryArg(fixture_gen_out);
    const fixture_gen_check_step = b.step("fixture-gen-check", "Regenerate Syrup fixtures via the upstream Racket Syrup encoder and diff against the committed corpus (needs racket + syrup)");
    fixture_gen_check_step.dependOn(&fixture_diff.step);

    // The core external protocol baseline, in one step.
    //
    // `check` is deliberately hermetic: it needs no network or live external
    // authority. Its small host tool set is declared by `check_runtimes`
    // above; CLI tests link the trap-on-use iroh stub, so Cargo and its cache
    // stay outside this gate. A green `check` still proves only that glowcap
    // agrees with glowcap. These
    // are the baseline that can contradict it — the upstream OCapN suite, a live
    // Goblins vat in both handoff roles, the pinned-source finding checks, and
    // the upstream Syrup encoder re-deriving the committed corpus. Run this
    // before believing a protocol claim; the checks workflow runs
    // `ci/gates.sh` on main-branch pushes and pull requests.
    const check_external_step = b.step("check-external", "Run the core external protocol baseline: upstream OCapN suite, pinned-source findings, native Goblins both directions, every handoff role, both foreign-promise listener directions, the hinted-locator give, and Syrup corpus parity (needs uv + racket + goblins)");
    check_external_step.dependOn(ocapn_conformance_step);
    check_external_step.dependOn(ocapn_findings_step);
    check_external_step.dependOn(goblins_reg.interop_step);
    check_external_step.dependOn(goblins_reg.handoff_step);
    check_external_step.dependOn(goblins_reg.gift_step);
    check_external_step.dependOn(goblins_reg.gift_hints_step);
    check_external_step.dependOn(goblins_reg.relayed_give_step);
    check_external_step.dependOn(goblins_reg.listen_recipient_step);
    check_external_step.dependOn(goblins_reg.exporter_step);
    check_external_step.dependOn(fixture_gen_check_step);

    // Hermetic C-ABI extract refuse matrix (ADR-0077): zip-slip / symlink
    // fixtures against each resolve port's hard-fail hygiene. `tar` is
    // required; optional language runtimes exercise their production
    // validators when present and name each skipped port. It remains in
    // `check` because a soft-green extract is a footgun.
    const c_abi_extract = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/c-abi/c-abi-extract-matrix.sh" });
    c_abi_extract.setCwd(b.path("."));
    const c_abi_extract_check_step = b.step("c-abi-extract-check", "Hermetic C-ABI extract hygiene matrix: refuse zip-slip/symlink, accept clean lib/ (ADR-0077)");
    c_abi_extract_check_step.dependOn(&c_abi_extract.step);
    check_step.dependOn(c_abi_extract_check_step);
}
