//! Ban rows: the CapTP I/O spine vocabulary.

const bans = @import("../bans.zig");
const Ban = bans.Ban;
const Where = bans.Where;

const completion_loop_paths = &.{
    "src/net/completion/loop.zig",
    "src/net/completion/loop/affinity.zig",
    "src/net/completion/loop/configuration.zig",
    "src/net/completion/loop/driver.zig",
    "src/net/completion/loop/state.zig",
    "src/net/completion/loop/wake.zig",
    "src/net/completion/loop/connections/admission.zig",
    "src/net/completion/loop/connections/deadlines.zig",
    "src/net/completion/loop/connections/flow.zig",
    "src/net/completion/loop/connections/lifecycle.zig",
};

const iroh_paths = &.{
    "src/net/transport/iroh.zig",
    "src/net/transport/iroh/backend.zig",
    "src/net/transport/iroh/locators.zig",
    "src/net/transport/iroh/resident.zig",
    "src/net/transport/iroh/resolver.zig",
    "src/net/transport/iroh/sidecar.zig",
};

/// One CapTP I/O spine (the forbid half of `checkCaptpIoSpine`. Its
/// require-groups and walks stay bespoke in `source_check.zig`): no
/// reintroduced `BlockingHost`, `net.Loop` alias, dual `dialTcp`/`dialIroh`
/// Loop APIs, shared `ConnectTarget`, soft `@hasDecl(Backend` forks,
/// Bridge-owned dial grammar, socket-shaped Loop dial choreography, or OCapN
/// resolve on bare platform Backends.
pub const captp_io_spine_table: []const Ban = &.{
    .{
        // The owning host face (ADR-0018) lives here and *embeds* the one
        // `driver_core.Host`; what stays banned is the deleted `BlockingHost`
        // shape, a parallel multi-session type that duplicated the core.
        .where = .{ .file = "src/driver/host_runtime.zig" },
        .kind = .forbid,
        .needles = &.{"BlockingHost"},
        .check = "captp-io-spine",
        .why = "`BlockingHost` is deleted; the owning face embeds driver_core.Host (ADR-0018), never a parallel core",
    },
    .{
        .where = .{ .file = "src/driver/mod.zig" },
        .kind = .forbid,
        .needles = &.{"BlockingHost"},
        .check = "captp-io-spine",
        .why = "do not re-export `BlockingHost`; `driver.HostRuntime` serves many sessions over one Host",
    },
    .{
        .where = .{ .file = "src/net/mod.zig" },
        .kind = .forbid,
        .needles = &.{"pub const Loop ="},
        .check = "captp-io-spine",
        .why = "use `net.TcpLoop` or `completion.Loop(Backend)`, not a second concept named `Loop`",
    },
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "pairedGoblins", "Offer.goblins(" },
        .check = "profile-names",
        .why = "protocol profiles do not wear an implementation's name; use `pairedV1_0Syrup` / `Offer.v1_0Syrup`",
    },
    .{
        .where = .{ .tree = .{ .dir = "test", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "pairedGoblins", "Offer.goblins(" },
        .check = "profile-names",
        .why = "protocol profiles do not wear an implementation's name; use `pairedV1_0Syrup` / `Offer.v1_0Syrup`",
    },
    .{
        .where = .{ .tree = .{ .dir = "examples", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "pairedGoblins", "Offer.goblins(" },
        .check = "profile-names",
        .why = "protocol profiles do not wear an implementation's name; use `pairedV1_0Syrup` / `Offer.v1_0Syrup`",
    },
    .{
        .where = .{ .files = completion_loop_paths },
        .kind = .forbid,
        .needles = &.{"pub fn dialTcp"},
        .check = "captp-io-spine",
        .why = "Bridge-facing dial is `dialLocator`; Backend owns `startDial`",
    },
    .{
        .where = .{ .files = completion_loop_paths },
        .kind = .forbid,
        .needles = &.{"pub fn dialIroh"},
        .check = "captp-io-spine",
        .why = "Bridge-facing dial is `dialLocator`; Backend owns `startDial`",
    },
    .{
        .where = .{ .files = completion_loop_paths },
        .kind = .forbid,
        .needles = &.{"pub const ConnectTarget = union"},
        .check = "captp-io-spine",
        .why = "no shared ConnectTarget union; each Backend declares its own associated type",
    },
    .{
        .where = .{ .files = completion_loop_paths },
        .kind = .forbid,
        .needles = &.{"@hasDecl(Backend, \""},
        .check = "captp-io-spine",
        .why = "total Backend contract via `validateBackend`; no soft dial/shutdown optionality at call sites",
    },
    .{
        .where = .{ .files = completion_loop_paths },
        .kind = .forbid,
        .needles = &.{"openDialFd"},
        .check = "captp-io-spine",
        .why = "socket-shaped Loop dial choreography is gone; Backend.startDial owns dial start",
    },
    .{
        .where = .{ .files = completion_loop_paths },
        .kind = .forbid,
        .needles = &.{"abandonDialFd"},
        .check = "captp-io-spine",
        .why = "Backend.startDial owns cleanup on failed start; no Loop abandonDialFd",
    },
    .{
        .where = .{ .files = completion_loop_paths },
        .kind = .forbid,
        .needles = &.{"submitIrohConnect"},
        .check = "captp-io-spine",
        .why = "optional `@hasDecl(submitIrohConnect)` is gone; Backends implement `startDial`",
    },
    .{
        .where = .{ .files = completion_loop_paths },
        .kind = .forbid,
        .needles = &.{"pub fn dial(self"},
        .check = "captp-io-spine",
        .why = "only public dial verb is `dialLocator`; `fn dial` stays private (no ConnectTarget at the Loop boundary)",
    },
    .{
        .where = .{ .file = "src/net/transport/tcp.zig" },
        .kind = .forbid,
        .needles = &.{"pub fn resolveDialAddress"},
        .check = "captp-io-spine",
        .why = "TCP address grammar lives only in `tcp.DialResolver.resolve`",
    },
    .{
        .where = .{ .files = iroh_paths },
        .kind = .forbid,
        .needles = &.{"submitIrohConnect"},
        .check = "captp-io-spine",
        .why = "iroh dials through `DialResolver.resolve` + `startDial`, not a parallel connect verb",
    },
    .{
        .where = .{ .file = "src/net/completion/uring.zig" },
        .kind = .forbid,
        .needles = &.{"resolveConnectTarget"},
        .check = "captp-io-spine",
        .why = "platform Backend has no OCapN resolve. TCP resolve lives on `tcp.DialResolver`",
    },
    .{
        .where = .{ .file = "src/net/completion/kqueue.zig" },
        .kind = .forbid,
        .needles = &.{"resolveConnectTarget"},
        .check = "captp-io-spine",
        .why = "platform Backend has no OCapN resolve. TCP resolve lives on `tcp.DialResolver`",
    },
    .{
        .where = .{ .file = "src/net/completion/epoll.zig" },
        .kind = .forbid,
        .needles = &.{"resolveConnectTarget"},
        .check = "captp-io-spine",
        .why = "platform Backend has no OCapN resolve. TCP resolve lives on `tcp.DialResolver`",
    },
    .{
        .where = .{ .file = "src/net/completion/linux.zig" },
        .kind = .forbid,
        .needles = &.{"resolveConnectTarget"},
        .check = "captp-io-spine",
        .why = "platform Backend has no OCapN resolve. TCP resolve lives on `tcp.DialResolver`",
    },
    .{
        .where = .{ .file = "src/net/mod.zig" },
        .kind = .forbid,
        .needles = &.{"tcp_backend"},
        .check = "captp-io-spine",
        .why = "`TcpLoop` is `Loop(platform, tcp.DialResolver)`; no forwarding `tcp_backend` wrapper",
    },
    .{
        .where = .{ .files = iroh_paths },
        .kind = .forbid,
        .needles = &.{"@import(\"../stream_shim.zig\")"},
        .check = "captp-io-spine",
        .why = "iroh is its own module root under transport/; reach stream_shim via net.stream_shim (ADR-0011)",
    },
    .{
        .where = .{ .file = "src/net/mod.zig" },
        .kind = .forbid,
        .needles = &.{"@import(\"completion/tcp_keepalive.zig\")"},
        .check = "captp-io-spine",
        .why = "public Keepalive is net.socket / net.Keepalive — no second door into completion/",
    },
    .{
        .where = .{ .file = "src/net/transport/tcp.zig" },
        .kind = .forbid,
        .needles = &.{"@import(\"../completion/"},
        .check = "captp-io-spine",
        .why = "tcp netlayer reaches socket ops through net.socket, never completion/ internals",
    },
    .{
        .where = .{ .file = "src/net/transport/tcp/profile.zig" },
        .kind = .forbid,
        .needles = &.{"@import(\"../completion/"},
        .check = "captp-io-spine",
        .why = "the TCP profile residents reach socket ops through net.socket, never completion/ internals",
    },
    .{
        .where = .{ .files = iroh_paths },
        .kind = .forbid,
        .needles = &.{"@import(\"../completion/"},
        .check = "captp-io-spine",
        .why = "iroh netlayer reaches socket ops through net.socket, never completion/ internals",
    },
    .{
        .where = .{ .file = "src/driver/core/mod.zig" },
        .kind = .forbid,
        .needles = &.{"pub const gc ="},
        .check = "captp-io-spine",
        .why = "export emitStatelessAfter only; gc.zig stays Served-private",
    },
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .forbid,
        .needles = &.{"pub const HostAction"},
        .check = "captp-io-spine",
        .why = "HostAction lives on driver.core barrel, not Host type home",
    },
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .forbid,
        .needles = &.{"pub const CrossedHellos"},
        .check = "captp-io-spine",
        .why = "CrossedHellos lives on driver.core barrel, not Host type home",
    },
    .{
        .where = .{ .file = "src/ocapn/codec/dispatch.zig" },
        .kind = .forbid,
        .needles = &.{"pub const registry"},
        .check = "captp-io-spine",
        .why = "codec.registry is the authority; dispatch keeps it private",
    },
    .{
        .where = .{ .files = iroh_paths },
        .kind = .forbid,
        .needles = &.{"Backend.Locator"},
        .check = "captp-io-spine",
        .why = "Locator is module-level `iroh.DialResolver`, not nested on Backend",
    },
};
