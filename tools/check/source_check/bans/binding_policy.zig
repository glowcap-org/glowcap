//! Ban rows: generated binding policy mirrors.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// Native drain quantum exhaustion is scheduler progress, not a time delay.
/// Each async binding names its runtime's continuation primitive.
pub const runtime_progress_rows: []const Ban = &.{
    .{
        .where = .{ .files = &.{
            "bindings/python/glowcap/_host/progress.py",
            "bindings/racket/private/pump.rkt",
            "bindings/rust/src/host/progress.rs",
            "bindings/rust/src/driver_loop.rs",
            "bindings/ts/runtime/host/drive.ts",
        } },
        .kind = .forbid,
        .needles = &.{ "asyncio.sleep(0)", "(sleep 0)", "yield_now()", "setTimeout(resolve, 0)" },
        .check = "binding-runtime-progress",
        .why = "binding progress follows scheduler/readiness events; zero-duration sleeps, timers, and unstructured yields make timing part of correctness",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/_host/progress.py" },
        .kind = .require,
        .needles = &.{"loop.call_soon(resume)"},
        .check = "binding-runtime-progress",
        .why = "Python resumes a yielded native drain on an explicit asyncio loop callback",
    },
    .{
        .where = .{ .file = "bindings/racket/private/pump.rkt" },
        .kind = .require,
        .needles = &.{"(loop (call-in-nested-thread (drain-effects-resume current)))"},
        .check = "binding-runtime-progress",
        .why = "Racket joins yielded native work through an explicit nested-thread scheduler handoff",
    },
    .{
        .where = .{ .file = "bindings/rust/src/host/progress.rs" },
        .kind = .require,
        .needles = &.{"tokio::task::coop::consume_budget().await;"},
        .check = "binding-runtime-progress",
        .why = "Rust charges native drain batches to Tokio's cooperative task budget",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/host/drive.ts" },
        .kind = .require,
        .needles = &.{"const channel = new MessageChannel();"},
        .check = "binding-runtime-progress",
        .why = "TypeScript uses a real task source when scheduler.yield is unavailable instead of a zero-duration timer",
    },
};

/// The unobserved-outcome FIFO cap is one binding-policy number shared by the
/// three async bindings and mirrored in the bindings README. The value belongs
/// to `tools/gen/binding/policy.zig`, not the C ABI; generated mirrors carry it
/// into each binding, and this row keeps consumers from reintroducing literals.
pub const unobserved_outcome_cap_rows: []const Ban = &.{
    .{
        .where = .{ .file = "tools/gen/binding/policy.zig" },
        .kind = .require,
        .needles = &.{"pub const unobserved_outcome_cap: usize = 1024;"},
        .check = "unobserved-outcome-cap",
        .why = "the shared unobserved-outcome FIFO cap lives in binding_policy and reaches bindings through generated mirrors; change that owner, then regenerate the mirrors and doc values",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/host/state.ts" },
        .kind = .require,
        .needles = &.{"MAX_UNOBSERVED_OUTCOMES = BINDING_UNOBSERVED_OUTCOME_CAP"},
        .check = "unobserved-outcome-cap",
        .why = "TypeScript's Host vow table must consume the generated binding-policy cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/rust/src/host.rs" },
        .kind = .require,
        .needles = &.{"MAX_UNOBSERVED_OUTCOMES: usize = crate::abi_constants::BINDING_UNOBSERVED_OUTCOME_CAP"},
        .check = "unobserved-outcome-cap",
        .why = "Rust's Host vow table must consume the generated binding-policy cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/_host/vows.py" },
        .kind = .require,
        .needles = &.{"_MAX_UNOBSERVED_OUTCOMES = _abi.BINDING_UNOBSERVED_OUTCOME_CAP"},
        .check = "unobserved-outcome-cap",
        .why = "Python's Host vow table must consume the generated binding-policy cap instead of carrying its own literal",
    },
};

/// Binding readiness loops share one generated drain batch.
pub const readiness_drain_cap_rows: []const Ban = &.{
    .{
        .where = .{ .file = "tools/gen/binding/policy.zig" },
        .kind = .require,
        .needles = &.{"pub const readiness_drain_cap: usize = 64;"},
        .check = "readiness-drain-cap",
        .why = "the shared readiness drain batch lives in binding_policy and reaches bindings through generated mirrors",
    },
    .{
        .where = .{ .file = "bindings/ts/iroh/channel.ts" },
        .kind = .require,
        .needles = &.{"DRAIN_READY_CAP = BINDING_READINESS_DRAIN_CAP"},
        .check = "readiness-drain-cap",
        .why = "TypeScript's iroh readiness loop must consume the generated binding-policy cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/rust/src/iroh.rs" },
        .kind = .require,
        .needles = &.{"DRAIN_READY_CAP: usize = BINDING_READINESS_DRAIN_CAP"},
        .check = "readiness-drain-cap",
        .why = "Rust's iroh readiness loop must consume the generated binding-policy cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/_iroh_async.py" },
        .kind = .require,
        .needles = &.{"_DRAIN_READY_CAP = BINDING_READINESS_DRAIN_CAP"},
        .check = "readiness-drain-cap",
        .why = "Python's iroh readiness loop must consume the generated binding-policy cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/racket/private/iroh/runtime.rkt" },
        .kind = .require,
        .needles = &.{"(define DRAIN-READY-CAP BINDING-READINESS-DRAIN-CAP)"},
        .check = "readiness-drain-cap",
        .why = "Racket's iroh readiness loop must consume the generated binding-policy cap instead of carrying its own literal",
    },
};

