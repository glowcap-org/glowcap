//! Ban rows: layer purity — the clock seam, the actors layer, the README's C
//! verb names, unobserved-outcome caps, Goblins runtime portability, and
//! signature-arm reads.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

/// The monotonic clock is consolidated onto one seam, `src/net/clock.zig`, so a
/// component that reads wall-clock or monotonic time goes through it rather than
/// calling the OS clock by hand. A stray `clock_gettime` anywhere else in the
/// core silently reopens the drift the consolidation closed.
pub const clock_seam: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"}, .exclude = &.{"src/net/clock.zig"} } },
        .kind = .forbid,
        .needles = &.{"clock_gettime"},
        .check = "clock-seam",
        .why = "read monotonic time through src/net/clock.zig's seam (nowMonotonicMs/nowMs), never a hand-rolled clock_gettime",
    },
};

/// The V1.0 resolver descriptor (`resolve_me_desc`) is CapTP wire knowledge:
/// mapping a resolver-only deliver to the virtual answer the engine installed
/// is the engine's job, reached through `Peer.answerForDeliver`. The actor
/// layer must never decode it, because `actors` adds no CapTP semantics the
/// engine lacks (architecture rule). This holds the boundary the
/// `answerForDeliver` seam established, so the vat's old inline descriptor
/// walk cannot creep back.
pub const actors_layer_purity: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/actors", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"resolve_me_desc"},
        .check = "actors-layer-purity",
        .why = "the V1.0 resolver descriptor is CapTP wire knowledge; route a resolver-only deliver's answer through `Peer.answerForDeliver`, never by decoding resolve_me_desc in the actor layer (architecture: actors adds no CapTP semantics the engine lacks)",
    },
};

/// The host-session and host-turn C verbs are `pancake_host_session_*` and
/// `pancake_host_turn_*`. ADR-0079 retired the binding `Connection` concept, so
/// no `conn_*` export exists. A backticked `conn_` shorthand in the bindings
/// README names a symbol a C consumer cannot grep, so the drift fails here.
pub const readme_c_verb_names: []const Ban = &.{
    .{
        .where = .{ .file = "bindings/DEVELOPING.md" },
        .kind = .forbid,
        .needles = &.{"`conn_"},
        .check = "readme-c-verb-names",
        .why = "no `conn_*` C export exists (ADR-0079 retired the binding Connection concept); name the real `pancake_host_session_*` or `pancake_iroh_conn_*` verb a consumer can grep",
    },
};

/// The unobserved-outcome FIFO cap is one policy number the three async
/// bindings share, mirrored in the bindings README. It is a hand-repeated
/// literal with no C ABI constant to reflect, so this holds the four in
/// lockstep: bumping the cap fails here until every copy and the README move
/// together.
pub const unobserved_outcome_cap_rows: []const Ban = &.{
    .{
        .where = .{ .file = "bindings/ts/runtime/host.ts" },
        .kind = .require,
        .needles = &.{"MAX_UNOBSERVED_OUTCOMES = 1024"},
        .check = "unobserved-outcome-cap",
        .why = "the unobserved-outcome FIFO cap is 1024 across TS, Python, and Rust and the bindings README; move all four together",
    },
    .{
        .where = .{ .file = "bindings/rust/src/host.rs" },
        .kind = .require,
        .needles = &.{"MAX_UNOBSERVED_OUTCOMES: usize = 1024"},
        .check = "unobserved-outcome-cap",
        .why = "the unobserved-outcome FIFO cap is 1024 across TS, Python, and Rust and the bindings README; move all four together",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_host.py" },
        .kind = .require,
        .needles = &.{"_MAX_UNOBSERVED_OUTCOMES = 1024"},
        .check = "unobserved-outcome-cap",
        .why = "the unobserved-outcome FIFO cap is 1024 across TS, Python, and Rust and the bindings README; move all four together",
    },
    .{
        .where = .{ .file = "bindings/README.md" },
        .kind = .require,
        .needles = &.{"1024 in TypeScript, Python, and Rust"},
        .check = "unobserved-outcome-cap",
        .why = "the bindings README states the unobserved-outcome FIFO cap (1024); keep it in step with the three host constants",
    },
};

pub const goblins_runtime_portability: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "interop/goblins_interop",
            .suffixes = &.{ ".zig", ".py", ".rs", ".ts", ".rkt" },
        } },
        .kind = .forbid,
        // The class, not one spelling: /usr/bin, /usr/local/bin, and
        // /opt/homebrew/bin all end this way.
        .needles = &.{"/bin/racket"},
        .check = "Goblins runtime portability",
        .why = "live interop resolves `racket` through PATH; an absolute path pins one machine's layout",
    },
};

/// Every migrated table, run once per gate invocation.
/// A borrowed `Signature` is two arms because two codecs spell one value two
/// ways: Syrup carries the halves, Cap'n Proto the concatenation. Reading
/// either arm by name outside the type's own file is therefore a claim about
/// which codec decoded the frame, which no consumer of a codec-neutral view is
/// entitled to make, and the arm that is not active panics. `Signature.eql`
/// answers across arms without allocating; every comparison goes through it.
pub const signature_arm_reads: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "src",
            .suffixes = &.{".zig"},
            .exclude = &.{"src/ocapn/model/view_records.zig"},
        } },
        .kind = .forbid,
        .needles = &.{ "signature.raw", "signature.halves" },
        .check = "signature-arm-reads",
        .why = "compare borrowed signatures through `Signature.eql`, which is total across arms; naming an arm assumes a codec and panics on the other",
    },
};

/// The rooms app's shared contract (`apps/rooms/lib/`) is consumed by the
/// server, the web supervisor, the browser page, and the terminal clients
/// alike, so it may import none of them: a lib module reaching up drags a
/// whole process graph into every consumer (a server import in a module the
/// page touches rides into the browser bundle). Demo orchestration that
/// needs the server belongs in `apps/rooms/demos/`.
pub const rooms_lib_layer: []const Ban = &.{
    .{
        .where = .{ .tree = .{
            .dir = "apps/rooms/lib",
            .suffixes = &.{".ts"},
        } },
        .kind = .forbid,
        .needles = &.{ "from \"../server/", "from \"../web/", "from \"../demos/" },
        .check = "rooms-lib-layer",
        .why = "apps/rooms/lib is the shared contract every rooms consumer imports; it imports no server, web, or demo module",
    },
};
