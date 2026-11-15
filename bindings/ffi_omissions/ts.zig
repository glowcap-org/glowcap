//! The exports the TypeScript FFI table leaves out beyond those in
//! `shared.zig`, each with the reason for that decision. Signatures and row
//! order come from the C inventories.
//!
//! An entry is `.{ .name = "<export>", .reason = "<why>" }`. A generator
//! refuses a name with no export in its archives, a name more than one
//! archive declares, a name repeated here or in `shared.zig`, and an empty
//! reason, and its refusal names the entry and the file that holds it.

const pump_drain = "The TypeScript action loop pops each action through next_action. The hook pump drains actions for an embedder that installs C hooks.";
const release_on_drop = "The Host attaches no behavior to this setting, which records scope-end release for a binding like Rust. The TypeScript binding releases through finalizers with the per-session opt-in.";
const resolver_break = "An async behavior's failure breaks its deferred answer through resolver_abandon with the failure message. resolver_abandon also tolerates an answer its session already retired.";
const resolver_fulfill = "resolver_fulfill_value replaces it. It settles the resolver with plain data or capabilities.";
const turn_defer = "turn_defer_if_answer defers an answered call onto a one-shot resolver. It also lets a told async behavior run with none.";
const runtime_allocator = "A caller-supplied Context allocator for a relay runtime serves a C embedder. The TypeScript binding builds relay runtimes on the library allocator.";

pub const omissions = .{
    // host
    .{ .name = "glowcap_host_pump_drain", .reason = pump_drain },
    .{ .name = "glowcap_host_release_on_drop", .reason = release_on_drop },
    .{ .name = "glowcap_host_resolver_break", .reason = resolver_break },
    .{ .name = "glowcap_host_resolver_fulfill", .reason = resolver_fulfill },
    .{ .name = "glowcap_host_set_release_on_drop", .reason = release_on_drop },
    .{ .name = "glowcap_host_turn_defer", .reason = turn_defer },
    // net_transport/relay
    .{ .name = "glowcap_relay_runtime_new_in", .reason = runtime_allocator },
};