/// Pending handoff dials borrow a Host-owned locator whose hint count is not a
/// binding policy. The Host C ABI reports the exact count, so bindings probe
/// with zero capacity before allocating rather than seeding a local guess.
pub const pending_dial_hint_probe_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/c_abi/host/host.zig" },
        .kind = .require,
        .needles = &.{"A null `hint_storage` with zero capacity probes the required"},
        .check = "pending-dial-hint-probe",
        .why = "glowcap_host_pending_dial owns the required hint count and documents the zero-capacity probe",
    },
    .{
        .where = .{ .file = "bindings/rust/src/dial.rs" },
        .kind = .require,
        .needles = &.{
            "let mut hints: Vec<sys::GlowcapLocatorHintView>;",
            "core::ptr::null_mut(),\n\t\t\t\t0,\n\t\t\t\t&mut view,\n\t\t\t\t&mut hint_count",
        },
        .check = "pending-dial-hint-probe",
        .why = "Rust asks the Host for the exact pending-dial hint count before allocating hint storage and keeps it alive through cloning",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/_dial.py" },
        .kind = .require,
        .needles = &.{
            "hints = None",
            "None,\n            0,\n            ctypes.byref(view),\n            ctypes.byref(count)",
        },
        .check = "pending-dial-hint-probe",
        .why = "Python asks the Host for the exact pending-dial hint count before allocating hint storage and keeps it alive through cloning",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/dial.ts" },
        .kind = .require,
        .needles = &.{
            "let hints: Uint8Array | null = null;",
            "null,\n\t\t\t0n,\n\t\t\tab(view),\n\t\t\tab(count)",
        },
        .check = "pending-dial-hint-probe",
        .why = "TypeScript asks the Host for the exact pending-dial hint count before allocating hint storage and keeps it alive through cloning",
    },
    .{
        .where = .{ .file = "bindings/racket/private/ffi-host.rkt" },
        .kind = .require,
        .needles = &.{
            "(glowcap_host_pending_dial* host ticket #f 0 view count)",
            "(glowcap_locator_clone view)",
        },
        .check = "pending-dial-hint-probe",
        .why = "Racket asks the Host for the exact pending-dial hint count before allocating hint storage and clones while it is live",
    },
    .{
        .where = .{ .files = &.{
            "bindings/rust/src/dial.rs",
            "bindings/python/glowcap/_dial.py",
            "bindings/ts/runtime/dial.ts",
            "bindings/racket/private/ffi-host.rkt",
        } },
        .kind = .forbid,
        .needles = &.{ "capacity = 8", "capacity = 4", "[capacity 4]" },
        .check = "pending-dial-hint-probe",
        .why = "pending-dial hint sizing comes from the C-reported required count, not a binding-local seed capacity",
    },
};

/// Binding-owned byte-stream transports share one read chunk size. The Host
/// owns framing and retained tails; bindings only choose the size of one
/// runtime read allocation.
pub const stream_read_chunk_rows: []const Ban = &.{
    .{
        .where = .{ .file = "tools/gen/binding/policy.zig" },
        .kind = .require,
        .needles = &.{"pub const stream_read_chunk_bytes: usize = 64 * 1024;"},
        .check = "stream-read-chunk",
        .why = "the shared binding byte-stream read batch lives in binding_policy and reaches bindings through generated mirrors",
    },
    .{
        .where = .{ .file = "bindings/rust/src/session_shared.rs" },
        .kind = .require,
        .needles = &.{"READ_CHUNK: usize = sys::BINDING_STREAM_READ_CHUNK_BYTES"},
        .check = "stream-read-chunk",
        .why = "Rust's byte-fed stream pump must consume the generated binding-policy chunk size instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/tcp.py" },
        .kind = .require,
        .needles = &.{"BINDING_STREAM_READ_CHUNK_BYTES"},
        .check = "stream-read-chunk",
        .why = "Python's TCP byte channel must consume the generated binding-policy chunk size instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/internal/ffi/adapters/deno.ts" },
        .kind = .require,
        .needles = &.{"new Uint8Array(BINDING_STREAM_READ_CHUNK_BYTES)"},
        .check = "stream-read-chunk",
        .why = "TypeScript's Deno byte channel must consume the generated binding-policy chunk size instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/racket/private/async.rkt" },
        .kind = .require,
        .needles = &.{"(make-bytes BINDING-STREAM-READ-CHUNK-BYTES)"},
        .check = "stream-read-chunk",
        .why = "Racket's TCP port byte channel must consume the generated binding-policy chunk size instead of carrying its own literal",
    },
    .{
        .where = .{ .files = &.{
            "bindings/rust/src/session_shared.rs",
            "bindings/python/glowcap/tcp.py",
            "bindings/ts/runtime/internal/ffi/adapters/deno.ts",
            "bindings/racket/private/async.rkt",
        } },
        .kind = .forbid,
        .needles = &.{ "READ_CHUNK: usize = 16 * 1024", "read(65536)", "Uint8Array(64 * 1024)", "make-bytes 65536" },
        .check = "stream-read-chunk",
        .why = "binding byte-stream readers use BINDING_STREAM_READ_CHUNK_BYTES, not local chunk-size literals",
    },
};

