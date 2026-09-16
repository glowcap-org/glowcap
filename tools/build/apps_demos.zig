//! The cross-language application demos beside rooms: the tasks board, the
//! tools (delegation/attenuation/revocation) demo, and the accountability
//! application with its three-party attribution test. The native clients
//! compile under `check`; the demos are siblings that need deno.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

const glowcapExecutable = common.glowcapExecutable;
const addInstalledSystemRun = common.addInstalledSystemRun;

pub fn register(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    check_step: *std.Build.Step,
    runtime_gate: *execution.RuntimeGate,
    pin_port: ?u16,
    attach: bool,
    demo_usage_mod: *std.Build.Module,
    demo_tools_check_mod: *std.Build.Module,
) void {
    // The tasks cross-language application demo: a capability-secure shared task
    // board with CRUD operations and live change notifications through capability
    // callbacks. One Zig-built native client plus the Deno server and
    // Deno/Python/Racket/Rust clients, all managing tasks on one board over TCP. Like
    // rooms, it needs `deno` (which hosts the board and runs the orchestrator)
    // and the Zig client, always built here. Python, Racket, and Rust join when their
    // runtimes are on PATH. It is a sibling step, not part of the hermetic gate.
    const tasks_client_exe = glowcapExecutable(b, lib_mod, target, optimize, "glowcap-tasks-client", "apps/tasks/zig/client.zig");
    tasks_client_exe.root_module.addImport("demo_usage", demo_usage_mod);
    check_step.dependOn(&tasks_client_exe.step);

    const tasks_demo = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno",               "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/tasks/demo.ts",
    });
    tasks_demo.addArtifactArg(tasks_client_exe);
    if (pin_port) |p| tasks_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) tasks_demo.addArg("--attach");
    const tasks_demo_step = b.step("demo-tasks", "Run the cross-language tasks board demo (needs deno; joins python3/racket/cargo clients when present)");
    tasks_demo_step.dependOn(&tasks_demo.step);

    const tasks_app_test = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno", "test", "apps/tasks/deno/containment_test.ts",
    });
    tasks_app_test.has_side_effects = true;
    const tasks_app_test_step = b.step("tasks-app-test", "Run the task board's bounded-state and lifecycle tests (needs deno)");
    tasks_app_test_step.dependOn(&tasks_app_test.step);
    runtime_gate.add(tasks_app_test_step);

    // The tools capability showcase: an AI-tool-harness shaped demo. A Deno
    // coordinator hands an agent capabilities to tools — attenuated to read-only,
    // and revocable — and each agent proves delegation, attenuation, and
    // revocation over an OCapN session on the `tcp` netlayer. The coordinator and agent are different languages
    // on the wire, so the capability trio is real, not in-process. It needs `deno`
    // (which hosts the coordinator and runs the orchestrator); Python, Racket,
    // and Rust agents join when their runtimes are on PATH. A sibling step, not
    // part of the hermetic gate.
    const tools_agent_exe = glowcapExecutable(b, lib_mod, target, optimize, "glowcap-tools-agent", "apps/tools/zig/agent.zig");
    tools_agent_exe.root_module.addImport("demo_tools_check", demo_tools_check_mod);
    tools_agent_exe.root_module.addImport("demo_usage", demo_usage_mod);
    check_step.dependOn(&tools_agent_exe.step);

    // The showcase's thesis — attenuation refuses the unsafe verb, revocation
    // severs the handle — is pure coordinator logic, so it is pinned hermetically
    // here rather than only by the off-gate cross-language demo (needs deno).
    const tools_app_test = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno", "test", "apps/tools/deno/capabilities_test.ts",
    });
    tools_app_test.has_side_effects = true;
    const tools_app_test_step = b.step("tools-app-test", "Pin the tools showcase's attenuation and revocation (needs deno)");
    tools_app_test_step.dependOn(&tools_app_test.step);
    runtime_gate.add(tools_app_test_step);

    const tools_demo = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno",               "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/tools/demo.ts",
    });
    tools_demo.addArtifactArg(tools_agent_exe); // the Zig agent's built path
    if (pin_port) |p| tools_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) tools_demo.addArg("--attach");
    const tools_demo_step = b.step("demo-tools", "Run the cross-language tools demo: delegation, attenuation, and revocation (needs deno; joins python3/racket/cargo agents when present)");
    tools_demo_step.dependOn(&tools_demo.step);

    // ── Accountability application ───────────────────────────────────────────
    // accountability-on-glowcap: a real worked application that runs ON glowcap's
    // own runtime. Two native glowcap peers complete an OCapN handshake over a
    // real loopback TCP socket; the host publishes an Affordance capability and
    // the caller invokes it, and every invocation produces a signed,
    // transparency-logged Episode attributing the attested caller. Identity
    // (KERI), Episodes, and the transparency log all live above glowcap, the app
    // imports the `glowcap` module and never reaches into the core. It needs no
    // extra language runtime, but it owns a real process and loopback socket, so
    // it rides `runtime-check` as an application contract below. The app source
    // lives under `apps/accountability-on-glowcap/`, beside
    // the other worked applications.
    const accountability_exe = glowcapExecutable(b, lib_mod, target, optimize, "accountability-on-glowcap", "apps/accountability-on-glowcap/zig/main.zig");
    const run_accountability = execution.addArtifact(b, .{ .deterministic = 30 }, accountability_exe);
    run_accountability.setCwd(b.path("."));
    run_accountability.has_side_effects = true;
    const accountability_step = b.step("accountability", "Run the accountability application on glowcap's own runtime over real TCP");
    accountability_step.dependOn(&run_accountability.step);
    // A runnable application is a contract, and this one owns a real loopback
    // socket, so `runtime-check` runs it. Its generated state stays under the
    // cache instead of the public demo's `.data/` path. The separate
    // three-party attribution proof below remains a self-contained Zig test in
    // `check`.
    const runtime_accountability = execution.addArtifact(b, .{ .deterministic = 30 }, accountability_exe);
    runtime_accountability.setCwd(b.path("."));
    runtime_accountability.has_side_effects = true;
    runtime_accountability.setEnvironmentVariable("GLOWCAP_ACCOUNTABILITY_DATA_ROOT", ".zig-cache/glowcap-accountability/runtime-check");
    runtime_gate.add(&runtime_accountability.step);

    // The cross-language accountability demo: the standalone Zig host (listens
    // on an ephemeral port and serves one connection per caller) driven by the
    // Deno orchestrator, which connects the Deno and Python callers over the
    // installed C ABI. The orchestrator receives the host binary's built path
    // as its argument; the host installs only for this step, not on every
    // default build.
    const host_exe = glowcapExecutable(b, lib_mod, target, optimize, "accountability-host", "apps/accountability-on-glowcap/zig/host.zig");
    const host_install = b.addInstallArtifact(host_exe, .{});
    const accountability_demo = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno",                                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/accountability-on-glowcap/deno/demo.ts",
    });
    accountability_demo.addArtifactArg(host_exe); // the Zig host's built path
    if (pin_port) |p| accountability_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) accountability_demo.addArg("--attach"); // the orchestrator rejects it: each caller needs a fresh host
    const accountability_demo_step = b.step("demo-accountability", "Run the cross-language accountability demo: Zig host + Deno/Python callers (needs deno)");
    accountability_demo_step.dependOn(&host_install.step);
    accountability_demo_step.dependOn(&accountability_demo.step);

    // The hand-rolled Blake3 the Deno caller derives its AID from must match the
    // Zig host's digest byte for byte, and the cross-language demo above is not
    // on the gate. Pin the primitive against known vectors here, which is (needs
    // deno).
    const accountability_blake3_test = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno", "test", "apps/accountability-on-glowcap/deno/blake3_test.ts",
    });
    accountability_blake3_test.has_side_effects = true;
    const accountability_blake3_step = b.step("accountability-blake3-test", "Pin the accountability app's Blake3 against known vectors (needs deno and python3)");
    accountability_blake3_step.dependOn(&accountability_blake3_test.step);
    runtime_gate.add(accountability_blake3_step);

    // The Python caller hand-rolls the same Blake3, with the same byte-agreement
    // requirement and the same off-gate demo, so its vectors are pinned too. Pure
    // Python, no dependency, so a bare python3 run serves.
    const accountability_blake3_py = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "python3", "apps/accountability-on-glowcap/python/blake3_test.py",
    });
    accountability_blake3_py.has_side_effects = true;
    accountability_blake3_step.dependOn(&accountability_blake3_py.step);

    // Three-party accountability proof: the production owning Host redeems a
    // live loopback-TCP handoff, then the exporter attributes the true caller
    // rather than the introducer.
    const three_party_mod = b.createModule(.{
        .root_source_file = b.path("apps/accountability-on-glowcap/zig/three_party_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    three_party_mod.addImport("glowcap", lib_mod);
    const three_party_test = b.addTest(.{
        .name = "accountability-three-party",
        .root_module = three_party_mod,
    });
    const run_three_party = execution.addZigTest(b, three_party_test, .unit_test);
    const three_party_step = b.step("accountability-three-party", "Run three-Host TCP handoff attribution");
    three_party_step.dependOn(&run_three_party.step);
    check_step.dependOn(&run_three_party.step);
}
