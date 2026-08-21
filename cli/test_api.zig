//! Test-facing re-exports so hermetic CLI tests import one module root.
pub const registry = @import("registry.zig");
pub const exit_codes = @import("exit_codes.zig");
pub const argv = @import("argv.zig");
pub const ctx = @import("ctx.zig");
pub const ocapn = @import("ocapn/mod.zig");
pub const signals = @import("operability/signals.zig");
pub const state_lock = @import("operability/state_lock.zig");
pub const xdg = @import("operability/xdg.zig");
pub const identity = @import("operability/identity.zig");
pub const log = @import("operability/log.zig");
pub const mcp = @import("mcp/mod.zig");
pub const mcp_schema = @import("mcp/schema.zig");
pub const rooms_peer_shim = @import("rooms_peer_shim.zig");
pub const rooms_peer = @import("app/rooms_peer.zig");
pub const rooms_peer_harness = @import("app/rooms_peer/harness.zig");
pub const rooms_peer_common = @import("app/rooms_peer/common.zig");
pub const rooms_peer_phase = @import("app/rooms_peer/phase.zig");
pub const rooms_peer_wire = @import("app/rooms_peer/wire.zig");
pub const cmd = @import("cmd/mod.zig");
pub const cmd_types = @import("cmd/types.zig");
pub const cmd_help = @import("cmd/help.zig");
pub const cmd_completion = @import("cmd/completion.zig");
pub const tree = @import("cmd/tree.zig");
pub const griddle_sim = @import("griddle/sim.zig");
pub const ocapn_listen_background = @import("ocapn/listen_background.zig");
pub const repl = @import("repl/mod.zig");
pub const repl_complete = @import("repl/complete.zig");
pub const repl_meta = @import("repl/meta.zig");
pub const repl_copy = @import("repl/copy.zig");
pub const repl_teach = @import("repl/teach.zig");
pub const repl_layout = @import("repl/layout.zig");
pub const repl_blocks = @import("repl/blocks.zig");
pub const repl_links = @import("repl/links.zig");
pub const repl_ecs = @import("repl/ecs/mod.zig");
pub const repl_exec = @import("repl/exec.zig");
pub const repl_history = @import("repl/history.zig");
pub const repl_await_queue = @import("repl/await_queue.zig");
pub const repl_select = @import("repl/select.zig");
pub const repl_flash = @import("repl/flash.zig");
const iroh_sidecar_stub = @import("iroh_sidecar_stub");

comptime {
    // The `cli/` sources carry unit tests, and Zig only collects tests from
    // files it actually analyzes. A `pub const` nothing references is not
    // analyzed, so those tests were never in any binary: a test asserting
    // `false` inside `cli/repl/` passed the whole step. Naming the files that
    // carry tests is what puts them in one. `zig build cli-test` roots this
    // file for exactly that.
    _ = repl_blocks;
    _ = repl_history;
    _ = repl_links;
    _ = repl_select;
    _ = repl_ecs;
    // CLI tests cover registry and orchestration without opening iroh. Link the
    // trap-on-use sidecar test double so this hermetic root needs no Cargo
    // cache; any accidental live iroh call fails at its exact boundary.
    _ = iroh_sidecar_stub;
}