/// Iroh async bindings share one non-blocking read batch.
pub const iroh_read_chunk_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/c_abi/net_transport/iroh/mod.zig" },
        .kind = .require,
        .needles = &.{"pub const GLOWCAP_IROH_READ_CHUNK_BYTES: usize = iroh.read_chunk_bytes;"},
        .check = "iroh-read-chunk",
        .why = "the shared iroh read batch lives in iroh transport policy and reaches bindings through the C ABI mirror",
    },
    .{
        .where = .{ .file = "bindings/ts/iroh/channel.ts" },
        .kind = .require,
        .needles = &.{"READ_CHUNK = BINDING_IROH_READ_CHUNK_BYTES"},
        .check = "iroh-read-chunk",
        .why = "TypeScript's iroh byte channel must consume the generated binding-policy chunk size instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/_iroh_async.py" },
        .kind = .require,
        .needles = &.{"_READ_CHUNK_BYTES = BINDING_IROH_READ_CHUNK_BYTES"},
        .check = "iroh-read-chunk",
        .why = "Python's iroh byte channel must consume the generated binding-policy chunk size instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/racket/private/iroh/runtime.rkt" },
        .kind = .require,
        .needles = &.{"(define READ-CHUNK BINDING-IROH-READ-CHUNK-BYTES)"},
        .check = "iroh-read-chunk",
        .why = "Racket's iroh byte channel must consume the generated binding-policy chunk size instead of carrying its own literal",
    },
    .{
        .where = .{ .files = &.{
            "bindings/ts/iroh/channel.ts",
            "bindings/python/glowcap/_iroh_async.py",
            "bindings/racket/private/iroh/runtime.rkt",
        } },
        .kind = .forbid,
        .needles = &.{ "READ_CHUNK = 64 * 1024", "_READ_CHUNK = 65536", "(define READ-CHUNK 65536)" },
        .check = "iroh-read-chunk",
        .why = "iroh binding byte channels use BINDING_IROH_READ_CHUNK_BYTES, not local chunk-size literals",
    },
};

/// Binding trace producers share one default payload window. The C ABI owns
/// trace queue installation and borrowed event delivery; this generated
/// binding-policy constant only owns the host-language default for how many
/// frame bytes a producer forwards into the public trace event.
pub const trace_payload_cap_rows: []const Ban = &.{
    .{
        .where = .{ .file = "tools/gen/binding/policy.zig" },
        .kind = .require,
        .needles = &.{"pub const trace_payload_cap_bytes: usize = 4096;"},
        .check = "trace-payload-cap",
        .why = "the shared binding trace payload default lives in binding_policy and reaches bindings through generated mirrors",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/trace.ts" },
        .kind = .require,
        .needles = &.{"payloadCap = options?.payloadCap ?? BINDING_TRACE_PAYLOAD_CAP_BYTES"},
        .check = "trace-payload-cap",
        .why = "TypeScript's trace producer must consume the generated binding-policy payload cap default instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/rust/src/trace.rs" },
        .kind = .require,
        .needles = &.{"PAYLOAD_CAP: usize = BINDING_TRACE_PAYLOAD_CAP_BYTES"},
        .check = "trace-payload-cap",
        .why = "Rust's trace producer must consume the generated binding-policy payload cap default instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/python/glowcap/_trace.py" },
        .kind = .require,
        .needles = &.{"_PAYLOAD_CAP = _abi.BINDING_TRACE_PAYLOAD_CAP_BYTES"},
        .check = "trace-payload-cap",
        .why = "Python's trace producer must consume the generated binding-policy payload cap default instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/racket/private/trace.rkt" },
        .kind = .require,
        .needles = &.{"(define PAYLOAD-CAP BINDING-TRACE-PAYLOAD-CAP-BYTES)"},
        .check = "trace-payload-cap",
        .why = "Racket's trace producer must consume the generated binding-policy payload cap default instead of carrying its own literal",
    },
    .{
        .where = .{ .files = &.{
            "bindings/ts/runtime/trace.ts",
            "bindings/rust/src/trace.rs",
            "bindings/python/glowcap/_trace.py",
            "bindings/racket/private/trace.rkt",
        } },
        .kind = .forbid,
        .needles = &.{ "payloadCap = options?.payloadCap ?? 4096", "const PAYLOAD_CAP: usize = 4096", "_PAYLOAD_CAP = 4096", "(define PAYLOAD-CAP 4096)" },
        .check = "trace-payload-cap",
        .why = "binding trace producers use BINDING_TRACE_PAYLOAD_CAP_BYTES, not local payload-cap literals",
    },
};
