//! The cross-language application demos beside rooms: the tasks board, the
//! tools (delegation/attenuation/revocation) demo, and the accountability
//! application with its three-party attribution test. The native clients
//! compile under `check`; the demos are siblings that need deno.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

const pancakeExecutable = common.pancakeExecutable;
const addInstalledSystemRun = common.addInstalledSystemRun;

pub fn register(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    check_step: *std.Build.Step,
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
    const tasks_client_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tasks-client", "apps/tasks/zig/client.zig");
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
    check_step.dependOn(tasks_app_test_step);

    // The tools capability showcase: an AI-tool-harness shaped demo. A Deno
    // coordinator hands an agent capabilities to tools — attenuated to read-only,
    // and revocable — and each agent proves delegation, attenuation, and
    // revocation over an OCapN session on the `tcp` netlayer. The coordinator and agent are different languages
    // on the wire, so the capability trio is real, not in-process. It needs `deno`
    // (which hosts the coordinator and runs the orchestrator); Python, Racket,
    // and Rust agents join when their runtimes are on PATH. A sibling step, not
    // part of the hermetic gate.
    const tools_agent_exe = pancakeExecutable(b, lib_mod, target, optimize, "pancake-tools-agent", "apps/tools/zig/agent.zig");
    tools_agent_exe.root_module.addImport("demo_tools_check", demo_tools_check_mod);
    tools_agent_exe.root_module.addImport("demo_usage", demo_usage_mod);
    check_step.dependOn(&tools_agent_exe.step);

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
    // accountability-on-pancake: a real worked application that runs ON pancake's
    // own runtime. Two native pancake peers complete an OCapN handshake over a
    // real loopback TCP socket; the host publishes an Affordance capability and
    // the caller invokes it, and every invocation produces a signed,
    // transparency-logged Episode attributing the attested caller. Identity
    // (KERI), Episodes, and the transparency log all live above pancake, the app
    // imports the `pancake` module and never reaches into the core. It needs no
    // extra runtime, so it rides the gate as an application contract (below). The
    // app source lives under `apps/accountability-on-pancake/`, beside
    // the other worked applications.
    const accountability_exe = pancakeExecutable(b, lib_mod, target, optimize, "accountability-on-pancake", "apps/accountability-on-pancake/zig/main.zig");
    const run_accountability = execution.addArtifact(b, .{ .deterministic = 30 }, accountability_exe);
    run_accountability.setCwd(b.path("."));
    run_accountability.has_side_effects = true;
    const accountability_step = b.step("accountability", "Run the accountability application on pancake's own runtime over real TCP");
    accountability_step.dependOn(&run_accountability.step);
    // The accountability application and its three-party attribution test are
    // Zig-hermetic (both use loopback TCP), so they ride the
    // gate: a runnable application is a contract the same way an example is. The
    // check run writes generated state under `.zig-cache` instead of the public
    // demo's `.data/` path, so the gate never dirties source files.
    const check_accountability = execution.addArtifact(b, .{ .deterministic = 30 }, accountability_exe);
    check_accountability.setCwd(b.path("."));
    check_accountability.has_side_effects = true;
    check_accountability.setEnvironmentVariable("PANCAKE_ACCOUNTABILITY_DATA_ROOT", ".zig-cache/pancake-accountability/check");
    check_step.dependOn(&check_accountability.step);

    // The cross-language accountability demo: the standalone Zig host (listens
    // on an ephemeral port and serves one connection per caller) driven by the
    // Deno orchestrator, which connects the Deno and Python callers over the
    // installed C ABI. The orchestrator receives the host binary's built path
    // as its argument; the host installs only for this step, not on every
    // default build.
    const host_exe = pancakeExecutable(b, lib_mod, target, optimize, "accountability-host", "apps/accountability-on-pancake/zig/host.zig");
    const host_install = b.addInstallArtifact(host_exe, .{});
    const accountability_demo = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno",                                        "run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-run", "--allow-env",
        "apps/accountability-on-pancake/deno/demo.ts",
    });
    accountability_demo.addArtifactArg(host_exe); // the Zig host's built path
    if (pin_port) |p| accountability_demo.addArg(b.fmt("--port={d}", .{p}));
    if (attach) accountability_demo.addArg("--attach"); // the orchestrator rejects it: each caller needs a fresh host
    const accountability_demo_step = b.step("demo-accountability", "Run the cross-language accountability demo: Zig host + Deno/Python callers (needs deno)");
    accountability_demo_step.dependOn(&host_install.step);
    accountability_demo_step.dependOn(&accountability_demo.step);

    // Three-party accountability proof: the production owning Host redeems a
    // live loopback-TCP handoff, then the exporter attributes the true caller
    // rather than the introducer.
    const three_party_mod = b.createModule(.{
        .root_source_file = b.path("apps/accountability-on-pancake/zig/three_party_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    three_party_mod.addImport("pancake", lib_mod);
    const three_party_test = b.addTest(.{
        .name = "accountability-three-party",
        .root_module = three_party_mod,
    });
    const run_three_party = execution.addZigTest(b, three_party_test, .{ .deterministic = 30 });
    const three_party_step = b.step("accountability-three-party", "Run three-Host TCP handoff attribution");
    three_party_step.dependOn(&run_three_party.step);
    check_step.dependOn(&run_three_party.step);
}
