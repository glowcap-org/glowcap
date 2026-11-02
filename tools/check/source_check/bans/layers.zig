//! Ban rows: layer purity, the clock seam, the actors layer, the Rooms
//! library layer, Goblins runtime portability, and signature-arm reads.

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
/// is the engine's job, carried by `Event.deliverAnswerTarget`. The actor
/// layer must never decode it, because `actors` adds no CapTP semantics the
/// engine lacks (architecture rule). This holds the boundary the
/// exact answer-target seam established, so the vat's old inline descriptor
/// walk cannot creep back.
pub const actors_layer_purity: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src/actors", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"resolve_me_desc"},
        .check = "actors-layer-purity",
        .why = "the resolver descriptor is CapTP wire knowledge; use `Event.deliverAnswerTarget` for its exact reply incarnation, never decode resolve_me_desc in the actor layer (architecture: actors adds no CapTP semantics the engine lacks)",
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
/// answers across arms without allocating. Every comparison goes through it.
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
